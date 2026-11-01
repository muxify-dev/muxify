#!/usr/bin/env python3
import argparse
import copy
import json
import math
import os
from pathlib import Path
import platform
import queue
import resource
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
TMUX = shutil.which('tmux')


def reap(process):
    deadline = time.monotonic() + 5
    while True:
        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            return usage.ru_utime + usage.ru_stime
        if time.monotonic() > deadline:
            raise TimeoutError(f'Process {process.pid} did not exit')
        time.sleep(.01)


class Reader:
    def __init__(self, command, env, mirrors=1):
        self.messages = queue.Queue()
        self.bytes = self.lines = self.sent_bytes = self.sent_lines = 0
        self.states = [{} for _ in range(mirrors)]
        self.revision = 0
        self.observed = time.perf_counter()
        self.module = None
        self.replies = {}
        self.metrics = None
        self.process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, bufsize=1)
        self.thread = threading.Thread(target=self.receive, daemon=True)
        self.thread.start()

    def receive(self):
        for line in self.process.stdout:
            self.messages.put((time.perf_counter(), line))
        self.messages.put((time.perf_counter(), None))

    def next(self, timeout=8):
        timestamp, line = self.messages.get(timeout=timeout)
        if line is None:
            raise RuntimeError('Reader exited: ' + self.process.stderr.read())
        self.bytes += len(line.encode())
        self.lines += 1
        message = json.loads(line)
        kind = message['type']
        if kind in ('full', 'delta'):
            assert message['version'] == 1
            assert message['revision'] == self.revision + 1
            assert self.module in (None, message['module'])
            self.module = message['module']
            self.revision = message['revision']
            self.observed = timestamp
            for state in self.states:
                if kind == 'full':
                    state.clear()
                state.update(copy.deepcopy(message['values']))
                for key in message['removed']:
                    state.pop(key)
            for request in self.replies.values():
                if 'revision' in request and not request.get('checked') and self.revision >= request['revision']:
                    assert self.revision == request['revision'], 'The first state missed its request revision'
                    assert request['predicate'](self.states[0]), request
                    request['checked'] = True
                    request['seen'] = timestamp
        elif kind == 'reply':
            request = self.replies[message['id']]
            assert bool(message['error']) == request['failure'], message
            assert message['module'] == self.module
            request['revision'] = message['revision']
        elif kind == 'metrics':
            self.metrics = message
        return timestamp

    def until(self, predicate, timeout=8):
        deadline = time.perf_counter() + timeout
        while not predicate():
            self.next(max(.01, deadline - time.perf_counter()))
            if time.perf_counter() > deadline:
                raise TimeoutError('State did not show the requested value')
        return self.observed

    def request(self, op, target, predicate, failure=False):
        ident = str(len(self.replies))
        self.replies[ident] = dict(predicate=predicate, failure=failure)
        line = json.dumps(dict(id=ident, op=op, target=target)) + '\n'
        start = time.perf_counter()
        self.process.stdin.write(line)
        self.process.stdin.flush()
        self.sent_bytes += len(line.encode())
        self.sent_lines += 1
        self.until(lambda: self.replies[ident].get('checked'))
        return (self.replies[ident]['seen'] - start) * 1000

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.until(lambda: self.metrics is not None)
        self.process_cpu = reap(self.process)
        self.thread.join(timeout=5)
        assert self.process.returncode == 0, self.process.stderr.read()
        return self.metrics

    def abort(self):
        if self.process.poll() is None:
            if not self.process.stdin.closed:
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)


