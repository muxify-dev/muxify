"""The Go to… Command Palette with its topics and sessions Sources, what ↩ and the row actions do on a
Topic, Settled, Session or Session Path row, and Move, which uses the palette's view.

The driver cannot type keys, so a check opens a palette from its View menu item, closes it with the
search field's Close accessibility action, uses its Back, Show Actions and Escape actions for ⌫, ⌘K and ⎋, and runs New Session and Paste Path through the row's
accessibility actions (UI/CommandPaletteView.swift), which call the same code as ⌘↩ and ⌃Y.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.command_palette
"""

import os
import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, frame, wait
from scripts.verify.topic_records import TopicRecords
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
        cls.store = TopicRecords(s.root/'state/muxify')
        # alpha is a plain repository, beta a plain directory, gamma a bare repository with two checkouts inside its
        # folder.
        cls.alpha = s.root/'projects/alpha'
        cls.beta = s.root/'projects/beta'
        cls.gamma = s.root/'projects/gamma'
        for directory in [cls.alpha, cls.beta]:
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
                                                       'command_palettes:\n'
                                                       '  - {name: Commands, keybinding: cmd+shift+p, sources: [commands]}\n'
                                                       '  - {name: Go to…, keybinding: cmd+p, sources: [topics, sessions]}\n')
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

    def write_topic(self, topic_id, title, **fields):
        """A Topic record, written as a script writes one. Reopen names the Session after the title's slug, so a title
        such as "Sw dormant" for id sw-dormant keeps the Session name predictable."""
        self.store.put(dict(id=topic_id, title=title, slug=topic_id, **fields))

    def records(self):
        return self.store.records()

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

    def open_palette(self, name='Go to…'):
        """Presses the View menu item until the palette shows. SwiftUI rebuilds the menu a moment after the state it
        reads changes, and a press in that moment can miss."""
        def opened():
            self.s.driver('press', name)
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

    def session_path_row(self, path):
        return 'palette-row-session-path:' + str(path)

    def choose_reopen(self, session):
        """↩ on a Settled row shows the Topic's Reopen choice and creates nothing; its Reopen button does."""
        self.s.wait_rows(lambda rs: self.s.has('reopen-choice-reopen', rs), 'the Topic did not show its Reopen choice')
        self.assertNotEqual(self.s.tmux_ok('has-session', '-t', '=' + session).returncode, 0, 'the Reopen choice created a Session')
        self.s.act('press', 'reopen-choice-reopen')

    def test_backspace_in_the_empty_field_keeps_go_to_and_commands_open(self):
        for name in ['Go to…', 'Commands']:
            self.open_palette(name)
            self.s.act('action', 'palette-search', 'Back')
            time.sleep(REFRESH_LIMIT)
            self.assertTrue(self.s.has('palette-search'), 'Backspace in the empty field closed ' + name)
            self.close_palette()

    def test_escape_hides_the_actions_menu_and_a_second_escape_closes_the_palette(self):
        self.open_palette('Commands')
        self.s.act('action', 'palette-search', 'Show Actions')
        self.s.wait_rows(lambda rs: self.s.has('palette-actions-menu', rs), 'Cmd-K did not show the actions menu')
        self.s.act('action', 'palette-search', 'Escape')
        self.s.wait_rows(lambda rs: not self.s.has('palette-actions-menu', rs), 'Escape did not hide the actions menu')
        time.sleep(REFRESH_LIMIT)
        self.assertTrue(self.s.has('palette-search'), 'Escape closed the palette while the actions menu showed')
        self.s.act('action', 'palette-search', 'Escape')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'a second Escape did not close the palette')

    def test_return_on_a_dormant_topic_reopens_it_and_goes_there(self):
        self.write_topic('sw-dormant', 'Sw dormant',
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

    def test_typing_sett_finds_a_settled_topic_by_its_title_and_return_shows_its_reopen_choice(self):
        self.write_topic('sw-settled', 'Sw settled', settled_at='2031-01-01T10:00:00Z',
                         sessions=[remembered_session(self.alpha, 'sw-settled', windows=[dict(directory=str(self.alpha), name='shell')])])
        key = 'palette-row-topic-sw-settled'
        self.open_palette()
        rs = self.search('sett sw', key)
        ids = self.s.ids(rs)
        self.assertNotIn('palette-section-settled', ids, 'a query still lists Settled Topics under their own header')
        self.assertLess(ids.index('palette-section-topics'), ids.index(key), 'the Settled row is not among the Topics')
        self.s.act('press', key)
        self.assertIn('settled_at', self.records()['sw-settled'], 'the Reopen choice changed the record')
        self.choose_reopen('alpha/sw-settled')
        wait(lambda: 'settled_at' not in self.records().get('sw-settled', {'settled_at': 1}), 'Reopen did not clear settled_at', seconds=15)
        wait(lambda: 'alpha/sw-settled' in self.client_sessions(), 'the client did not go to the reopened Session', seconds=10)

    def test_launch_row_opens_a_session_with_the_exact_name_in_no_topic(self):
        key = self.session_path_row(self.gamma/'release')
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

    def test_new_session_on_a_running_session_row_creates_another_in_no_topic(self):
        sid = self.new_session('gamma/main', self.gamma/'main')
        key = self.session_row(sid)
        self.open_palette()
        rs = self.search('gamma/main', key)
        self.assertFalse(self.s.has(self.session_path_row(self.gamma/'main'), rs), 'the exact name still offers a launch row')
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

    def test_a_folder_made_after_the_config_loaded_is_a_session_path_row_when_the_palette_opens(self):
        late = self.s.root/'projects/latecomer'
        late.mkdir()
        self.open_palette()
        self.search('latecomer', self.session_path_row(late))

    def test_paste_path_on_a_session_path_row_types_its_path_at_the_prompt_without_enter(self):
        sid = self.new_session('sw-paste', self.beta)
        window = self.window_of(sid)
        self.select_window(window)
        pane = self.s.tmux('display-message', '-p', '-t', window, '#{pane_id}')
        wait(lambda: self.s.tmux('capture-pane', '-p', '-t', pane).strip() != '', 'the shell in sw-paste did not start', seconds=10)
        key = self.session_path_row(self.gamma/'release')
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
        # ADR 0047: the moved Session keeps its own name as the base, whatever its folder is named.
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', sid + ':', '#{session_name}'), 'sw-move-src/moved-by-move')

    def test_move_into_a_topic_with_a_session_in_the_same_folder_joins_it_under_the_sessions_own_name(self):
        """ADR 0047: a Topic groups Sessions, so a Session in the same folder as a member does not block the move."""
        self.write_topic('sw-occupied', 'Sw occupied')
        self.new_session('beta/sw-occupied', self.beta, topic='sw-occupied')
        sid = self.new_session('sw-move-joins', self.beta)
        self.select_window(self.window_of(sid))
        self.open_move()
        key = 'palette-row-topic-sw-occupied'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'the Topic with a beta Session is not listed')
        self.s.act('press', key)
        wait(lambda: self.s.tmux_ok('show-options', '-qv', '-t', sid, '@muxify_topic').stdout.strip() == 'sw-occupied',
             'the Session did not move into the Topic: ' + self.describe(key, rs), seconds=10)
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Move did not close after the move')
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', sid + ':', '#{session_name}'), 'sw-move-joins/sw-occupied')

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

    def test_a_no_topic_session_opened_here_shows_as_one_card_after_the_open_topics_and_goes_when_a_topic_is_selected(self):
        s = self.s
        outside = s.root/'outside-slot'
        outside.mkdir(exist_ok=True)
        cards = lambda rs: [key for key in s.ids(rs) if key.startswith('no-topic') and not key.endswith('-more')]
        for topic_id, title, fields in [('sw-slot-open', 'Sw slot open', {}), ('sw-slot-settled', 'Sw slot settled', dict(settled_at='2031-01-01T10:00:00Z'))]:
            self.write_topic(topic_id, title, **fields)
            self.addCleanup(self.store.remove, topic_id)
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
                         and s.has('settled-topics', rs), 'the Sidebar does not show the Topic Window selected and the Settled group')
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
        _, settled_top = frame(s.row('settled-topics', rs))
        self.assertLessEqual(card_top, topic_bottom, 'the No Topic card is not below the open Topic')
        self.assertGreaterEqual(card_bottom, settled_top, 'the No Topic card is not above the Settled group')

        self.select_window(topic_window)
        s.wait_rows(lambda rs: cards(rs) == [], 'selecting a Topic Window did not remove the No Topic card')

    def test_add_session_names_the_selected_windows_topic_and_moves_a_running_session_into_it(self):
        sid = self.new_session('sw-add-candidate', self.alpha)
        self.write_topic('sw-add-running', 'Sw add running')
        self.addCleanup(self.store.remove, 'sw-add-running')
        self.select_window(self.window_of(self.new_session('beta/sw-add-running', self.beta, topic='sw-add-running')))
        # The menu follows the selected Window about a second later; a press that lands earlier does nothing.
        wait(lambda: self.s.driver('press', 'Add a Session to Topic…')['pressed'], 'Add a Session stays disabled', seconds=10)
        self.s.wait_rows(lambda rs: 'Sw add running › Add a Session' in self.describe('palette-breadcrumb', rs),
                         'Add a Session did not open for the selected Window\'s Topic')
        key = 'palette-row-running-' + sid
        self.search('sw-add-candidate', key)
        self.s.act('press', key)
        wait(lambda: self.s.tmux('show-options', '-qv', '-t', sid, '@muxify_topic') == 'sw-add-running',
             'the running Session did not move into the Topic')
        self.s.wait_shown(self.window_of(sid))
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the Session move did not finish')

    def test_visit_order_survives_an_app_restart(self):
        windows = {}
        for name in ['sw-first', 'sw-second']:
            self.write_topic(name, 'Sw ' + name[3:])
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
