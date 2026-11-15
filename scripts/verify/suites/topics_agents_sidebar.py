"""Topics in the Sidebar: the Agents section and Pane rows.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_agents_sidebar
"""

import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import SHELL, TopicsSidebar


class TopicsAgentsSidebar(TopicsSidebar):
    def agents_header(self, rs):
        row = self.s.row('agents-header', rs)
        return row.get('accessibilityValue') or row.get('accessibilityLabel', '')

    def wait_agents(self, header, listed, hidden, message):
        """Waits until the Agents section has the header and lists every pane in listed and no pane in hidden."""
        def shows(rs):
            return (self.agents_header(rs) == header and all(self.s.has('agent-' + p, rs) for p in listed)
                    and not any(self.s.has('agent-' + p, rs) for p in hidden))
        latency, rs = self.rows_until(shows)
        self.assertIsNotNone(latency, '%s: header %r, Agent rows %s' % (
            message, self.agents_header(rs), [key for key in self.s.ids(rs) if key.startswith('agent-')]))
        return rs

    def set_show_panes(self, shown, probe):
        """Sets View > Show Panes, one value for both Sidebar modes. probe is a Pane row that shows only while it is on.
        The driver presses the menu item without opening the menu."""
        if self.s.has(probe) != shown:
            self.press_menu_item('Show Panes')
        self.s.wait_rows(lambda rs: self.s.has(probe, rs) == shown,
                         'Show Panes is not %s: no change to %s' % ('on' if shown else 'off', probe))

    def split(self, target):
        """Splits the Window and returns the new Pane, which tmux makes active."""
        return self.s.tmux('split-window', '-t', target, '-P', '-F', '#{pane_id}', '-c', str(self.beta), SHELL)

    def pane_active(self, pane):
        return self.s.tmux('display-message', '-p', '-t', pane, '#{pane_active}') == '1'

    def test_agents_section_lists_only_the_agents_of_the_active_topic_or_no_topic(self):
        self.write_topic('scope-a', 'Scope A')
        self.write_topic('scope-b', 'Scope B')
        _, window_a, pane_a = self.agent_session('scope-a', topic='scope-a')
        _, window_b, pane_b = self.agent_session('scope-b', topic='scope-b', status='blocked', unread=True)
        _, window_loose, pane_loose = self.agent_session('scope-loose')

        self.select_window(window_a)
        rs = self.wait_agents('Agents · Scope A', [pane_a], [pane_b, pane_loose], 'Window in Topic Scope A')
        self.assertIn('blocked', self.describe('topic-scope-b', rs), 'out-of-scope blocked Agent has no mark on its Topic')
        self.select_window(window_b)
        self.wait_agents('Agents · Scope B', [pane_b], [pane_a, pane_loose], 'Window in Topic Scope B')
        self.select_window(window_loose)
        self.wait_agents('Agents · No Topic', [pane_loose], [pane_a, pane_b], 'Window in No Topic')

    def test_agents_section_in_sessions_mode_lists_only_the_agents_of_the_selected_session(self):
        self.addCleanup(self.show_view, 'topics')
        self.write_topic('scope-shared', 'Scope shared')
        sid_one, window_one, pane_one = self.agent_session('scope-one', topic='scope-shared')
        sid_two, window_two, pane_two = self.agent_session('scope-two', topic='scope-shared', status='blocked', unread=True)
        self.show_view('sessions')

        self.select_window(window_one)
        rs = self.wait_agents('Agents · scope-one', [pane_one], [pane_two], 'Window in Session scope-one')
        self.assertIn('blocked', self.describe('session-' + sid_two, rs), 'out-of-scope blocked Agent has no mark on its Session')
        self.assertNotIn('blocked', self.describe('session-' + sid_one, rs))
        self.select_window(window_two)
        self.wait_agents('Agents · scope-two', [pane_two], [pane_one], 'Window in Session scope-two')

    def test_agents_scope_all_puts_the_topic_or_the_session_under_each_agent_and_never_the_window(self):
        self.addCleanup(self.show_view, 'topics')
        self.addCleanup(lambda: (self.config.write_text(self.config_text),
                                 self.s.wait_rows(lambda rs: self.agents_header(rs).startswith('Agents · '),
                                                  'agents_scope did not return to active')))
        self.write_topic('scope-all', 'Scope all')
        sid, window, pane = self.agent_session('scope-all-session', topic='scope-all')
        self.s.tmux('rename-window', '-t', window, 'window-title')
        self.select_window(window)
        self.config.write_text(self.config_text + 'sidebar:\n  agents_scope: all\n')
        key = 'agent-' + pane

        def value(rs):
            return self.s.row(key, rs).get('accessibilityValue', '') if self.s.has(key, rs) else None

        rs = self.wait_agents('Agents', [pane], [], 'agents_scope: all in Topics mode')
        self.s.wait_rows(lambda rs: (value(rs) or '').endswith(', Scope all'), 'Agent row %r has no Topic title' % value(rs))
        self.show_view('sessions')
        self.wait_agents('Agents', [pane], [], 'agents_scope: all in Sessions mode')
        rs = self.s.wait_rows(lambda rs: (value(rs) or '').endswith(', scope-all-session'),
                              'Agent row %r has no Session name' % value(self.s.rows()))
        self.assertNotIn('window-title', value(rs))

    def test_window_scope_shows_only_the_selected_windows_agents_in_both_modes(self):
        self.addCleanup(self.show_view, 'topics')
        self.addCleanup(self.config.write_text, self.config_text)
        self.write_topic('scope-window', 'Scope window')
        sid, first, first_pane = self.agent_session('scope-window-session', topic='scope-window')
        second, second_pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}',
                                          '-t', sid + ':', '-c', str(self.beta), 'sleep 600').split()
        self.s.tmux('set-option', '-p', '-t', second_pane, '@muxify_agent', 'claude')
        self.s.tmux('set-option', '-p', '-t', second_pane, '@muxify_agent_status', 'working')
        for window, pane, title in [(first, first_pane, 'Scope first'), (second, second_pane, 'Scope second')]:
            self.s.tmux('select-pane', '-t', pane, '-T', title)
        self.config.write_text(self.config_text + 'sidebar:\n  agents_scope: window\n')
        for mode in ['topics', 'sessions']:
            self.show_view(mode)
            self.select_window(first)
            self.wait_agents('Agents · Scope first', [first_pane], [second_pane], mode + ' first Window')
            self.select_window(second)
            self.wait_agents('Agents · Scope second', [second_pane], [first_pane], mode + ' second Window')

    def test_show_agents_is_remembered_separately_for_topics_and_sessions(self):
        self.addCleanup(self.set_show_agents, True)
        self.addCleanup(self.show_view, 'topics')
        self.set_show_agents(False)

        self.show_view('sessions')
        self.s.wait_rows(lambda rs: self.s.has('agents-header', rs), 'Sessions mode took the Show Agents value of Topics mode')
        self.show_view('topics')
        self.s.wait_rows(lambda rs: not self.s.has('agents-header', rs), 'Topics mode does not keep Agents hidden')

    def test_config_hides_agents_in_one_sidebar_mode_and_leaves_the_other_to_show_agents(self):
        def restore():
            self.config.write_text(self.config_text)
            self.show_view('sessions')
            self.s.wait_rows(lambda rs: self.s.has('agents-header', rs), 'Sessions mode did not return to Show Agents')
            self.show_view('topics')
        self.addCleanup(restore)
        self.config.write_text(self.config_text + 'sidebar:\n  agents:\n    sessions: false\n')
        self.show_view('sessions')
        self.s.wait_rows(lambda rs: not self.s.has('agents-header', rs), 'the Config did not hide Agents in Sessions mode')
        self.show_view('topics')
        self.s.wait_rows(lambda rs: self.s.has('agents-header', rs), 'the Config for Sessions mode hid Agents in Topics mode')

    def test_split_window_shows_one_pane_row_per_pane_and_a_one_pane_window_shows_none(self):
        s = self.s
        self.write_topic('panes-split', 'Panes split')
        sid = self.new_session('panes-split', self.beta, topic='panes-split')
        split_window, first = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id} #{pane_id}').split()
        second = self.split(split_window)
        plain_window, plain_pane = s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-t', sid + ':',
                                          '-c', str(self.beta), SHELL).split()
        self.select_window(split_window)
        self.addCleanup(self.set_show_panes, False, 'pane-' + second)
        self.set_show_panes(True, 'pane-' + second)

        rs = s.wait_rows(lambda rs: s.has('pane-' + first, rs) and s.has('topic-window-' + plain_window, rs),
                         'no Pane rows under ' + split_window)
        shown = [key for key in s.ids(rs) if key in {'topic-window-' + split_window, 'pane-' + first, 'pane-' + second,
                                                     'topic-window-' + plain_window, 'pane-' + plain_pane}]
        self.assertEqual(shown, ['topic-window-' + split_window, 'pane-' + first, 'pane-' + second,
                                 'topic-window-' + plain_window],
                         'Pane rows follow their Window in Pane order, and a one-Pane Window has none')
        self.assertEqual(s.row('pane-' + second, rs).get('accessibilityValue'), 'active', self.describe('pane-' + second, rs))
        self.assertEqual(s.row('pane-' + first, rs).get('accessibilityValue', ''), '', self.describe('pane-' + first, rs))

    def test_one_window_session_shows_pane_rows_in_place_of_the_window_row_in_both_modes(self):
        s = self.s
        self.addCleanup(self.show_view, 'topics')
        sid = self.new_session('panes-only-window', self.beta)
        window, first = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id} #{pane_id}').split()
        second = self.split(window)
        self.select_window(window)
        self.addCleanup(self.set_show_panes, False, 'pane-' + first)
        self.set_show_panes(True, 'pane-' + first)

        rs = s.wait_rows(lambda rs: s.has('pane-' + second, rs), 'no Pane rows in Topics mode')
        self.assertFalse(s.has('topic-window-' + window, rs), 'the Window row shows next to its Pane rows')
        self.assertTrue(s.has('no-topic-session-' + sid, rs), 'no Session row above the Pane rows')

        self.show_view('sessions')
        rs = s.wait_rows(lambda rs: s.has('pane-' + first, rs) and s.has('pane-' + second, rs),
                         'Show Panes does not apply in Sessions mode')
        self.assertFalse(s.has('session-window-' + window, rs), 'the Window row shows next to its Pane rows')
        # Topics mode shows a No Topic Session only while one of its Windows is selected, so Go to Session is checked here.
        base = s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.select_window(base)
        s.wait_shown(base)
        s.act('action', 'session-' + sid, 'Go to Session')
        wait(lambda: window in s.tmux('list-clients', '-F', '#{window_id}').split(),
             'Go to Session did not select its only Window ' + window, seconds=10)

    def test_pressing_a_pane_row_makes_that_pane_active_in_tmux(self):
        s = self.s
        self.write_topic('panes-press', 'Panes press')
        sid = self.new_session('panes-press', self.beta, topic='panes-press')
        window, first = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id} #{pane_id}').split()
        second = self.split(window)
        self.select_window(window)
        self.addCleanup(self.set_show_panes, False, 'pane-' + first)
        self.set_show_panes(True, 'pane-' + first)
        self.assertTrue(self.pane_active(second), 'fixture: the new split is not the active Pane')

        s.act('press', 'pane-' + first)
        wait(lambda: self.pane_active(first), 'pressing pane-%s did not make it the active Pane' % first, seconds=10)
        s.wait_rows(lambda rs: s.row('pane-' + first, rs).get('accessibilityValue') == 'active',
                    'the Pane row icon does not follow the active Pane')

    def marked_agent(self, name, status, unread):
        """An Agent in its own Topic, split beside a shell, with Pane rows on and another Window of the Session selected,
        so its card is open and its Window is never read. Returns the Agent's Pane."""
        s = self.s
        self.write_topic(name, name)
        sid, window, pane = self.agent_session(name, topic=name, status=status, unread=unread)
        self.split(window)
        other = s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', sid + ':', '-c', str(self.beta), SHELL)
        self.select_window(other)
        self.addCleanup(self.set_show_panes, False, 'pane-' + pane)
        self.set_show_panes(True, 'pane-' + pane)
        return pane

    def test_a_failed_unread_agent_shows_the_failed_mark_on_its_pane_row_and_its_topic_card(self):
        pane = self.marked_agent('marks-failed', 'failed', unread=True)
        card = 'topic-marks-failed'
        latency, rs = self.rows_until(lambda rs: 'failed' in self.s.row('pane-' + pane, rs).get('accessibilityValue', '')
                                      and 'failed' in self.describe(card, rs))
        self.assertIsNotNone(latency, 'no failed mark: %s; %s' % (self.describe('pane-' + pane, rs), self.describe(card, rs)))

    def test_a_read_done_agent_has_no_mark_on_its_pane_row_or_its_topic_card(self):
        pane = self.marked_agent('marks-read-done', 'done', unread=False)
        card = 'topic-marks-read-done'
        # The Agents row shows once the app has read the Agent, so the absence below is not a read that is late.
        rs = self.wait_agents('Agents · marks-read-done', [pane], [], 'the read, done Agent is not listed')
        rs = self.s.wait_rows(lambda rs: self.s.has('pane-' + pane, rs), 'no Pane row for the read, done Agent')
        self.assertEqual(self.s.row('pane-' + pane, rs).get('accessibilityValue', ''), '', self.describe('pane-' + pane, rs))
        self.assertNotIn('done', self.describe(card, rs).split(' | ')[1], 'the card shows a mark')
