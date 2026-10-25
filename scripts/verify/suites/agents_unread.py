"""Manual Read through palette row actions, Commands, navigation and configured shortcuts.

HintVerification exposes Mark Read through the existing configured-shortcut action.
This uses the normal keybinding path without taking keyboard focus from the user.
"""

import time
import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import TopicsSidebar


class AgentsUnread(TopicsSidebar):
    def setUp(self):
        super().setUp()
        self.configure()
        self.addCleanup(self.config.write_text, self.config_text)

    def configure(self, extra='', manual_read=True):
        self.config.write_text(self.config_text + '''command_palettes:
  - name: Commands
    keybinding: cmd+shift+p
    sources: [commands]
  - name: Read targets
    keybinding: cmd+p
    sources: [topics, sessions, windows, agents]
  - name: Read windows
    keybinding: cmd+alt+p
    sources: [windows]
''' + 'notifications:\n  manual_read: ' + ('true' if manual_read else 'false') + '\n' + extra)
        self.press_menu_item('Reload Config')

    def unread(self, pane):
        return self.s.tmux('display-message', '-p', '-t', pane, '#{@muxify_agent_unread}') == '1'

    def assert_read(self, *panes):
        wait(lambda: all(not self.unread(pane) for pane in panes), 'Agents stayed Unread')
        time.sleep(2.2)
        self.assertEqual([self.unread(pane) for pane in panes], [False] * len(panes))

    def search(self, palette, query, key):
        self.press_menu_item(palette)
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), palette + ' did not open')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', query)
        return self.s.wait_rows(lambda rs: self.s.has(key, rs), 'No palette row ' + key)

    def mark_row(self, query, key, palette='Read targets', action='Mark Read'):
        self.search(palette, query, key)
        wait(lambda: self.s.driver('action', key, action)['pressed'], action + ' did not become available for ' + key)
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), action + ' did not close the palette')

    def test_navigation_keeps_unread_and_command_reads_only_its_window_in_sessions_mode(self):
        self.write_topic('manual-topic', 'Manual topic', self.beta)
        _, first, one = self.agent_session('manual-one', topic='manual-topic', status='done', unread=True)
        _, _, two = self.agent_session('manual-two', topic='manual-topic', status='failed', unread=True)
        _, _, other = self.agent_session('manual-other', status='done', unread=True)
        self.select_window(first)
        self.s.wait_shown(first)
        self.find('topic-manual-topic')
        self.s.act('action', 'topic-manual-topic', 'Go to Topic')
        self.s.wait_shown(first)
        time.sleep(2.2)
        self.assertTrue(self.unread(one))
        self.assertTrue(self.unread(two))
        self.show_view('sessions')
        key = 'palette-row-command-Mark Read'
        rows = self.search('Commands', 'Mark Read', key)
        self.assertIn('⇧⌘R', self.describe(key, rows))
        self.s.act('press', key)
        self.assert_read(one)
        self.assertTrue(self.unread(two))
        self.assertTrue(self.unread(other))

    def test_no_topic_command_reads_only_its_window_and_new_updates_become_unread(self):
        sid, first, one = self.agent_session('manual-session', status='done', unread=True)
        _, two = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-t', sid + ':',
                            'sleep 600').split()
        wait(lambda: self.s.tmux('display-message', '-p', '-t', two, '#{pane_current_command}') == 'sleep',
             'The second Agent process did not start')
        self.s.tmux('set-option', '-p', '-t', two, '@muxify_agent', 'claude',
                    ';', 'set-option', '-p', '-t', two, '@muxify_agent_status', 'failed',
                    ';', 'set-option', '-p', '-t', two, '@muxify_agent_unread', '1')
        _, _, other = self.agent_session('manual-session-other', status='done', unread=True)
        self.select_window(first)
        self.s.wait_shown(first)
        self.s.wait_rows(lambda rs: self.s.has('agent-' + one, rs) and self.s.has('agent-' + two, rs),
                         'The Session Agents did not appear')
        self.press_shortcut('⇧⌘R')
        self.assert_read(one)
        self.assertTrue(self.unread(two))
        self.assertTrue(self.unread(other))
        self.s.tmux('set-option', '-p', '-t', one, '@muxify_agent_status', 'working')
        self.s.wait_rows(lambda rs: 'working' in self.s.row('agent-' + one, rs).get('accessibilityHelp', ''), 'The Working mark did not show')
        self.s.tmux('set-option', '-p', '-t', one, '@muxify_agent_status', 'done')
        wait(lambda: self.unread(one), 'An update in the selected Window did not become Unread')
        self.assertTrue(self.unread(one))

    def test_row_targets_clear_only_their_agents_and_keep_the_blocked_mark(self):
        self.write_topic('manual-rows', 'Manual rows', self.beta)
        _, window, one = self.agent_session('manual-row-one', topic='manual-rows', status='blocked', unread=True)
        _, _, other = self.agent_session('manual-row-other', topic='manual-rows', status='done', unread=True)
        self.select_window(window)
        self.s.wait_shown(window)
        self.mark_row('claude', 'palette-row-agent:' + one)
        self.assert_read(one)
        self.assertTrue(self.unread(other))
        self.s.wait_rows(lambda rs: 'blocked' in self.describe('topic-manual-rows', rs), 'Mark Read hid the blocked mark')
        self.s.tmux('set-option', '-p', '-t', one, '@muxify_agent_unread', '1')
        self.mark_row('manual-row-one', 'palette-row-window:' + window, palette='Read windows')
        self.assert_read(one)
        self.assertTrue(self.unread(other))
        self.mark_row('Manual rows', 'palette-row-topic-manual-rows')
        self.assert_read(other)

    def test_session_row_reads_only_that_session(self):
        sid = self.new_session('manual-loose-row', self.s.root, command='sleep 600')
        pane = self.s.tmux('display-message', '-p', '-t', sid, '#{pane_id}')
        wait(lambda: self.s.tmux('display-message', '-p', '-t', pane, '#{pane_current_command}') == 'sleep',
             'The Session Agent process did not start')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude',
                    ';', 'set-option', '-p', '-t', pane, '@muxify_agent_status', 'done',
                    ';', 'set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')
        _, _, other = self.agent_session('manual-loose-other', status='done', unread=True)
        _, _, outside = self.agent_session('manual-loose-read', status='failed')
        self.mark_row('manual-loose-row', 'palette-row-session:' + sid)
        self.assert_read(pane)
        self.assertTrue(self.unread(other))
        self.mark_row('manual-loose-row', 'palette-row-session:' + sid, action='Mark Unread')
        self.assert_unread(pane)
        self.assertTrue(self.unread(other))
        self.assertFalse(self.unread(outside))

    def test_disabling_manual_read_reads_only_the_visited_window(self):
        self.configure(manual_read=False)
        self.write_topic('automatic-topic', 'Automatic topic', self.beta)
        _, _, one = self.agent_session('automatic-one', topic='automatic-topic', status='done', unread=True)
        _, _, two = self.agent_session('automatic-two', topic='automatic-topic', status='failed', unread=True)
        self.find('topic-automatic-topic')
        self.s.act('action', 'topic-automatic-topic', 'Go to Topic')
        self.assert_read(one)
        self.assertTrue(self.unread(two))

    def assert_unread(self, *panes):
        wait(lambda: all(self.unread(pane) for pane in panes), 'Agents stayed read')
        time.sleep(2.2)
        self.assertEqual([self.unread(pane) for pane in panes], [True] * len(panes))

    def test_mark_unread_command_uses_window_and_all_read_clears_environment(self):
        self.write_topic('unread-topic', 'Unread topic', self.beta)
        _, first, one = self.agent_session('unread-one', topic='unread-topic', status='done')
        _, _, two = self.agent_session('unread-two', topic='unread-topic', status='failed')
        _, _, working = self.agent_session('unread-working', topic='unread-topic', status='working')
        _, _, other = self.agent_session('unread-other', status='blocked', unread=True)
        _, _, outside = self.agent_session('unread-outside', status='done')
        self.s.show(first)
        self.s.wait_shown(first)
        key = 'palette-row-command-Mark Unread'
        rows = self.search('Commands', 'Mark Unread', key)
        self.assertIn('⇧⌘U', self.describe(key, rows))
        self.s.act('press', key)
        self.assert_unread(one)
        self.assertFalse(self.unread(two))
        self.assertFalse(self.unread(working))
        self.assertFalse(self.unread(outside))
        key = 'palette-row-command-Mark All as Read'
        self.search('Commands', 'Mark All as Read', key)
        self.s.act('press', key)
        self.assert_read(one, two, other)

    def test_unread_row_targets_only_the_selected_agents(self):
        self.write_topic('unread-rows', 'Unread rows', self.beta)
        _, window, one = self.agent_session('unread-row-one', topic='unread-rows', status='blocked')
        _, _, other = self.agent_session('unread-row-other', topic='unread-rows', status='done')
        self.mark_row('claude', 'palette-row-agent:' + one, action='Mark Unread')
        self.assert_unread(one)
        self.assertFalse(self.unread(other))
        self.mark_row('unread-row-one', 'palette-row-window:' + window, palette='Read windows')
        self.assert_read(one)
        self.mark_row('unread-row-one', 'palette-row-window:' + window, palette='Read windows', action='Mark Unread')
        self.assert_unread(one)
        self.assertFalse(self.unread(other))
        self.mark_row('Unread rows', 'palette-row-topic-unread-rows', action='Mark Unread')
        self.assert_unread(one, other)

    def test_automatic_mark_unread_survives_until_next_visit(self):
        self.configure(manual_read=False)
        _, window, pane = self.agent_session('unread-auto', status='done')
        _, away, _ = self.agent_session('unread-away', status='working')
        self.select_window(window)
        self.s.wait_shown(window)
        self.mark_row('unread-auto', 'palette-row-window:' + window, palette='Read windows', action='Mark Unread')
        self.assert_unread(pane)
        self.search('Read windows', 'unread-away', 'palette-row-window:' + away)
        self.s.act('press', 'palette-row-window:' + away)
        self.s.wait_shown(away)
        self.search('Read windows', 'unread-auto', 'palette-row-window:' + window)
        self.s.act('press', 'palette-row-window:' + window)
        self.s.wait_shown(window)
        self.assert_read(pane)

    def test_remapped_unread_and_all_read_shortcuts_use_session_and_environment(self):
        self.configure('keybindings:\n  mark_unread: ctrl+alt+u\n  mark_all_read: ctrl+alt+a\n')
        _, window, pane = self.agent_session('unread-remap', status='done')
        _, _, other = self.agent_session('unread-remap-other', status='working', unread=True)
        self.select_window(window)
        self.s.wait_shown(window)
        self.s.wait_rows(lambda rs: self.s.has('agent-' + pane, rs), 'No Agent for Mark Unread')
        self.press_shortcut('⌃⌥U')
        self.assert_unread(pane)
        self.press_shortcut('⌃⌥A')
        self.assert_read(pane, other)

    def test_remapped_shortcut_runs_mark_read(self):
        self.configure('keybindings:\n  mark_read: ctrl+alt+r\n')
        _, window, pane = self.agent_session('manual-remap', status='done', unread=True)
        self.select_window(window)
        self.s.wait_shown(window)
        self.s.wait_rows(lambda rs: self.s.has('agent-' + pane, rs), 'No Agent for the remapped shortcut')
        self.press_shortcut('⌃⌥R')
        self.assert_read(pane)

    def run_command(self, title):
        key = 'palette-row-command-' + title
        self.search('Commands', title, key)
        self.s.act('press', key)

    def split_agent(self, window, status='blocked', unread=True):
        pane = self.s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', window, 'sleep 600')
        wait(lambda: self.s.tmux('display-message', '-p', '-t', pane, '#{pane_current_command}') == 'sleep',
             'The split Agent did not start')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude',
                    ';', 'set-option', '-p', '-t', pane, '@muxify_agent_status', status,
                    ';', 'set-option', '-p', '-t', pane, '@muxify_agent_unread', '1' if unread else '0')
        return pane

    def test_zoom_shortcuts_and_command_summary_use_only_the_shown_pane(self):
        _, window, one = self.agent_session('zoom-read-target', status='done', unread=True)
        two = self.split_agent(window)
        self.s.show(window)
        self.s.wait_shown(window)
        self.run_command('Zoom Pane')
        self.press_shortcut('⇧⌘R')
        self.assert_read(one)
        self.assert_unread(two)
        key = 'palette-row-command-Mark Unread'
        rows = self.search('Commands', 'Mark Unread', key)
        self.assertIn('Zoomed Pane:', self.describe(key, rows))
        self.s.act('press', key)
        self.assert_unread(one, two)
        self.mark_row('zoom-read-target', 'palette-row-window:' + window, palette='Read windows')
        self.assert_read(one, two)
        self.run_command('Zoom Pane')
        self.press_shortcut('⇧⌘U')
        self.assert_unread(one, two)
        key = 'palette-row-command-Mark Read'
        rows = self.search('Commands', 'Mark Read', key)
        self.assertIn('Window:', self.describe(key, rows))
        self.s.act('press', key)
        self.assert_read(one, two)

    def test_automatic_same_window_visit_reads_only_the_zoomed_pane(self):
        self.configure(manual_read=False)
        _, window, one = self.agent_session('zoom-auto-target', status='done', unread=True)
        two = self.split_agent(window)
        self.s.tmux('resize-pane', '-Z', '-t', one)
        self.s.show(window)
        self.s.wait_shown(window)
        self.assert_read(one)
        self.assert_unread(two)
        self.press_shortcut('⇧⌘U')
        self.assert_unread(one)
        self.s.show(window)
        self.assert_read(one)
        self.assert_unread(two)

    def test_hidden_terminal_visit_preserves_unread_and_explicit_command_still_reads(self):
        self.configure(manual_read=False)
        _, window, pane = self.agent_session('hidden-read-target', status='done', unread=True)
        self.s.show(window)
        self.s.wait_shown(window)
        self.assert_read(pane)
        self.s.tmux('set-option', '-w', '-t', window, '@muxify_open', 'about:blank')
        self.s.wait_rows(lambda rs: self.s.has('browser-panel', rs), 'Browser did not open')
        self.press_menu_item('Maximize Browser')
        self.s.wait_rows(lambda rs: not self.s.has('terminal-panel', rs), 'Terminal stayed visible')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')
        self.s.show(window)
        self.s.wait_shown(window)
        self.assert_unread(pane)
        self.press_shortcut('⇧⌘R')
        self.assert_read(pane)
        self.press_menu_item('Restore')

    def test_git_view_visit_preserves_unread(self):
        self.configure(manual_read=False)
        _, window, pane = self.agent_session('git-read-target', status='done', unread=True)
        self.s.show(window)
        self.s.wait_shown(window)
        self.assert_read(pane)
        self.press_menu_item('Show Git View')
        self.s.wait_rows(lambda rs: self.s.has('git-view', rs), 'Git View did not open')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')
        self.s.show(window)
        self.s.wait_shown(window)
        self.assert_unread(pane)
        self.s.act('action', 'git-view', 'q')


if __name__ == '__main__':
    unittest.main()
