"""The Go to… Command Palette with its topics and sessions Sources, what ↩ and the row actions do on a
Topic, Settled, Session or Session Path row, and Move, which uses the palette's view.

The driver cannot type keys, so a check opens a palette from its View menu item, closes it with the
search field's Close accessibility action, and runs New Session, Paste Path and Snooze through the row's
accessibility actions (UI/CommandPaletteView.swift), which call the same code as ⌘↩, ⌃Y and ⌃S.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.command_palette
"""

import datetime
import json
import os
import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, frame, remove_topic, wait
from scripts.verify.topics_sidebar import remembered_session

# The app reads tmux once per second; a visit is recorded when it sees the client move.
REFRESH_LIMIT = 2.0
SHELL = '/bin/zsh -f'
LAUNCH_ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES']


class CommandPalette(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.topics_dir = s.root/'state/muxify/topics'
        # alpha is a plain repository, beta a plain directory, gamma a bare repository with two Worktrees,
        # delta a plain directory with an alias.
        cls.alpha = s.root/'projects/alpha'
        cls.beta = s.root/'projects/beta'
        cls.gamma = s.root/'projects/gamma'
        cls.delta = s.root/'projects/delta'
        for directory in [cls.topics_dir, cls.alpha, cls.beta, cls.delta]:
            directory.mkdir(parents=True, exist_ok=True)
        git = ['/usr/bin/git', '-C', str(cls.alpha), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid',
               '-c', 'commit.gpgSign=false']
        subprocess.run(['/usr/bin/git', 'init', '-q', '-b', 'main', str(cls.alpha)], check=True)
        (cls.alpha/'README').write_text('alpha\n')
        subprocess.run(git + ['add', 'README'], check=True)
        subprocess.run(git + ['commit', '-q', '-m', 'init'], check=True)
        subprocess.run(['/usr/bin/git', 'clone', '-q', '--bare', str(cls.alpha), str(cls.gamma)], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(cls.gamma), 'worktree', 'add', '-q', str(cls.gamma/'main'), 'main'], check=True)
        subprocess.run(['/usr/bin/git', '-C', str(cls.gamma), 'worktree', 'add', '-q', str(cls.gamma/'release'), '-b', 'release-line'],
                       check=True)
        (s.root/'config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(s.root/'projects') + '/*\n'
                                                       '  aliases:\n    - ' + str(cls.delta) + ': Delta Notes\n')
        cls.base = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'base', '-c', str(cls.beta), SHELL)
        cls.base_window = s.tmux('display-message', '-p', '-t', cls.base + ':', '#{window_id}')
        s.launch(LAUNCH_ARGS)

    def setUp(self):
        self.close_palette()
        self.show_view('topics')

    def new_session(self, name, directory, topic=None, command=SHELL):
        sid = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, '-c', str(directory), command)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', sid)
        self.addCleanup(self.select_window, self.base_window)
        if topic:
            self.s.tmux('set-option', '-t', sid, '@muxify_topic', topic)
        return sid

    def write_topic(self, topic_id, title, home, **fields):
        """A Topic file as a person writes one. Reopen names the Session after the title's slug, so a title
        such as "Sw dormant" for id sw-dormant keeps the Session name predictable."""
        with open(self.topics_dir/(topic_id + '.json'), 'w') as handle:
            handle.write(json.dumps(dict(id=topic_id, title=title, slug=topic_id, **fields)))

    def records(self):
        out = {}
        for path in self.topics_dir.glob('*.json'):
            try:
                out[path.stem] = json.loads(path.read_text())
            except json.JSONDecodeError:
                pass
        return out

    def window_of(self, sid):
        return self.s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')

    def client_sessions(self):
        return self.s.tmux('list-clients', '-F', '#{session_name}').split()

    def client_windows(self):
        return self.s.tmux('list-clients', '-F', '#{window_id}').split()

    def select_window(self, window):
        """Moves the app's tmux client to the Window, as tmux navigation does, and lets the app see it."""
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty}').split():
            self.s.tmux('switch-client', '-c', tty, '-t', window)
        self.s.wait_shown(window)

    def describe(self, key, rs):
        row = self.s.row(key, rs)
        return '%s: %s | %s' % (key, row.get('accessibilityLabel', ''), row.get('accessibilityValue', ''))

    def rows_until(self, predicate, seconds=10):
        start = time.monotonic()
        rs = []
        while time.monotonic() - start < seconds:
            rs = self.s.rows()
            if predicate(rs):
                return time.monotonic() - start, rs
        return None, rs

    def show_view(self, name):
        key = 'sidebar-view-' + name
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no Sidebar mode button ' + key)
        if self.s.row(key).get('accessibilityValue') != 'selected':
            self.s.act('press', key)
        self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityValue') == 'selected', key + ' not selected')

    def open_palette(self):
        """Presses the View menu item until the palette shows. SwiftUI rebuilds the menu a moment after the state it
        reads changes, and a press in that moment can miss."""
        def opened():
            self.s.driver('press', 'Go to…')
            return self.rows_until(lambda rs: self.s.has('palette-search', rs), seconds=3)[0] is not None
        wait(opened, 'the palette did not open', seconds=20)
        return self.s.rows()

    def close_palette(self):
        # A palette that a check's last press closes can still be in the dump, and gone at the action.
        if self.s.has('palette-search'):
            self.s.driver('action', 'palette-search', 'Close')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close')

    def search(self, text, key):
        """Types text into the palette field until the row with key shows. A set without focus fills the field but
        not its binding, and Worktree rows follow git a moment after the palette opens, so the search is set again."""
        def searched():
            self.s.act('focus', 'palette-search')
            self.s.act('set', 'palette-search', text)
            return self.rows_until(lambda rs: self.s.has(key, rs), seconds=3)[0] is not None
        wait(searched, 'no row %s for %r' % (key, text), seconds=20)
        return self.s.rows()

    def topic_row_ids(self, rs):
        return [key for key in self.s.ids(rs) if key.startswith('palette-row-topic-')]

    def session_row(self, sid):
        return 'palette-row-session:' + sid

    def project_row(self, path):
        return 'palette-row-project:' + str(path)

    def choose_reopen(self, session):
        """↩ on a Settled row shows the Topic's Reopen choice and creates nothing; its Reopen button does."""
        self.s.wait_rows(lambda rs: self.s.has('reopen-choice-reopen', rs), 'the Topic did not show its Reopen choice')
        self.assertNotEqual(self.s.tmux_ok('has-session', '-t', '=' + session).returncode, 0, 'the Reopen choice created a Session')
        self.s.act('press', 'reopen-choice-reopen')

    def test_return_on_a_dormant_topic_reopens_it_and_goes_there(self):
        self.write_topic('sw-dormant', 'Sw dormant', self.beta,
                         sessions=[remembered_session(self.beta, 'sw-dormant', windows=[dict(directory=str(self.beta), name='shell')])])
        rs = self.open_palette()
        key = 'palette-row-topic-sw-dormant'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Dormant Topic row did not show')
        self.assertIn('Reopen', self.describe(key, rs), 'a Dormant row does not say Reopen')
        self.s.act('press', key)
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=beta/sw-dormant').returncode == 0, 'Reopen did not create the Session', seconds=15)
        wait(lambda: 'beta/sw-dormant' in self.client_sessions(), 'the client did not go to the reopened Session', seconds=10)
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close after ↩')
        self.assertFalse(self.s.has('reopen-choice-reopen'), '↩ on a Dormant row showed the Reopen choice')

    def test_return_on_a_snoozed_topic_with_a_window_goes_there_and_keeps_the_snooze(self):
        self.write_topic('sw-snoozed-go', 'Sw snoozed go', self.beta, snoozed_until='never')
        window = self.window_of(self.new_session('beta/sw-snoozed-go', self.beta, topic='sw-snoozed-go'))
        self.select_window(self.base_window)
        if self.s.row('snoozed-topics').get('accessibilityValue') == 'expanded':
            self.s.act('press', 'snoozed-topics')
        key = 'palette-row-topic-sw-snoozed-go'
        self.open_palette()
        self.search('snoozed go', key)
        self.s.act('press', key)
        wait(lambda: window in self.client_windows(), 'the client did not go to the Snoozed Topic\'s Window', seconds=10)
        rs = self.s.wait_rows(lambda rs: self.s.row('topic-window-' + window, rs).get('accessibilityValue') == 'selected',
                              'the Sidebar does not show the Window selected: %s, %s' % (
                                  self.describe('snoozed-topics', self.s.rows()), self.s.ids()))
        self.assertEqual(self.records()['sw-snoozed-go'].get('snoozed_until'), 'never', 'going to the Topic changed its Snooze')
        self.assertIn(window, self.client_windows(), 'the selection moved away from the Snoozed Topic')

    def test_return_on_a_dormant_snoozed_topic_reopens_it_and_keeps_the_snooze(self):
        self.write_topic('sw-snoozed-dormant', 'Sw snoozed dormant', self.beta, snoozed_until='never',
                         sessions=[remembered_session(self.beta, 'sw-snoozed-dormant', windows=[dict(directory=str(self.beta), name='shell')])])
        key = 'palette-row-topic-sw-snoozed-dormant'
        self.open_palette()
        rs = self.search('snoozed dormant', key)
        self.assertIn('Reopen', self.describe(key, rs), 'a Dormant Snoozed row does not say Reopen')
        self.s.act('press', key)
        wait(lambda: 'beta/sw-snoozed-dormant' in self.client_sessions(), 'the client did not go to the reopened Session', seconds=15)
        self.s.wait_shown('=beta/sw-snoozed-dormant:')
        self.assertEqual(self.records()['sw-snoozed-dormant'].get('snoozed_until'), 'never', 'Reopen changed the Snooze')

    def test_typing_sett_finds_a_settled_topic_by_its_outcome_and_return_shows_its_reopen_choice(self):
        self.write_topic('sw-settled', 'Sw settled', self.alpha, settled_at='2031-01-01T10:00:00Z', outcome='Shipped proof',
                         sessions=[remembered_session(self.alpha, 'sw-settled', windows=[dict(directory=str(self.alpha), name='shell')])])
        key = 'palette-row-topic-sw-settled'
        self.open_palette()
        rs = self.search('sett proof', key)
        ids = self.s.ids(rs)
        self.assertIn('palette-section-settled', ids, 'no Settled section header')
        self.assertLess(ids.index('palette-section-settled'), ids.index(key), 'the Settled row is not under its header')
        self.assertIn('Shipped proof', self.describe(key, rs), 'the row does not show the outcome that matched')
        self.s.act('press', key)
        self.assertIn('settled_at', self.records()['sw-settled'], 'the Reopen choice changed the record')
        self.choose_reopen('alpha/sw-settled')
        wait(lambda: 'settled_at' not in self.records().get('sw-settled', {'settled_at': 1}), 'Reopen did not clear settled_at', seconds=15)
        wait(lambda: 'alpha/sw-settled' in self.client_sessions(), 'the client did not go to the reopened Session', seconds=10)

    def test_launch_row_opens_exact_name_and_is_replaced_by_its_running_session_row(self):
        key = self.project_row(self.gamma/'release')
        self.open_palette()
        rs = self.search('gamma/rel', key)
        self.assertIn('↩ open', self.describe(key, rs), 'a row without a Session does not offer open')
        self.s.act('press', key)
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=gamma/release').returncode == 0, 'no Session gamma/release was created', seconds=10)
        wait(lambda: 'gamma/release' in self.client_sessions(), 'the client did not go to the new Session', seconds=10)
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=gamma/release', '@muxify_topic'), '', 'the Session is not in No Topic')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close after open')
        sid = self.s.tmux('display-message', '-p', '-t', '=gamma/release:', '#{session_id}')
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', sid)
        self.addCleanup(self.select_window, self.base_window)

        self.select_window(self.base_window)
        self.open_palette()
        rs = self.search('gamma/rel', self.session_row(sid))
        self.assertFalse(self.s.has(key, rs), 'an exact running name must suppress its launch row')
        self.s.act('press', self.session_row(sid))
        wait(lambda: 'gamma/release' in self.client_sessions(), 'the client did not go back to the Session', seconds=10)
        time.sleep(REFRESH_LIMIT)
        names = [name for name in self.s.tmux('list-sessions', '-F', '#{session_name}').split() if name.startswith('gamma/release')]
        self.assertEqual(names, ['gamma/release'], 'a second press made another Session')

    def test_new_session_on_a_running_session_row_creates_another_in_no_topic(self):
        sid = self.new_session('gamma/main', self.gamma/'main')
        key = self.session_row(sid)
        self.open_palette()
        rs = self.search('gamma/main', key)
        self.assertFalse(self.s.has(self.project_row(self.gamma/'main'), rs), 'the exact name still offers a launch row')
        self.s.act('action', key, 'New Session')
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=gamma/main+2').returncode == 0, 'no Session gamma/main+2 was created', seconds=10)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', '=gamma/main+2')
        self.addCleanup(self.select_window, self.base_window)
        wait(lambda: 'gamma/main+2' in self.client_sessions(), 'the client did not go to the new Session', seconds=10)
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close after New Session')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=gamma/main+2', '@muxify_topic'), '', 'the Session is not in No Topic')
        path = self.s.tmux('display-message', '-p', '-t', '=gamma/main+2:', '#{pane_current_path}')
        self.assertEqual(os.path.realpath(path), os.path.realpath(self.gamma/'main'), 'the new Session did not start in the Worktree')
        time.sleep(REFRESH_LIMIT)
        names = sorted(name for name in self.s.tmux('list-sessions', '-F', '#{session_name}').split() if name.startswith('gamma/main'))
        self.assertEqual(names, ['gamma/main', 'gamma/main+2'], 'New Session did not start exactly one more Session')

    def test_a_project_alias_names_the_row_typing_alias_or_folder_finds_it_and_its_session_keeps_the_folder_name(self):
        key = self.project_row(self.delta)
        self.open_palette()
        rs = self.search('delta notes', key)
        self.assertIn('Delta Notes', self.describe(key, rs), 'the row does not show the alias')
        rs = self.search('delta', key)
        self.assertIn('Delta Notes', self.describe(key, rs), 'typing the folder name does not find the aliased row')
        self.s.act('press', key)
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=delta').returncode == 0, 'no Session delta was created', seconds=10)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', '=delta')
        self.addCleanup(self.select_window, self.base_window)
        names = self.s.tmux('list-sessions', '-F', '#{session_name}').splitlines()
        self.assertNotIn('Delta Notes', names, 'the alias named a tmux Session')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close after open')

    def test_a_folder_made_after_the_config_loaded_is_a_project_row_when_the_palette_opens(self):
        late = self.s.root/'projects/latecomer'
        late.mkdir()
        self.open_palette()
        self.search('latecomer', self.project_row(late))

    def test_paste_path_on_a_project_row_types_its_path_at_the_prompt_without_enter(self):
        sid = self.new_session('sw-paste', self.beta)
        window = self.window_of(sid)
        self.select_window(window)
        pane = self.s.tmux('display-message', '-p', '-t', window, '#{pane_id}')
        wait(lambda: self.s.tmux('capture-pane', '-p', '-t', pane).strip() != '', 'the shell in sw-paste did not start', seconds=10)
        key = self.project_row(self.gamma/'release')
        self.open_palette()
        self.search('gamma/rel', key)
        self.s.act('action', key, 'Paste Path')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close after Paste Path')
        path = str(self.gamma/'release')
        wait(lambda: path in self.s.tmux('capture-pane', '-p', '-t', pane), 'the path was not typed in sw-paste', seconds=10)
        time.sleep(REFRESH_LIMIT)
        screen = self.s.tmux('capture-pane', '-p', '-t', pane)
        last = [line for line in screen.splitlines() if line.strip()][-1]
        self.assertTrue(last.rstrip().endswith(path), 'the path is not waiting at the prompt: %r' % screen)
        self.assertEqual(set(self.client_windows()), {window}, 'Paste Path moved the client')

    def test_snooze_on_a_topic_row_uses_the_palette_and_a_bare_1300_snoozes_until_the_next_1300(self):
        self.write_topic('sw-snooze', 'Sw snooze', self.beta)
        key = 'palette-row-topic-sw-snooze'
        self.open_palette()
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'the Topic row did not show')
        self.s.act('action', key, 'Snooze Topic')
        rs = self.s.wait_rows(lambda rs: self.s.has('palette-accept', rs), 'Snooze did not open the Snooze palette')
        self.assertTrue(self.s.has('palette-search', rs), 'Snooze did not retain the palette input')
        self.assertTrue(any('Sw snooze › Snooze' in r.get('accessibilityLabel', '') + r.get('accessibilityValue', '') for r in rs),
                        'the Snooze palette is not for the Topic: %s' % [r.get('accessibilityLabel') for r in rs])

        def next_1300():
            now = datetime.datetime.now().astimezone()
            today = now.replace(hour=13, minute=0, second=0, microsecond=0)
            return today if today > now else today + datetime.timedelta(days=1)
        expected = {next_1300()}

        def typed():
            self.s.act('focus', 'palette-search')
            self.s.act('set', 'palette-search', '1300')
            return self.rows_until(lambda rs: self.s.has('palette-row-typed', rs), seconds=3)[0] is not None
        wait(typed, 'the typed 1300 did not show as a choice', seconds=20)
        self.s.act('press', 'palette-accept')
        expected.add(next_1300())
        self.s.wait_rows(lambda rs: not self.s.has('palette-accept', rs), 'the Snooze palette did not close')
        stored = wait(lambda: self.records().get('sw-snooze', {}).get('snoozed_until'), 'the Topic was not Snoozed', seconds=10)
        until = datetime.datetime.strptime(stored, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        self.assertIn(until, expected, 'snoozed_until %s is not the next 13:00 local time %s' % (stored, sorted(expected)))

    def test_sessions_mode_finds_a_topic_session_by_name_on_its_project_row_and_goes_into_it(self):
        self.write_topic('sw-join', 'Sw join', self.alpha)
        sid = self.new_session('alpha/sw-join', self.alpha, topic='sw-join')
        window = self.window_of(sid)
        self.show_view('sessions')
        self.open_palette()
        rs = self.search('sw-join', self.project_row(self.alpha))
        self.assertFalse(self.s.has(self.session_row(sid), rs), 'a Session in a Session Path has a row of its own')
        self.s.act('press', self.project_row(self.alpha))
        wait(lambda: window in self.client_windows(), 'the client did not go into the Topic Session', seconds=10)

    def open_move(self):
        self.s.act('press', 'Move Session…')
        return self.s.wait_rows(lambda rs: self.s.has('palette-row-new-topic', rs), 'Move did not open')

    def test_move_makes_a_new_topic_titled_by_the_query_from_the_selected_session(self):
        sid = self.new_session('sw-move-src', self.beta)
        self.select_window(self.window_of(sid))
        self.open_move()
        rs = self.search('Moved by Move', 'palette-row-new-topic')
        self.assertIn('“Moved by Move”', self.describe('palette-row-new-topic', rs), 'New Topic is not titled by the query')
        self.s.act('press', 'palette-row-new-topic')
        record = wait(lambda: [r for r in self.records().values() if r.get('title') == 'Moved by Move'],
                      'no Topic record titled by the query', seconds=15)[0]
        wait(lambda: self.s.tmux_ok('show-options', '-qv', '-t', sid, '@muxify_topic').stdout.strip() == record['id'],
             'the Session did not move into the new Topic', seconds=10)
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', sid + ':', '#{session_name}'), 'beta/moved-by-move')

    def test_move_blocks_a_topic_with_a_session_in_the_same_project(self):
        self.write_topic('sw-occupied', 'Sw occupied', self.beta)
        self.new_session('beta/sw-occupied', self.beta, topic='sw-occupied')
        sid = self.new_session('sw-move-blocked', self.beta)
        self.select_window(self.window_of(sid))
        self.open_move()
        key = 'palette-row-topic-sw-occupied'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'the occupied Topic is not listed')
        self.assertEqual(self.s.row(key, rs).get('accessibilityValue'), 'has a beta Session', self.describe(key, rs))
        self.s.driver('press', key)
        time.sleep(REFRESH_LIMIT)
        self.assertTrue(self.s.has('palette-search'), 'pressing a blocked row closed Move')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', sid, '@muxify_topic'), '', 'the Session moved into the occupied Topic')
        self.close_palette()

    def test_move_menu_item_is_disabled_when_topics_are_off(self):
        config = self.s.root/'config/muxify/config.yaml'
        text = config.read_text()
        self.addCleanup(config.write_text, text)
        config.write_text(text + 'sidebar:\n  topics: false\n')
        self.s.wait_rows(lambda rs: not self.s.has('sidebar-view-topics', rs), 'the Sidebar still offers Topics mode')

        def refused():
            # The menu follows the Sidebar about a second later; a press that still lands opens Move.
            if self.s.driver('press', 'Move Session…')['pressed']:
                self.close_palette()
                return False
            return True
        wait(refused, 'the menu item stays enabled with Topics off', seconds=10)
        self.assertIsNone(self.rows_until(lambda rs: self.s.has('palette-search', rs), seconds=2)[0], 'Move opened')
        config.write_text(text)
        self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the Sidebar did not offer Topics mode again')
        wait(lambda: self.s.driver('press', 'Move Session…')['pressed'], 'the menu item did not come back', seconds=10)
        self.close_palette()

    def test_topic_palette_ranks_other_live_topics_by_visits_then_current_then_dormant_and_empty(self):
        windows = {}
        for name in ['sw-order-older', 'sw-order-recent', 'sw-order-current']:
            self.addCleanup(remove_topic, self.topics_dir/(name + '.json'))
            self.write_topic(name, 'Sw ' + name[3:], self.beta, pinned=name != 'sw-order-recent')
            windows[name] = self.window_of(self.new_session('beta/' + name, self.beta, topic=name))
        dormant, empty = 'sw-order-dormant', 'sw-order-empty-topic'
        for name in [dormant, empty]:
            self.addCleanup(remove_topic, self.topics_dir/(name + '.json'))
        self.write_topic(dormant, 'Sw order dormant', self.beta, pinned=True,
                         sessions=[remembered_session(self.beta, dormant, windows=[dict(directory=str(self.beta), name='shell')])])
        self.write_topic(empty, 'Sw order empty', self.beta)
        for name in ['sw-order-older', 'sw-order-recent', 'sw-order-current']:
            self.select_window(windows[name])
        self.addCleanup(self.close_palette)
        self.open_palette()
        self.s.wait_rows(lambda rs: self.s.has('palette-row-topic-sw-order-recent', rs), 'recent Topic row did not show')
        listed = self.palette_order()
        expected = ['palette-row-topic-' + name for name in ['sw-order-recent', 'sw-order-older', 'sw-order-current']]
        self.assertEqual([key for key in listed if key in expected], expected, listed)
        for name in [dormant, empty]:
            self.assertGreater(listed.index('palette-row-topic-' + name), listed.index(expected[-1]), listed)
        self.s.reveal(expected[0])
        self.assertEqual(self.s.row(expected[0]).get('accessibilityValue'), 'selected', 'the most recent other Topic should be under the cursor')
        self.close_palette()

    def test_no_topic_has_no_row_and_a_no_topic_session_has_a_session_row(self):
        outside = self.s.root/'outside'
        outside.mkdir(exist_ok=True)
        sid = self.new_session('sw-outside', outside)
        window = self.window_of(sid)
        key = self.session_row(sid)
        rs = self.open_palette()
        self.assertFalse(any(k.startswith('palette-row-no-topic') for k in self.s.ids(rs)), 'No Topic has a row')
        rs = self.search('sw-outside', key)
        self.assertIn('session', self.describe(key, rs), 'the row does not say it is a Session')
        self.s.act('press', key)
        wait(lambda: window in self.client_windows(), 'the client did not go to the Session', seconds=10)
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close after go')

    def palette_order(self):
        """The section headers and rows of the open palette, top to bottom. The list is lazy, so it reveals the
        last row it has until no row follows."""
        def listed(rs):
            keys = [r for r in rs if r.get('accessibilityIdentifier', '').startswith(('palette-section-', 'palette-row-'))]
            return [r['accessibilityIdentifier'] for r in sorted(keys, key=lambda r: -frame(r)[1])]
        order = listed(self.s.reveal('palette-section-topics'))
        for _ in range(50):
            more = listed(self.s.reveal(order[-1]))
            more = more[more.index(order[-1]) + 1:]
            if not more:
                return order
            order += [key for key in more if key not in order]
        self.fail('the palette list did not end: %s' % order)

    def test_an_empty_query_lists_topics_sessions_snoozed_and_settled_in_that_order(self):
        empty = self.s.root/'projects/sw-order-empty'
        outside = self.s.root/'outside-order'
        for directory in [empty, outside]:
            directory.mkdir(exist_ok=True)
        self.write_topic('sw-order-open', 'Sw order open', self.beta)
        self.write_topic('sw-order-snoozed', 'Sw order snoozed', self.beta, snoozed_until='never')
        self.write_topic('sw-order-settled', 'Sw order settled', self.beta, settled_at='2031-01-01T10:00:00Z')
        for topic_id in ['sw-order-open', 'sw-order-snoozed', 'sw-order-settled']:
            self.addCleanup(remove_topic, self.topics_dir/(topic_id + '.json'))
        outside_sid = self.new_session('sw-order-outside', outside)
        for sid in [self.new_session('beta/sw-order-open', self.beta, topic='sw-order-open'), outside_sid]:
            self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', sid)
        placed = [('palette-row-topic-sw-order-open', 'topics'), (self.session_row(outside_sid), 'sessions'),
                  (self.project_row(empty), 'sessions'), ('palette-row-topic-sw-order-snoozed', 'snoozed'),
                  ('palette-row-topic-sw-order-settled', 'settled')]
        rows = [row for row, _ in placed]
        self.open_palette()
        # The app sees the new Sessions at its next read of tmux, and the open palette follows.
        order = wait(lambda: (lambda order: order if set(rows) <= set(order) else None)(self.palette_order()),
                     'an empty query does not list every section\'s row: %s' % rows, seconds=10)
        names = ['topics', 'sessions', 'snoozed', 'settled']
        headers = ['palette-section-' + name for name in names]
        self.assertEqual([key for key in order if key.startswith('palette-section-')], headers, order)
        bounds = [order.index(header) for header in headers] + [len(order)]
        for row, name in placed:
            section = names.index(name)
            self.assertTrue(bounds[section] < order.index(row) < bounds[section + 1], '%s is not under %s: %s' % (row, headers[section], order))
        self.close_palette()

    def test_a_no_topic_session_opened_here_shows_as_one_card_after_the_open_topics_and_goes_when_a_topic_is_selected(self):
        s = self.s
        outside = s.root/'outside-slot'
        outside.mkdir(exist_ok=True)
        cards = lambda rs: [key for key in s.ids(rs) if key.startswith('no-topic') and not key.endswith('-more')]
        for topic_id, title, fields in [('sw-slot-open', 'Sw slot open', {}), ('sw-slot-snoozed', 'Sw slot snoozed', dict(snoozed_until='never'))]:
            self.write_topic(topic_id, title, self.beta, **fields)
            self.addCleanup(remove_topic, self.topics_dir/(topic_id + '.json'))
        topic_sid = self.new_session('beta/sw-slot-open', self.beta, topic='sw-slot-open')
        topic_window = self.window_of(topic_sid)
        sid = self.new_session('sw-slot-outside', outside)
        window = self.window_of(sid)
        other = self.new_session('sw-slot-other', outside)
        for session in [sid, other, topic_sid]:
            self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        self.addCleanup(self.select_window, self.base_window)
        self.select_window(topic_window)
        rs = s.wait_rows(lambda rs: s.row('topic-window-' + topic_window, rs).get('accessibilityValue') == 'selected'
                         and s.has('snoozed-topics', rs), 'the Sidebar does not show the Topic Window selected and the Snoozed group')
        self.assertEqual(cards(rs), [], 'the No Topic slot is not empty while a Topic is active')

        self.open_palette()
        self.search('sw-slot-outside', self.session_row(sid))
        s.act('press', self.session_row(sid))
        wait(lambda: window in self.client_windows(), 'the client did not go to the No Topic Session', seconds=10)
        card = 'no-topic-session-' + sid
        rs = s.wait_rows(lambda rs: s.has(card, rs), 'opening a No Topic Session did not show its card: %s' % cards(rs))
        self.assertEqual(cards(rs), [card], 'the Topic list shows more than the opened No Topic Session')
        topic_bottom, _ = frame(s.row('topic-sw-slot-open', rs))
        card_bottom, card_top = frame(s.row(card, rs))
        _, snoozed_top = frame(s.row('snoozed-topics', rs))
        self.assertLessEqual(card_top, topic_bottom, 'the No Topic card is not below the open Topic')
        self.assertGreaterEqual(card_bottom, snoozed_top, 'the No Topic card is not above the Snoozed group')

        self.select_window(topic_window)
        s.wait_rows(lambda rs: cards(rs) == [], 'selecting a Topic Window did not remove the No Topic card')

    def test_a_done_agent_shows_as_the_topic_rows_notification_mark_and_not_as_text(self):
        self.write_topic('sw-finished', 'Sw finished', self.beta)
        # Muxify drops the Unread mark of a Pane whose command is a shell, because its Agent has exited.
        sid = self.new_session('beta/sw-finished', self.beta, topic='sw-finished', command='sleep 600')
        pane = self.s.tmux('display-message', '-p', '-t', sid + ':', '#{pane_id}')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', 'done')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')
        self.select_window(self.base_window)
        self.open_palette()
        key = 'palette-row-topic-sw-finished'
        # The row's label is its mark's Status, title, detail and right column; the mark is the only "done".
        latency, rs = self.rows_until(lambda rs: self.s.row(key, rs).get('accessibilityLabel', '').startswith('done, '))
        self.assertIsNotNone(latency, 'the row has no done mark: ' + self.describe(key, rs))
        self.assertEqual(self.s.row(key, rs)['accessibilityLabel'].count('done'), 1, 'the Status shows as text too: ' + self.describe(key, rs))
        self.close_palette()

    def test_add_session_menu_item_opens_the_palette_for_the_selected_windows_topic(self):
        self.write_topic('sw-add-menu', 'Sw add menu', self.beta, created_at='2026-10-07T00:00:00Z')
        sid = self.new_session('beta/sw-add-menu', self.beta, topic='sw-add-menu')
        self.select_window(self.window_of(sid))
        self.addCleanup(lambda: self.s.has('palette-accept') and self.s.act('press', 'palette-cancel'))
        # The menu follows the selected Window about a second later; a press that lands earlier does nothing.
        wait(lambda: self.s.driver('press', 'Add a Session to Topic…')['pressed'], 'the menu item stays disabled', seconds=10)
        rs = self.s.wait_rows(lambda rs: self.s.has('palette-accept', rs), 'the Add a Session Path palette did not open')
        self.assertTrue(any('Sw add menu › Add a Session' in row.get('accessibilityValue', '') + row.get('accessibilityLabel', '')
                            for row in rs if row.get('accessibilityRole') == 'AXStaticText'),
                        'the palette does not name the selected Window\'s Topic')
        self.s.act('press', 'palette-cancel')
        self.s.wait_rows(lambda rs: not self.s.has('palette-accept', rs), 'the Add a Session Path palette did not close')

    def test_visit_order_survives_an_app_restart(self):
        windows = {}
        for name in ['sw-first', 'sw-second']:
            self.write_topic(name, 'Sw ' + name[3:], self.beta)
            windows[name] = self.window_of(self.new_session('beta/' + name, self.beta, topic=name))
        self.select_window(windows['sw-first'])
        self.select_window(windows['sw-second'])
        self.select_window(self.base_window)
        keys = ['palette-row-topic-sw-first', 'palette-row-topic-sw-second']

        def order():
            rs = self.open_palette()
            rs = self.s.wait_rows(lambda rs: all(self.s.has(key, rs) for key in keys), 'the Topics did not show')
            self.close_palette()
            return [key for key in self.topic_row_ids(rs) if key in keys]

        self.assertEqual(order(), ['palette-row-topic-sw-second', 'palette-row-topic-sw-first'], 'the Topic visited last is not first')
        self.s.restart_app(LAUNCH_ARGS)
        self.show_view('topics')
        self.assertEqual(order(), ['palette-row-topic-sw-second', 'palette-row-topic-sw-first'], 'the restart lost the visit order')


if __name__ == '__main__':
    unittest.main()
