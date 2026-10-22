"""The order of a Topic's Sessions in its Sidebar card: by creation in the Config's order, or as the user moved them.

A long press on a Session line moves it, which the driver's drag with `hold` does. The context menu's Move Up and Sort
Sessions by Creation are also accessibility actions of the line (SessionHeading in UI/SidebarView.swift), so the
checks reach them without the menu.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_session_order_sidebar
"""

import time
import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import TopicsSidebar


class TopicsSessionOrderSidebar(TopicsSidebar):
    def two_session_topic(self, topic):
        """A Topic with a beta Session and, created a later second, an alpha Session; returns their Session IDs.
        tmux lists Sessions by name, so alpha comes first in tmux and last by creation."""
        self.write_topic(topic, topic.capitalize(), self.beta)
        older = self.new_session('beta/' + topic, self.beta, topic=topic)
        # #{session_created} counts whole seconds.
        time.sleep(1.1)
        newer = self.new_session('alpha/' + topic, self.alpha, topic=topic)
        self.select_window(newer + ':')
        return older, newer

    def session_lines(self, topic, rs):
        prefix = 'topic-%s-session-' % topic
        return [key[len(prefix):] for key in self.s.ids(rs) if key.startswith(prefix)]

    def wait_order(self, topic, expected, message):
        return self.s.wait_rows(lambda rs: self.session_lines(topic, rs) == expected,
                                '%s: lines %s' % (message, self.session_lines(topic, self.s.rows())))

    def recorded_paths(self, topic):
        return [session.get('directory') for session in self.records()[topic].get('sessions', [])]

    def test_sessions_follow_their_creation_oldest_first_and_newest_first_with_the_config(self):
        older, newer = self.two_session_topic('order-auto')
        self.wait_order('order-auto', [older, newer], 'the Sessions are not oldest first')
        self.addCleanup(self.config.write_text, self.config_text)
        self.config.write_text(self.config_text + '  session_order: newest_first\n')
        self.wait_order('order-auto', [newer, older], 'topics.session_order: newest_first did not put the newest Session first')

    def test_a_long_press_on_a_session_line_moves_it_within_its_topic(self):
        older, newer = self.two_session_topic('order-pressed')
        self.wait_order('order-pressed', [older, newer], 'the Sessions are not oldest first')
        self.s.act('drag', 'topic-order-pressed-session-' + newer, 'topic-order-pressed-session-' + older, hold=0.7)
        self.wait_order('order-pressed', [newer, older], 'the long press did not move the Session up')
        wait(lambda: self.records()['order-pressed'].get('session_order') == 'manual', 'the record does not keep the manual order')

    def test_move_up_keeps_the_users_order_in_the_record_and_sort_by_creation_ends_it(self):
        older, newer = self.two_session_topic('order-moved')
        self.wait_order('order-moved', [older, newer], 'the Sessions are not oldest first')
        line = 'topic-order-moved-session-' + newer
        self.assertFalse(self.s.driver('action', line, 'Sort Sessions by Creation')['pressed'],
                         'a Topic in creation order offers Sort Sessions by Creation')
        self.s.act('action', line, 'Move Up')
        self.wait_order('order-moved', [newer, older], 'Move Up did not move the Session up')
        wait(lambda: self.records()['order-moved'].get('session_order') == 'manual', 'the record does not keep the manual order')
        self.assertEqual(self.recorded_paths('order-moved'), [str(self.alpha), str(self.beta)], 'the record keeps another order')
        # The app writes the live Sessions to the record again after each tmux change; the order must survive it.
        self.s.tmux('new-window', '-d', '-t', older + ':', '-c', str(self.beta))
        time.sleep(2)
        self.assertEqual(self.session_lines('order-moved', self.s.rows()), [newer, older], 'a tmux change undid the order')
        self.assertEqual(self.recorded_paths('order-moved'), [str(self.alpha), str(self.beta)], 'a tmux change rewrote the order')

        self.s.act('action', line, 'Sort Sessions by Creation')
        self.wait_order('order-moved', [older, newer], 'Sort Sessions by Creation did not go back to creation order')
        wait(lambda: 'session_order' not in self.records()['order-moved'], 'Sort Sessions by Creation kept the manual order')


if __name__ == '__main__':
    unittest.main()
