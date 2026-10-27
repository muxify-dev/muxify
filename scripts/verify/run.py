"""Runs verify suites side by side, judges each check, keeps the evidence, and runs the gate.

    python3 -m scripts.verify.run [--repeat N] [--shuffle] [suite ...]

Without a suite it runs every suite in suites/. A run of every suite is a full run. Each suite runs in its own process
(run_suite.py) with its own Sandbox, at most JOBS at the same time, the longest first; set
MUXIFY_VERIFY_JOBS to change JOBS. Without the Accessibility permission it stops before any suite starts.

After the parallel pass only the checks that failed run again, alone. A check that passes then is
FLAKY. A suite that stops making progress reaches its timeout, and the
check that ran gets the status timeout. --repeat N runs the selection N times, and --shuffle shuffles
the order of the checks in each suite, with a seed that the output names.

Each run keeps its evidence in RUNS/<run-id>/: per suite the output, results.json and the app logs.
Nothing deletes it. REPORTS/<run-id>.html shows it per check. The exit status is 1 when a check
fails, and, for a full run, when the gate fails.
"""

import json
import os
import random
import signal
import subprocess
import sys
import time

from scripts.verify import gate, report
from scripts.verify.run_suite import write_json
from scripts.verify.sandbox import AX_WAKE_NOT_TRUSTED, EVIDENCE, REPO, ax_wake, new_run_id

SUITES = REPO/'scripts/verify/suites'
RUNS = gate.EVIDENCE/'runs'
REPORTS = gate.EVIDENCE/'reports'
TIMINGS = gate.EVIDENCE/'timings.json'
# Each suite runs its own app, and each app starts tmux every second. With all 30 suites at once on a
# 12-core Mac, a process start took 30 times longer and checks failed by chance; 10 at once was faster.
JOBS = 10
PROGRESS_TIMEOUT = 120
STOP_GRACE = 60
FAILED = ('fail', 'error', 'timeout')


def results(out):
    """The check records of one suite process. Without results.json the process died before the end, and
    the id of the module stands for the whole suite."""
    try:
        return json.loads((out/'results.json').read_text())['checks']
    except (FileNotFoundError, ValueError):
        return [dict(check='scripts.verify.suites.' + out.name.split('.')[0], status='error', seconds=0,
                     error='no per-check results; read %s' % (out/'output.log'))]


def short(id):
    """test_name, or setUpClass (Class) for a fixture."""
    return id.split(' ')[0] + ' (%s)' % rerun_target(id).rsplit('.', 1)[-1] if id.endswith(')') else id.rsplit('.', 1)[-1]


def finish_timeout(state, now):
    out, frozen = state['out'], state['expired']
    records = dict(frozen['records'])
    phase = frozen['phase']
    id = phase['check'] or 'scripts.verify.suites.' + state['suite']
    try:
        last_records = list(json.loads((out/'progress.json').read_text())['records'].values())
    except (FileNotFoundError, ValueError):
        last_records = []
    detail = next((record['error'] for record in results(out) + last_records
                   if record['check'] == id and record['status'] == 'timeout'), None)
    records[id] = dict(check=id, status='timeout', seconds=round(state['stopped'] - phase['began'], 2),
                       error=detail or 'run.py stopped the suite after %g seconds without progress; read %s'
                       % (state['limit'], out/'output.log'))
    checks = [records.get(id) or dict(check=id, status='not-run', seconds=0, error=None)
              for id in frozen['expected']]
    checks += [record for id, record in records.items() if id not in frozen['expected']]
    write_json(out/'results.json', dict(suite=state['suite'], seconds=round(now - state['began'], 1),
                                       shuffle=frozen['shuffle'], checks=checks))


