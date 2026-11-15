"""The verify runner's own checks: its progress timeout, its reruns and its FLAKY and alone verdicts (run.py, gate.py).
Each check runs probe suites that never launch the app, so make test runs them, not make verify.

Run from the repo root:
    python3 -m unittest -v scripts.verify.test_run
"""

import os
import pathlib
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

from scripts.verify import gate
from scripts.verify.run import Job, results, run_round, run_suites


class VerifyRunner(unittest.TestCase):
    def run_probe(self, source, *, timeout=1.5):
        root = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory(prefix='muxify-runner-')))
        module = root/'scripts/verify/suites/timeout_probe.py'
        module.parent.mkdir(parents=True)
        module.write_text('import os, signal, time, unittest\n' + textwrap.dedent(source))
        out = root/'evidence'
        environment = dict(os.environ, PYTHONPATH=str(root) + os.pathsep + os.environ.get('PYTHONPATH', ''))
        for key in ('TMUX', 'TMUX_PANE'):
            environment.pop(key, None)
        with patch.dict(os.environ, environment, clear=True):
            outcome = run_suites([Job('timeout_probe', out, [], None, 0)], time.monotonic(),
                                 timeout=timeout, stop_grace=.5)[out]
            status = outcome['status'], outcome['seconds'], outcome['timeout']
        return status, results(out), out

    def test_runner_allows_a_suite_to_outlive_the_progress_deadline(self):
        status, records, _ = self.run_probe('''
            class Checks(unittest.TestCase):
                def test_a(self): time.sleep(.6)
                def test_b(self): time.sleep(.6)
                def test_c(self): time.sleep(.6)
                def test_d(self): time.sleep(.6)
                def test_e(self): time.sleep(.6)
                def test_f(self): time.sleep(.6)
        ''')
        self.assertEqual(status[0], 'ok')
        self.assertGreater(status[1], status[2])
        self.assertEqual([record['status'] for record in records], ['pass'] * 6)

    def test_runner_keeps_completed_checks_and_times_only_the_stuck_check(self):
        status, records, out = self.run_probe('''
            from pathlib import Path
            class Checks(unittest.TestCase):
                def test_a(self): time.sleep(.6)
                def test_b(self):
                    self.addClassCleanup(lambda: Path(os.environ['MUXIFY_VERIFY_EVIDENCE'], 'cleaned').touch())
                    while True:
                        print('still running', flush=True)
                        time.sleep(.05)
                def test_c(self): pass
        ''')
        self.assertEqual(status[0], 'timeout')
        self.assertEqual([record['status'] for record in records], ['pass', 'timeout', 'not-run'])
        self.assertLess(records[1]['seconds'], status[1] - .4)
        self.assertIn('test_b', records[1]['error'])
        self.assertTrue((out/'cleaned').is_file())

    def test_runner_bounds_import_discovery_and_class_fixtures(self):
        cases = {
            'import': 'time.sleep(30)\n',
            'discovery': 'def load_tests(*args): time.sleep(30)\n',
            'setup': '''
                class Checks(unittest.TestCase):
                    @classmethod
                    def setUpClass(cls): time.sleep(30)
                    def test_a(self): pass
            ''',
            'teardown': '''
                class Checks(unittest.TestCase):
                    @classmethod
                    def tearDownClass(cls): time.sleep(30)
                    def test_a(self): pass
            ''',
            'cleanup': '''
                class Checks(unittest.TestCase):
                    @classmethod
                    def setUpClass(cls): cls.addClassCleanup(time.sleep, 30)
                    def test_a(self): pass
            ''',
        }
        for phase, source in cases.items():
            with self.subTest(phase=phase):
                status, records, _ = self.run_probe(source)
                self.assertEqual(status[0], 'timeout')
                timeout = [record for record in records if record['status'] == 'timeout']
                self.assertEqual([record['check'] for record in timeout], ['scripts.verify.suites.timeout_probe'])

    def test_runner_keeps_results_when_a_check_cannot_handle_signals(self):
        status, records, _ = self.run_probe('''
            class Checks(unittest.TestCase):
                def test_a(self): pass
                def test_b(self): os.kill(os.getpid(), signal.SIGSTOP)
                def test_c(self): pass
        ''')
        self.assertEqual(status[0], 'timeout')
        self.assertEqual([record['status'] for record in records], ['pass', 'timeout', 'not-run'])

    def test_runner_keeps_timeout_when_cleanup_blocks_or_the_check_returns_late(self):
        for action in ('self.addClassCleanup(time.sleep, 30); raise', 'return'):
            with self.subTest(action=action):
                status, records, out = self.run_probe('''
                    class Checks(unittest.TestCase):
                        def test_a(self): pass
                        def test_b(self):
                            try:
                                time.sleep(30)
                            except KeyboardInterrupt:
                                %s
                        def test_c(self): pass
                ''' % action)
                self.assertEqual(status[0], 'timeout')
                self.assertEqual([record['status'] for record in records], ['pass', 'timeout', 'not-run'])
                if action == 'return':
                    self.assertIn('OK', (out/'output.log').read_text())
                else:
                    self.assertIn('test_b', records[1]['error'])

    def run_round_of(self, probes):
        """Runs the probe suites, name to the body of one check, as one round of make verify. A check can call
        log(text), and reads `busy`, a file the probe `slow` removes when it ends. Returns the verdict of each
        check and the logged lines."""
        root = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory(prefix='muxify-runner-')))
        suites = root/'scripts/verify/suites'
        suites.mkdir(parents=True)
        events, busy = root/'events', root/'busy'
        busy.touch()
        for name, body in probes.items():
            (suites/(name + '.py')).write_text(
                'import pathlib, time, unittest\nbusy = pathlib.Path(%r)\n'
                'def log(text):\n    with open(%r, "a") as file: file.write(text + "\\n")\n'
                'class Checks(unittest.TestCase):\n    def test_%s(self):\n%s'
                % (str(busy), str(events), name, textwrap.indent(textwrap.dedent(body), ' ' * 8)))
        environment = dict(os.environ, PYTHONPATH=str(root) + os.pathsep + os.environ.get('PYTHONPATH', ''))
        for key in ('TMUX', 'TMUX_PANE'):
            environment.pop(key, None)
        with patch.dict(os.environ, environment, clear=True), patch.object(gate, 'EVIDENCE', root):
            summaries = run_round(sorted(probes), root/'evidence', 10, None, {})
        verdicts = {check['check'].rsplit('.', 1)[-1]: check['verdict'] for suite in summaries for check in suite['checks']}
        return verdicts, events.read_text().splitlines()

    def test_a_rerun_starts_once_two_suites_still_run_and_a_check_that_passes_there_is_flaky(self):
        verdicts, events = self.run_round_of({
            **{'slow_%d' % n: 'time.sleep(%g)\nlog("slow %d ends")\n' % (seconds, n) for n, seconds in [(1, 1.5), (2, 4), (3, 6.5)]},
            'flaky': '''
                ran = busy.with_name('flaky-ran')
                first = not ran.exists()
                ran.touch()
                log('flaky runs')
                self.assertFalse(first, 'the first run fails')
            ''',
        })
        self.assertEqual(verdicts, dict(test_slow_1='pass', test_slow_2='pass', test_slow_3='pass', test_flaky='FLAKY'))
        self.assertEqual(events, ['flaky runs', 'slow 1 ends', 'flaky runs', 'slow 2 ends', 'slow 3 ends'],
                         'the rerun did not start beside the last two suites, or ran more than once')

    def test_a_check_that_fails_beside_another_suite_runs_once_more_alone_and_only_that_run_fails_it(self):
        verdicts, events = self.run_round_of({
            'slow': 'time.sleep(4)\nbusy.unlink()\nlog("slow ends")\n',
            'shy': 'log("shy runs")\nself.assertFalse(busy.exists(), "another suite runs")\n',
            'broken': 'log("broken runs")\nself.fail("always")\n',
        })
        self.assertEqual(verdicts, dict(test_slow='pass', test_shy='FLAKY', test_broken='failed'))
        self.assertEqual(events[events.index('slow ends'):].count('shy runs'), 1, events)
        self.assertEqual(events.count('shy runs'), 3, 'shy did not run in the pass, beside slow, and alone: %s' % events)
        self.assertEqual(events.count('broken runs'), 3, events)


if __name__ == '__main__':
    unittest.main()
