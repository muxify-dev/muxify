"""Topics in the Sidebar: the Snoozed and Settled groups, their order, and which group is open.

A card in a group (TopicCard in UI/SidebarView.swift) gives its context menu's items as accessibility actions.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_groups_sidebar
"""

import json
import time
import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import TopicsSidebar


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

    def test_opening_one_group_closes_the_other_and_a_header_press_goes_to_no_topic(self):
        s = self.s
        self.write_topic('one-open-snoozed', 'One open snoozed', self.beta, snoozed_until='never')
        self.write_topic('one-open-settled', 'One open settled', self.beta, settled_at='2031-01-01T10:00:00Z')
        self.collapse('settled-topics')
        self.collapse('snoozed-topics')
        clients = s.tmux('list-clients', '-F', '#{window_id}')
        s.act('press', 'snoozed-topics')
        s.wait_rows(lambda rs: self.expanded('snoozed-topics', rs), 'the Snoozed header did not open its group')
        s.act('press', 'settled-topics')
        rs = s.wait_rows(lambda rs: self.expanded('settled-topics', rs), 'the Settled header did not open its group')
        self.assertFalse(self.expanded('snoozed-topics', rs), 'opening Settled did not close Snoozed')
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

    def test_snoozed_group_lists_snoozed_topic_with_its_live_windows_and_unsnooze_returns_it(self):
        self.write_topic('group-snoozed', 'Group snoozed', self.beta, snoozed_until='never')
        sid = self.new_session('group-snoozed', self.beta, topic='group-snoozed')
        window = self.s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        self.expand('snoozed-topics')
        latency, rs = self.rows_until(lambda rs: self.grouped('topic-group-snoozed', 'snoozed-topics', rs))
        self.assertIsNotNone(latency, 'Topic is not in the Snoozed group; Topic rows %s' % self.topic_rows(rs))
        self.assertIn('never', self.describe('topic-group-snoozed', rs), 'row does not show its wake time')
        # The app reads the Topic file within a quarter second and tmux once per second, so the row can show before
        # the app has seen the Session.
        latency, rs = self.rows_until(lambda rs: 'Dormant' not in self.describe('topic-group-snoozed', rs), seconds=5)
        self.assertIsNotNone(latency, 'a Topic with a live Session is Dormant: ' + self.describe('topic-group-snoozed', rs))

        self.expand('topic-group-snoozed')
        self.s.wait_rows(lambda rs: self.s.has('topic-window-' + window, rs), 'snoozed Topic does not list its live Window')
        self.s.act('press', 'topic-window-' + window)
        wait(lambda: window in self.s.tmux('list-clients', '-F', '#{window_id}').split(),
             'click on the snoozed Window did not show it', seconds=10)

        self.s.act('press', 'unsnooze-topic-group-snoozed')
        latency, rs = self.rows_until(lambda rs: self.s.has('topic-group-snoozed', rs)
                                      and not self.grouped('topic-group-snoozed', 'snoozed-topics', rs))
        self.assertIsNotNone(latency, 'Unsnooze did not return the Topic to the Topics list; Topic rows %s' % self.topic_rows(rs))
        self.assertNotIn('snoozed_until', self.records()['group-snoozed'], 'Unsnooze kept the snooze in the record')

    def test_snoozed_group_lists_topics_by_wake_time_soonest_first_and_until_unsnooze_last(self):
        at = lambda seconds: time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() + seconds))
        self.write_topic('wake-order-never', 'Wake never', self.beta, snoozed_until='never', order=-3000)
        self.write_topic('wake-order-late', 'Wake late', self.beta, snoozed_until=at(7200), order=-2999, pinned=True)
        self.write_topic('wake-order-soon', 'Wake soon', self.beta, snoozed_until=at(3600), order=-2998)
        expected = ['topic-wake-order-soon', 'topic-wake-order-late', 'topic-wake-order-never']
        mine = lambda rs: [key for key in self.topic_rows(rs) if key.startswith('topic-wake-order-')
                           and self.grouped(key, 'snoozed-topics', rs)]
        self.expand('snoozed-topics')
        latency, rs = self.rows_until(lambda rs: len(mine(rs)) == 3)
        self.assertIsNotNone(latency, 'the Snoozed group does not list the three Topics; Topic rows %s' % self.topic_rows(rs))
        self.assertEqual(mine(rs), expected, 'the Snoozed group is not in wake time order, with the Pin ignored')

    def test_a_press_on_a_closed_snoozed_card_goes_to_the_topic_and_keeps_it_snoozed_with_pin(self):
        s = self.s
        self.write_topic('card-snoozed', 'Card snoozed', self.beta, snoozed_until='never')
        sid = self.new_session('card-snoozed', self.beta, topic='card-snoozed')
        window = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        self.expand('snoozed-topics')
        rs = s.wait_rows(lambda rs: self.grouped('topic-card-snoozed', 'snoozed-topics', rs)
                         and 'Empty' not in s.row('topic-card-snoozed', rs).get('accessibilityValue', ''),
                         'the Topic is not in the Snoozed group with its live Session')
        self.assertFalse(self.expanded('topic-card-snoozed', rs), 'a Snoozed card starts open')
        self.assertFalse(s.has('topic-window-' + window, rs), 'a closed Snoozed card lists its Windows')
        s.act('press', 'topic-card-snoozed')
        s.wait_shown(window)
        rs = s.wait_rows(lambda rs: self.expanded('topic-card-snoozed', rs) and s.has('topic-window-' + window, rs),
                         'going to the Snoozed Topic did not open its card to its Windows')
        self.assertTrue(self.grouped('topic-card-snoozed', 'snoozed-topics', rs), 'a press on a Snoozed card Unsnoozed it')
        self.assertEqual(self.records()['card-snoozed'].get('snoozed_until'), 'never', 'a press on a Snoozed card changed its Snooze')
        s.act('action', 'topic-card-snoozed', 'Pin Topic')
        wait(lambda: self.records()['card-snoozed'].get('pinned') is True, 'Pin on a Snoozed card did not Pin the Topic')

    def test_snoozed_topic_wakes_at_its_deadline_while_the_app_runs(self):
        deadline = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() + 6))
        self.write_topic('group-wakes', 'Group wakes', self.beta, snoozed_until=deadline)
        self.new_session('group-wakes', self.beta, topic='group-wakes')
        self.expand('snoozed-topics')
        self.s.wait_rows(lambda rs: self.grouped('topic-group-wakes', 'snoozed-topics', rs),
                         'Topic is not in the Snoozed group before its deadline')
        # Nothing changes in tmux or in the Topic files at the deadline; only the time tells the app to wake the Topic.
        latency, rs = self.rows_until(lambda rs: self.s.has('topic-group-wakes', rs)
                                      and not self.grouped('topic-group-wakes', 'snoozed-topics', rs), seconds=20)
        self.assertIsNotNone(latency, 'Topic did not wake at its deadline; Topic rows %s' % self.topic_rows(rs))
        self.assertNotIn('snoozed_until', self.records()['group-wakes'], 'the woken Topic kept its snooze in the record')

    def test_snoozed_topic_row_offers_settle_and_snooze_again(self):
        self.write_topic('group-again', 'Group again', self.beta, snoozed_until='never')
        self.expand('snoozed-topics')
        rs = self.s.wait_rows(lambda rs: self.grouped('topic-group-again', 'snoozed-topics', rs), 'Topic is not in the Snoozed group')
        self.assertIn('Empty', self.describe('topic-group-again', rs), 'a snoozed Topic that remembers no Session does not say Empty')
        self.s.act('action', 'topic-group-again', 'Snooze again…')
        self.s.wait_rows(lambda rs: self.s.has('palette-accept', rs), 'Snooze again did not open the Snooze palette')
        self.s.act('press', 'palette-cancel')
        self.s.wait_rows(lambda rs: not self.s.has('palette-accept', rs), 'Snooze palette did not close')
        self.s.act('action', 'topic-group-again', 'Settle…')
        self.s.wait_rows(lambda rs: self.s.has('palette-cancel', rs), 'Settle did not open the Settle palette')
        self.s.act('press', 'palette-cancel')
        self.s.wait_rows(lambda rs: not self.s.has('palette-cancel', rs), 'Settle palette did not close')

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
                         sessions=[dict(project_path=str(self.alpha), windows=[dict(directory=str(self.alpha), name='shell')])])
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
        self.s.wait_rows(lambda rs: self.s.has('topic-above-24', rs) or self.s.has('topic-above-00', rs), 'no open Topic rows')
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
