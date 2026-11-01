#!/usr/bin/env python3
import argparse
from collections import deque
import json
import os
from pathlib import Path
import queue
import resource
import subprocess
import sys
import threading
import time
import uuid


def send(value):
    print(json.dumps(value, separators=(',', ':')), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--socket', required=True)
    parser.add_argument('--tmux', required=True)
    parser.add_argument('--session', default='s0')
    parser.add_argument('--mode', choices=['watch', 'poll'], default='watch')
    parser.add_argument('--fallback-seconds', type=float, default=5)
    parser.add_argument('--status-sessions', choices=['attached', 'all'], default='attached')
    args = parser.parse_args()
    if 'TMUX' in os.environ or 'TMUX_PANE' in os.environ:
        raise RuntimeError('Remove TMUX and TMUX_PANE before this prototype starts')
    root = Path(os.environ['TMUX_TMPDIR']).resolve()
    if not Path(args.socket).resolve().is_relative_to(root):
        raise RuntimeError('The socket must be inside TMUX_TMPDIR')
    helper_path = Path(__file__).parent / '.build/release/InventoryProbe'
    helper = subprocess.Popen([str(helper_path), args.tmux, args.socket], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True, bufsize=1)
    control = None
    events = queue.Queue()
    counters = dict(calls=0, tmux_bytes=0, tmux_lines=0, control_bytes=0, control_lines=0,
                    subscriptions=0, reads=0, errors=0)
    module = str(uuid.uuid4())
    revision = 0
    previous = {}

    def inventory_command(arguments=None):
        helper.stdin.write(json.dumps({} if arguments is None else {'arguments': arguments}) + '\n')
        helper.stdin.flush()
        result = json.loads(helper.stdout.readline())
        for name in ('calls', 'tmux_bytes', 'tmux_lines'):
            counters[name] = result[name]
        if 'error' in result:
            raise RuntimeError(result['error'])
        return result

    def publish(request=None):
        nonlocal previous, revision
        failure = None
        if request is not None:
            try:
                target = request['target']
                if request['op'] == 'mark_read':
                    command = ['set-option', '-pqu', '-t', target, '@muxify_agent_unread']
                elif request['op'] == 'select_window':
                    command = ['select-window', '-t', target]
                else:
                    raise ValueError('Unknown request')
                inventory_command(command)
            except (RuntimeError, KeyError, ValueError) as error:
                failure = str(error)
                counters['errors'] += 1
        counters['reads'] += 1
        try:
            state = inventory_command()['state']
            state['connection'] = 'connected'
        except RuntimeError as error:
            state = dict(previous, connection='read_failed')
            if request is not None and failure is None:
                failure = str(error)
                counters['errors'] += 1
        changed = {key: value for key, value in state.items() if previous.get(key) != value}
        removed = sorted(previous.keys() - state.keys())
        if revision == 0 or changed or removed or request is not None or args.mode == 'poll':
            revision += 1
            if request is not None:
                send(dict(type='reply', module=module, revision=revision, id=request.get('id'), error=failure))
            full = revision == 1 or args.mode == 'poll'
            send(dict(type='full' if full else 'delta', version=1, module=module,
                      revision=revision, values=state if full else changed, removed=[] if full else removed))
            previous = state

    def read_control():
        for line in control.stdout:
            counters['control_bytes'] += len(line.encode())
            counters['control_lines'] += 1
            if line.startswith('%subscription-changed'):
                counters['subscriptions'] += 1
            if line.startswith('%') and not line.startswith((
                    '%begin', '%end', '%error', '%output', '%extended-output', '%exit')):
                events.put(('event', None))
            elif line.startswith('%error'):
                events.put(('fatal', 'Control command failed'))
        events.put(('fatal', 'Control client stopped'))

    def read_requests():
        for line in sys.stdin:
            try:
                events.put(('request', json.loads(line)))
            except ValueError as error:
                events.put(('fatal', str(error)))
        events.put(('eof', None))

    try:
        control = subprocess.Popen([args.tmux, '-S', args.socket, '-C', 'attach-session',
                                    '-f', 'no-output,ignore-size', '-t', args.session],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
        if args.mode == 'watch':
            # A subscription's scope is the attached Session, but an S: loop in its format reaches every Session.
            subscription = ('status:%*:#{@muxify_agent_status}' if args.status_sessions == 'attached'
                            else 'status::#{S:#{W:#{P:#{pane_id}=#{@muxify_agent_status};}}}')
            control.stdin.write(f'refresh-client -B "{subscription}"\n')
            control.stdin.flush()
        threading.Thread(target=read_control, daemon=True).start()
        threading.Thread(target=read_requests, daemon=True).start()
        publish()
        interval = 1.0 if args.mode == 'poll' else args.fallback_seconds
        deadline = time.monotonic() + interval
        deferred = deque()
        while True:
            try:
                kind, value = deferred.popleft() if deferred else events.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                kind, value = 'timer', None
            if kind == 'eof':
                break
            if kind == 'fatal':
                raise RuntimeError(value)
            if kind == 'event':
                pending = []
                while True:
                    try:
                        event = events.get_nowait()
                        if event[0] != 'event':
                            pending.append(event)
                    except queue.Empty:
                        break
                deferred.extend(pending)
            publish(value if kind == 'request' else None)
            if kind == 'timer' or time.monotonic() >= deadline:
                deadline = time.monotonic() + interval
    finally:
        if control is not None:
            control.stdin.close()
            try:
                control.wait(timeout=3)
            except subprocess.TimeoutExpired:
                control.terminate()
                control.wait(timeout=3)
        helper.stdin.close()
        helper.wait(timeout=3)
        own = resource.getrusage(resource.RUSAGE_SELF)
        children = resource.getrusage(resource.RUSAGE_CHILDREN)
        counters['reader_cpu_seconds'] = own.ru_utime + own.ru_stime
        counters['child_cpu_seconds'] = children.ru_utime + children.ru_stime
        counters['cpu_seconds'] = counters['reader_cpu_seconds'] + counters['child_cpu_seconds']
        counters['calls'] += 1
        send(dict(type='metrics', **counters))


if __name__ == '__main__':
    main()
