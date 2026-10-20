"""Where the Sidebar puts its parts: the Snoozed and Settled groups at the bottom of the panel, under the Topics list,
the Agents section, Pane rows and card title lines that the Config can decide, and the accessibility elements of the
card lists.

This suite has its own sandbox with few Topics, so the Topics list is shorter than the Sidebar. In the
topics_*_sidebar suites the list grows with every check, and a position would depend on the order of the checks.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.sidebar_layout
"""

import json
import re
import unittest

from scripts.verify.sandbox import Sandbox, frame

SHELL = '/bin/zsh -f'


class SidebarLayout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.project = s.root/'projects/alpha'
        cls.project.mkdir(parents=True)
        cls.topics_dir = s.root/'state/muxify/topics'
        cls.topics_dir.mkdir(parents=True)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.write_config('')
        for topic_id, fields in [('layout-open', {}), ('layout-other', {}), ('layout-snoozed', {'snoozed_until': 'never'}),
                                 ('layout-settled', {'settled_at': '2026-01-01T00:00:00Z'})]:
            (cls.topics_dir/(topic_id + '.json')).write_text(json.dumps(dict(
                id=topic_id, title=topic_id, slug=topic_id, home_project=str(cls.project), **fields)))
        sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'layout-open', '-c', str(cls.project), SHELL)
        s.tmux('set-option', '-t', sid, '@muxify_topic', 'layout-open')
        cls.panes = s.tmux('list-panes', '-t', sid + ':', '-F', '#{pane_id}').split()
        cls.panes.append(s.tmux('split-window', '-t', sid + ':', '-P', '-F', '#{pane_id}', '-c', str(cls.project), SHELL))
        below = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'layout-other', '-c', str(cls.project), SHELL)
        s.tmux('set-option', '-t', below, '@muxify_topic', 'layout-other')
        cls.sessions = [sid, below]
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES', '-sidebarWorkView', 'Topics'])

    @classmethod
    def write_config(cls, sidebar):
        cls.config.write_text('sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n' + sidebar)

    def test_snoozed_and_settled_groups_sit_at_the_bottom_of_the_panel(self):
        rs = self.s.wait_rows(lambda rs: all(self.s.has(key, rs) for key in
                                             ['topics-list', 'topic-layout-open', 'snoozed-topics', 'settled-topics']),
                              'the Topics list does not show the open Topic and both groups')
        list_bottom, list_top = frame(self.s.row('topics-list', rs))
        topic_bottom, topic_top = frame(self.s.row('topic-layout-open', rs))
        _, snoozed_top = frame(self.s.row('snoozed-topics', rs))
        settled_bottom, settled_top = frame(self.s.row('settled-topics', rs))
        self.assertLess(list_top - topic_top, 40, 'the open Topic is not at the top of the list')
        self.assertLess(abs(list_bottom - snoozed_top), 12,
                        'Snoozed starts %.0f points away from the end of the Topics list' % (list_bottom - snoozed_top))
        self.assertLess(settled_top, snoozed_top, 'Settled is not below Snoozed')
        self.assertGreater(topic_bottom - snoozed_top, 100,
                           'the groups follow the Topics instead of the bottom of the panel')

    def test_custom_topic_summary_changes_the_closed_card(self):
        self.addCleanup(self.write_config, '')
        key = 'topic-layout-open'
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'the Topic card is missing')
        if 'expanded' in self.s.row(key).get('accessibilityValue', ''):
            self.s.act('press', key)
        self.write_config("sidebar:\n  formats:\n    topic:\n      summary: 'Custom: #{window_count} Windows'\n")
        rs = self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityHelp', '').startswith('Custom: '),
                              'the closed Topic card did not show its custom Summary')
        self.assertEqual(self.s.row(key, rs).get('accessibilityHelp'), 'Custom: 1 Windows')

    def test_custom_window_and_pane_lines_follow_the_sidebar_mode(self):
        self.addCleanup(self.write_config, '')
        self.addCleanup(self.show_view, 'topics')
        self.write_config("""sidebar:
  panes: true
  formats:
    window:
      title:
        topics: 'Window Topics #{window_index}'
        sessions: 'Window Sessions #{window_index}'
      summary: 'Window Summary'
    pane:
      title: 'Pane Format #{pane_index}'
      summary: 'Pane Summary'
""")
        window = self.s.tmux('display-message', '-p', '-t', self.sessions[1] + ':', '#{window_id}')
        for mode in ['topics', 'sessions']:
            self.show_view(mode)
            cards = (['topic-layout-open', 'topic-layout-other'] if mode == 'topics'
                     else ['session-' + sid for sid in self.sessions])
            window_key = ('topic-window-' if mode == 'topics' else 'session-window-') + window
            checks = [(cards[1], window_key, 'Window ' + mode.title(), 'Window Summary'),
                      (cards[0], 'pane-' + self.panes[0], 'Pane Format', 'Pane Summary')]
            for card, row_key, title, summary in checks:
                self.s.wait_rows(lambda rs: self.s.has(card, rs), 'missing card ' + card)
                if 'expanded' not in self.s.row(card).get('accessibilityValue', ''):
                    self.s.act('press', card)
                def formatted(rs):
                    row = json.dumps([r for r in rs if r.get('accessibilityIdentifier') == row_key], ensure_ascii=False)
                    return title in row and summary in row
                try:
                    rs = self.s.wait_rows(formatted, 'custom lines did not appear on ' + row_key + ' in ' + mode)
                except AssertionError:
                    self.fail('Format rows: ' + json.dumps([r for r in self.s.rows() if any(
                        word in json.dumps(r) for word in ['Window ', 'Pane ', 'session-window-', 'session-$'])]))
                self.assertTrue(formatted(rs))

    def test_titles_wrap_false_keeps_a_long_card_title_on_one_line(self):
        self.addCleanup(self.write_config, '')
        self.addCleanup(self.show_view, 'topics')
        tail = ' has a title long enough to need several lines in a card of the Sidebar'
        long_titles = ("sidebar:\n  formats:\n    topic:\n      title: '#{topic_title}" + tail + "'\n"
                       "    session:\n      title: '#{session_name}" + tail + "'\n")
        def height(key, rs):
            bottom, top = frame(self.s.row(key, rs))
            return top - bottom
        for mode, key in [('topics', 'topic-layout-other'), ('sessions', 'session-' + self.sessions[1])]:
            self.show_view(mode)
            self.write_config('')
            rs = self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityLabel') == 'layout-other',
                                  'the card %s does not show its default title' % key)
            if self.s.row(key, rs).get('accessibilityValue', '').startswith('expanded'):
                self.s.act('press', key)
            rs = self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityValue', '').startswith('collapsed'),
                                  'the card %s did not close' % key)
            one_line = height(key, rs)
            self.write_config(long_titles)
            rs = self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityLabel') == 'layout-other' + tail
                                  and height(key, rs) > one_line + 8,
                                  'the long title of %s does not wrap by default' % key)
            wrapped = height(key, rs)
            self.write_config(long_titles + '  titles:\n    wrap: false\n')
            rs = self.s.wait_rows(lambda rs: abs(height(key, rs) - one_line) < 1,
                                  'titles.wrap: false keeps %s at %.0f points, not the %.0f of one line'
                                  % (key, wrapped, one_line))
            self.assertEqual(self.s.row(key, rs).get('accessibilityLabel'), 'layout-other' + tail,
                             'the cut title of %s does not keep the whole title for accessibility' % key)

    def show_view(self, name):
        key = 'sidebar-view-' + name
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no button ' + key)
        if self.s.row(key).get('accessibilityValue') != 'selected':
            self.s.act('press', key)
        self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityValue') == 'selected', key + ' not selected')

    def assert_no_element_spans_two_cards(self, list_key, card_keys):
        """A click tool such as Homerow offers an anchor for each element and clicks at its centre. An element over
        several cards puts that centre on another card's header, so the anchor at the last card presses a different one."""
        rs = self.s.wait_rows(lambda rs: all(self.s.has(key, rs) for key in [list_key] + card_keys),
                              'the list %s does not show the cards %s' % (list_key, card_keys))
        list_bottom, list_top = frame(self.s.row(list_key, rs))
        cards = [frame(self.s.row(key, rs)) for key in card_keys]
        spanning = [row for row in rs if 'accessibilityFrame' in row and row is not self.s.row(list_key, rs)
                    and list_bottom <= frame(row)[0] and frame(row)[1] <= list_top
                    and sum(frame(row)[0] <= bottom and top <= frame(row)[1] for bottom, top in cards) > 1]
        self.assertEqual(spanning, [], 'elements in %s cover more than one card' % list_key)

    def test_no_element_in_the_topics_list_covers_two_topic_cards(self):
        self.assert_no_element_spans_two_cards('topics-list', ['topic-layout-open', 'topic-layout-other'])

    def test_no_element_in_the_sessions_list_covers_two_session_cards(self):
        self.show_view('sessions')
        self.addCleanup(self.show_view, 'topics')
        self.assert_no_element_spans_two_cards('sessions-list', ['session-' + sid for sid in self.sessions])

    def test_a_click_tool_clicks_a_closed_topic_card_on_its_title_line(self):
        key = 'topic-layout-other'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no card for the Topic')
        if self.s.row(key, rs).get('accessibilityValue', '').startswith('expanded'):
            self.s.act('press', key)
        rs = self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityValue', '').startswith('collapsed'),
                              'the card did not close')
        row = self.s.row(key, rs)
        bottom, top = frame(row)
        x, y = map(float, re.findall(r'-?[\d.]+', row['accessibilityActivationPoint']))
        # The title is the first line of a closed card; the summary line is under it, in the lower half.
        self.assertTrue(bottom + (top - bottom) / 2 < y < top,
                        'the activation point %.0f is not in the upper half of the header %.0f..%.0f' % (y, bottom, top))

    def test_an_opened_group_grows_up_from_the_bottom_with_its_topics_under_its_row(self):
        rs = self.s.wait_rows(lambda rs: self.s.has('settled-topics', rs), 'no Settled group')
        closed_bottom, _ = frame(self.s.row('settled-topics', rs))
        self.s.act('press', 'settled-topics')
        self.addCleanup(lambda: self.s.act('press', 'settled-topics'))
        rs = self.s.wait_rows(lambda rs: self.s.has('topic-layout-settled', rs), 'the Settled group did not open')
        row_bottom, row_top = frame(self.s.row('topic-layout-settled', rs))
        open_bottom, _ = frame(self.s.row('settled-topics', rs))
        self.assertLessEqual(row_top, open_bottom + 1, 'the Settled Topic is not under the Settled row')
        self.assertGreater(open_bottom - closed_bottom, 10, 'the Settled row did not move up when the group opened')
        self.assertLess(abs(row_bottom - closed_bottom), 4, 'the opened group does not end at the bottom of the panel')

    def test_sidebar_panes_true_shows_pane_rows_whatever_the_view_menu_says(self):
        rs = self.s.wait_rows(lambda rs: self.s.has('topic-layout-open', rs), 'no row for the open Topic')
        if not self.s.row('topic-layout-open', rs).get('accessibilityValue', '').startswith('expanded'):
            self.s.act('press', 'topic-layout-open')
        pane_rows = ['pane-' + pane for pane in self.panes]
        self.s.wait_rows(lambda rs: not any(self.s.has(key, rs) for key in pane_rows),
                         'Pane rows show with the default Config and Show Panes off')
        self.addCleanup(lambda: (self.write_config(''),
                                 self.s.wait_rows(lambda rs: not any(self.s.has(key, rs) for key in pane_rows),
                                                  'Pane rows stay without sidebar.panes')))
        self.write_config('sidebar:\n  panes: true\n')
        self.s.wait_rows(lambda rs: all(self.s.has(key, rs) for key in pane_rows), 'sidebar.panes: true shows no Pane rows')
        self.s.driver('press', 'Show Panes')
        rs = self.s.rows()
        self.assertTrue(all(self.s.has(key, rs) for key in pane_rows), 'Show Panes hides the Pane rows that the Config shows')

    def test_sidebar_agents_false_removes_the_agents_section(self):
        self.s.wait_rows(lambda rs: self.s.has('agents-header', rs), 'the Agents section does not show with the default Config')
        self.addCleanup(lambda: (self.write_config(''),
                                 self.s.wait_rows(lambda rs: self.s.has('agents-header', rs),
                                                  'the Agents section did not return without sidebar.agents')))
        self.write_config('sidebar:\n  agents: false\n')
        self.s.wait_rows(lambda rs: not self.s.has('agents-header', rs), 'sidebar.agents: false keeps the Agents section')
        self.s.driver('press', 'Show Agents')
        rs = self.s.rows()
        self.assertFalse(self.s.has('agents-header', rs), 'Show Agents brings back the section that the Config removed')
