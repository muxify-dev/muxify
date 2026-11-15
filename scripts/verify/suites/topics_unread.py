"""Topic Unread persists without Agents. Palette actions use the existing background driver."""

from pathlib import Path
import os
import signal
import time
import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import TopicsSidebar


class TopicsUnread(TopicsSidebar):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.config_text += '''command_palettes:
  - name: Commands
    keybinding: cmd+shift+p
    sources: [commands]
  - name: Read targets
    keybinding: cmd+p
    sources: [topics, sessions, windows, agents]
notifications:
  manual_read: true
'''
        cls.config.write_text(cls.config_text)
        cls.s.press_menu_item('Reload Config')

    def read_automatically(self):
        """Sets manual_read: false for this check only."""
        self.config.write_text(self.config_text.replace('manual_read: true', 'manual_read: false'))
        self.s.press_menu_item('Reload Config')
        self.addCleanup(self.s.press_menu_item, 'Reload Config')
        self.addCleanup(self.config.write_text, self.config_text)

    def search(self, palette, query, key):
        self.s.open_palette(palette, query)
        return self.s.wait_rows(lambda rs: self.s.has(key, rs), 'No row ' + key)

    def mark_row(self, topic, action):
        key = 'palette-row-topic-' + topic
        self.search('Read targets', topic, key)
        wait(lambda: self.s.driver('action', key, action)['pressed'], 'Action unavailable ' + action)

    def assert_unread(self, topic, unread):
        wait(lambda: self.records().get(topic, {}).get('unread', False) == unread, 'Topic mark did not persist')
        self.assertEqual(self.records()[topic].get('unread', False), unread)

    def write_empty_topic(self, topic, **fields):
        self.write_topic(topic, topic, **fields)

    def enter_empty(self, topic):
        self.enter(topic)
        self.s.wait_rows(lambda rs: topic in self.describe('empty-topic-title', rs), 'Empty Topic view did not appear')

    def enter(self, topic):
        self.find('topic-' + topic)
        self.s.act('action', 'topic-' + topic, 'Go to Topic')

    def test_hidden_agent_rows_keep_a_summary_line_until_shown(self):
        topic = 'notification-overflow'
        self.write_topic(topic, topic)
        sid, first, pane = self.agent_session(topic, topic=topic, status='done', unread=True)
        for _ in range(5):
            self.s.tmux('new-window', '-d', '-t', sid + ':', '/bin/zsh -f')
        last, blocked = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}',
                                   '-t', sid + ':', 'sleep 600').split()
        for key, value in [('agent', 'claude'), ('agent_status', 'blocked')]:
            self.s.tmux('set-option', '-p', '-t', blocked, '@muxify_' + key, value)
        self.open_card('topic-' + topic)
        self.s.wait_rows(lambda rs: self.s.has('topic-window-' + first, rs), 'the first Window did not appear')
        self.enter(topic)
        self.s.wait_shown(first)
        self.s.wait_rows(lambda rs: self.s.has('topic-' + topic + '-more', rs)
                         and 'blocked' in self.describe('topic-' + topic, rs), 'the overflow fixture is incomplete')
        self.assertTrue(self.s.has('topic-agent-mark-' + first), 'the visible Agent line disappeared')
        self.s.wait_rows(lambda rs: 'blocked' in self.describe('topic-' + topic + '-more', rs), 'hidden Agents have no summary line')
        self.s.act('press', 'topic-' + topic + '-more')
        self.s.wait_rows(lambda rs: self.s.has('topic-agent-mark-' + first, rs) and self.s.has('topic-agent-mark-' + last, rs),
                         'the full list did not replace the full spine with Window lines')

    def test_empty_topic_commands_shortcuts_persist_and_show_unread(self):
        topic = 'empty-read-target'
        # A mark writes only its own column (ADR 0079); a field the app does not know no longer survives (a3308a1).
        self.write_empty_topic(topic, note='keep')
        self.enter_empty(topic)
        self.s.run_command('Mark Unread')
        self.assert_unread(topic, True)
        self.s.wait_rows(lambda rs: 'unread' in self.describe('topic-' + topic, rs), 'No Topic Unread mark')
        time.sleep(2.2)
        self.assert_unread(topic, True)
        self.assertEqual(self.records()[topic].get('note'), 'keep', 'the mark changed the Topic Note')
        self.press_shortcut('⇧⌘R')
        self.assert_unread(topic, False)
        self.press_shortcut('⇧⌘U')
        self.assert_unread(topic, True)
        self.s.run_command('Mark Read')
        self.assert_unread(topic, False)

    def test_shell_and_working_topics_mark_without_changing_agent_status(self):
        for topic, status in [('shell-read-target', None), ('working-read-target', 'working')]:
            self.write_topic(topic, topic)
            if status:
                _, _, pane = self.agent_session(topic, topic=topic, status=status)
            else:
                sid = self.new_session(topic, self.beta, topic=topic)
                pane = self.s.tmux('display-message', '-p', '-t', sid, '#{pane_id}')
            self.mark_row(topic, 'Mark Unread')
            self.assert_unread(topic, True)
            self.assertEqual(self.s.tmux('display-message', '-p', '-t', pane, '#{@muxify_agent_status}'), status or '')
            self.assertNotEqual(self.s.tmux('display-message', '-p', '-t', pane, '#{@muxify_agent_unread}'), '1')
            self.mark_row(topic, 'Mark Read')
            self.assert_unread(topic, False)

    def test_dormant_and_settled_records_and_all_read(self):
        for topic, fields in [('dormant-read-target', {'sessions': [dict(id='saved', name='debug/dormant-read-target', base_name='debug', directory=str(self.beta))]}),
                              ('settled-read-target', {'settled_at': '2026-10-01T10:00:00Z'})]:
            self.write_topic(topic, topic, **fields)
            self.mark_row(topic, 'Mark Unread')
            self.assert_unread(topic, True)
        self.s.act('press', 'settled-topics')
        self.s.wait_rows(lambda rs: 'unread' in self.describe('topic-settled-read-target', rs),
                         'Settled Topic did not show Unread')
        self.write_topic('hidden-read-target', 'hidden-read-target',
                         settled_at='2020-01-01T00:00:00Z', unread=True)
        self.s.run_command('Mark All as Read')
        self.assert_unread('hidden-read-target', False)
        for topic in ['dormant-read-target', 'settled-read-target']:
            self.assert_unread(topic, False)

    def test_topic_mark_remains_after_its_agent_exits(self):
        topic = 'exit-read-target'
        self.write_topic(topic, topic)
        sid, _, pane = self.agent_session(topic, topic=topic, status='done')
        self.mark_row(topic, 'Mark Unread')
        self.assert_unread(topic, True)
        self.end_session(sid)
        self.s.wait_rows(lambda rs: not self.s.has('agent-' + pane, rs), 'The Agent did not leave')
        self.assert_unread(topic, True)
        self.s.wait_rows(lambda rs: 'unread' in self.describe('topic-' + topic, rs), 'The Topic lost its Unread mark')
        self.mark_row(topic, 'Mark Read')
        self.assert_unread(topic, False)

    def test_empty_topic_can_be_marked_without_a_running_tmux_server(self):
        topic = 'offline-read-target'
        self.write_empty_topic(topic)
        socket = self.s.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(Path(socket).resolve().is_relative_to(self.s.root.resolve()))
        self.addCleanup(self.s.tmux, 'new-session', '-d', '-s', 'base', '-c', str(self.beta), '/bin/zsh -f')
        self.s.tmux('kill-server')
        self.enter_empty(topic)
        self.s.run_command('Mark Unread')
        self.assert_unread(topic, True)
        self.s.run_command('Mark Read')
        self.assert_unread(topic, False)
        self.assertNotEqual(self.s.tmux_ok('list-sessions').returncode, 0)

    def test_detached_client_can_reattach_after_a_local_inventory_read_times_out(self):
        topic = 'timeout-read-target'
        self.write_empty_topic(topic)
        self.enter_empty(topic)
        socket = self.s.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(Path(socket).resolve().is_relative_to(self.s.root.resolve()))
        server = int(self.s.tmux('display-message', '-p', '#{pid}'))
        clients = self.s.tmux('list-clients', '-F', '#{client_control_mode}|#{client_tty}').splitlines()
        for client in clients:
            control, tty = client.split('|')
            if control == '0':
                self.s.tmux('detach-client', '-t', tty)
        self.s.wait_rows(lambda rs: any(r.get('accessibilityLabel') == 'Reattach' for r in rs),
                         'The detached Client has no Reattach button')
        os.kill(server, signal.SIGSTOP)
        try:
            self.s.wait_rows(lambda rs: 'timed out' in self.s.row('header-environment-selector', rs).get('accessibilityHelp', ''),
                             'The Local Inventory read did not time out', seconds=20)
        finally:
            os.kill(server, signal.SIGCONT)
        self.s.act('press', 'Reattach')
        window = self.s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.s.show(window)
        wait(lambda: '0|' + window in self.s.tmux('list-clients', '-F', '#{client_control_mode}|#{window_id}').splitlines(),
             'The Terminal Client did not reattach after the Local Inventory read timed out')

    def test_empty_topic_view_stays_when_the_tmux_server_stops(self):
        topic = 'offline-stays-target'
        self.write_empty_topic(topic)
        for button in ['Reattach', 'Reconnect']:
            self.s.driver('press', button)
        window = self.s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.s.show(window)
        self.enter_empty(topic)
        socket = self.s.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(Path(socket).resolve().is_relative_to(self.s.root.resolve()))
        self.addCleanup(self.s.tmux, 'new-session', '-d', '-s', 'base', '-c', str(self.beta), '/bin/zsh -f')
        self.s.tmux('kill-server')
        # The app reads tmux once per second; after two reads it has seen that the server stopped.
        time.sleep(2.2)
        self.assertIn(topic, self.describe('empty-topic-title', self.s.rows()), 'the Empty Topic view closed with the server')

    def test_automatic_empty_topic_reads_only_on_next_visit(self):
        self.read_automatically()
        for topic in ['empty-auto-target', 'empty-auto-away']:
            self.write_empty_topic(topic)
        self.enter_empty('empty-auto-target')
        self.s.run_command('Mark Unread')
        self.assert_unread('empty-auto-target', True)
        self.enter_empty('empty-auto-target')
        time.sleep(2.2)
        self.assert_unread('empty-auto-target', True)
        self.enter_empty('empty-auto-away')
        self.enter_empty('empty-auto-target')
        self.assert_unread('empty-auto-target', False)

    def test_automatic_live_topic_preserves_its_record_on_next_visit(self):
        self.read_automatically()
        topic = 'live-auto-target'
        self.write_topic(topic, topic)
        _, window, _ = self.agent_session(topic, topic=topic, status='working')
        self.write_empty_topic('live-auto-away')
        # Go to Topic shows the Empty Topic view while the app has not yet read the new Window.
        self.open_card('topic-' + topic)
        self.s.wait_rows(lambda rs: self.s.has('topic-window-' + window, rs), 'the Topic card does not list ' + window)
        self.enter(topic)
        self.s.wait_shown(window)
        self.mark_row(topic, 'Mark Unread')
        self.assert_unread(topic, True)
        time.sleep(2.2)
        self.assert_unread(topic, True)
        self.enter('live-auto-away')
        self.enter(topic)
        self.assert_unread(topic, True)


if __name__ == '__main__':
    unittest.main()