def server_cpu(pid):
    minutes, seconds = subprocess.check_output(['ps', '-o', 'time=', '-p', str(pid)], text=True).split(':')
    return int(minutes) * 60 + float(seconds)


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def trial(mode, count, remote, cycles):
    root = Path(tempfile.mkdtemp(prefix='muxify-env-watch-', dir='/tmp'))
    socket = root / 'server'
    env = dict(os.environ, TMUX_TMPDIR=str(root), SHELL='/bin/sh')
    env.pop('TMUX', None)
    env.pop('TMUX_PANE', None)
    readers = []

    def tmux(*args):
        return subprocess.run([TMUX, '-S', str(socket), *args], env=env, check=True,
                              capture_output=True, text=True).stdout.strip()

    try:
        panes, windows = [], []
        for session in range(3):
            for window in range(4):
                create = ['new-session', '-d', '-s', f's{session}'] if window == 0 else [
                    'new-window', '-d', '-t', f's{session}']
                fixture = tmux('-f', '/dev/null', *create, '-P', '-F', '#{pane_id} #{window_id}', 'sleep 600')
                pane, wid = fixture.split()
                panes.append(pane)
                windows.append(wid)
                tmux('split-window', '-d', '-t', wid, 'sleep 600')
                tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude')
                tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', 'done')
                tmux('set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')
        command = [sys.executable, str(HERE / 'watch.py'), '--socket', str(socket),
                   '--tmux', TMUX, '--mode', 'poll' if mode == 'poll' else 'watch',
                   '--fallback-seconds', '1' if mode == 'watch_1s' else '5',
                   '--status-sessions', 'all' if mode == 'watch_all' else 'attached']
        master = None
        if remote:
            master = subprocess.Popen(['ssh', '-M', '-S', str(root / 'ssh'), '-o', 'ControlPersist=no',
                                       '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', '-N', 'localhost'],
                                      env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 5
            while not (root / 'ssh').exists():
                if master.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('SSH master failed')
                time.sleep(.02)
            remote_command = ['env', '-u', 'TMUX', '-u', 'TMUX_PANE', f'TMUX_TMPDIR={root}', *command]
            command = ['ssh', '-S', str(root / 'ssh'), '-o', 'BatchMode=yes', 'localhost', shlex.join(remote_command)]
        server_pid = int(tmux('display-message', '-p', '#{pid}'))
        server_start = server_cpu(server_pid)
        cpu_start = resource.getrusage(resource.RUSAGE_SELF)
        started = time.perf_counter()
        for _ in range(count if mode == 'poll' else 1):
            reader = Reader(command, env, mirrors=count if mode != 'poll' else 1)
            readers.append(reader)
            reader.until(lambda: reader.revision > 0)
        latency, attached = [], []
        for index in range(cycles):
            cycle_start = time.perf_counter()
            status = 'working' if index % 2 == 0 else 'done'
            change_start = time.perf_counter()
            tmux('set-option', '-p', '-t', panes[0], '@muxify_agent_status', status)
            for reader in readers:
                seen = reader.until(lambda r=reader: r.states[0][f'pane:{panes[0]}']['status'] == status)
                attached.append((seen - change_start) * 1000)
            tmux('set-option', '-p', '-t', panes[0], '@muxify_agent_unread', '1')
            writer = readers[0]
            read_predicate = lambda state: not state[f'pane:{panes[0]}']['unread']
            latency.append(writer.request('mark_read', panes[0], read_predicate))
            target = windows[1 + index % 2]
            selected = lambda state: state[f'window:$0:{target}']['active']
            latency.append(writer.request('select_window', target, selected))
            for reader in readers[1:]:
                reader.until(lambda r=reader: read_predicate(r.states[0]) and selected(r.states[0]))
            time.sleep(max(0, 1.5 - (time.perf_counter() - cycle_start)))
        time.sleep(1.2)
        for reader in readers:
            while not reader.messages.empty():
                reader.next()
        change_start = time.perf_counter()
        tmux('set-option', '-p', '-t', panes[4], '@muxify_agent_status', 'blocked')
        other = []
        for reader in readers:
            seen = reader.until(lambda r=reader: r.states[0][f'pane:{panes[4]}']['status'] == 'blocked')
            other.append((seen - change_start) * 1000)
        writer = readers[0]
        writer.request('mark_read', panes[0], lambda state: not state[f'pane:{panes[0]}']['unread'])
        writer.request('select_window', '@999999', lambda state: not state[f'pane:{panes[0]}']['unread'], failure=True)
        time.sleep(max(0, cycles * 1.5 + 14 - (time.perf_counter() - started)))
        for reader in readers:
            reader.process.stdin.close()
        metrics = [reader.close() for reader in readers]
        if mode != 'poll':
            assert all(item['subscriptions'] > 0 for item in metrics), metrics
        cpu_end = resource.getrusage(resource.RUSAGE_SELF)
        server_used = server_cpu(server_pid) - server_start
        result = dict(mode=mode, readers=count, remote=remote, duration=time.perf_counter() - started,
                      request_ms=latency, attached_ms=attached, other_ms=other,
                      client_cpu=cpu_end.ru_utime + cpu_end.ru_stime - cpu_start.ru_utime - cpu_start.ru_stime,
                      pipe_bytes=sum(r.bytes + r.sent_bytes for r in readers),
                      pipe_lines=sum(r.lines + r.sent_lines for r in readers),
                      expected_failures=sum(m['errors'] for m in metrics), metrics=metrics,
                      server_cpu=server_used, cleanup=False, transport_cpu=sum(r.process_cpu for r in readers) if remote else 0)
        assert result['expected_failures'] == 1
        result.update({key: sum(m[key] for m in metrics) for key in metrics[0] if key != 'type'})
        return result
    finally:
        cleanup_errors = []
        for reader in readers:
            try:
                reader.abort()
            except Exception as error:
                cleanup_errors.append(str(error))
        if 'master' in locals() and master is not None:
            try:
                master.terminate()
                master_cpu = reap(master)
                if 'result' in locals():
                    result['transport_cpu'] += master_cpu
            except Exception as error:
                cleanup_errors.append(str(error))
        if socket.exists():
            actual = Path(tmux('display-message', '-p', '#{socket_path}')).resolve()
            assert actual.is_relative_to(root.resolve()), actual
            server_pid = int(tmux('display-message', '-p', '#{pid}'))
            tmux('kill-server')
            deadline = time.monotonic() + 5
            while True:
                try:
                    os.kill(server_pid, 0)
                except ProcessLookupError:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError(f'Throwaway server {server_pid} did not exit')
                time.sleep(.02)
        if 'result' in locals():
            result['cleanup'] = True
        shutil.rmtree(root)
        if cleanup_errors:
            raise RuntimeError('; '.join(cleanup_errors))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--cycles', type=int, default=4)
    parser.add_argument('--output', type=Path, default=HERE / 'measurements.json')
    args = parser.parse_args()
    subprocess.run(['swift', 'build', '-c', 'release', '--package-path', str(HERE)], check=True,
                   stdout=sys.stderr)
    ssh = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                          '-o', 'ConnectTimeout=3', 'localhost', 'true'], capture_output=True, text=True)
    cases = [('poll', 1, False), ('watch', 1, False), ('watch_1s', 1, False), ('watch_all', 1, False),
             ('poll', 2, False), ('watch', 2, False), ('watch_all', 2, False)]
    if ssh.returncode == 0:
        cases += [('watch', 1, True), ('watch_all', 1, True)]
    evidence = dict(machine=platform.platform(), cores=os.cpu_count(), load=os.getloadavg(),
                    tmux=subprocess.check_output([TMUX, '-V'], text=True).strip(),
                    ssh=ssh.stderr.strip() if ssh.returncode else 'available', runs=[])
    for repeat in range(args.repeats):
        for case in cases if repeat % 2 == 0 else reversed(cases):
            print(f'Run {repeat + 1}: {case}', file=sys.stderr, flush=True)
            result = trial(*case, args.cycles)
            evidence['runs'].append(result)
            args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    headers = ['Case', 'CPU s median [range]', 'tmux server CPU s median', 'tmux starts', 'tmux output bytes', 'Protocol bytes', 'Protocol lines',
               'Request p50/p95 ms', 'Status attached p50/p95 ms', 'Status other p50/p95 ms']
    table = ['| ' + ' | '.join(headers) + ' |', '| ' + ' | '.join(['---'] * len(headers)) + ' |']
    for mode, readers, remote in cases:
        runs = [r for r in evidence['runs'] if (r['mode'], r['readers'], r['remote']) == (mode, readers, remote)]
        cpu = [r['cpu_seconds'] + r['client_cpu'] + r['transport_cpu'] for r in runs]
        row = [f'{mode} {readers} ' + ('SSH' if remote else 'Local'),
               f'{statistics.median(cpu):.3f} [{min(cpu):.3f}, {max(cpu):.3f}]',
               f"{statistics.median(r['server_cpu'] for r in runs):.3f}"]
        row += [str(round(statistics.median(r[key] for r in runs))) for key in ('calls', 'tmux_bytes', 'pipe_bytes', 'pipe_lines')]
        for key in ('request_ms', 'attached_ms', 'other_ms'):
            values = [v for r in runs for v in r[key]]
            row.append(f'{percentile(values, .50):.1f} / {percentile(values, .95):.1f}')
        table.append('| ' + ' | '.join(row) + ' |')
    print('\n'.join(table))
    args.output.with_suffix('.md').write_text('\n'.join(table) + '\n')
    print('SSH: ' + evidence['ssh'], file=sys.stderr)


if __name__ == '__main__':
    main()
