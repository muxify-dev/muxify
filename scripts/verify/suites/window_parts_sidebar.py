import json
import unittest

from scripts.verify.sandbox import Sandbox, wait


class WindowPartsSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.config = s.root / 'config/muxify/config.yaml'
        cls.default_config = "sidebar:\n  formats:\n    window:\n      title: 'Parts Window'\n"
        cls.config.write_text(cls.default_config)
        topics = s.root / 'state/muxify/topics'
        topics.mkdir(parents=True)
        (topics / 'parts.json').write_text(json.dumps(dict(id='parts', title='Parts', slug='parts')))
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'parts', '/bin/zsh -f')
        s.tmux('set-option', '-t', cls.session, '@muxify_topic', 'parts')
        cls.window = s.tmux('display-message', '-p', '-t', cls.session + ':', '#{window_id}')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])

    def setUp(self):
        self.show_mode("topics")
        self.config.write_text(self.default_config)
        self.addCleanup(self.config.write_text, self.default_config)

    def show_mode(self, mode):
        key = 'sidebar-view-' + mode
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Sidebar mode control is missing')
        if self.s.row(key).get('accessibilityValue') != 'selected':
            self.s.act('press', key)
        card = 'topic-parts' if mode == 'topics' else 'session-' + self.session
        self.s.wait_rows(lambda rs: self.s.has(card, rs), 'the card is missing in ' + mode)
        if 'expanded' not in self.s.row(card).get('accessibilityValue', ''):
            self.s.act('press', card)
        self.row_key = ('topic-window-' if mode == 'topics' else 'session-window-') + self.window
        return self.s.wait_rows(lambda rs: self.s.has(self.row_key, rs), 'the Window row is missing in ' + mode)

    def window_rows(self, rs):
        return [row for row in rs if row.get('accessibilityIdentifier') == self.row_key]

    def label(self, rs):
        return ', '.join(row['accessibilityLabel'] for row in rs
                         if row.get('accessibilityIdentifier') == self.row_key and row.get('accessibilityLabel'))

    def test_the_pane_badge_glows_while_a_pane_is_zoomed(self):
        self.show_mode('topics')
        badge = 'window-right-panes-' + self.window
        self.s.tmux('split-window', '-d', '-t', self.window, '/bin/zsh -f')
        self.addCleanup(self.s.tmux, 'kill-pane', '-a', '-t', self.window + '.0')
        self.s.tmux('resize-pane', '-Z', '-t', self.window + '.0')
        self.s.wait_rows(lambda rs: self.s.row(badge, rs).get('accessibilityValue') == 'zoomed',
                         'the Pane badge did not show the Zoomed Pane')
        self.s.tmux('resize-pane', '-Z', '-t', self.window + '.0')
        self.s.wait_rows(lambda rs: self.s.has(badge, rs) and self.s.row(badge, rs).get('accessibilityValue') != 'zoomed',
                         'the Pane badge kept the Zoom mark after the Pane was zoomed out')

    def test_native_defaults_keep_mode_specific_pane_badges(self):
        for mode in ['topics', 'sessions']:
            self.show_mode(mode)
            expected = 'Parts Window, 1' if mode == 'topics' else 'Parts Window'
            rs = self.s.wait_rows(lambda rs: self.label(rs) == expected, 'native badges differ from ' + expected)
            self.assertEqual(self.label(rs), expected)

    def test_empty_parts_hide_icons_and_badges_in_both_modes(self):
        self.show_mode('sessions')
        native = self.s.wait_rows(lambda rs: self.label(rs) == 'Parts Window', 'native parts did not return')
        self.assertEqual(sum(row.get('accessibilityRole') == 'AXImage' for row in self.window_rows(native)), 1)
        self.config.write_text("sidebar:\n  formats:\n    window:\n      left: ''\n      right: ''\n      title: 'Hidden parts'\n")
        for mode in ['topics', 'sessions']:
            self.show_mode(mode)
            rs = self.s.wait_rows(lambda rs: self.label(rs) == 'Hidden parts', 'hidden parts retain text or badges')
            self.assertEqual(self.label(rs), 'Hidden parts')
            if mode == 'sessions':
                self.assertFalse(any(row.get('accessibilityRole') == 'AXImage' for row in self.window_rows(rs)))
            if mode == 'topics':
                self.s.act('snapshot', self.row_key, str(self.s.root / 'window-parts-hidden.png'))

    def test_mixed_parts_follow_mode_and_recover_from_invalid_symbol(self):
        self.config.write_text("""sidebar:
  formats:
    window:
      title: 'Parts Window'
      left:
        topics: '#{current_app_icon} 🚀'
        sessions: '✨ #{current_app_icon}'
      right:
        topics: '#{symbol:globe} #{tab_count}'
        sessions: '#{symbol:rectangle.split.2x1} #{window_panes}'
""")
        for mode, emoji, symbol, count in [('topics', '🚀', 'globe', '0'), ('sessions', '✨', 'rectangle.split.2x1', '1')]:
            self.show_mode(mode)
            rs = self.s.wait_rows(lambda rs: emoji in self.label(rs) and symbol in self.label(rs)
                                  and self.label(rs).endswith(count), 'mixed parts did not apply in ' + mode)
            self.assertIn('Parts Window', self.label(rs))
            self.assertEqual(self.label(rs).count(symbol), 1)
            if mode == 'sessions':
                images = [row for row in self.window_rows(rs) if row.get('accessibilityRole') == 'AXImage']
                self.assertEqual(len(images), 2, 'the app icon or the SF Symbol is missing')
                self.assertEqual(sum(row.get('accessibilityLabel') == symbol for row in images), 1)
            if mode == 'topics':
                self.s.act('snapshot', self.row_key, str(self.s.root / 'window-parts.png'))
        self.config.write_text("""sidebar:
  formats:
    window:
      title: 'Parts Window'
      left: 'Recovered'
      right:
        topics: '#{symbol:absent.muxify.symbol}'
        sessions: '#{symbol:globe} valid'
""")
        for mode in ['topics', 'sessions']:
            self.show_mode(mode)
            expected = 'Recovered, Parts Window, 1' if mode == 'topics' else 'Recovered, Parts Window, globe,  valid'
            rs = self.s.wait_rows(lambda rs: self.label(rs) == expected, 'invalid Format affected another part or mode')
            self.assertEqual(self.label(rs), expected)
        self.config.write_text("sidebar:\n  formats:\n    window:\n      title: 'Parts Window'\n      left: null\n      right: null\n")
        rs = self.s.wait_rows(lambda rs: self.label(rs) == 'Parts Window', 'null did not restore native parts')
        self.assertEqual(self.label(rs), 'Parts Window')

    def test_a_terminal_bell_shows_as_a_bell_symbol(self):
        s = self.s
        sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'parts-bell', '/bin/zsh -f')
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', sid)
        # A bell in a Window that is not its Session's current Window sets the Window's bell flag.
        window = s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', sid + ':',
                        "sh -c 'sleep 1; printf \"\\a\"; exec sleep 600'")
        wait(lambda: s.tmux('display-message', '-p', '-t', window, '#{window_bell_flag}') == '1', 'tmux saw no bell')
        self.show_mode('sessions')
        card = 'session-' + sid
        s.wait_rows(lambda rs: s.has(card, rs), 'no card for the Session with the bell')
        if 'expanded' not in s.row(card).get('accessibilityValue', ''):
            s.act('press', card)
        self.row_key = 'session-window-' + window
        rs = s.wait_rows(lambda rs: any(row.get('accessibilityRole') == 'AXImage'
                                       and row.get('accessibilityLabel') == 'Bell' for row in self.window_rows(rs)),
                         'the Window row shows no bell')
        bell = next(row for row in self.window_rows(rs) if row.get('accessibilityRole') == 'AXImage'
                    and row.get('accessibilityLabel') == 'Bell')
        self.assertEqual((bell.get('accessibilityRole'), bell.get('accessibilityLabel')), ('AXImage', 'Bell'), json.dumps(bell))
