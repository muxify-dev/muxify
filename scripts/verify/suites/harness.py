"""The harness itself: a run that dies leaves nothing behind once the next run starts, the runner keeps its results,
and the gate of the compare run matches the rows of two dumps.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.harness
"""

import io
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
from unittest.mock import Mock, patch

from scripts.verify.compare_gate import area_rows, judge, judge_actions, list_rows
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
        from scripts.verify.run import Job, results, run_suites

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
        from scripts.verify import gate
        from scripts.verify.run import run_round

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


class CompareGate(unittest.TestCase):
    """The gate of the compare run (compare_gate.py) on made-up rows, with no app."""

    WINDOW = (100, 200, 1500, 920)
    LIST = (100, 200, 260, 856)
    # The identifier of the made-up list whose rows the gate compares, as an area names its list.
    KEY = 'made-up-list'

    def dump(self, *rows):
        """A dump as the driver gives it: an App Window, a row outside the list, the list, and `rows` in the list. A
        row is (identifier, label, frame); a frame is (x, y, width, height) in screen points."""
        def row(depth, role, frame, **more):
            return dict(depth=str(depth), accessibilityRole=role, accessibilityFrame='{{%r, %r}, {%r, %r}}' % frame,
                        **{'accessibility' + key.title(): value for key, value in more.items()})
        return ([row(0, 'AXWindow', self.WINDOW, title='made up'),
                 row(1, 'AXButton', (120, 1090, 60, 20), identifier='sidebar-view-sessions', label='Sessions'),
                 row(1, 'AXScrollArea', self.LIST, identifier=self.KEY)]
                + [row(2, 'AXButton', frame, identifier=identifier, label=label) for identifier, label, frame in rows]
                + [row(1, 'AXGroup', (360, 200, 1240, 890), identifier='terminal-panel')])

    def judged(self, first, second):
        return judge(list_rows(self.dump(*first), self.KEY), list_rows(self.dump(*second), self.KEY))

    ALPHA = ('session-$0', 'alpha', (106, 1000, 248, 50))
    BETA = ('session-$1', 'beta', (106, 944, 248, 50))

    def test_the_same_rows_pass_and_only_the_rows_inside_the_list_count(self):
        result = self.judged([self.ALPHA, self.BETA], [self.ALPHA, self.BETA])
        self.assertEqual(result['failed'], [])
        self.assertIsNone(result['order'])
        # The list and its two rows: not the App Window, the row before the list or the row after it.
        self.assertEqual(result['rows'], [3, 3])

    def test_the_rows_of_an_areas_part_outside_its_list_count_too(self):
        # A part under the list, as the Settled group stands under the Topics list, with a row of its own.
        part = [dict(depth='1', accessibilityRole='AXGroup', accessibilityIdentifier='made-up-part',
                     accessibilityFrame='{{106, 210}, {248, 40}}'),
                dict(depth='2', accessibilityRole='AXButton', accessibilityIdentifier='made-up-header',
                     accessibilityLabel='Settled (2)', accessibilityFrame='{{106, 220}, {248, 26}}')]
        first = self.dump(self.ALPHA) + part
        moved = [dict(row, accessibilityFrame='{{106, 230}, {248, 26}}') if row['accessibilityIdentifier'] == 'made-up-header'
                 else row for row in part]
        keys = (self.KEY, 'made-up-part')
        self.assertEqual([row['identifier'] for row in area_rows(first, keys)],
                         [self.KEY, self.ALPHA[0], 'made-up-part', 'made-up-header'])
        self.assertEqual(judge(area_rows(first, keys), area_rows(first, keys))['failed'], [])
        failed = judge(area_rows(first, keys), area_rows(self.dump(self.ALPHA) + moved, keys))['failed']
        self.assertEqual({row['row'] for row in failed}, {'made-up-header (AXButton)'})

    def test_a_row_with_no_match_fails_and_is_named_with_the_version_that_has_it(self):
        for first, second, has in (([self.ALPHA, self.BETA], [self.ALPHA], 'first'),
                                   ([self.ALPHA], [self.ALPHA, self.BETA], 'second')):
            with self.subTest(has=has):
                failed = self.judged(first, second)['failed']
                self.assertEqual([(row['row'], row['what']) for row in failed], [('session-$1 (AXButton)', 'no match')])
                other = 'second' if has == 'first' else 'first'
                self.assertIn("label 'beta'", failed[0][has], 'the row is not shown with what it has')
                self.assertIsNone(failed[0][other], 'the version without the row shows one')

    def test_a_changed_label_fails_with_both_values(self):
        changed = (self.BETA[0], 'gamma', self.BETA[2])
        failed = self.judged([self.ALPHA, self.BETA], [self.ALPHA, changed])['failed']
        self.assertEqual(failed, [dict(row='session-$1 (AXButton)', what='label', first='beta', second='gamma')])

    def test_rows_that_share_an_identifier_match_in_the_order_of_the_dump(self):
        # SwiftUI gives a row's identifier to the row's parts.
        icon, title = ('session-window-@1', 'icon', (112, 980, 14, 14)), ('session-window-@1', 'editor', (132, 980, 60, 15))
        self.assertEqual(self.judged([icon, title], [icon, title])['failed'], [])
        failed = self.judged([icon, title], [title, icon])['failed']
        self.assertEqual([(row['row'], row['what']) for row in failed],
                         [('session-window-@1 (AXButton) #1', 'label'), ('session-window-@1 (AXButton) #1', 'frame'),
                          ('session-window-@1 (AXButton) #2', 'label'), ('session-window-@1 (AXButton) #2', 'frame')])

    def moved(self, by):
        """BETA with each edge of its frame in turn `by` points away: (edge, row) pairs."""
        identifier, label, (x, y, width, height) = self.BETA
        # Screen points have their origin at the bottom left, so a taller frame from the same y moves the top edge.
        return [('left', (identifier, label, (x - by, y, width + by, height))),
                ('right', (identifier, label, (x, y, width + by, height))),
                ('top', (identifier, label, (x, y, width, height + by))),
                ('bottom', (identifier, label, (x, y - by, width, height + by)))]

    def test_a_frame_0_4_points_away_passes(self):
        for edge, row in self.moved(.4):
            with self.subTest(edge=edge):
                self.assertEqual(self.judged([self.ALPHA, self.BETA], [self.ALPHA, row])['failed'], [])

    def test_a_frame_0_6_points_away_fails_and_names_the_edge(self):
        for edge, row in self.moved(.6):
            with self.subTest(edge=edge):
                failed = self.judged([self.ALPHA, self.BETA], [self.ALPHA, row])['failed']
                self.assertEqual([(found['row'], found['what'], found['edges']) for found in failed],
                                 [('session-$1 (AXButton)', 'frame', [edge])])
                self.assertNotEqual(failed[0]['first'], failed[0]['second'], 'the two frames read the same')

    def test_an_app_window_in_another_place_on_the_screen_moves_no_row(self):
        with patch.object(self, 'WINDOW', (300, 100, 1500, 920)), patch.object(self, 'LIST', (300, 100, 260, 856)):
            there = self.dump(*[(identifier, label, (x + 200, y - 100, width, height))
                                for identifier, label, (x, y, width, height) in (self.ALPHA, self.BETA)])
        self.assertEqual(judge(list_rows(self.dump(self.ALPHA, self.BETA), self.KEY), list_rows(there, self.KEY))['failed'],
                         [])

    def test_rows_in_another_order_are_reported_and_do_not_fail(self):
        result = self.judged([self.ALPHA, self.BETA], [self.BETA, self.ALPHA])
        self.assertEqual(result['failed'], [])
        self.assertEqual(result['order'], dict(
            first=['made-up-list (AXScrollArea)', 'session-$0 (AXButton)', 'session-$1 (AXButton)'],
            second=['made-up-list (AXScrollArea)', 'session-$1 (AXButton)', 'session-$0 (AXButton)']))

    def test_the_same_named_actions_pass_and_other_names_or_another_order_fail_with_both_values(self):
        card = ['Go to Session', 'Move to Topic…', 'Lock Session']
        same = {'card-session-$1': [card], 'session-window-@1': [[], []]}
        self.assertEqual(judge_actions(same, dict(same)), [])
        self.assertEqual(judge_actions(None, {}), [], 'a shot that reads no named actions fails')
        for name, other in (('order', card[::-1]), ('names', card[:2])):
            with self.subTest(differ=name):
                failed = judge_actions(same, {**same, 'card-session-$1': [other]})
                self.assertEqual(failed, [dict(row='card-session-$1', what='named actions',
                                               first='[Go to Session, Move to Topic…, Lock Session]',
                                               second='[%s]' % ', '.join(other))])
        failed = judge_actions(same, {'card-session-$1': [card], 'session-window-@1': []})
        self.assertEqual([(row['row'], row['first'], row['second']) for row in failed],
                         [('session-window-@1', '[] []', 'no element')])

    def test_a_scene_fails_its_measure_when_the_app_shows_the_other_version(self):
        from scripts.verify.compare import Side, View
        from scripts.verify.compare_scenes import Area

        sandbox = Mock()
        area = Area(name='made-up', title='Made-up list', list=self.KEY, default='madeUpListAppKit', args=[],
                    shown=lambda s: 'swiftui', scenes=[])
        with self.assertRaisesRegex(AssertionError, 'shows the swiftui Made-up list, and the scene asked for the appkit one'):
            View(sandbox, area, Side('appkit', 'appkit'), pathlib.Path('/nowhere')).measure('shot')
        sandbox.act.assert_not_called()

    def test_with_no_area_that_has_two_versions_the_compare_run_says_so_and_passes(self):
        from scripts.verify import compare

        with patch.object(compare, 'AREAS', []), patch.object(compare, 'prepare_mac') as prepare, \
                patch('sys.stdout', new_callable=io.StringIO) as output:
            self.assertEqual(compare.main([]), 0)
        self.assertIn('no area has two versions', output.getvalue())
        prepare.assert_not_called()


if __name__ == '__main__':
    unittest.main()
