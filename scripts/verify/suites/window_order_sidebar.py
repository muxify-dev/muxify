"""The order of a Session's Windows in the Sidebar. A long press on a Window row moves the Window within its Session,
in a Topic card and in a Session card, which the driver's drag with `hold` does. The row's own Button keeps its
accessibility press, and a click goes to the long-press handle around it (CardList in UI/SidebarCard.swift).

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.window_order_sidebar
"""

import json
import unittest

from scripts.verify.sandbox import Sandbox, remove_topic, wait

SHELL = '/bin/zsh -f'


class WindowOrderSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.topics = s.root/'state/muxify/topics'
        cls.topics.mkdir(parents=True)
        # A Session no check uses, where the client waits while a check's Session ends.
        s.tmux('new-session', '-d', '-s', 'base', SHELL)
        s.tmux('set-option', '-g', 'detach-on-destroy', 'off')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])

    def three_windows(self, name, topic=None):
        """A Session with three Windows, in the Topic `topic` when given; returns its Session ID and Window IDs."""
        s = self.s
        if topic:
            path = self.topics/(topic + '.json')
            self.addCleanup(remove_topic, path)
            path.write_text(json.dumps(dict(id=topic, title=topic.capitalize(), slug=topic)))
        sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, SHELL)
        self.addCleanup(self.end_session, sid)
        if topic:
            s.tmux('set-option', '-t', sid, '@muxify_topic', topic)
        windows = [s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')]
        windows += [s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', sid + ':', SHELL) for _ in range(2)]
        return sid, windows

    def end_session(self, sid):
        if sid in self.s.tmux('list-clients', '-F', '#{session_id}').split():
            self.select_window('base:')
            self.s.wait_shown('base:')
        self.s.tmux_ok('kill-session', '-t', sid)

    def select_window(self, window):
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty}').split():
            self.s.tmux('switch-client', '-c', tty, '-t', window)

    def show_view(self, name):
        key = 'sidebar-view-' + name
        if self.s.row(key).get('accessibilityValue') != 'selected':
            self.s.act('press', key)
        self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityValue') == 'selected', key + ' not selected')

    def row_order(self, prefix, windows, rs=None):
        """The Windows' rows top to bottom. A Session card's row gives its identifier to each of its parts."""
        order = []
        for key in self.s.ids(rs):
            window = key[len(prefix):]
            if key.startswith(prefix) and window in windows and window not in order:
                order.append(window)
        return order

    def tmux_order(self, sid):
        return self.s.tmux('list-windows', '-t', sid, '-F', '#{window_id}').split()

    def current_window(self, sid):
        return self.s.tmux('display-message', '-p', '-t', sid, '#{window_id}')

    def test_a_long_press_on_a_window_row_moves_it_up_within_its_session_in_a_topic_card(self):
        s = self.s
        sid, windows = self.three_windows('order-topic', topic='window-order')
        self.show_view('topics')
        self.select_window(windows[0])
        # The drag takes the rows' frames from one dump. The rows move when the app follows the client, so wait
        # for that first, as the README asks after a client move.
        s.wait_shown(windows[0])
        s.wait_rows(lambda rs: self.row_order('topic-window-', windows, rs) == windows,
                    'the Topic card does not list the Windows in tmux order: %s' % self.row_order('topic-window-', windows))
        s.act('drag', 'topic-window-' + windows[2], 'topic-window-' + windows[0], hold=0.7)
        moved = [windows[2], windows[0], windows[1]]
        wait(lambda: self.tmux_order(sid) == moved, 'tmux order after the long press: %s' % self.tmux_order(sid))
        s.wait_rows(lambda rs: self.row_order('topic-window-', windows, rs) == moved,
                    'the card does not show the new order: %s' % self.row_order('topic-window-', windows))
        self.assertEqual(self.current_window(sid), windows[0], 'the move changed the Session\'s current Window')

    def test_a_long_press_on_a_window_row_moves_it_down_within_its_session_in_a_session_card(self):
        s = self.s
        sid, windows = self.three_windows('order-session')
        self.addCleanup(self.show_view, 'topics')
        self.show_view('sessions')
        self.select_window(windows[1])
        s.wait_shown(windows[1])
        s.wait_rows(lambda rs: self.row_order('session-window-', windows, rs) == windows,
                    'the Session card does not list the Windows in tmux order: %s' % self.row_order('session-window-', windows))
        s.act('drag', 'session-window-' + windows[0], 'session-window-' + windows[2], hold=0.7, edge='bottom')
        moved = [windows[1], windows[2], windows[0]]
        wait(lambda: self.tmux_order(sid) == moved, 'tmux order after the long press: %s' % self.tmux_order(sid))
        s.wait_rows(lambda rs: self.row_order('session-window-', windows, rs) == moved,
                    'the card does not show the new order: %s' % self.row_order('session-window-', windows))
        self.assertEqual(self.current_window(sid), windows[1], 'the move changed the Session\'s current Window')

    def test_a_click_on_a_window_row_selects_the_window_and_moves_nothing(self):
        s = self.s
        sid, windows = self.three_windows('order-click', topic='window-click')
        self.show_view('topics')
        self.select_window(windows[0])
        s.wait_rows(lambda rs: self.row_order('topic-window-', windows, rs) == windows, 'the Topic card does not list the Windows')
        s.act('click', 'topic-window-' + windows[2])
        s.wait_shown(windows[2])
        self.assertEqual(self.tmux_order(sid), windows, 'a click moved a Window')


if __name__ == '__main__':
    unittest.main()
