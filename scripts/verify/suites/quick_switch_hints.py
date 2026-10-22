"""HintVerification gives the Debug App Window accessibility actions for modifier input and resolved shortcuts.

The suite calls production hold state and Config dispatch without posting keys or taking focus.
HintTests separately checks NSEvent conversion and the exact delay.
"""

import json
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait


class QuickSwitchHints(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        (s.root/'config/muxify/config.yaml').write_text('keybindings:\n  select_window_1: ctrl+w\n')
        topics = s.root/'state/muxify/topics'
        topics.mkdir()
        # The Dormant Topic remembers no Session and has no Home Session Path, so going to it shows its empty Topic view.
        for name, title, pinned, home in [('first', 'Pinned Topic', True, str(s.root)), ('dormant', 'Dormant Topic', False, None)]:
            (topics/(name + '.json')).write_text(json.dumps(dict(
                id=name, title=title, slug=name, home_project=home, pinned=pinned,
                created_at='2026-01-01T00:00:00Z', order=0 if pinned else 1)))
        cls.session, cls.first = s.tmux('new-session', '-d', '-P', '-F', '#{session_id} #{window_id}',
                                      '-s', 'topic', '-c', str(s.root), '/bin/zsh -f').split()
        s.tmux('set-option', '-t', cls.session, '@muxify_topic', 'first')
        cls.second = s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', cls.session, '/bin/zsh -f')
        cls.no_topic_session, cls.no_topic = s.tmux('new-session', '-d', '-P', '-F', '#{session_id} #{window_id}',
                                                   '-s', 'no-topic', '/bin/zsh -f').split()
        for option, value in [('@muxify_tabs', 'data:text/html,one data:text/html,two'),
                              ('@muxify_active_tab', '0'), ('@muxify_browser', 'on')]:
            s.tmux('set-option', '-w', '-t', cls.first, option, value)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'topics'])
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(), 'no app client')

    def input(self, action):
        self.s.act('action', 'quick-switch-input', action)

    def select(self, window):
        for client in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').splitlines():
            if client.endswith(' 0'):
                self.s.tmux('switch-client', '-c', client.split()[0], '-t', window)
        self.s.wait_shown(window)

    def value(self, key, rows=None):
        return self.s.row(key, rows).get('accessibilityValue') if self.s.has(key, rows) else None

    def configure(self, hints='', keybindings='  select_window_1: ctrl+w\n'):
        (self.s.root/'config/muxify/config.yaml').write_text('keybindings:\n' + keybindings + hints)

    def setUp(self):
        self.configure()
        if self.s.has('palette-search'):
            self.s.act('action', 'palette-search', 'Close')
        self.input('Release modifiers')
        self.select(self.first)
        if not self.s.has('sidebar-panel'):
            self.s.act('press', 'toggle-sidebar')
        self.s.act('press', 'sidebar-view-topics')
        self.s.wait_rows(lambda rows: self.s.has('topic-first', rows), 'initial Topic card not shown')
        self.s.act('action', 'topic-first', 'Go to Topic')
        self.s.wait_rows(lambda rows: self.value('topic-window-' + self.first, rows) == 'selected'
                         and not self.s.has('empty-topic-title', rows)
                         and self.value('hint-topic-first', rows) == '1', 'initial Topic and rest Hint not shown')

    def tearDown(self):
        self.input('Release modifiers')

    def test_card_window_and_terminal_hints_share_control(self):
        self.input('Hold Control')
        rows = self.s.wait_rows(lambda rows: self.s.has('hint-window-' + self.first, rows)
                               and self.s.has('hint-topic-first', rows) and self.s.has('hint-terminal', rows),
                               'combined Hints did not appear')
        self.assertEqual(self.s.row('hint-topic-first', rows).get('accessibilityValue'), '⌃1')
        self.assertEqual(self.s.row('hint-window-' + self.first, rows).get('accessibilityValue'), '⌃W')
        self.s.act('snapshot', '', str(self.s.root/'hints.png'))
        self.input('Release modifiers')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == '1', 'release did not restore rest Hint')

    def test_card_shortcuts_reach_topics_and_never_no_topic_sessions(self):
        self.input('Press ⌃2')
        self.s.wait_rows(lambda rows: not self.s.has('hint-terminal', rows)
                         and self.s.has('empty-topic-title', rows)
                         and self.s.row('empty-topic-title', rows).get('accessibilityValue') == 'Dormant Topic',
                         'Dormant Topic not shown')
        self.input('Hold Control')
        time.sleep(0.45)
        self.assertFalse(self.s.has('hint-terminal'), 'Dormant placeholder has a Terminal Hint')
        self.input('Release modifiers')
        self.input('Press ⌃3')
        time.sleep(2)
        self.assertEqual(self.value('empty-topic-title'), 'Dormant Topic', 'a No Topic Session has a card number')
        self.select(self.no_topic)
        card = 'no-topic-session-' + self.no_topic_session
        self.s.wait_rows(lambda rows: self.s.has(card, rows), 'opened No Topic card missing')
        self.input('Hold Control')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == '⌃1', 'no hold Hint')
        self.assertFalse(self.s.has('hint-session-' + self.no_topic_session), 'opened No Topic card has a Hint')
        self.input('Release modifiers')
        self.s.act('press', 'toggle-sidebar')
        self.input('Press ⌃1')
        self.s.wait_shown(self.first)
        self.input('Release modifiers')
        self.input('Hold Control')
        time.sleep(0.45)
        self.assertFalse(self.s.has('hint-topic-first'), 'hidden Sidebar has Hints')

    def test_hidden_browser_tab_shortcut_selects_and_shows_browser(self):
        if self.s.has('browser-panel'):
            self.s.act('press', 'toggle-browser')
        self.input('Hold Option')
        time.sleep(0.45)
        self.assertFalse(any(key.startswith('hint-tab-') for key in self.s.ids()), 'hidden Browser has Tab Hints')
        self.input('Press ⌥2')
        self.s.wait_rows(lambda rows: self.s.has('browser-panel', rows), 'Tab shortcut did not show Browser')
        wait(lambda: self.s.tmux('show-option', '-wqv', '-t', self.first, '@muxify_active_tab') == '1',
             'Tab shortcut did not select the second Tab')
        self.input('Release modifiers')
        self.input('Hold Option')
        rows = self.s.wait_rows(lambda rows: len([key for key in self.s.ids(rows) if key.startswith('hint-tab-') and str(self.value(key, rows)).startswith('⌥')]) == 2,
                               'the Browser did not show both Tab Hints')
        self.assertTrue(self.s.has('hint-terminal', rows))

    def test_key_suppression_exact_modifiers_and_palette_reset(self):
        self.input('Hold Control Command')
        time.sleep(0.45)
        self.assertEqual(self.value('hint-topic-first'), '1', 'extra modifier matched Control')
        self.input('Release modifiers')
        self.input('Hold Control')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == '⌃1', 'no Hint')
        self.input('Other key')
        self.input('Hold Control')
        time.sleep(0.45)
        self.assertEqual(self.value('hint-topic-first'), '1', 'key suppression restarted Hints')
        self.input('Release modifiers')
        self.input('Hold Control')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == '⌃1', 'no Hint after release')
        self.s.act('action', 'topic-first', 'Rename Topic…')
        self.s.wait_rows(lambda rows: self.s.has('palette-search', rows) and self.value('hint-topic-first', rows) == '1',
                         'palette did not clear Hints')

    def test_sessions_mode_hints_follow_rendered_card_order(self):
        self.s.act('press', 'sidebar-view-sessions')
        rows = self.s.wait_rows(lambda rows: self.s.has('session-' + self.session, rows)
                               and self.s.has('session-' + self.no_topic_session, rows), 'Session cards missing')
        cards = [key.removeprefix('session-') for key in self.s.ids(rows)
                 if key in {'session-' + self.session, 'session-' + self.no_topic_session}]
        self.assertEqual(len(cards), 2)
        self.input('Hold Control')
        rows = self.s.wait_rows(lambda rows: all(str(self.value('hint-session-' + card, rows)).startswith('⌃') for card in cards),
                               'Session Hints missing')
        for index, card in enumerate(cards, 1):
            self.assertEqual(self.s.row('hint-session-' + card, rows).get('accessibilityValue'), '⌃' + str(index))
        self.input('Press ⌃' + str(cards.index(self.no_topic_session) + 1))
        self.s.wait_shown(self.no_topic)

    def test_rest_defaults_and_live_surface_switches(self):
        self.assertEqual(self.value('hint-topic-first'), '1')
        self.assertFalse(self.s.has('hint-window-' + self.first))
        if not self.s.has('browser-panel'):
            self.s.act('press', 'toggle-browser')
        rows = self.s.wait_rows(lambda rows: len([key for key in self.s.ids(rows) if key.startswith('hint-tab-')]) == 2,
                               'rest Tab Hints missing')
        self.assertEqual(sorted(self.value(key, rows) for key in self.s.ids(rows) if key.startswith('hint-tab-')), ['1', '2'])
        self.assertFalse(self.s.has('hint-terminal'))
        self.s.act('snapshot', '', str(self.s.root/'hints-rest.png'))
        self.configure('hints:\n  windows: {always: true}\n', '  select_card_1: [ctrl+j, ctrl+k]\n')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == 'J'
                         and self.value('hint-window-' + self.first, rows) == '1', 'live rest keys did not update')
        self.configure('hints:\n  cards: {always: false, hold: false}\n  windows: {always: false, hold: false}\n  tabs: {always: false, hold: false}\n  terminal: {hold: false}\n')
        self.s.wait_rows(lambda rows: not any(key.startswith('hint-') for key in self.s.ids(rows)), 'disabled rest Hints remain')
        for modifier in ['Control', 'Command', 'Option']:
            self.input('Release modifiers')
            self.input('Hold ' + modifier)
            time.sleep(0.45)
            self.assertFalse(any(key.startswith('hint-') for key in self.s.ids()), 'disabled hold Hints remain')
        self.input('Press ⌃2')
        self.s.wait_rows(lambda rows: self.s.has('empty-topic-title', rows), 'disabled Hints disabled shortcut')

    def test_live_zero_delay_and_false_delay(self):
        self.input('Hold Control')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == '⌃1', 'hold Hint missing')
        self.configure('hints: {hold_delay: false}\n')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == '1'
                         and not self.s.has('hint-terminal', rows), 'false did not clear active hold')
        self.input('Release modifiers')
        self.input('Hold Control')
        time.sleep(0.45)
        self.assertEqual(self.value('hint-topic-first'), '1')
        self.configure('hints: {hold_delay: 0}\n')
        self.s.wait_rows(lambda rows: self.value('hint-topic-first', rows) == '⌃1', 'zero delay did not show held Hint')
        self.input('Release modifiers')
        self.input('Hold Option')
        self.assertTrue(self.s.has('hint-terminal'), 'zero delay did not show immediately')

    def test_window_shortcut_uses_current_session_order(self):
        self.select(self.second)
        self.press_when_bound('⌃W')
        self.s.wait_shown(self.first)

    def press_when_bound(self, symbol):
        wait(lambda: self.s.driver('action', 'quick-switch-input', 'Press ' + symbol)['pressed'],
             symbol + ' is not bound from the Config')

    def test_topic_step_goes_to_the_row_below_and_wraps(self):
        self.configure(keybindings='  select_next_topic: ctrl+alt+j\n  select_prev_topic: ctrl+alt+k\n')
        self.press_when_bound('⌃⌥J')
        self.s.wait_rows(lambda rows: self.value('empty-topic-title', rows) == 'Dormant Topic',
                         'the Topic below the Pinned Topic is not shown')
        self.input('Press ⌃⌥J')
        self.s.wait_shown(self.first)
        self.input('Press ⌃⌥K')
        self.s.wait_rows(lambda rows: self.value('empty-topic-title', rows) == 'Dormant Topic',
                         'the Topic above the first row did not wrap to the last row')

    def test_session_step_in_topics_mode_stays_in_the_active_topic(self):
        session, window = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id} #{window_id}',
                                      '-s', 'topic-steps', '-c', str(self.s.root), '/bin/zsh -f').split()
        self.addCleanup(self.s.tmux, 'kill-session', '-t', session)
        self.s.tmux('set-option', '-t', session, '@muxify_topic', 'first')
        self.s.wait_rows(lambda rows: self.s.has('topic-window-' + window, rows), 'the second Session is not in the Topic')
        self.configure(keybindings='  select_next_session: ctrl+alt+n\n  select_prev_session: ctrl+alt+p\n')
        self.press_when_bound('⌃⌥N')
        self.s.wait_shown(window)
        self.input('Press ⌃⌥N')
        self.s.wait_shown(self.first)
        self.input('Press ⌃⌥P')
        self.s.wait_shown(window)
        self.input('Press ⌃⌥P')
        self.s.wait_shown(self.first)

    def test_topic_window_step_goes_through_every_window_of_the_active_topic(self):
        session, window = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id} #{window_id}',
                                      '-s', 'topic-windows', '-c', str(self.s.root), '/bin/zsh -f').split()
        self.addCleanup(self.s.tmux, 'kill-session', '-t', session)
        self.s.tmux('set-option', '-t', session, '@muxify_topic', 'first')
        rows = self.s.wait_rows(lambda rows: self.s.has('topic-window-' + window, rows)
                               and self.s.has('topic-window-' + self.second, rows), 'the Topic does not show all its Windows')
        topic_windows = {self.first, self.second, window}
        order = [key.removeprefix('topic-window-') for key in self.s.ids(rows)
                 if key.removeprefix('topic-window-') in topic_windows and key.startswith('topic-window-')]
        self.assertEqual(sorted(order), sorted(topic_windows), f'Sidebar Window rows: {order}')
        start = order.index(self.first)
        self.configure(keybindings='  select_next_topic_window: ctrl+alt+w\n  select_prev_topic_window: ctrl+alt+q\n')
        self.press_when_bound('⌃⌥W')
        self.s.wait_shown(order[(start + 1) % 3])
        self.input('Press ⌃⌥W')
        self.s.wait_shown(order[(start + 2) % 3])
        self.input('Press ⌃⌥W')
        self.s.wait_shown(self.first)
        self.input('Press ⌃⌥Q')
        self.s.wait_shown(order[(start - 1) % 3])


if __name__ == '__main__':
    unittest.main()
