"""Topics in the Sidebar: the Settled group, its pages, and when it is open.

A card in a group (TopicCard in UI/SidebarView.swift) gives its context menu's items as accessibility actions.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_groups_sidebar
"""

import json
import unittest

from scripts.verify.sandbox import frame, wait
from scripts.verify.topics_sidebar import TopicsSidebar, remembered_session


class TopicsGroupsSidebar(TopicsSidebar):
    def go_to(self, query):
        def opened():
            if not self.s.has('palette-search'):
                self.s.driver('press', 'Go to…')
            return self.s.has('palette-search')
        wait(opened, 'Go to… did not open', seconds=20)
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', query)
        return self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue', '') == query,
                                'Go to… did not take the query %r' % query)

    def assert_group_row_in_view(self, rs, when):
        floor = frame(self.s.row('agents-header', rs))[1]
        ceiling = frame(self.s.row('topics-list', rs))[0]
        bottom, top = frame(self.s.row('settled-topics', rs))
        self.assertTrue(floor <= bottom and top <= ceiling,
                        '%s: the Settled row %s is not between the Topics list and the Agents section (%s..%s)'
                        % (when, (bottom, top), floor, ceiling))

    def test_an_open_group_keeps_its_row_in_view(self):
        s = self.s
        settled = ['rows-in-view-settled-%02d' % i for i in range(12)]
        for number, topic_id in enumerate(settled):
            self.write_topic(topic_id, 'Rows in view ' + topic_id[-2:], self.beta, settled_at='2030-02-%02dT10:00:00Z' % (28 - number))
        self.collapse('settled-topics')
        s.act('press', 'settled-topics')
        last = 'topic-' + settled[-1]
        rs = s.wait_rows(lambda rs: self.expanded('settled-topics', rs) and s.has(last, rs),
                         'the Settled header did not open its group')
        self.assertLess(frame(s.row(last, rs))[1], frame(s.row('agents-header', rs))[1],
                        'the 12 Settled cards fit in their block, so the check proves nothing')
        self.assert_group_row_in_view(rs, 'Settled open')
        s.reveal(last)
        rs = s.rows()
        self.assertGreaterEqual(frame(s.row(last, rs))[0], frame(s.row('agents-header', rs))[1],
                                'revealing the last Settled card did not scroll it into its block above the Agents section')
        self.assert_group_row_in_view(rs, 'Settled scrolled to its last card')

    def test_a_group_header_press_opens_the_group_and_does_not_go_to_a_topic(self):
        s = self.s
        self.write_topic('one-open-settled', 'One open settled', self.beta, settled_at='2031-01-01T10:00:00Z')
        # A move of the shown Window closes the group, so the check starts on base, not on a Reopen choice that an
        # earlier check left.
        self.select_window('base:')
        s.wait_shown('base:')
        self.collapse('settled-topics')
        clients = s.tmux('list-clients', '-F', '#{window_id}')
        s.act('press', 'settled-topics')
        s.wait_rows(lambda rs: self.expanded('settled-topics', rs), 'the Settled header did not open its group')
        self.assertEqual(s.tmux('list-clients', '-F', '#{window_id}'), clients, 'a header press went to a Topic')

    def test_go_to_a_settled_topic_opens_its_group_and_going_to_a_topic_in_the_list_closes_it(self):
        s = self.s
        self.write_topic('leave-open', 'Leave open', self.beta)
        sid = self.new_session('leave-open', self.beta, topic='leave-open')
        self.write_topic('goto-settled', 'Goto settled', self.beta, settled_at='2031-01-01T10:00:00Z')
        self.select_window('base:')
        s.wait_shown('base:')
        self.collapse('settled-topics')
        self.go_to('Goto settled')
        s.wait_rows(lambda rs: s.has('palette-row-topic-goto-settled', rs), 'Go to… does not list the Settled Topic')
        s.act('press', 'palette-row-topic-goto-settled')
        rs = s.wait_rows(lambda rs: self.expanded('settled-topics', rs) and self.grouped('topic-goto-settled', 'settled-topics', rs),
                         'Go to… a Settled Topic did not open the Settled group')
        self.select_window(sid + ':')
        s.wait_rows(lambda rs: not self.expanded('settled-topics', rs),
                    'going to a Topic in the Topics list did not close the Settled group')

    def test_settled_group_lists_settled_topic_with_remembered_windows_and_its_reopen_choice_rebuilds_it(self):
        self.write_topic('group-settled', 'Group settled', self.alpha, settled_at='2031-01-01T10:00:00Z', outcome='Shipped proof',
                         sessions=[dict(id='saved', name='alpha/group-settled', base_name='alpha', directory=str(self.alpha), windows=[dict(directory=str(self.alpha), name='shell')])])
        self.expand('settled-topics')
        latency, rs = self.rows_until(lambda rs: self.grouped('topic-group-settled', 'settled-topics', rs))
        self.assertIsNotNone(latency, 'Topic is not in the Settled group; Topic rows %s' % self.topic_rows(rs))
        self.assertIn('Shipped proof', self.describe('topic-group-settled', rs), 'row does not show its outcome')

        self.expand('topic-group-settled')
        key = 'remembered-window-group-settled-0-0'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'settled Topic does not list its remembered Window')
        self.assertIn('shell', json.dumps(self.s.row(key, rs)), 'remembered Window row %s' % json.dumps(self.s.row(key, rs)))
        self.assertFalse(self.s.tmux_ok('has-session', '-t', '=alpha/group-settled').returncode == 0,
                         'a remembered row made a live Session')

        self.s.act('press', 'reopen-topic-group-settled')
        rs = self.s.wait_rows(lambda rs: self.s.has('reopen-choice-reopen', rs), 'Reopen… did not show the Reopen choice')
        self.assertIn('shell', self.describe('reopen-session-alpha', rs), 'the Reopen column does not list the remembered Window')
        self.assertIsNotNone(self.records()['group-settled'].get('settled_at'), 'the Reopen choice changed the record')
        self.s.act('press', 'reopen-choice-reopen')
        self.wait_session('alpha/group-settled')
        latency, rs = self.rows_until(lambda rs: self.s.has('topic-group-settled', rs)
                                      and not self.grouped('topic-group-settled', 'settled-topics', rs))
        self.assertIsNotNone(latency, 'Reopen did not return the Topic to the Topics list; Topic rows %s' % self.topic_rows(rs))
        self.assertIsNone(self.records()['group-settled'].get('settled_at'), 'Reopen kept the settle date in the record')

    def test_a_click_on_a_closed_settled_card_shows_its_reopen_choice_and_reopens_nothing(self):
        self.write_topic('click-settled', 'Click settled', self.alpha, settled_at='2031-01-02T10:00:00Z',
                         sessions=[remembered_session(self.alpha, 'click-settled', windows=[dict(directory=str(self.alpha), name='shell')])])
        self.expand('settled-topics')
        rs = self.s.wait_rows(lambda rs: self.grouped('topic-click-settled', 'settled-topics', rs), 'the Topic is not in the Settled group')
        self.assertFalse(self.expanded('topic-click-settled', rs), 'a Settled card starts open')
        self.s.act('click', 'topic-click-settled')
        rs = self.s.wait_rows(lambda rs: self.s.has('reopen-choice-reopen', rs) and self.expanded('topic-click-settled', rs),
                              'a click on a Settled card did not show its Reopen choice with the card open')
        self.assertTrue(self.grouped('topic-click-settled', 'settled-topics', rs), 'a click on a Settled card took it out of the group')
        self.assertIsNotNone(self.records()['click-settled'].get('settled_at'), 'a click on a Settled card changed the record')
        self.assertNotEqual(self.s.tmux_ok('has-session', '-t', '=alpha/click-settled').returncode, 0,
                            'a click on a Settled card Reopened it without the Reopen choice')

    def test_settled_group_below_twenty_five_open_topics_shows_fifteen_newest_then_fifteen_more_and_collapsing_resets(self):
        # The Sidebar builds only the rows it shows. The open Topics push the Settled group and its pages below the
        # visible part, so each step reveals the row it needs before it reads the rows.
        for number in range(25):
            self.write_topic('above-%02d' % number, 'Above %02d' % number, self.beta)
        self.addCleanup(self.remove_topics, 'above-')
        for number in range(17):
            self.write_topic('page-%02d' % number, 'Page %02d' % number, self.beta, settled_at='2030-01-%02dT00:00:00Z' % (number + 1))
        self.addCleanup(self.collapse, 'settled-topics')
        # The app reads the Topic files once per quarter second, so one read can see the open Topics and not yet the
        # Settled ones. Wait for the Settled header's count before the first reveal, which does not wait.
        self.s.wait_rows(lambda rs: (self.s.has('topic-above-24', rs) or self.s.has('topic-above-00', rs))
                         and '(17)' in self.s.row('settled-topics', rs).get('accessibilityLabel', ''),
                         'the Sidebar does not show the open Topics and the 17 Settled Topics')
        self.s.reveal('settled-topics')
        self.collapse('settled-topics')
        self.expand('settled-topics')
        self.s.reveal('settled-show-more')
        latency, rs = self.rows_until(lambda rs: len(self.settled_rows(rs)) == 15 and self.s.has('settled-show-more', rs))
        self.assertIsNotNone(latency, 'Settled group rows %s' % self.settled_rows(rs))
        self.assertIn('topic-page-16', self.settled_rows(rs), 'the newest Settled Topic is not on the first page')
        self.assertNotIn('topic-page-00', self.settled_rows(rs), 'the oldest Settled Topic is on the first page')

        self.s.act('press', 'settled-show-more')
        self.s.reveal('topic-page-00')
        latency, rs = self.rows_until(lambda rs: 'topic-page-00' in self.settled_rows(rs))
        self.assertIsNotNone(latency, 'Show 15 more did not add the oldest Topic; rows %s' % self.settled_rows(rs))
        self.assertGreaterEqual(len(self.settled_rows(rs)), 17)

        self.collapse('settled-topics')
        self.expand('settled-topics')
        self.s.reveal('settled-show-more')
        latency, rs = self.rows_until(lambda rs: len(self.settled_rows(rs)) == 15)
        self.assertIsNotNone(latency, 'collapsing did not reset the Settled group to 15 rows; rows %s' % self.settled_rows(rs))
