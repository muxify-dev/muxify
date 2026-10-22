"""Topic Unread persists without Agents. Palette actions use the existing background driver."""

from pathlib import Path
import json
import time
import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import TopicsSidebar


class TopicsUnread(TopicsSidebar):
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
''' + 'notifications:\n  manual_read: ' + ('true' if manual_read else 'false') + '\n' + extra)
        self.press_menu_item('Reload Config')

    def search(self, palette, query, key):
        self.press_menu_item(palette)
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Palette did not open')
        self.s.act('set', 'palette-search', query)
        return self.s.wait_rows(lambda rs: self.s.has(key, rs), 'No row ' + key)

    def command(self, title):
        key = 'palette-row-command-' + title
        self.search('Commands', title, key)
        self.s.act('press', key)

    def mark_row(self, topic, action):
        key = 'palette-row-topic-' + topic
        self.search('Read targets', topic, key)
        wait(lambda: self.s.driver('action', key, action)['pressed'], 'Action unavailable ' + action)

    def assert_unread(self, topic, unread):
        wait(lambda: self.records().get(topic, {}).get('unread', False) == unread, 'Topic mark did not persist')
        self.assertEqual(self.records()[topic].get('unread', False), unread)

    def write_empty_topic(self, topic, **fields):
        self.write_topic(topic, topic, self.beta, **fields)

    def enter_empty(self, topic):
        self.enter(topic)
        self.s.wait_rows(lambda rs: topic in self.describe('empty-topic-title', rs), 'Empty Topic view did not appear')

    def enter(self, topic):
        self.find('topic-' + topic)
        self.s.act('action', 'topic-' + topic, 'Go to Topic')

    def test_empty_topic_commands_shortcuts_persist_and_show_unread(self):
        topic = 'empty-read-target'
        self.write_empty_topic(topic, future={'keep': 1})
        self.enter_empty(topic)
        self.command('Mark Unread')
        self.assert_unread(topic, True)
        self.s.wait_rows(lambda rs: 'unread' in self.describe('topic-' + topic, rs), 'No Topic Unread mark')
        time.sleep(2.2)
        self.assert_unread(topic, True)
        self.assertEqual(self.records()[topic]['future'], {'keep': 1})
        self.s.act('action', 'quick-switch-input', 'Press ⇧⌘R')
        self.assert_unread(topic, False)
        self.s.act('action', 'quick-switch-input', 'Press ⇧⌘U')
        self.assert_unread(topic, True)
        self.command('Mark Read')
        self.assert_unread(topic, False)

    def test_shell_and_working_topics_mark_without_changing_agent_status(self):
        for topic, status in [('shell-read-target', None), ('working-read-target', 'working')]:
            self.write_topic(topic, topic, self.beta)
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

    def test_dormant_snoozed_and_settled_records_and_all_read(self):
        for topic, fields in [('dormant-read-target', {'sessions': [dict(id='saved', name='debug/dormant-read-target', base_name='debug', directory=str(self.beta))]}),
                              ('snoozed-read-target', {'snoozed_until': 'never'}),
                              ('settled-read-target', {'settled_at': '2026-10-01T10:00:00Z'})]:
            self.write_topic(topic, topic, self.beta, **fields)
            self.mark_row(topic, 'Mark Unread')
            self.assert_unread(topic, True)
        self.s.act('press', 'settled-topics')
        self.s.wait_rows(lambda rs: 'unread' in self.describe('topic-settled-read-target', rs),
                         'Settled Topic did not show Unread')
        self.write_topic('hidden-read-target', 'hidden-read-target', self.beta,
                         settled_at='2020-01-01T00:00:00Z', unread=True)
        self.command('Mark All as Read')
        self.assert_unread('hidden-read-target', False)
        for topic in ['dormant-read-target', 'snoozed-read-target', 'settled-read-target']:
            self.assert_unread(topic, False)

    def test_topic_mark_remains_after_its_agent_exits(self):
        topic = 'exit-read-target'
        self.write_topic(topic, topic, self.beta)
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
        self.command('Mark Unread')
        self.assert_unread(topic, True)
        self.command('Mark Read')
        self.assert_unread(topic, False)
        self.assertNotEqual(self.s.tmux_ok('list-sessions').returncode, 0)

    def test_empty_topic_view_stays_when_the_tmux_server_stops(self):
        topic = 'offline-stays-target'
        self.write_empty_topic(topic)
        # The app must show a Window that goes away with the server. After an earlier check stopped the server, the
        # app waits for a press on Reattach or Reconnect.
        for button in ['Reattach', 'Reconnect']:
            self.s.driver('press', button)
        self.s.wait_shown('base:')
        self.enter_empty(topic)
        socket = self.s.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(Path(socket).resolve().is_relative_to(self.s.root.resolve()))
        self.addCleanup(self.s.tmux, 'new-session', '-d', '-s', 'base', '-c', str(self.beta), '/bin/zsh -f')
        self.s.tmux('kill-server')
        # The app reads tmux once per second; after two reads it has seen that the server stopped.
        time.sleep(2.2)
        self.assertIn(topic, self.describe('empty-topic-title', self.s.rows()), 'the Empty Topic view closed with the server')

    def test_automatic_empty_topic_reads_only_on_next_visit(self):
        self.configure(manual_read=False)
        for topic in ['empty-auto-target', 'empty-auto-away']:
            self.write_empty_topic(topic)
        self.enter_empty('empty-auto-target')
        self.command('Mark Unread')
        self.assert_unread('empty-auto-target', True)
        self.enter_empty('empty-auto-target')
        time.sleep(2.2)
        self.assert_unread('empty-auto-target', True)
        self.enter_empty('empty-auto-away')
        self.enter_empty('empty-auto-target')
        self.assert_unread('empty-auto-target', False)

    def test_automatic_live_topic_reads_its_record_on_next_visit(self):
        self.configure(manual_read=False)
        topic = 'live-auto-target'
        self.write_topic(topic, topic, self.beta)
        _, window, _ = self.agent_session(topic, topic=topic, status='working')
        self.write_empty_topic('live-auto-away')
        # Go to Topic shows the Empty Topic view while the app has not yet read the new Window.
        self.open_card('topic-' + topic)
        self.s.wait_rows(lambda rs: self.s.has('topic-window-' + window, rs), 'the Topic card does not list ' + window)
        self.enter(topic)
        self.s.wait_shown(window)
        self.command('Mark Unread')
        self.assert_unread(topic, True)
        time.sleep(2.2)
        self.assert_unread(topic, True)
        self.enter('live-auto-away')
        self.enter(topic)
        self.assert_unread(topic, False)


if __name__ == '__main__':
    unittest.main()
