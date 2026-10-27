"""Runs one verify suite, or some of its checks, and writes one result per check.

    python3 -m scripts.verify.run_suite <suite> <out-dir> [--shuffle SEED] [id ...]

run.py starts one of these for each suite. <out-dir>/results.json lists every check with its status
(pass, fail, error, skip, timeout or not-run), its seconds and its error. An id selects a check, or
every check in a class or module. The Sandbox of the suite copies its app logs to <out-dir>, because
run.py names that folder in MUXIFY_VERIFY_EVIDENCE.

SIGTERM is the progress timeout of run.py: the check that runs gets the status timeout and the
stack where it waited, the class cleanups tear the Sandbox down, and results.json is written.
"""

import importlib
import json
import pathlib
import random
import signal
import sys
import time
import traceback
import unittest


class TimedOut(KeyboardInterrupt):
    """A KeyboardInterrupt, because unittest catches every other exception and goes on to the next check."""


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(path)


def checks(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from checks(test)
        else:
            yield test


def selected(test, wanted):
    return not wanted or any(test.id() == id or test.id().startswith(id + '.') for id in wanted)


def shuffled(found, seed):
    """Shuffled within each class only: interleaved classes would start the class fixture, an app, again and again."""
    rng = random.Random(seed)
    classes = {}
    for test in found:
        classes.setdefault(type(test), []).append(test)
    groups = list(classes.values())
    rng.shuffle(groups)
    for group in groups:
        rng.shuffle(group)
    return [test for group in groups for test in group]


class Recorder(unittest.TextTestResult):
    def __init__(self, *args, state, checkpoint, progress, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = state['records']
        self.checkpoint = checkpoint
        self.progress = progress
        self.current = None

    def startTest(self, test):
        self.current = (test, time.monotonic())
        self.progress(test.id())
        super().startTest(test)

    def stopTest(self, test):
        super().stopTest(test)
        self.current = None
        self.progress()

    def record(self, test, status, error=None):
        began = self.current[1] if self.current and self.current[0] is test else time.monotonic()
        # A fixture error (setUpClass, tearDownClass) arrives as an _ErrorHolder with an id such as
        # "setUpClass (scripts.verify.suites.x.Class)"; a rerun of that id runs the class.
        self.records[test.id()] = dict(check=test.id(), status=status, seconds=round(time.monotonic() - began, 2),
                                       error=error if isinstance(error, str) or error is None
                                       else self._exc_info_to_string(error, test))
        self.checkpoint()

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, 'pass')

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.record(test, 'fail', error)

    def addError(self, test, error):
        super().addError(test, error)
        self.record(test, 'error', error)

    def addSubTest(self, test, subtest, error):
        super().addSubTest(test, subtest, error)
        # A failed subtest fails its check, and unittest does not call addFailure for it.
        if error is not None and self.records.get(test.id(), {}).get('status') != 'fail':
            self.record(test, 'fail', '%s\n%s' % (subtest.id(), self._exc_info_to_string(error, test)))

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.record(test, 'skip', reason)

    def addExpectedFailure(self, test, error):
        super().addExpectedFailure(test, error)
        self.record(test, 'pass', 'expected failure')

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.record(test, 'fail', 'unexpected success: the check passes, so remove @unittest.expectedFailure')


def main(argv):
    seed = None
    if '--shuffle' in argv:
        at = argv.index('--shuffle')
        seed = int(argv[at + 1])
        argv = argv[:at] + argv[at + 2:]
    name, out, wanted = argv[0], pathlib.Path(argv[1]), argv[2:]
    out.mkdir(parents=True, exist_ok=True)
    module_name = 'scripts.verify.suites.' + name
    started = time.monotonic()
    state = dict(suite=name, started=started, shuffle=seed, expected=[], records={},
                 phase=dict(check=None, began=started))

    def checkpoint():
        write_json(out/'progress.json', state)

    def progress(check=None):
        state['phase'] = dict(check=check, began=time.monotonic())
        checkpoint()

    def stop(_, frame):
        raise TimedOut(dict(state['phase']), ''.join(traceback.format_stack(frame)))

    signal.signal(signal.SIGTERM, stop)
    checkpoint()
    found = []
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=2,
                                    resultclass=lambda *args, **kwargs: Recorder(
                                        *args, state=state, checkpoint=checkpoint, progress=progress, **kwargs))
    try:
        module = importlib.import_module(module_name)
        progress()
        found = [test for test in checks(unittest.defaultTestLoader.loadTestsFromModule(module)) if selected(test, wanted)]
        if seed is not None:
            found = shuffled(found, seed)
        state['expected'] = [test.id() for test in found]
        progress()
        runner.run(unittest.TestSuite(found))
    except TimedOut as timeout:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        phase, stack = timeout.args
        id = phase['check'] or module_name
        state['records'][id] = dict(check=id, status='timeout', seconds=round(time.monotonic() - phase['began'], 2),
                                    error='run.py stopped the suite without progress; it waited here:\n' + stack)
        checkpoint()
        print('\nTIMEOUT in %s' % id, flush=True)
        try:
            for cls in {type(test) for test in found}:
                cls.doClassCleanups()
        finally:
            checkpoint()
    records = [state['records'].get(id) or dict(check=id, status='not-run', seconds=0, error=None)
               for id in state['expected']]
    records += [record for id, record in state['records'].items() if id not in state['expected']]
    write_json(out/'results.json', dict(suite=name, seconds=round(time.monotonic() - started, 1),
                                       shuffle=seed, checks=records))
    return 0 if all(record['status'] in ('pass', 'skip') for record in records) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