def run_suites(jobs, starts, clock, *, timeout=PROGRESS_TIMEOUT, stop_grace=STOP_GRACE):
    """Runs each (suite, out, ids, seed), `jobs` at a time and in the given order. Returns per out:
    (status, seconds, timeout) with status ok, failed or timeout."""
    waiting, running, ended = list(starts), {}, {}
    while waiting or running:
        while waiting and len(running) < jobs:
            suite, out, ids, seed = waiting.pop(0)
            out.mkdir(parents=True, exist_ok=True)
            command = [sys.executable, '-m', 'scripts.verify.run_suite', suite, str(out), *ids]
            if seed is not None:
                command += ['--shuffle', str(seed)]
            with open(out/'output.log', 'w') as handle:
                # A session of its own, so a suite that ignores the stop dies with all its children.
                process = subprocess.Popen(command, cwd=REPO, stdout=handle, stderr=subprocess.STDOUT,
                                           env=dict(os.environ, **{EVIDENCE: str(out)}), start_new_session=True)
            began = time.monotonic()
            checkpoint = dict(phase=dict(check=None, began=began), records={}, expected=[], shuffle=seed)
            running[process] = dict(suite=suite, out=out, began=began, limit=timeout, stopped=None,
                                    checkpoint=checkpoint, expired=None)
        now = time.monotonic()
        for process, state in list(running.items()):
            if process.poll() is None:
                if state['stopped'] is None:
                    try:
                        state['checkpoint'] = json.loads((state['out']/'progress.json').read_text())
                    except (FileNotFoundError, ValueError):
                        pass
                    if now - state['checkpoint']['phase']['began'] > state['limit']:
                        state['expired'] = state['checkpoint']
                        state['stopped'] = now
                        process.terminate()
                elif now - state['stopped'] > stop_grace:
                    os.killpg(process.pid, signal.SIGKILL)
                continue
            del running[process]
            seconds = now - state['began']
            status = 'timeout' if state['stopped'] is not None else 'ok' if process.returncode == 0 else 'failed'
            if state['stopped'] is not None:
                finish_timeout(state, now)
            ended[state['out']] = (status, seconds, state['limit'])
            bad = [short(record['check']) for record in results(state['out']) if record['status'] in FAILED]
            print('%-7s %-30s %5.1f s  (at %4.0f s)%s' % (status.upper() if status != 'ok' else 'ok', state['out'].name,
                  seconds, now - clock, '  %s' % ', '.join(bad) if bad else ''), flush=True)
        time.sleep(.2)
    return ended


def rerun_target(id):
    """A fixture error such as "setUpClass (scripts.verify.suites.x.Class)" reruns the class it names."""
    return id[id.index('(') + 1:-1] if id.endswith(')') else id


def covers(id, check):
    """Whether a rerun of id ran check: the id itself, a check in it, or a fixture of it."""
    inner = rerun_target(check)
    return inner == id or inner.startswith(id + '.')


def judged(record, again):
    """The verdict of one check from its parallel pass and the alone rerun of its suite.

    A check is judged by its own rerun record. The module id stands for a suite without per-check
    results, so every check of the rerun judges it. A class fixture that does not fail again passed
    when its class ran, and its checks have rows of their own."""
    id, status = record['check'], record['status']
    own = [other for other in again if other['check'] == id]
    covered = [other for other in again if covers(rerun_target(id), other['check'])]
    rerun = own if own or id.endswith(')') else covered
    if status not in FAILED + ('not-run',):
        verdict = status
    elif not covered or not all(other['status'] in ('pass', 'skip') for other in rerun):
        verdict = 'failed'
    else:
        verdict = 'pass' if status == 'not-run' else 'FLAKY'
    return dict(check=id, first=record, rerun=rerun, verdict=verdict)


def run_round(names, round_dir, jobs, seed, timings):
    """One parallel pass over the suites, then the alone rerun of what failed. Returns the suite summaries."""
    clock = time.monotonic()
    # Suites with no recorded time first: they may be long, and this run learns their time.
    order = sorted(names, key=lambda name: -timings.get(name, float('inf')))
    ended = run_suites(jobs, [(name, round_dir/name, [], seed) for name in order], clock)
    first = {name: results(round_dir/name) for name in names}
    redo = {name: [record['check'] for record in records if record['status'] in FAILED + ('not-run',)]
            for name, records in first.items() if ended[round_dir/name][0] != 'ok'}
    redo = {name: ids for name, ids in redo.items() if ids}
    if redo:
        print('running again alone: %s' % ', '.join('%s (%d)' % item for item in
                                                    ((name, len(ids)) for name, ids in redo.items())), flush=True)
    again_ended = run_suites(1, [(name, round_dir/(name + '.rerun'), sorted({rerun_target(id) for id in ids}), None)
                                 for name, ids in redo.items()], clock)

    suites = []
    for name in order:
        status, seconds, limit = ended[round_dir/name]
        rerun = round_dir/(name + '.rerun')
        again = results(rerun) if name in redo else []
        checks = [judged(record, again) for record in first[name]]
        suites.append(dict(suite=name, status=status, seconds=round(seconds, 1), timeout=limit,
                           dir=str((round_dir/name).relative_to(gate.EVIDENCE)),
                           rerun=dict(status=again_ended[rerun][0], dir=str(rerun.relative_to(gate.EVIDENCE)))
                           if name in redo else None,
                           files=sorted(str(path.relative_to(gate.EVIDENCE)) for folder in (round_dir/name, rerun)
                                        for path in folder.rglob('*') if path.is_file()),
                           checks=checks))
        if status == 'ok':
            timings[name] = round(seconds, 1)
    return suites


