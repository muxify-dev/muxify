"""Move choices and cancellation through the palette's accessibility actions.

BrowserPanel exposes Submit and history controls so navigation does not take focus.
"""

import json
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/zsh -f'


class PaletteActions(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.project = s.root/'projects/palette'
        cls.project.mkdir(parents=True)
        cls.topics = s.root/'state/muxify/topics'
        cls.topics.mkdir(parents=True, exist_ok=True)
        (s.root/'config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n'
            'command_palettes:\n  - name: Commands\n    keybinding: cmd+shift+p\n    sources: [commands]\n'
            '  - name: Go to…\n    keybinding: cmd+p\n    sources: [topics, sessions]\n'
            '  - name: Verify Windows\n    keybinding: cmd+shift+w\n    sources: [windows]\n')
        cls.base = s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'base', '-c', str(cls.project), SHELL)
        s.tmux('set-option', '-g', 'detach-on-destroy', 'off')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES'])

    def setUp(self):
        # The last check's Close can still be closing the palette, so this Close is a request, not an assertion.
        if self.s.has('palette-search'):
            self.s.driver('action', 'palette-search', 'Close')
            self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette of the last check stays open')
        self.session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}',
                                   '-s', self.id().rsplit('.', 1)[-1], '-c', str(self.project), SHELL)
        self.window = self.s.tmux('display-message', '-p', '-t', self.session + ':', '#{window_id}')
        self.pane = self.s.tmux('display-message', '-p', '-t', self.window, '#{pane_id}')
        self.other_pane = self.s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', self.window, SHELL)
        self.show(self.window)

    def show(self, window):
        """Moves the app's client to the Window, as tmux navigation does, until the app shows it. The app finishes
        the last check's navigation on its own time: the Window it falls back to after a kill, or the Window a
        request opened. That move can land after this one, so the switch repeats until the app shows the Window."""
        def shown():
            for tty in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').splitlines():
                if tty.endswith(' 0'):
                    self.s.tmux('switch-client', '-c', tty.split()[0], '-t', window)
            try:
                self.s.wait_shown(window, seconds=3)
                return True
            except AssertionError:
                return False
        wait(shown, 'the app does not show %s' % window, seconds=20)

    def client_window(self):
        """The Window that the app's terminal shows, as tmux reports it."""
        for line in self.s.tmux('list-clients', '-F', '#{client_control_mode} #{window_id}').splitlines():
            if line.startswith('0 '):
                return line.split()[1]

    def open_move(self):
        wait(lambda: self.s.driver('press', 'Move Pane…')['pressed'], 'Move menu stayed disabled')
        return self.s.wait_rows(lambda rs: self.s.has('palette-row-new-topic', rs), 'Move did not open')

    def type_query(self, value):
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', value)
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == value,
                         'The palette did not keep the typed value')

    def records(self):
        return [json.loads(path.read_text()) for path in self.topics.glob('*.json')]

    def pane_window(self, pane):
        return self.s.tmux('display-message', '-p', '-t', pane, '#{window_id}')

    def test_commands_new_topic_back_restores_search_and_cancel_creates_nothing(self):
        before = self.records()
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Commands search did not show')
        self.type_query('New Topic')
        self.s.act('press', 'palette-row-command-New Topic')
        self.s.wait_rows(lambda rs: 'New Topic' in (self.s.row('palette-breadcrumb', rs).get('accessibilityLabel', '')
                                                  + self.s.row('palette-breadcrumb', rs).get('accessibilityValue', '')),
                         'The Command did not open its Text step')
        self.s.act('action', 'palette-search', 'Back')
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == 'New Topic',
                         'Back did not restore the Commands search')
        self.s.act('press', 'palette-row-command-New Topic')
        self.type_query('Do not create this')
        self.s.act('action', 'palette-search', 'Close')
        self.assertEqual(self.records(), before)

    def test_commands_can_create_a_tmux_window(self):
        before = self.s.tmux('list-windows', '-t', self.session, '-F', '#{window_id}').splitlines()
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Commands search did not show')
        self.type_query('New tmux Window')
        self.s.act('press', 'palette-row-command-New tmux Window')
        created = wait(lambda: list(set(self.s.tmux('list-windows', '-t', self.session, '-F', '#{window_id}').splitlines()) - set(before)),
                       'The Command did not create a Window')
        self.assertEqual(len(created), 1)
        wait(lambda: self.client_window() == created[0], 'The terminal did not go to the new Window')
        self.s.wait_shown(created[0])

    def test_cancel_keeps_panes_sessions_and_topics(self):
        before = self.s.tmux('list-panes', '-a', '-F', '#{session_id} #{window_id} #{pane_id}')
        records = self.records()
        self.open_move()
        self.type_query('Cancelled Topic')
        self.s.act('press', 'palette-scope-window')
        self.s.act('press', 'palette-cancel')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Cancel did not close Move')
        self.assertEqual(self.s.tmux('list-panes', '-a', '-F', '#{session_id} #{window_id} #{pane_id}'), before)
        self.assertEqual(self.records(), records)

    def test_move_pane_creates_the_typed_topic_and_keeps_the_other_pane(self):
        self.open_move()
        self.type_query('Named Pane Topic')
        rs = self.s.wait_rows(lambda rs: 'Named Pane Topic' in self.s.row('palette-row-new-topic', rs).get('accessibilityLabel', ''),
                              'New Topic does not show the typed name')
        row_ids = [key for key in self.s.ids(rs) if key.startswith('palette-row-')]
        self.assertEqual(row_ids[0], 'palette-row-new-topic', row_ids)
        self.s.act('action', 'palette-search', 'Accept')
        record = wait(lambda: next((r for r in self.records() if r.get('title') == 'Named Pane Topic'), None),
                      'Move did not create the named Topic')
        wait(lambda: self.pane_window(self.pane) != self.window, 'The Pane did not move')
        self.s.wait_shown(self.pane_window(self.pane))
        self.assertEqual(self.pane_window(self.other_pane), self.window)
        moved_session = self.s.tmux('display-message', '-p', '-t', self.pane, '#{session_id}')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', moved_session, '@muxify_topic'), record['id'])

    def test_move_window_keeps_both_panes_together(self):
        self.open_move()
        self.s.act('press', 'palette-scope-window')
        self.type_query('Named Window Topic')
        self.s.act('press', 'palette-accept')
        record = wait(lambda: next((r for r in self.records() if r.get('title') == 'Named Window Topic'), None),
                      'Move did not create the Window Topic')
        moved_session = wait(lambda: (lambda sid: sid if sid != self.session else None)(
            self.s.tmux('display-message', '-p', '-t', self.window, '#{session_id}')), 'The Window did not move')
        self.s.wait_shown(self.window)
        self.assertEqual(self.pane_window(self.pane), self.window)
        self.assertEqual(self.pane_window(self.other_pane), self.window)
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', moved_session, '@muxify_topic'), record['id'])

    def test_kill_window_requires_confirm_after_accept_toggle_and_row_press(self):
        wait(lambda: self.s.driver('press', 'Verify Windows')['pressed'], 'Windows palette did not open')
        key = 'palette-row-window:' + self.window
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'The selected Window did not show')
        self.s.act('action', key, 'Kill Window')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-kill-window', rs)
                         and 'This stops' in (self.s.row('palette-note', rs).get('accessibilityLabel', '')
                                              + self.s.row('palette-note', rs).get('accessibilityValue', '')),
                         'Kill confirmation did not finish loading')
        self.s.act('action', 'palette-search', 'Accept')
        self.s.act('action', 'palette-search', 'Toggle Choice')
        self.s.act('press', 'palette-row-kill-window')
        time.sleep(2)
        self.assertEqual(self.pane_window(self.pane), self.window, 'An unconfirmed action killed the Window')
        self.assertTrue(self.s.has('palette-row-kill-window'), 'An unconfirmed action closed the confirmation')
        self.s.act('action', 'palette-search', 'Confirm')
        wait(lambda: self.window not in self.s.tmux('list-windows', '-a', '-F', '#{window_id}').splitlines(),
             'Confirm did not kill the Window')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Confirm did not close the palette')

    def test_kill_window_reviews_new_panes_before_confirming_again(self):
        wait(lambda: self.s.driver('press', 'Verify Windows')['pressed'], 'Windows palette did not open')
        key = 'palette-row-window:' + self.window
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'The selected Window did not show')
        self.s.act('action', key, 'Kill Window')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-kill-window', rs)
                         and 'This stops' in (self.s.row('palette-note', rs).get('accessibilityLabel', '')
                                              + self.s.row('palette-note', rs).get('accessibilityValue', '')),
                         'Kill confirmation did not finish loading')
        extra = self.s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', self.window, SHELL)
        self.s.act('action', 'palette-search', 'Confirm')
        self.s.wait_rows(lambda rs: 'changed' in (self.s.row('palette-note', rs).get('accessibilityLabel', '')
                                                 + self.s.row('palette-note', rs).get('accessibilityValue', '')).lower(),
                         'The changed Pane count did not require review')
        self.assertEqual(self.pane_window(extra), self.window)
        self.s.act('action', 'palette-search', 'Confirm')
        wait(lambda: self.window not in self.s.tmux('list-windows', '-a', '-F', '#{window_id}').splitlines(),
             'The second confirmation did not kill the reviewed Window')

    def test_new_window_with_active_tab_keeps_back_and_forward_history(self):
        pages = [self.s.root/'first.html', self.s.root/'second.html']
        for page in pages:
            page.write_text('<title>' + page.stem + '</title><p>' + page.stem + '</p>')
        first, second = [page.as_uri() for page in pages]
        wait(lambda: self.s.driver('press', 'New Tab')['pressed'], 'New Tab stayed disabled')
        self.s.wait_rows(lambda rs: self.s.has('browser-address', rs), 'The Browser address did not show')
        for page, url in zip(pages, [first, second]):
            self.s.act('press', 'Open Location…')
            self.s.act('focus', 'browser-address')
            self.s.act('set', 'browser-address', url)
            self.s.act('action', 'browser-address', 'Submit')
            wait(lambda: url in self.s.tmux('show-options', '-wqv', '-t', self.window, '@muxify_tabs'),
                 'The Browser did not load ' + url)
            self.s.wait_rows(lambda rs: any(r.get('accessibilityIdentifier', '').startswith('browser-tab-title-')
                                            and r.get('accessibilityValue') == page.stem for r in rs),
                             'The page did not finish loading ' + page.stem)
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.type_query('Move Pane with Active Tab')
        key = 'palette-row-command-Move Pane with Active Tab'
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Move Pane with Active Tab was missing')
        self.s.act('press', key)
        self.s.wait_rows(lambda rs: self.s.row('palette-include-tab', rs).get('accessibilityValue') == 'on',
                         'The Command did not include the active Tab')
        self.s.wait_rows(lambda rs: not self.s.has('palette-note', rs), 'Move did not finish reading the active Pane')
        self.s.act('press', 'palette-row-new-window')
        moved_window = wait(lambda: (lambda wid: wid if wid != self.window else None)(self.pane_window(self.pane)),
                            'The Pane did not move into a new Window')
        self.s.wait_shown(moved_window)
        wait(lambda: second in self.s.tmux('show-options', '-wqv', '-t', moved_window, '@muxify_tabs'),
             'The active Tab did not move')
        for command, url in [('Back', first), ('Forward', second)]:
            self.s.act('press', 'browser-' + command.lower())
            wait(lambda: url in self.s.tmux('show-options', '-wqv', '-t', moved_window, '@muxify_tabs'),
                 command + ' did not retain the transferred Tab history')
            title = 'first' if command == 'Back' else 'second'
            self.s.wait_rows(lambda rs: any(r.get('accessibilityIdentifier', '').startswith('browser-tab-title-')
                                            and r.get('accessibilityValue') == title for r in rs),
                             command + ' did not finish loading the page')
        self.assertEqual(self.s.tmux('show-options', '-wqv', '-t', self.window, '@muxify_tabs'), '')
        self.assertEqual(self.pane_window(self.other_pane), self.window)


if __name__ == '__main__':
    unittest.main()
