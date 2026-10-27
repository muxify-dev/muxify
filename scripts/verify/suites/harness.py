"""The sandbox itself: a run that dies leaves nothing behind once the next run starts.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.harness
"""

import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

from scripts.verify.sandbox import BASE, OWNER, OWNERLESS_GRACE, REPO, Sandbox, alive, new_run_id, wait

NAME = __name__.rsplit('.', 1)[-1]

# Owns one run with an app and a tmux server, reports them, then waits to be killed.
OWNER_PROCESS = '''
import json, time
from scripts.verify.sandbox import Sandbox
s = Sandbox(%r)
s.launch()
s.tmux('new-session', '-d', '-s', 'orphan')
print(json.dumps(dict(root=str(s.root), app=s.pid, server=int(s.tmux('display-message', '-p', '#{pid}')))), flush=True)
time.sleep(600)
''' % NAME


class VerifyRunner(unittest.TestCase):
    def run_probe(self, source, *, timeout=3):
        from scripts.verify.run import results, run_suites

        root = pathlib.Path(self.enterContext(tempfile.TemporaryDirectory(prefix='muxify-runner-')))
        module = root/'scripts/verify/suites/timeout_probe.py'
        module.parent.mkdir(parents=True)
        module.write_text('import os, signal, time, unittest\n' + textwrap.dedent(source))
        out = root/'evidence'
        environment = dict(os.environ, PYTHONPATH=str(root) + os.pathsep + os.environ.get('PYTHONPATH', ''))
        for key in ('TMUX', 'TMUX_PANE'):
            environment.pop(key, None)
        with patch.dict(os.environ, environment, clear=True):
            status = run_suites(1, [('timeout_probe', out, [], None)], time.monotonic(),
                                timeout=timeout, stop_grace=.5)[out]
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


class Harness(unittest.TestCase):
    def test_fixture_commits_do_not_use_the_users_signer(self):
        from scripts.verify.suites.command_palette import CommandPalette
        from scripts.verify.topics_sidebar import TopicsSidebar

        run = Sandbox(NAME)
        self.addCleanup(run.teardown)
        config = run.root/'signing.gitconfig'
        config.write_text('[commit]\n\tgpgSign = true\n[gpg]\n\tprogram = /usr/bin/false\n\tformat = openpgp\n')
        # Exercise the real repository setup, but do not launch a UI or invoke
        # the user's signer. A commit without its override would fail here.
        with patch.dict(os.environ, GIT_CONFIG_GLOBAL=str(config)), patch.object(Sandbox, 'launch'):
            for fixture in [TopicsSidebar, CommandPalette]:
                with self.subTest(fixture=fixture.__name__):
                    class Fixture(fixture):
                        pass

                    try:
                        Fixture.setUpClass()
                        commit = subprocess.check_output(
                            ['/usr/bin/git', '-C', str(Fixture.alpha), 'cat-file', 'commit', 'HEAD'], text=True)
                        self.assertNotIn('\ngpgsig ', commit, 'a fixture commit was signed')
                    finally:
                        Fixture.doClassCleanups()

    def live_run(self):
        run = Sandbox(NAME)
        self.addCleanup(run.teardown)
        run.tmux('new-session', '-d', '-s', 'live')
        return run, int(run.tmux('display-message', '-p', '#{pid}'))

    def test_run_whose_owner_was_killed_is_swept_and_live_run_is_kept(self):
        live, live_server = self.live_run()
        environment = {key: value for key, value in os.environ.items() if key not in ('TMUX', 'TMUX_PANE')}
        owner = subprocess.Popen([sys.executable, '-c', OWNER_PROCESS], cwd=REPO, env=environment,
                                 stdout=subprocess.PIPE, text=True)
        self.addCleanup(owner.kill)
        self.addCleanup(owner.stdout.close)
        dead = json.loads(owner.stdout.readline())
        dead_root = pathlib.Path(dead['root'])

        os.kill(owner.pid, signal.SIGKILL)
        owner.wait(timeout=5)
        self.assertTrue(dead_root.is_dir() and alive(dead['app']) and alive(dead['server']),
                        'killed run should leave its root, app and tmux server: %s' % dead)

        self.addCleanup(Sandbox(NAME).teardown)
        wait(lambda: not alive(dead['app']) and not alive(dead['server']),
             'sweep left the dead run running: %s' % dead, seconds=10)
        self.assertFalse(dead_root.exists(), 'sweep left the dead root %s' % dead_root)
        self.assertTrue(live.root.is_dir() and alive(live_server),
                        'sweep touched the live run %s (server %d)' % (live.root, live_server))
        self.assertEqual(live.tmux('display-message', '-p', '-t', 'live', '#{session_name}'), 'live')

    def test_teardown_stops_a_process_that_names_the_root_only_in_its_environment_or_working_directory(self):
        run = Sandbox(NAME)
        self.addCleanup(run.teardown)
        # The command line is the same for both; the root is in the environment of one and the working directory of
        # the other. A process that is not a descendant of this one, as the Codex daemon is not, must still be found.
        code = 'import time; time.sleep(600)'
        with_environment = subprocess.Popen([sys.executable, '-c', code], cwd='/', env=dict(os.environ, SANDBOX_ROOT=str(run.root)),
                                            start_new_session=True)
        with_directory = subprocess.Popen([sys.executable, '-c', code], cwd=run.root, start_new_session=True)
        self.addCleanup(with_environment.kill)
        self.addCleanup(with_directory.kill)
        wait(lambda: {with_environment.pid, with_directory.pid} <= set(run.processes()),
             'processes() missed %s: it lists %s' % ([with_environment.pid, with_directory.pid], run.processes()), seconds=10)

        run.teardown()
        for process in (with_environment, with_directory):
            self.assertIsNotNone(process.wait(timeout=10), 'teardown left process %d running' % process.pid)

    def test_run_whose_owner_pid_was_reused_is_swept(self):
        reused, server = self.live_run()
        # The owner PID still runs, but it is a later process than the one that made the run.
        (reused.root/OWNER).write_text(json.dumps(dict(pid=os.getpid(), started='Thu Jan  1 00:00:00 1970')))

        self.addCleanup(Sandbox(NAME).teardown)
        wait(lambda: not alive(server), 'sweep left the tmux server %d of a reused-PID run' % server, seconds=10)
        self.assertFalse(reused.root.exists(), 'sweep left the reused-PID root %s' % reused.root)

    def test_root_without_owner_is_swept_only_after_grace(self):
        old, young = BASE/NAME/new_run_id(), BASE/NAME/new_run_id()
        for root in (old, young):
            (root/'logs').mkdir(parents=True)
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        then = time.time() - OWNERLESS_GRACE - 60
        os.utime(old, (then, then))

        self.addCleanup(Sandbox(NAME).teardown)
        self.assertFalse(old.exists(), 'sweep left the ownerless root %s older than the grace' % old)
        self.assertTrue(young.is_dir(), 'sweep removed the ownerless root %s inside the grace' % young)


if __name__ == '__main__':
    unittest.main()