def parse(argv):
    repeat, shuffle, names = 1, False, []
    args = iter(argv)
    for arg in args:
        if arg == '--repeat':
            repeat = int(next(args))
        elif arg == '--shuffle':
            shuffle = True
        else:
            names.append(arg)
    return repeat, shuffle, names


def main(argv):
    repeat, shuffle, names = parse(argv)
    every = sorted(path.stem for path in SUITES.glob('*.py'))
    names = sorted(set(names or every))
    unknown = [name for name in names if name not in every]
    if unknown:
        sys.exit('no suite %s in %s' % (', '.join(unknown), SUITES))
    # The gate trusts only a run of every suite: a passing subset proves nothing about the others.
    full = names == every

    # Without the permission every launch fails only at its deadline, so each suite would wait it out.
    deadline = time.monotonic() + 5
    while (probe := ax_wake(os.getpid())).returncode == AX_WAKE_NOT_TRUSTED:
        if time.monotonic() > deadline:
            sys.exit('nothing ran: ' + probe.stderr.strip())
        time.sleep(.5)

    run_id = new_run_id()
    run_dir = RUNS/run_id
    jobs = int(os.environ.get('MUXIFY_VERIFY_JOBS') or JOBS)
    try:
        timings = json.loads(TIMINGS.read_text())
    except (FileNotFoundError, ValueError):
        timings = {}
    tree = gate.tree_state()
    clock, started = time.monotonic(), time.strftime(gate.TIME)
    print('run %s: %d suites%s, %d jobs, evidence in %s' % (run_id, len(names), ' (full)' if full else '', jobs,
                                                            run_dir), flush=True)

    rounds = []
    for number in range(1, repeat + 1):
        seed = random.randrange(1 << 30) if shuffle else None
        if repeat > 1 or seed is not None:
            print('round %d of %d%s' % (number, repeat, ', shuffle seed %d' % seed if seed is not None else ''), flush=True)
        round_dir = run_dir/('round-%d' % number) if repeat > 1 else run_dir
        suites = run_round(names, round_dir, jobs, seed, timings)
        TIMINGS.write_text(json.dumps(timings, indent=2, sort_keys=True))
        rounds.append(dict(number=number, seed=seed, suites=suites))

    verdicts = [(check['verdict'], check['check']) for one in rounds for suite in one['suites'] for check in suite['checks']]
    failed = sorted({check for status, check in verdicts if status == 'failed'})
    flaky = sorted({check for status, check in verdicts if status == 'FLAKY'})
    if full:
        if gate.tree_state()['files'] == tree['files']:
            gate.record_full_run(run_id, tree, passed=not failed)
        else:
            print('the tree changed during the run, so this run does not count for the gate')
    problems = gate.problems()

    summary = dict(run=run_id, started=started, seconds=round(time.monotonic() - clock), tree=tree, full=full,
                   jobs=jobs, repeat=repeat, rounds=rounds, failed=failed, flaky=flaky,
                   gate=dict(problems=problems, counted=full))
    (run_dir/'run.json').write_text(json.dumps(summary, indent=2))
    REPORTS.mkdir(parents=True, exist_ok=True)
    page = REPORTS/(run_id + '.html')
    page.write_text(report.render(summary))

    for check in flaky:
        print('FLAKY   %s' % check)
    for check in failed:
        print('FAILED  %s' % check)
    print('%d suites in %.0f s: %s' % (len(names), time.monotonic() - clock, '; '.join(
        ['%d checks failed' % len(failed)] * bool(failed) + ['%d FLAKY' % len(flaky)] * bool(flaky)) or 'all passed'))
    print('verify gate%s: %s' % ('' if full else ' (a subset run: not part of its status)',
                                 'FAILED\n' + '\n'.join('  - ' + problem for problem in problems) if problems else 'passed'))
    print('report: %s' % page)
    return 1 if failed or (full and problems) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
