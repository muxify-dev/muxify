"""Topics in the Sidebar: with topics.in_play, the Topics after the ones In Play wait on the Bench, behind one line.

The Bench line is a button, so `press` shows or hides the Bench through its accessibility action.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_bench_sidebar
"""

import time
import unittest

from scripts.verify.sandbox import frame, wait
from scripts.verify.topics_sidebar import TopicsSidebar

LINE = 'topics-bench-line'


class TopicsBenchSidebar(TopicsSidebar):
    def bench_topics(self, prefix, dormant=0):
        """Topics <prefix>-a, -b and -c in that order, each with one live Session, and only one In Play. `dormant` more
        Topics with no Session, <prefix>-t03 on, make the Bench longer than the Sidebar. Returns the Window of each live
        Topic by its card identifier."""
        self.addCleanup(self.config.write_text, self.config_text)
        self.config.write_text(self.config_text + 'topics:\n  in_play: 1\n')
        windows = {}
        for order, name in enumerate(['a', 'b', 'c']):
            topic = '%s-%s' % (prefix, name)
            self.write_topic(topic, topic.capitalize(), self.beta, order=order)
            sid = self.new_session('beta/' + topic, self.beta, topic=topic)
            windows['topic-' + topic] = self.s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        for order in range(3, 3 + dormant):
            topic = '%s-t%02d' % (prefix, order)
            self.write_topic(topic, topic.capitalize(), self.beta, order=order)
        return windows

    def long_bench(self, prefix):
        """A shown Bench much longer than the Sidebar. Returns the identifiers of the Benched cards in list order. The
        check stays in No Topic: a drag right after going to a Topic can come while the app still changes the Topic,
        which turns the drag off."""
        s = self.s
        self.bench_topics(prefix, dormant=17)
        bench = ['topic-%s-%s' % (prefix, name) for name in ['b', 'c'] + ['t%02d' % i for i in range(3, 20)]]
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.show_bench()
        s.wait_rows(lambda rs: self.cards(prefix, rs) == ['topic-%s-a' % prefix, LINE] + bench,
                    'the long Bench did not show in list order: %s' % self.cards(prefix, s.rows()))
        s.wait_rows(lambda rs: frame(s.row(bench[-1], rs))[1] < frame(s.row('topics-list', rs))[0],
                    'the long Bench fits in the Sidebar')
        # From the top, whatever an earlier check left.
        s.act('scroll', 'topics-list', from_end=100000)
        s.wait_rows(lambda rs: frame(s.row(bench[0], rs))[1] < frame(s.row(LINE, rs))[0],
                    'the Bench did not scroll back to its top')
        return bench

    def tops(self, keys, rs):
        return {key: frame(self.s.row(key, rs))[1] for key in keys}

    def assert_in_place(self, keys, before, rs):
        after = self.tops(keys, rs)
        for key in keys:
            self.assertAlmostEqual(after[key], before[key], delta=1, msg='%s moved with the Bench: %s, before %s' % (key, after, before))

    def line(self, rs):
        return self.s.row(LINE, rs).get('accessibilityLabel')

    def shown_after_line(self, rs):
        """The cards under the Bench line, in Sidebar order."""
        ids = self.s.ids(rs)
        return [key for key in ids[ids.index(LINE) + 1:] if key in self.topic_rows(rs)] if LINE in ids else None

    def hide_bench(self):
        if self.line(self.s.rows()) == 'Hide Bench':
            self.s.act('press', LINE)
        self.s.wait_rows(lambda rs: self.line(rs) == 'Bench', 'the Bench did not hide')

    def show_bench(self):
        if self.line(self.s.rows()) == 'Bench':
            self.s.act('press', LINE)
        self.s.wait_rows(lambda rs: self.line(rs) == 'Hide Bench', 'the Bench did not show')

    def test_a_new_topic_goes_to_the_top_of_the_bench(self):
        s = self.s
        self.bench_topics('bench-new')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.show_bench()
        key = 'topic-' + self.create_topic('Bench new')['id']
        expected = ['topic-bench-new-a', LINE, key, 'topic-bench-new-b', 'topic-bench-new-c']
        shown = lambda rs: [k for k in s.ids(rs) if k in expected]
        s.wait_rows(lambda rs: shown(rs) == expected, 'the new Topic is not first on the Bench: %s' % shown(s.rows()))

    def test_settling_a_card_in_play_moves_the_top_of_the_bench_into_its_place(self):
        s = self.s
        windows = self.bench_topics('bench-settle')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-settle-a'])

        def settle_opened():
            # The menu item follows the Location about a second after the Sidebar, so it can still settle the last Topic.
            if s.has('palette-search'):
                s.act('action', 'palette-search', 'Close')
            s.driver('press', 'Settle Topic…')
            found, rs = self.rows_until(lambda rs: any(key.startswith('palette-row-session-') for key in s.ids(rs)), seconds=3)
            return found is not None and 'Bench-settle-a' in self.describe('palette-breadcrumb', rs)
        wait(settle_opened, 'Settle did not open for the card In Play', seconds=20)

        def settled():
            # The step takes no ↩ while another change of the Topics runs, as after the last check's clean-up.
            if not s.has('palette-search'):
                return True
            s.act('press', 'palette-accept')
            return False
        wait(settled, 'Settle did not close the palette')
        s.wait_rows(lambda rs: self.cards('bench-settle', rs) == ['topic-bench-settle-b', LINE],
                    'the first Benched card did not come In Play: %s' % self.cards('bench-settle', s.rows()))

    def test_the_bench_line_shows_the_bench_and_going_to_a_topic_leaves_it_shown(self):
        s = self.s
        windows = self.bench_topics('bench-toggle')
        s.wait_rows(lambda rs: s.has('topic-bench-toggle-a', rs) and self.line(rs) is not None,
                    'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        rs = s.rows()
        self.assertEqual(self.shown_after_line(rs), [], 'a hidden Bench shows cards: %s' % s.ids(rs))
        self.assertLess(s.ids(rs).index('topic-bench-toggle-a'), s.ids(rs).index(LINE), 'the In Play card is not above the line')

        s.act('press', LINE)
        s.wait_rows(lambda rs: self.line(rs) == 'Hide Bench'
                    and self.shown_after_line(rs) == ['topic-bench-toggle-b', 'topic-bench-toggle-c'],
                    'a press on the line did not show the Benched cards: %s' % self.shown_after_line(s.rows()))

        s.show(windows['topic-bench-toggle-b'])
        s.show(windows['topic-bench-toggle-c'])
        rs = s.rows()
        self.assertEqual(self.line(rs), 'Hide Bench', 'going from one Benched Topic to another hid the Bench')

        s.show(windows['topic-bench-toggle-a'])
        time.sleep(2)
        rs = s.rows()
        self.assertEqual(self.line(rs), 'Hide Bench', 'going to the Topic In Play hid the Bench: %s' % s.ids(rs))

    def test_the_card_of_a_benched_location_shows_alone_under_the_hidden_line(self):
        s = self.s
        windows = self.bench_topics('bench-visit')
        s.wait_rows(lambda rs: s.has('topic-bench-visit-a', rs) and self.line(rs) is not None,
                    'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-visit-c'])
        s.wait_rows(lambda rs: self.shown_after_line(rs) == ['topic-bench-visit-c'],
                    'the Benched card of the Location does not show alone under the line: %s' % s.ids())
        self.assertEqual(self.line(s.rows()), 'Bench', 'going to a Benched Topic showed the whole Bench')

    def cards(self, prefix, rs):
        """The cards of the check's Topics and the Bench line, in Sidebar order."""
        return [key for key in self.s.ids(rs) if key.startswith('topic-' + prefix) and '-session-' not in key or key == LINE]

    def orders(self, prefix):
        return {i: r.get('order') for i, r in self.records().items() if i.startswith(prefix + '-')}

    def test_a_card_dragged_across_the_shown_bench_line_trades_with_the_card_it_is_let_go_on(self):
        s = self.s
        self.bench_topics('bench-drag')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.show_bench()
        s.wait_rows(lambda rs: self.cards('bench-drag', rs)
                    == ['topic-bench-drag-a', LINE, 'topic-bench-drag-b', 'topic-bench-drag-c'],
                    'the Bench did not show: %s' % self.cards('bench-drag', s.rows()))
        s.act('drag', 'topic-bench-drag-c', 'topic-bench-drag-a')
        # The Sidebar shows the new order before the app saves it. Wait for the save, so that the cleanup removes the
        # records after it and the save does not bring a Topic back for the next check.
        orders = lambda: self.orders('bench-drag')
        wait(lambda: orders()['bench-drag-c'] < orders()['bench-drag-b'] < orders()['bench-drag-a'],
             'the drag did not save c, b, a: %s' % orders(), seconds=5)
        s.wait_rows(lambda rs: self.cards('bench-drag', rs)
                    == ['topic-bench-drag-c', LINE, 'topic-bench-drag-b', 'topic-bench-drag-a'],
                    'the Benched card and the card In Play did not trade places: %s' % self.cards('bench-drag', s.rows()))

    def test_a_tall_benched_card_trades_with_a_short_first_card_in_play(self):
        # An open card lists its Sessions. The tall card stops with its top at the top of the first card, where its
        # middle stays under the line.
        s = self.s
        self.bench_topics('bench-tall')
        for n in range(6):
            self.new_session('beta/bench-tall-b-%d' % n, self.beta, topic='bench-tall-b')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.show_bench()
        s.wait_rows(lambda rs: self.cards('bench-tall', rs)
                    == ['topic-bench-tall-a', LINE, 'topic-bench-tall-b', 'topic-bench-tall-c'],
                    'the Bench did not show: %s' % self.cards('bench-tall', s.rows()))
        self.expand('topic-bench-tall-b')
        rs = s.rows()

        def height(key):
            """The span of the card's header and its Session rows."""
            card = [frame(r) for r in rs if r.get('accessibilityIdentifier', '').startswith(key)]
            return max(end for _, end in card) - min(start for start, _ in card)
        self.assertGreater(height('topic-bench-tall-b'), 3 * height('topic-bench-tall-a'),
                           'the Benched card is not tall enough for the check')
        s.act('drag', 'topic-bench-tall-b', 'topic-bench-tall-a')
        orders = lambda: self.orders('bench-tall')
        wait(lambda: orders()['bench-tall-b'] < orders()['bench-tall-a'] < orders()['bench-tall-c'],
             'the tall card did not trade with the first card: %s' % orders(), seconds=5)

    def test_a_card_let_go_on_the_shown_bench_line_stays_in_its_place(self):
        # The line is between the cards, so a card that reaches only the line has not passed the card under it.
        s = self.s
        self.bench_topics('bench-line-drop')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        if self.line(s.rows()) == 'Bench':
            s.act('press', LINE)
        before = ['topic-bench-line-drop-a', LINE, 'topic-bench-line-drop-b', 'topic-bench-line-drop-c']
        s.wait_rows(lambda rs: self.cards('bench-line-drop', rs) == before,
                    'the Bench did not show: %s' % self.cards('bench-line-drop', s.rows()))
        s.act('drag', 'topic-bench-line-drop-a', LINE)
        s.act('drag', 'topic-bench-line-drop-b', LINE, edge='bottom')
        time.sleep(2)
        self.assertEqual(self.cards('bench-line-drop', s.rows()), before, 'a card let go on the line moved')

    def test_a_card_in_play_let_go_across_the_hidden_line_on_no_card_goes_back_and_the_bench_hides_again(self):
        s = self.s
        self.bench_topics('bench-hidden-drop')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        before = ['topic-bench-hidden-drop-a', LINE]
        s.wait_rows(lambda rs: self.cards('bench-hidden-drop', rs) == before,
                    'the hidden Bench shows cards: %s' % self.cards('bench-hidden-drop', s.rows()))
        saved = self.orders('bench-hidden-drop')
        s.act('drag', 'topic-bench-hidden-drop-a', LINE, edge='bottom')
        s.wait_rows(lambda rs: self.cards('bench-hidden-drop', rs) == before and self.line(rs) == 'Bench',
                    'the Bench that the drag opened did not hide again: %s' % self.cards('bench-hidden-drop', s.rows()))
        time.sleep(1)
        self.assertEqual(self.orders('bench-hidden-drop'), saved, 'a card let go on no card changed the order')

    def test_a_card_in_play_dragged_past_the_hidden_line_opens_the_bench_and_trades_with_a_benched_card(self):
        # The Benched card shows only once the drag opened the Bench, so the drag finds it after it waits on the line.
        s = self.s
        self.bench_topics('bench-hidden-trade')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.wait_rows(lambda rs: self.cards('bench-hidden-trade', rs) == ['topic-bench-hidden-trade-a', LINE],
                    'the hidden Bench shows cards: %s' % self.cards('bench-hidden-trade', s.rows()))
        s.act('drag', 'topic-bench-hidden-trade-a', 'topic-bench-hidden-trade-b', via=LINE, edge='bottom')
        orders = lambda: self.orders('bench-hidden-trade')
        wait(lambda: orders()['bench-hidden-trade-b'] < orders()['bench-hidden-trade-a'] < orders()['bench-hidden-trade-c'],
             'the drag did not save b, a, c: %s' % orders(), seconds=5)
        s.wait_rows(lambda rs: self.cards('bench-hidden-trade', rs) == ['topic-bench-hidden-trade-b', LINE]
                    and self.line(rs) == 'Bench',
                    'the Bench that the drag opened did not hide again: %s' % self.cards('bench-hidden-trade', s.rows()))
        self.show_bench()
        s.wait_rows(lambda rs: self.cards('bench-hidden-trade', rs)
                    == ['topic-bench-hidden-trade-b', LINE, 'topic-bench-hidden-trade-a', 'topic-bench-hidden-trade-c'],
                    'the card that left In Play did not take the place of the card that came: %s'
                    % self.cards('bench-hidden-trade', s.rows()))

    def test_the_benched_card_of_the_location_dragged_onto_a_card_in_play_trades_with_it(self):
        s = self.s
        windows = self.bench_topics('bench-visit-drag')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-visit-drag-b'])
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs) == ['topic-bench-visit-drag-a', LINE, 'topic-bench-visit-drag-b'],
                    'the Benched card of the Location does not show under the line: %s' % self.cards('bench-visit-drag', s.rows()))
        orders = lambda: self.orders('bench-visit-drag')
        traded = lambda: orders()['bench-visit-drag-b'] < orders()['bench-visit-drag-a'] < orders()['bench-visit-drag-c']
        # The app saves no change of the Topics while it still finishes going to b, and on a slow Mac the trade can come
        # before that. Nothing changes then, and the card goes back, so the check drags again.
        for _ in range(2):
            s.act('drag', 'topic-bench-visit-drag-b', 'topic-bench-visit-drag-a')
            if self.rows_until(lambda rs: traded(), seconds=5)[0] is not None:
                break
        self.assertTrue(traded(), 'the drag did not save b, a, c: %s' % orders())
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs) == ['topic-bench-visit-drag-b', LINE],
                    'the card it replaced did not fold into the hidden Bench: %s' % self.cards('bench-visit-drag', s.rows()))
        self.show_bench()
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs)
                    == ['topic-bench-visit-drag-b', LINE, 'topic-bench-visit-drag-a', 'topic-bench-visit-drag-c'],
                    'the card it replaced did not take its place on the Bench: %s' % self.cards('bench-visit-drag', s.rows()))

    def test_a_shown_bench_shows_the_benched_card_of_the_location_at_its_place_in_the_list(self):
        s = self.s
        windows = self.bench_topics('bench-visit-open')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-visit-open-c'])
        s.wait_rows(lambda rs: self.shown_after_line(rs) == ['topic-bench-visit-open-c'],
                    'the Benched card of the Location does not show under the line: %s' % s.ids())
        saved = self.orders('bench-visit-open')
        self.show_bench()
        s.wait_rows(lambda rs: self.shown_after_line(rs) == ['topic-bench-visit-open-b', 'topic-bench-visit-open-c'],
                    'the shown Bench is not in list order: %s' % self.shown_after_line(s.rows()))
        self.assertEqual(self.orders('bench-visit-open'), saved, 'showing the Bench changed the order')

    def test_the_benched_card_of_the_location_dragged_up_and_back_below_the_hidden_line_keeps_its_place(self):
        s = self.s
        windows = self.bench_topics('bench-visit-back')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-visit-back-c'])
        before = ['topic-bench-visit-back-a', LINE, 'topic-bench-visit-back-c']
        s.wait_rows(lambda rs: self.cards('bench-visit-back', rs) == before,
                    'the Benched card of the Location does not show under the line: %s' % self.cards('bench-visit-back', s.rows()))
        orders = lambda: self.orders('bench-visit-back')
        saved = orders()
        s.act('drag', 'topic-bench-visit-back-c', 'topic-bench-visit-back-c', via='topic-bench-visit-back-a')
        time.sleep(2)
        self.assertEqual(self.cards('bench-visit-back', s.rows()), before, 'the card let go below the line moved')
        self.assertEqual(orders(), saved, 'the card let go below the line changed the order')

    def test_a_click_on_a_card_of_the_shown_bench_does_not_move_it(self):
        # The opened No Topic Session under the line goes away with the click, so the clicked card is measured from the
        # Benched card above it.
        s = self.s
        windows = self.bench_topics('bench-click')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.show_bench()
        order = ['topic-bench-click-a', LINE, 'topic-bench-click-b', 'topic-bench-click-c']
        rs = s.wait_rows(lambda rs: self.cards('bench-click', rs) == order,
                         'the Bench did not show in list order: %s' % self.cards('bench-click', s.rows()))
        under_b = lambda rs: frame(s.row('topic-bench-click-b', rs))[0] - frame(s.row('topic-bench-click-c', rs))[1]
        before = under_b(rs)
        s.act('click', 'topic-bench-click-c')
        s.wait_shown(windows['topic-bench-click-c'])
        # The dump can list the line before the card above it for a moment after the click, with the same frames.
        rs = s.wait_rows(lambda rs: self.cards('bench-click', rs) == order,
                         'the click changed the order the Sidebar shows: %s' % self.cards('bench-click', s.rows()))
        self.assertAlmostEqual(under_b(rs), before, delta=1, msg='the clicked card moved')

    def test_scrolling_a_long_bench_leaves_the_cards_in_play_in_place(self):
        s = self.s
        bench = self.long_bench('bench-scroll')
        fixed = ['topic-bench-scroll-a', LINE]
        rs = s.rows()
        before = self.tops(fixed + [bench[0]], rs)
        s.act('scroll', 'topics-list', from_end=10)
        rs = s.wait_rows(lambda rs: self.tops([bench[0]], rs)[bench[0]] > before[bench[0]] + 100,
                         'the Bench did not scroll: %s' % self.tops([bench[0]], s.rows()))
        self.assert_in_place(fixed, before, rs)

    def test_a_lifted_card_held_at_the_bottom_edge_scrolls_the_bench(self):
        s = self.s
        bench = self.long_bench('bench-edge')
        fixed = ['topic-bench-edge-a', LINE]
        rs = s.rows()
        before = self.tops(fixed + [bench[-1]], rs)
        scrolled = lambda rs: self.tops([bench[-1]], rs)[bench[-1]] > before[bench[-1]] + 100
        # The app can cancel a drag while it still finishes a change of the Location that an earlier check made, as
        # after a click on a card. The card then goes back and nothing scrolls, so the check drags again.
        for _ in range(3):
            s.act('drag', bench[0], 'topics-list', edge='bottom', inset=10, hold=1.5)
            rs = s.rows()
            if scrolled(rs):
                break
        self.assertTrue(scrolled(rs), 'the Bench did not scroll while the card was held at its bottom edge: %s, before %s'
                        % (self.tops([bench[-1]], rs), before))
        self.assert_in_place(fixed, before, rs)
        # The card landed further down the Bench. Wait for the save, so that the cleanup removes the records after it.
        orders = lambda: self.orders('bench-edge')
        wait(lambda: orders()['bench-edge-b'] > orders()['bench-edge-c'], 'the drop did not save: %s' % orders(), seconds=5)

    def test_a_card_in_play_trades_with_the_card_it_is_let_go_on_in_a_scrolled_bench(self):
        s = self.s
        prefix = 'bench-scrolled-trade'
        bench = self.long_bench(prefix)
        rs = s.rows()
        area_top = frame(s.row(bench[0], rs))[1] + 6
        list_bottom = frame(s.row('topics-list', rs))[0]
        last = frame(s.row(bench[-1], rs))
        # The end of the content that puts the last card's bottom in the middle of the Bench area, away from its edges.
        s.act('scroll', 'topics-list', from_end=(area_top - list_bottom) / 2 - (last[1] - last[0]) - 6)
        rs = s.wait_rows(lambda rs: frame(s.row(bench[0], rs))[1] > area_top + 100, 'the Bench did not scroll')
        middle = (area_top + list_bottom) / 2
        target = min(bench, key=lambda key: abs(sum(frame(s.row(key, rs))) / 2 - middle))
        self.assertGreater(bench.index(target), 5, 'the card in the middle of the Bench area is not far down the Bench')
        by_order = lambda: [name for name, _ in sorted(self.orders(prefix).items(), key=lambda item: (item[1], item[0]))]
        before = by_order()
        a, other = prefix + '-a', target[len('topic-'):]
        expected = [other if name == a else a if name == other else name for name in before]
        s.act('drag', 'topic-%s-a' % prefix, target)
        wait(lambda: by_order() == expected, 'the card In Play did not trade with %s: %s' % (other, by_order()), seconds=5)

    def test_make_a_guest_puts_a_benched_topic_in_play_with_its_mark_and_end_guest_puts_it_on_top_of_the_bench(self):
        # The card's accessibility actions are its context menu (`listActions` in UI/SidebarView.swift).
        s = self.s
        self.bench_topics('bench-guest')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.show_bench()
        guest = 'topic-bench-guest-c'
        s.wait_rows(lambda rs: self.cards('bench-guest', rs) == ['topic-bench-guest-a', LINE, 'topic-bench-guest-b', guest],
                    'the Bench did not show: %s' % self.cards('bench-guest', s.rows()))
        s.act('action', guest, 'Make a Guest')
        s.wait_rows(lambda rs: self.cards('bench-guest', rs) == ['topic-bench-guest-a', guest, LINE, 'topic-bench-guest-b'],
                    'the Guest is not at the end of In Play, or a card went to the Bench: %s' % self.cards('bench-guest', s.rows()))
        wait(lambda: self.records()['bench-guest-c'].get('guest') is True,
             'the record has no Guest mark: %s' % self.records()['bench-guest-c'], seconds=5)
        s.wait_rows(lambda rs: 'Guest' in s.row(guest, rs).get('accessibilityValue', ''),
                    'the card shows no Guest mark: %s' % self.describe(guest, s.rows()))

        s.act('action', guest, 'End Guest')
        s.wait_rows(lambda rs: self.cards('bench-guest', rs) == ['topic-bench-guest-a', LINE, guest, 'topic-bench-guest-b'],
                    'End Guest did not put the card at the top of the Bench: %s' % self.cards('bench-guest', s.rows()))
        wait(lambda: 'guest' not in self.records()['bench-guest-c'],
             'the record keeps its Guest mark: %s' % self.records()['bench-guest-c'], seconds=5)

    def test_with_in_play_a_locked_session_is_a_guest_at_the_end_of_in_play(self):
        # The Session card's accessibility actions are its context menu (`lockButton` in UI/SidebarView.swift).
        s = self.s
        self.bench_topics('bench-guest-lock')
        sid = self.new_session('bench-guest-lock-notes', self.beta)
        window = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.show_bench()
        s.show(window)
        card = 'no-topic-session-' + sid
        s.wait_rows(lambda rs: s.has(card, rs), 'the No Topic Session has no card: %s' % s.ids())
        s.act('action', card, 'Make a Guest')
        locked = 'locked-' + sid
        s.wait_rows(lambda rs: [k for k in s.ids(rs) if k in ('topic-bench-guest-lock-a', locked, LINE)]
                    == ['topic-bench-guest-lock-a', locked, LINE],
                    'the Guest Session is not at the end of In Play: %s' % s.ids())
        self.assertIn('Guest', s.row(locked).get('accessibilityValue', ''), 'the card shows no Guest mark')
        self.assertTrue(s.tmux('show-options', '-qv', '-t', sid, '@muxify_lock').strip(), 'Make a Guest wrote no Lock')
        s.act('action', locked, 'End Guest')
        wait(lambda: not s.tmux('show-options', '-qv', '-t', sid, '@muxify_lock').strip(), 'End Guest did not end the Lock')


if __name__ == '__main__':
    unittest.main()
