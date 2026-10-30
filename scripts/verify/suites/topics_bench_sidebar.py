"""Topics in the Sidebar: with topics.in_play, the Topics after the ones In Play wait on the Bench, behind one line.

The Bench line is a button, so `press` shows or hides the Bench through its accessibility action.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_bench_sidebar
"""

import time
import unittest

from scripts.verify.sandbox import wait
from scripts.verify.topics_sidebar import TopicsSidebar

LINE = 'topics-bench-line'


class TopicsBenchSidebar(TopicsSidebar):
    def bench_topics(self, prefix):
        """Topics <prefix>-a, -b and -c in that order, each with one live Session, and only one In Play. Returns the
        Window of each Topic by its card identifier."""
        self.addCleanup(self.config.write_text, self.config_text)
        self.config.write_text(self.config_text + 'topics:\n  in_play: 1\n')
        windows = {}
        for order, name in enumerate(['a', 'b', 'c']):
            topic = '%s-%s' % (prefix, name)
            self.write_topic(topic, topic.capitalize(), self.beta, order=order)
            sid = self.new_session('beta/' + topic, self.beta, topic=topic)
            windows['topic-' + topic] = self.s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        return windows

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
        s.act('drag', 'topic-bench-visit-drag-b', 'topic-bench-visit-drag-a')
        orders = lambda: self.orders('bench-visit-drag')
        wait(lambda: orders()['bench-visit-drag-b'] < orders()['bench-visit-drag-a'] < orders()['bench-visit-drag-c'],
             'the drag did not save b, a, c: %s' % orders(), seconds=5)
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs) == ['topic-bench-visit-drag-b', LINE],
                    'the card it replaced did not fold into the hidden Bench: %s' % self.cards('bench-visit-drag', s.rows()))
        self.show_bench()
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs)
                    == ['topic-bench-visit-drag-b', LINE, 'topic-bench-visit-drag-a', 'topic-bench-visit-drag-c'],
                    'the card it replaced did not take its place on the Bench: %s' % self.cards('bench-visit-drag', s.rows()))

    def test_the_benched_card_of_the_location_stays_right_under_the_line_when_the_bench_shows(self):
        s = self.s
        windows = self.bench_topics('bench-visit-open')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-visit-open-c'])
        s.wait_rows(lambda rs: self.shown_after_line(rs) == ['topic-bench-visit-open-c'],
                    'the Benched card of the Location does not show under the line: %s' % s.ids())
        saved = self.orders('bench-visit-open')
        self.show_bench()
        s.wait_rows(lambda rs: self.shown_after_line(rs) == ['topic-bench-visit-open-c', 'topic-bench-visit-open-b'],
                    'the card of the Location moved when the Bench showed: %s' % self.shown_after_line(s.rows()))
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


if __name__ == '__main__':
    unittest.main()
