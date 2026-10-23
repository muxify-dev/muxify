"""Topics in the Sidebar: moving a Window to a Topic, Topic and Session cards, the Snoozed and Settled groups, and Zen.

The Topic and Session card headers in UI/SidebarView.swift give "Zen…", "Pin Topic", "Go to Topic" and "Go to Session"
as accessibility actions, so the checks reach them without the header's context menu.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_cards_sidebar
"""

import json
import time
import unittest

from scripts.verify.sandbox import frame, wait
from scripts.verify.topics_sidebar import REFRESH_LIMIT, SHELL, TopicsSidebar, remembered_session

AGENT_WINDOW = ('#{session_name}|#{@muxify_topic}|#{window_id}|#{pane_id}|#{pane_pid}|#{pane_current_command}|'
                '#{@muxify_agent}|#{@muxify_agent_status}|#{@muxify_agent_conversation}|#{@muxify_tabs}|'
                '#{@muxify_active_tab}|#{@muxify_browser}')
AGENT_WINDOW_FIELDS = ['session', 'topic', 'window', 'pane', 'pane_pid', 'command', 'agent', 'status', 'conversation',
                       'tabs', 'active_tab', 'browser']


class TopicsCardsSidebar(TopicsSidebar):
    def wait_selected(self, window):
        """Waits until the app selects the Window. tmux moves the client at once, but the app follows it only at its
        next read, and until then it still keeps the last Window of the Topic that it shows."""
        key = 'topic-window-' + window
        def selected():
            rs = self.s.rows()
            if not self.s.has(key, rs):
                rs = self.s.driver('dump', key, reveal=True)['rows']
            return self.s.row(key, rs).get('accessibilityValue') == 'selected'
        wait(selected, 'the app did not select ' + window, seconds=10)

    def client_windows(self):
        return self.s.tmux('list-clients', '-F', '#{window_id}').split()

    def test_new_topics_go_below_locked_sessions_by_default(self):
        self.write_topic('insert-existing', 'Existing', self.beta, order=0)
        sid = self.new_session('insert-lock', self.beta)
        self.s.tmux('set-option', '-t', sid, '@muxify_lock', '2')
        self.find('locked-' + sid)
        record = self.create_topic('Inserted below Lock')
        key = 'topic-' + record['id']
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs) and self.s.has('locked-' + sid, rs)
                             and frame(self.s.row('locked-' + sid, rs))[1] > frame(self.s.row(key, rs))[1],
                             'the new Topic is not below the Locked Session')
        self.assertGreater(record['order'], 2)
        self.assertGreater(frame(self.s.row('locked-' + sid, rs))[1], frame(self.s.row(key, rs))[1])

    def test_top_config_puts_a_new_topic_below_pinned_topics(self):
        self.write_topic('insert-pin', 'Pinned', self.beta, order=0, pinned=True)
        self.write_topic('insert-top', 'Existing', self.beta, order=0)
        self.addCleanup(self.s.act, 'press', 'Reload Config')
        self.addCleanup(self.config.write_text, self.config_text)
        self.config.write_text(self.config_text + '  insert_position: top\n')
        self.s.act('press', 'Reload Config')
        record = self.create_topic('Inserted at top')
        key = 'topic-' + record['id']
        expected = ['topic-insert-pin', key, 'topic-insert-top']
        rs = self.s.wait_rows(lambda rs: [row for row in self.topic_rows(rs) if row in expected] == expected,
                             'the new Topic is not first below the Pinned Topics')
        self.assertEqual([row for row in self.topic_rows(rs) if row in expected], expected)

    def test_window_moved_to_topic_keeps_its_panes_agent_and_browser(self):
        s = self.s
        self.write_topic('move-target', 'Move target', self.alpha, created_at='2026-10-07T00:00:00Z', order=0)
        self.new_session('alpha/move-target', self.alpha, topic='move-target')
        session, window, pane, pane_pid = s.tmux(
            'new-session', '-d', '-P', '-F', '#{session_id} #{window_id} #{pane_id} #{pane_pid}', '-s', 'agent-src',
            '-c', str(self.beta), '-n', 'agent', 'sleep 600').split()
        # A second Window keeps the source Session alive after the move.
        s.tmux('new-window', '-d', '-t', session + ':', '-n', 'spare', '-c', str(self.beta), SHELL)
        s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude')
        s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', 'working')
        s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_conversation', 'verify-conversation')
        for key, value in [('@muxify_tabs', 'https://example.com/ https://example.org/'), ('@muxify_active_tab', '1'),
                           ('@muxify_browser', 'on')]:
            s.tmux('set-option', '-w', '-t', window, key, value)
        s.wait_rows(lambda rs: s.has('topic-move-target', rs), 'no row for Topic move-target')
        before = s.tmux('display-message', '-p', '-t', window, AGENT_WINDOW).split('|')

        self.select_window(session + ':spare')
        self.expand('no-topic-session-' + session)
        s.wait_rows(lambda rs: s.has('topic-window-' + window, rs), 'Agent Window row not visible')
        # SidebarView gives the Window row the context menu's moves as accessibility actions
        # (topicMembershipActions), because the menu itself takes the mouse and the keyboard.
        s.act('action', 'topic-window-' + window, 'Move Window to Topic…')
        s.wait_rows(lambda rs: s.has('palette-row-topic-move-target', rs), 'Move did not show the target Topic')
        # The Topic has one Session, so the move skips the destination step and lands in that Session (ADR 0036).
        s.act('press', 'palette-row-topic-move-target')
        wait(lambda: s.tmux('display-message', '-p', '-t', window, '#{session_name}') == 'alpha/move-target',
             'Window did not move to alpha/move-target', seconds=10)
        self.select_window(window)
        self.expand('topic-move-target')
        rs = s.wait_rows(lambda rs: self.card_of('topic-window-' + window, rs) == 'topic-move-target' and s.has('agent-' + pane, rs),
                         'the moved Window row is not under its Topic, or its Agent row is missing')
        agent_rows = [r for r in rs if r.get('accessibilityIdentifier') == 'agent-' + pane]
        self.assertTrue(any(r.get('accessibilityHelp') == 'Claude Code — working' for r in agent_rows),
                        'Agent rows %s' % json.dumps(agent_rows, ensure_ascii=False))
        # The Sidebar shows the moved Window only after the app read tmux again, so options it lost would show now.
        after = s.tmux('display-message', '-p', '-t', window, AGENT_WINDOW).split('|')
        changes = {name: (b, a) for name, b, a in zip(AGENT_WINDOW_FIELDS, before, after) if b != a}
        self.assertEqual((after[0], after[1]), ('alpha/move-target', 'move-target'), 'moved Window: %s' % changes)
        self.assertEqual(set(changes), {'session', 'topic'}, 'moved Window changed more than its Session and Topic')

    def card_of(self, key, rs):
        """The card whose header is the nearest above the row on screen, nil without the row. The dump lists an open card's
        header after its rows, because the header draws above them to stay at the top of the list."""
        if not self.s.has(key, rs):
            return None
        row_top = frame(self.s.row(key, rs))[1]
        cards = [card for card in self.topic_rows(rs) + ['no-topic-session-' + sid for sid in self.no_topic_cards(rs)]
                 if frame(self.s.row(card, rs))[1] >= row_top]
        return min(cards, key=lambda card: frame(self.s.row(card, rs))[1] - row_top, default=None)

    def windows(self, sid, count):
        """Adds Windows to the Session, without making them active, until it has count; returns their ids in order."""
        for _ in range(count - 1):
            self.s.tmux('new-window', '-d', '-t', sid + ':', '-c', str(self.beta), SHELL)
        return self.s.tmux('list-windows', '-t', sid, '-F', '#{window_id}').split()

    def test_pressing_another_topics_card_header_goes_to_the_topic_and_opens_its_card(self):
        s = self.s
        self.write_topic('card-press', 'Card press', self.beta)
        sid = self.new_session('card-press', self.beta, topic='card-press')
        window = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        base = s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.select_window(base)
        self.s.wait_shown(base)
        s.wait_rows(lambda rs: s.has('topic-card-press', rs), 'the Topic has no card')
        s.act('press', 'topic-card-press')
        s.wait_shown(window)
        rs = s.wait_rows(lambda rs: s.has('topic-window-' + window, rs), 'pressing the header did not open the card')
        self.assertTrue(s.row('topic-card-press', rs).get('accessibilityValue', '').startswith('expanded'),
                        self.describe('topic-card-press', rs))

    def test_a_mouse_click_on_another_topics_card_header_goes_to_the_topic_and_opens_its_card(self):
        s = self.s
        self.write_topic('card-click', 'Card click', self.beta)
        sid = self.new_session('card-click', self.beta, topic='card-click')
        window = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        base = s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.select_window(base)
        self.s.wait_shown(base)
        rs = s.wait_rows(lambda rs: s.has('topic-card-click', rs), 'the Topic has no card')
        self.assertFalse(s.has('topic-window-' + window, rs), 'the card is open before the click')
        s.act('click', 'topic-card-click')
        s.wait_shown(window)
        s.wait_rows(lambda rs: s.has('topic-window-' + window, rs), 'a click on the header did not open the card')

    def test_go_to_topic_goes_to_its_last_window(self):
        s = self.s
        self.write_topic('card-go', 'Card go', self.beta)
        sid = self.new_session('card-go', self.beta, topic='card-go')
        first, last = self.windows(sid, 2)
        self.select_window(last)
        self.wait_selected(last)
        base = s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.select_window(base)
        # A change of the current Window while the app still shows the Topic would become its last Window.
        self.wait_selected(base)
        # tmux now makes the other Window the Session's current one; the Topic still remembers the last Window looked at.
        s.tmux('select-window', '-t', first)
        self.find('topic-card-go')
        s.act('action', 'topic-card-go', 'Go to Topic')
        wait(lambda: last in self.client_windows(),
             'Go to Topic did not go to the Topic\'s last Window %s: client on %s' % (last, self.client_windows()), seconds=10)

    def test_pressing_the_header_closes_the_card_of_the_active_topic(self):
        s = self.s
        self.write_topic('card-close', 'Card close', self.beta)
        sid = self.new_session('card-close', self.beta, topic='card-close')
        window = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        self.select_window(window)
        self.wait_selected(window)
        self.expand('topic-card-close')
        s.wait_rows(lambda rs: s.has('topic-window-' + window, rs), 'the open card does not list its Window')
        s.act('press', 'topic-card-close')
        rs = s.wait_rows(lambda rs: not s.has('topic-window-' + window, rs), 'the active Topic\'s card did not close')
        self.assertEqual(s.row('topic-card-close', rs).get('accessibilityValue'), 'collapsed', self.describe('topic-card-close', rs))

    def test_forget_live_topic_kills_its_session_and_removes_its_record(self):
        s = self.s
        topic = 'forget-live'
        self.write_topic(topic, 'Forget live', self.alpha)
        sid = self.new_session('alpha/forget-live', self.alpha, topic=topic)
        self.find('topic-' + topic)
        # The Topic card gives Forget as an accessibility action to avoid opening a context menu.
        s.act('action', 'topic-' + topic, 'Forget Topic…')
        rs = s.wait_rows(lambda rows: s.has('palette-accept', rows) and s.has('palette-row-session-' + sid, rows),
                         'Forget palette did not load its Sessions')
        self.assertIn('Forget', self.describe('palette-breadcrumb', rs))
        self.choose_kill(sid)
        self.assertTrue(s.tmux('display-message', '-p', '#{socket_path}').startswith(str(s.root) + '/'))
        s.act('press', 'palette-accept')
        wait(lambda: topic not in self.records(), 'Forget kept the Topic record')
        wait(lambda: s.tmux_ok('has-session', '-t', sid).returncode != 0, 'Forget did not kill the Session')
        s.wait_rows(lambda rows: not s.has('topic-' + topic, rows), 'Forget kept the Topic card')

    def choose_kill(self, sid):
        """Turns the Session's row of the Settle or Forget palette from Keep, the default for every live Session
        (ADR 0036), to Kill. A press toggles the row."""
        key = 'palette-row-session-' + sid
        self.s.act('press', key)
        self.s.wait_rows(lambda rs: 'Kill' in self.s.row(key, rs).get('accessibilityLabel', ''),
                         'the Session row did not turn to Kill: ' + self.describe(key, self.s.rows()))

    def test_forget_dormant_snoozed_and_settled_topics_confirms_before_removal(self):
        s = self.s
        for state in ['dormant', 'snoozed', 'settled']:
            topic = 'forget-' + state
            fields = {'snoozed_until': 'never'} if state == 'snoozed' else {'settled_at': '2031-01-01T00:00:00Z'} if state == 'settled' else {}
            self.write_topic(topic, 'Forget ' + state, self.alpha, **fields)
            if state != 'dormant':
                self.find(state + '-topics')
                self.expand(state + '-topics')
            self.find('topic-' + topic)
            s.act('action', 'topic-' + topic, 'Forget Topic…')
            s.wait_rows(lambda rows: s.has('palette-cancel', rows), 'Forget palette did not open')
            s.act('press', 'palette-cancel')
            s.wait_rows(lambda rows: not s.has('palette-cancel', rows), 'Forget palette did not close')
            self.assertIn(topic, self.records())
            s.act('action', 'topic-' + topic, 'Forget Topic…')
            s.wait_rows(lambda rows: 'This removes the Topic for good.' in self.describe('palette-note', rows),
                        'Forget did not finish checking Sessions and Worktrees')
            self.assertTrue(s.tmux('display-message', '-p', '#{socket_path}').startswith(str(s.root) + '/'))
            s.act('press', 'palette-accept')
            wait(lambda: topic not in self.records(), 'Forget kept the ' + state + ' Topic')
            s.wait_rows(lambda rows: not s.has('palette-accept', rows), 'Forget palette did not close')

    def test_settle_shows_on_closed_open_and_dormant_topic_cards(self):
        s = self.s
        self.write_topic('corner-closed', 'Corner closed', self.beta)
        self.write_topic('corner-open', 'Corner open', self.beta)
        self.write_topic('corner-dormant', 'Corner dormant', self.beta)
        self.new_session('corner-closed', self.beta, topic='corner-closed')
        self.new_session('corner-open', self.beta, topic='corner-open')
        self.open_card('topic-corner-open')
        for topic in ['corner-closed', 'corner-open', 'corner-dormant']:
            rs = self.find('topic-' + topic)
            self.assertTrue(s.has('settle-topic-' + topic, rs), 'the %s card has no Settle: %s' % (topic, self.describe('topic-' + topic, rs)))
        self.assertTrue(self.expanded('topic-corner-open', rs), self.describe('topic-corner-open', rs))
        self.assertTrue(s.row('topic-corner-closed', rs).get('accessibilityValue', '').startswith('collapsed'),
                        self.describe('topic-corner-closed', rs))

    def test_settle_on_a_closed_topic_card_opens_the_settle_palette_and_leaves_the_card_closed(self):
        s = self.s
        self.write_topic('card-settle', 'Card settle', self.beta)
        self.new_session('card-settle', self.beta, topic='card-settle')
        rs = self.find('settle-topic-card-settle')
        self.assertTrue(s.row('topic-card-settle', rs).get('accessibilityValue', '').startswith('collapsed'),
                        self.describe('topic-card-settle', rs))
        s.act('press', 'settle-topic-card-settle')
        s.wait_rows(lambda rs: s.has('palette-cancel', rs), 'Settle did not open the Settle palette')
        s.act('press', 'palette-cancel')
        rs = s.wait_rows(lambda rs: not s.has('palette-cancel', rs), 'Settle palette did not close')
        self.assertTrue(s.row('topic-card-settle', rs).get('accessibilityValue', '').startswith('collapsed'),
                        'Settle opened the card: ' + self.describe('topic-card-settle', rs))
        self.assertIsNone(self.records()['card-settle'].get('settled_at'), 'Cancel settled the Topic')

    def test_settle_palette_saves_the_outcome_kills_an_idle_session_and_keeps_the_session_of_a_working_agent(self):
        s = self.s
        topic = 'palette-settle'
        self.write_topic(topic, 'Palette settle', self.alpha)
        idle = self.new_session('alpha/palette-settle', self.alpha, topic=topic)
        working = self.new_session('beta/palette-settle', self.beta, '/bin/sleep 300', topic=topic)
        pane = s.tmux('display-message', '-p', '-t', working + ':', '#{pane_id}')
        s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'opencode')
        s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', 'working')
        self.find('settle-topic-' + topic)
        s.act('press', 'settle-topic-' + topic)
        s.wait_rows(lambda rs: s.has('palette-row-session-' + idle, rs) and s.has('palette-row-session-' + working, rs),
                    'the Settle palette does not list both Sessions')
        self.choose_kill(idle)
        self.assertIn('Keep', s.row('palette-row-session-' + working).get('accessibilityLabel', ''),
                      'the Session of the working Agent is not kept: ' + self.describe('palette-row-session-' + working, s.rows()))
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', 'Shipped from the palette')
        s.act('press', 'palette-accept')
        s.wait_rows(lambda rs: not s.has('palette-accept', rs), 'Settle palette did not close after saving')
        wait(lambda: self.records()[topic].get('settled_at'), 'Settle did not save the settle date')
        self.assertEqual(self.records()[topic].get('outcome'), 'Shipped from the palette')
        wait(lambda: s.tmux_ok('has-session', '-t', idle).returncode != 0, 'Settle did not kill the idle Session')
        def kept_without_topic():
            options = s.tmux_ok('show-options', '-t', working)
            return options.returncode == 0 and '@muxify_topic' not in options.stdout
        wait(kept_without_topic, 'the Session of the working Agent is gone or still has the Topic')
        # Keep removes the membership and gives the Session its base name back (ADR 0036).
        wait(lambda: s.tmux('display-message', '-p', '-t', working + ':', '#{session_name}') == 'beta',
             'Keep did not restore the base name of the kept Session')

    def test_rename_palette_renames_the_topic_and_its_session(self):
        s = self.s
        topic = 'alert-rename'
        self.write_topic(topic, 'Alert rename', self.alpha)
        sid = self.new_session('alpha/alert-rename', self.alpha, topic=topic)
        self.find('topic-' + topic)
        # "Rename Topic…" is an accessibility action of the Topic card in UI/SidebarView.swift, because the
        # context menu takes the mouse.
        s.act('action', 'topic-' + topic, 'Rename Topic…')
        s.wait_rows(lambda rs: s.has('palette-search', rs), 'Rename palette did not open')
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', 'Alert renamed')
        s.act('press', 'palette-accept')
        wait(lambda: self.records()[topic].get('title') == 'Alert renamed', 'Rename did not save the title')
        self.assertEqual(self.records()[topic].get('slug'), 'alert-renamed')
        wait(lambda: s.tmux('display-message', '-p', '-t', sid + ':', '#{session_name}') == 'alpha/alert-renamed',
             'Rename did not rename the Session')

    def test_a_card_lists_five_rows_and_n_more_lists_the_rest(self):
        s = self.s
        self.write_topic('card-more', 'Card more', self.beta)
        sid = self.new_session('card-more', self.beta, topic='card-more')
        windows = self.windows(sid, 7)
        self.select_window(windows[0])
        self.s.wait_shown(windows[0])
        self.open_card('topic-card-more')
        rs = s.wait_rows(lambda rs: s.has('topic-window-' + windows[4], rs) and s.has('topic-card-more-more', rs),
                         'the card does not list five rows with N more under them')
        self.assertEqual([w for w in windows if s.has('topic-window-' + w, rs)], windows[:5], 'the card lists other rows than the first five')
        self.assertIn('2 more', s.row('topic-card-more-more', rs).get('accessibilityLabel', ''), self.describe('topic-card-more-more', rs))
        s.act('press', 'topic-card-more-more')
        rs = s.wait_rows(lambda rs: all(s.has('topic-window-' + w, rs) for w in windows), 'N more did not list the hidden rows')
        self.assertFalse(s.has('topic-card-more-more', rs), 'N more stays after every row shows')

    def test_an_open_cards_header_stays_at_the_top_of_the_list_while_its_rows_scroll(self):
        s = self.s
        self.write_topic('card-sticky', 'Card sticky', self.beta)
        sid = self.new_session('card-sticky', self.beta, topic='card-sticky')
        windows = self.windows(sid, 60)
        self.select_window(windows[0])
        self.expand('topic-card-sticky')
        # reveal scrolls the last row to the top of the list, so the card's header would be far above it.
        rs = s.reveal('topic-window-' + windows[-1])
        rs = s.wait_rows(lambda rs: s.has('topic-card-sticky', rs) and s.has('topics-list', rs), 'the card or the list left the dump')
        _, list_top = frame(s.row('topics-list', rs))
        _, header_top = frame(s.row('topic-card-sticky', rs))
        self.assertLess(abs(header_top - list_top), 3, 'the header is not at the top of the list: header top %s, list top %s, row %s'
                        % (header_top, list_top, frame(s.row('topic-window-' + windows[-1], rs))))

    def test_a_card_lists_every_row_when_the_selected_window_is_past_the_fifth(self):
        s = self.s
        self.write_topic('card-deep', 'Card deep', self.beta)
        sid = self.new_session('card-deep', self.beta, topic='card-deep')
        windows = self.windows(sid, 7)
        self.select_window(windows[6])
        self.s.wait_shown(windows[6])
        self.open_card('topic-card-deep')
        rs = s.wait_rows(lambda rs: s.row('topic-window-' + windows[6], rs).get('accessibilityValue') == 'selected',
                         'the card hides the selected Window')
        self.assertFalse(s.has('topic-card-deep-more', rs), 'N more shows while the card lists every row')

    def test_go_to_session_on_a_session_card_goes_to_the_sessions_active_window(self):
        s = self.s
        self.addCleanup(self.show_view, 'topics')
        sid = self.new_session('card-session', self.beta)
        first, second = self.windows(sid, 2)
        s.tmux('select-window', '-t', second)
        base = s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.select_window(base)
        wait(lambda: base in self.client_windows(), 'the client did not move to ' + base, seconds=10)
        self.show_view('sessions')
        self.find('session-' + sid)
        s.act('action', 'session-' + sid, 'Go to Session')
        wait(lambda: second in self.client_windows(),
             'Go to Session did not go to its active Window %s: client on %s' % (second, self.client_windows()),
             seconds=10)

    def test_a_click_on_another_session_card_goes_to_the_sessions_active_window(self):
        s = self.s
        self.addCleanup(self.show_view, 'topics')
        sid = self.new_session('card-session-click', self.beta)
        first, second = self.windows(sid, 2)
        s.tmux('select-window', '-t', second)
        base = s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        self.select_window(base)
        wait(lambda: base in self.client_windows(), 'the client did not move to ' + base, seconds=10)
        self.show_view('sessions')
        self.find('session-' + sid)
        s.act('click', 'session-' + sid)
        wait(lambda: second in self.client_windows(),
             'a click on the Session card did not go to its active Window %s: client on %s' % (second, self.client_windows()),
             seconds=10)

    def test_pinning_a_lower_topic_moves_it_to_the_top_and_a_new_topic_goes_last(self):
        s = self.s
        self.write_topic('pin-upper', 'Pin upper', self.beta, order=-1000)
        self.write_topic('pin-lower', 'Pin lower', self.beta, order=1000)

        def above(upper, lower, rs):
            return s.has(upper, rs) and s.has(lower, rs) and frame(s.row(upper, rs))[1] > frame(s.row(lower, rs))[1]

        self.find('topic-pin-lower')
        s.wait_rows(lambda rs: above('topic-pin-upper', 'topic-pin-lower', rs), 'Pin upper is not above Pin lower before the Pin')
        s.act('action', 'topic-pin-lower', 'Pin Topic')
        rs = s.wait_rows(lambda rs: above('topic-pin-lower', 'topic-pin-upper', rs),
                         'the Pinned Topic did not move above the other Topic')
        self.assertIn('Pinned', s.row('topic-pin-lower', rs).get('accessibilityValue', ''), self.describe('topic-pin-lower', rs))
        self.assertEqual(self.topic_rows(rs)[0], 'topic-pin-lower', 'Topic rows %s' % self.topic_rows(rs))
        self.assertIs(self.records()['pin-lower'].get('pinned'), True)

        key = 'topic-' + self.create_topic('Pin newcomer')['id']
        rs = s.wait_rows(lambda rs: above('topic-pin-lower', 'topic-pin-upper', rs) and above('topic-pin-upper', key, rs),
                         'the new Topic is not below the Pinned Topic and the other Topic')
        self.assertEqual(self.topic_rows(rs)[0], 'topic-pin-lower', 'Topic rows %s' % self.topic_rows(rs))

    def test_zen_from_a_topic_row_snoozes_the_other_topics_and_end_zen_puts_back_their_snoozes(self):
        s = self.s
        zen_file = self.topics_dir.parent/'zen.json'
        self.addCleanup(zen_file.unlink, missing_ok=True)
        earlier = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() + 600))
        self.write_topic('zen-kept', 'Zen kept', self.beta)
        self.write_topic('zen-other', 'Zen other', self.beta)
        self.write_topic('zen-earlier', 'Zen earlier', self.beta, snoozed_until=earlier)
        self.find('topic-zen-kept')
        s.act('action', 'topic-zen-kept', 'Zen…')
        rs = s.wait_rows(lambda rs: s.has('palette-breadcrumb', rs), 'Zen… did not open the Zen palette')
        names = self.describe('palette-note', rs)
        self.assertTrue('Zen other' in names and 'Zen earlier' in names and 'Zen kept' not in names,
                        'the Zen palette lists the wrong Topics: ' + names)
        # A preset row accepts on a press: In one hour, after the Snooze of zen-earlier.
        s.act('press', 'palette-row-0')
        s.wait_rows(lambda rs: not s.has('palette-breadcrumb', rs), 'the Zen palette did not close')

        zen = wait(lambda: zen_file.exists() and json.loads(zen_file.read_text()), 'Zen wrote no zen.json')
        records = self.records()
        changes = {c['topic_id']: c.get('previous_snoozed_until') for c in zen['changes']}
        self.assertEqual(zen['kept_topic_id'], 'zen-kept', json.dumps(zen))
        self.assertEqual({key: changes.get(key, 'absent') for key in ['zen-kept', 'zen-other', 'zen-earlier']},
                         {'zen-kept': 'absent', 'zen-other': None, 'zen-earlier': earlier}, json.dumps(zen))
        self.assertNotIn('snoozed_until', records['zen-kept'], 'Zen Snoozed the Topic it keeps')
        self.assertEqual([records[key].get('snoozed_until') for key in ['zen-other', 'zen-earlier']], [zen['until']] * 2,
                         'Zen did not Snooze the other Topics until its time')

        s.wait_rows(lambda rs: s.has('end-zen', rs), 'the Sidebar does not show End Zen')
        s.act('press', 'end-zen')
        wait(lambda: not zen_file.exists(), 'End Zen kept zen.json')
        records = self.records()
        self.assertNotIn('snoozed_until', records['zen-other'], 'End Zen did not unsnooze a Topic that was not Snoozed')
        self.assertEqual(records['zen-earlier'].get('snoozed_until'), earlier, 'End Zen did not put back the earlier Snooze')
        s.wait_rows(lambda rs: not s.has('end-zen', rs), 'the Sidebar still shows End Zen')

    def test_zen_keeps_the_no_topic_card_and_hides_the_notification_marks_of_no_topic_until_it_ends(self):
        s = self.s
        zen_file = self.topics_dir.parent/'zen.json'
        self.addCleanup(zen_file.unlink, missing_ok=True)
        self.addCleanup(self.show_view, 'topics')
        self.write_topic('zen-hide-kept', 'Zen hide kept', self.beta)
        kept = self.new_session('zen-hide-kept', self.beta, topic='zen-hide-kept')
        sid_one, window_one, _ = self.agent_session('zen-hide-one')
        sid_two, window_two, _ = self.agent_session('zen-hide-two')
        # Never selected, so its done Agent stays Unread through the check.
        sid_unread, _, _ = self.agent_session('zen-hide-unread', status='done', unread=True)
        unread_mark = lambda rs: 'done' in self.describe('session-' + sid_unread, rs)
        self.select_window(kept + ':')
        self.find('topic-zen-hide-kept')
        self.show_view('sessions')
        s.wait_rows(unread_mark, 'Sessions mode shows no done mark on a No Topic Session before Zen')
        self.show_view('topics')

        s.act('action', 'topic-zen-hide-kept', 'Zen…')
        s.wait_rows(lambda rs: s.has('palette-breadcrumb', rs), 'Zen… did not open the Zen palette')
        s.act('press', 'palette-row-0')
        rs = s.wait_rows(lambda rs: s.has('end-zen', rs), 'the Sidebar does not show End Zen')
        self.assertEqual(self.no_topic_cards(rs), [], 'Zen shows a No Topic card while the kept Topic is active')

        self.select_window(window_one)
        rs = s.wait_rows(lambda rs: self.no_topic_cards(rs) == [sid_one], 'opening a No Topic Session during Zen did not show its card')
        self.select_window(window_two)
        s.wait_rows(lambda rs: self.no_topic_cards(rs) == [sid_two], 'opening another No Topic Session did not replace the card')
        self.select_window(kept + ':')
        s.wait_rows(lambda rs: self.no_topic_cards(rs) == [], 'going back to the kept Topic did not remove the No Topic card')

        self.show_view('sessions')
        rs = s.wait_rows(lambda rs: s.has('session-' + sid_unread, rs), 'Sessions mode does not list a No Topic Session during Zen')
        self.assertFalse(unread_mark(rs), 'Sessions mode shows a No Topic mark during Zen: ' + self.describe('session-' + sid_unread, rs))
        self.show_view('topics')

        s.act('press', 'end-zen')
        s.wait_rows(lambda rs: not s.has('end-zen', rs), 'the Sidebar still shows End Zen')
        self.show_view('sessions')
        s.wait_rows(unread_mark, 'the No Topic mark did not come back after Zen')

    def test_pressing_a_dormant_topic_card_reopens_it_without_the_reopen_choice(self):
        s = self.s
        self.write_topic('dormant-first', 'First', self.beta, order=0)
        self.write_topic('click-dormant', 'Click dormant', self.alpha, order=1, sessions=[remembered_session(self.alpha, 'click-dormant', windows=[
            dict(directory=str(self.alpha), name='edit'), dict(directory=str(self.alpha), name='logs')])])
        self.find('topic-click-dormant')
        s.act('press', 'topic-click-dormant')
        self.wait_session('alpha/click-dormant')
        self.addCleanup(self.end_session, s.tmux('display-message', '-p', '-t', '=alpha/click-dormant:', '#{session_id}'))
        wait(lambda: s.tmux('list-windows', '-t', '=alpha/click-dormant:', '-F', '#{window_name}').split() == ['edit', 'logs'],
             'Reopen did not create the remembered Windows')
        s.wait_shown('=alpha/click-dormant:')
        self.assertFalse(s.has('reopen-choice-reopen'), 'going to the Dormant Topic showed the Reopen choice')
        self.assertEqual(self.records()['click-dormant']['order'], 1, 'Reopen moved the Dormant Topic')

    def test_reopen_keeps_browser_tabs_in_the_window_and_the_topic_record(self):
        s = self.s
        tabs = ['data:text/html,reopen-one', 'data:text/html,reopen-two']
        for split in [False, True]:
            with self.subTest(split=split):
                topic = 'browser-split' if split else 'browser-shell'
                directory = self.beta if split else self.alpha
                panes = [dict(directory=str(directory), active=True)]
                if split:
                    panes[0].update(agent='claude', agent_conversation='verify-reopen')
                    panes.append(dict(directory=str(self.alpha), active=False))
                self.write_topic(topic, topic, self.alpha, sessions=[remembered_session(self.alpha, topic, windows=[
                    dict(directory=str(directory), name='browser', panes=panes,
                         browser_tabs=tabs, browser_active_tab=1, browser_open=True, terminal_open=not split)])])
                self.find('topic-' + topic)
                s.act('press', 'topic-' + topic)
                target = '=alpha/' + topic + ':'
                self.wait_session('alpha/' + topic)
                sid = s.tmux('display-message', '-p', '-t', target, '#{session_id}')
                self.addCleanup(self.end_session, sid)
                s.wait_shown(target)
                wait(lambda: len(s.tmux('list-panes', '-t', target, '-F', '#{pane_id}').split()) == len(panes),
                     'Reopen did not restore the Panes')
                with self.subTest(restored_browser=True):
                    _, rows = self.rows_until(lambda rs: len([key for key in s.ids(rs)
                                                              if key.startswith('browser-tab-title-')]) == len(tabs))
                    tab_rows = [key for key in s.ids(rows) if key.startswith('browser-tab-title-')]
                    self.assertEqual(len(tab_rows), len(tabs), 'Reopen did not show the remembered Tabs')
                    self.assertEqual(s.has('terminal-panel', rows), not split)
                    if split:
                        wait(lambda: any(name.startswith(('WKWebView', 'WKContentView'))
                                         for name in s.driver('responder')['responders']),
                             'Reopen did not give the Browser keyboard focus while the Terminal was hidden')
                self.press_menu_item('Focus Terminal')
                time.sleep(REFRESH_LIMIT)
                with self.subTest(saved_browser=True):
                    self.assertEqual(s.tmux('show-options', '-wqv', '-t', target, '@muxify_tabs').split(), tabs)
                    self.assertEqual(s.tmux('show-options', '-wqv', '-t', target, '@muxify_active_tab'), '1')
                    self.assertEqual(s.tmux('show-options', '-wqv', '-t', target, '@muxify_browser'), 'on')
                s.tmux('rename-window', '-t', target, 'browser-saved')
                def saved():
                    windows = self.records().get(topic, {}).get('sessions', [{}])[0].get('windows', [])
                    return windows[0] if windows and windows[0].get('name') == 'browser-saved' else None
                record = wait(saved, 'the Topic record did not save the reopened Window')
                self.assertEqual(record.get('browser_tabs'), tabs, record)
                self.assertEqual(record.get('browser_active_tab'), 1, record)
                self.assertTrue(record.get('browser_open'), record)

    def test_a_dormant_topic_comes_back_with_the_panes_of_its_split_window_and_its_program_typed_not_run(self):
        s = self.s
        # Reopen reaches each Pane by its place, not its index, so a pane-base-index the user changed must not matter.
        s.tmux('set-option', '-g', 'pane-base-index', '1')
        self.addCleanup(s.tmux, 'set-option', '-gu', 'pane-base-index')
        self.write_topic('split-dormant', 'Split dormant', self.alpha)
        sid = self.new_session('alpha/split-dormant', self.alpha, topic='split-dormant')
        # Each split goes right after the first Pane, which stays active: shell, sleep, shell.
        s.tmux('split-window', '-d', '-t', sid + ':', '-c', str(self.alpha), SHELL)
        s.tmux('split-window', '-d', '-t', sid + ':', '-c', str(self.alpha), 'sleep 6061')

        def remembered():
            windows = self.records().get('split-dormant', {}).get('sessions', [{}])[0].get('windows', [])
            panes = windows[0].get('panes', []) if windows else []
            return len(panes) == 3 and any(pane.get('command') == 'sleep 6061' for pane in panes)
        wait(remembered, 'the Topic did not remember three Panes and the program: %s' % self.records().get('split-dormant'))
        saved = self.records()['split-dormant']
        s.tmux('kill-session', '-t', sid)
        wait(lambda: self.records()['split-dormant'].get('sessions') == [], 'confirmed closure did not empty the Topic')
        # A deliberate saved-layout fixture; individually stopped Sessions no longer reopen themselves.
        (self.topics_dir/'split-dormant.json').write_text(json.dumps(saved))
        self.find('topic-split-dormant')
        s.wait_rows(lambda rs: 'Dormant' in self.describe('topic-split-dormant', rs), 'the Topic did not become Dormant')

        s.act('press', 'topic-split-dormant')
        self.wait_session('alpha/split-dormant')
        self.addCleanup(self.end_session, s.tmux('display-message', '-p', '-t', '=alpha/split-dormant:', '#{session_id}'))
        panes = lambda: [line.split() for line in s.tmux('list-panes', '-t', '=alpha/split-dormant:', '-F',
                                                         '#{pane_id} #{pane_active} #{pane_current_command}').splitlines()]
        wait(lambda: len(panes()) == 3, 'Reopen did not make three Panes: %s' % panes())
        typed = lambda: [pane[0] for pane in panes() if 'sleep 6061' in s.tmux('capture-pane', '-p', '-t', pane[0])]
        wait(lambda: len(typed()) == 1, 'Reopen did not type the program in one Pane')
        time.sleep(REFRESH_LIMIT)
        now = panes()
        self.assertEqual(typed(), [now[1][0]], 'Reopen typed the program in the wrong Pane: %s' % now)
        self.assertEqual([pane[1] for pane in now], ['1', '0', '0'], 'the remembered active Pane is not active: %s' % now)
        self.assertNotIn('sleep', [pane[2] for pane in now], 'Reopen ran the program it should only type')

    def test_next_topic_on_a_dormant_topic_shows_what_each_choice_creates_and_start_fresh_opens_one_shell_window_per_project(self):
        s = self.s
        agent = dict(directory=str(self.alpha), name='agent', agent='claude', agent_conversation='conversation-1',
                     browser_tabs=['https://example.com/a'], browser_open=True)
        self.write_topic('choice-active', 'Choice active', self.beta, order=-2001)
        sid = self.new_session('beta/choice-active', self.beta, topic='choice-active')
        self.write_topic('choice-dormant', 'Choice dormant', self.alpha, order=-2000, sessions=[
            remembered_session(self.alpha, 'choice-dormant', windows=[dict(directory=str(self.alpha), name='edit'), agent]),
            remembered_session(self.beta, 'choice-dormant', windows=[dict(directory=str(self.beta), name='logs')])])
        self.find('topic-choice-dormant')
        self.select_window(sid + ':')
        s.wait_shown(sid + ':')
        self.press_menu_item('Go to…')
        key = 'palette-row-topic-choice-active'
        s.wait_rows(lambda rs: s.has(key, rs), 'the Active Topic did not show in Go to')
        s.act('action', key, 'Snooze Topic')
        rs = s.wait_rows(lambda rs: s.has('palette-note', rs), 'Snooze did not show the Next Topic')
        note = s.row('palette-note', rs)
        self.assertIn('Then opens: Choice dormant', note.get('accessibilityLabel', '') + note.get('accessibilityValue', ''))
        s.act('press', 'palette-row-never')
        rs = s.wait_rows(lambda rs: s.has('reopen-choice-start-fresh', rs), 'Next Topic did not show the Reopen choice')
        reopen = self.describe('reopen-session-alpha', rs)
        for text in ['edit', 'agent', '1 Tab', 'resumes Claude Code']:
            self.assertIn(text, reopen, 'the Reopen column does not say ' + text)
        self.assertIn('logs', self.describe('reopen-session-beta', rs), 'the Reopen column misses the second Session Path')
        fresh = self.describe('start-fresh-session-alpha', rs)
        self.assertIn('shell', fresh, 'the Start Fresh column does not list its shell Window')
        for text in ['edit', 'Tab', 'resumes']:
            self.assertNotIn(text, fresh, 'the Start Fresh column says ' + text)
        self.assertTrue(s.has('start-fresh-session-beta', rs), 'the Start Fresh column misses the second Session Path')
        for name in ['alpha/choice-dormant', 'beta/choice-dormant']:
            self.assertNotEqual(s.tmux_ok('has-session', '-t', '=' + name).returncode, 0, 'showing the choice created ' + name)

        s.act('press', 'reopen-choice-start-fresh')
        for name in ['alpha/choice-dormant', 'beta/choice-dormant']:
            self.wait_session(name)
            self.addCleanup(self.end_session, s.tmux('display-message', '-p', '-t', '=' + name + ':', '#{session_id}'))
            self.assertEqual(s.tmux('list-windows', '-t', '=' + name + ':', '-F', '#{window_name}').split(), ['shell'],
                             'Start Fresh made other Windows in ' + name)
        time.sleep(REFRESH_LIMIT)
        typed = s.tmux('capture-pane', '-p', '-t', '=alpha/choice-dormant:')
        self.assertNotIn('claude', typed, 'Start Fresh started an Agent')
        self.assertEqual(s.tmux('show-options', '-wqv', '-t', '=alpha/choice-dormant:', '@muxify_tabs'), '',
                         'Start Fresh brought a Tab back')
        latency, rs = self.rows_until(lambda rs: not s.has('reopen-choice-start-fresh', rs))
        self.assertIsNotNone(latency, 'the Reopen choice stays after Start Fresh')
