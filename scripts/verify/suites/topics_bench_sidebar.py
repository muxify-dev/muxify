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

    def test_a_card_dragged_across_the_shown_bench_line_changes_places_with_the_cards_it_passes(self):
        s = self.s
        self.bench_topics('bench-drag')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        if self.line(s.rows()) == 'Bench':
            s.act('press', LINE)
        s.wait_rows(lambda rs: self.cards('bench-drag', rs)
                    == ['topic-bench-drag-a', LINE, 'topic-bench-drag-b', 'topic-bench-drag-c'],
                    'the Bench did not show: %s' % self.cards('bench-drag', s.rows()))
        s.act('drag', 'topic-bench-drag-c', 'topic-bench-drag-a')
        # The Sidebar shows the new order before the app saves it. Wait for the save, so that the cleanup removes the
        # records after it and the save does not bring a Topic back for the next check.
        orders = lambda: {i: r.get('order') for i, r in self.records().items() if i.startswith('bench-drag-')}
        wait(lambda: orders()['bench-drag-c'] < orders()['bench-drag-a'],
             'the drag did not save bench-drag-c above bench-drag-a', seconds=5)
        s.wait_rows(lambda rs: self.cards('bench-drag', rs)
                    == ['topic-bench-drag-c', LINE, 'topic-bench-drag-a', 'topic-bench-drag-b'],
                    'the Benched card dragged onto the card In Play did not go In Play: %s' % self.cards('bench-drag', s.rows()))

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

    def test_a_card_in_play_does_not_go_to_the_hidden_bench(self):
        # The hidden Bench shows no place to drop a card, and the cards it hides would come In Play in its place.
        s = self.s
        self.bench_topics('bench-hidden-drop')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        before = ['topic-bench-hidden-drop-a', LINE]
        s.wait_rows(lambda rs: self.cards('bench-hidden-drop', rs) == before,
                    'the hidden Bench shows cards: %s' % self.cards('bench-hidden-drop', s.rows()))
        s.act('drag', 'topic-bench-hidden-drop-a', LINE, edge='bottom')
        time.sleep(2)
        self.assertEqual(self.cards('bench-hidden-drop', s.rows()), before, 'the card In Play went to the hidden Bench')

    def test_the_benched_card_of_the_location_dragged_past_the_hidden_line_goes_in_play(self):
        s = self.s
        windows = self.bench_topics('bench-visit-drag')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-visit-drag-c'])
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs) == ['topic-bench-visit-drag-a', LINE, 'topic-bench-visit-drag-c'],
                    'the Benched card of the Location does not show under the line: %s' % self.cards('bench-visit-drag', s.rows()))
        s.act('drag', 'topic-bench-visit-drag-c', 'topic-bench-visit-drag-a')
        orders = lambda: {i: r.get('order') for i, r in self.records().items() if i.startswith('bench-visit-drag-')}
        wait(lambda: orders()['bench-visit-drag-c'] < orders()['bench-visit-drag-a'] < orders()['bench-visit-drag-b'],
             'the drag did not save bench-visit-drag-c above a, and a above b: %s' % orders(), seconds=5)
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs) == ['topic-bench-visit-drag-c', LINE],
                    'the dragged card did not go In Play: %s' % self.cards('bench-visit-drag', s.rows()))
        self.show_bench()
        s.wait_rows(lambda rs: self.cards('bench-visit-drag', rs)
                    == ['topic-bench-visit-drag-c', LINE, 'topic-bench-visit-drag-a', 'topic-bench-visit-drag-b'],
                    'the last card In Play did not go to the top of the Bench: %s' % self.cards('bench-visit-drag', s.rows()))

    def test_the_benched_card_of_the_location_dragged_up_and_back_below_the_hidden_line_keeps_its_place(self):
        s = self.s
        windows = self.bench_topics('bench-visit-back')
        s.wait_rows(lambda rs: self.line(rs) is not None, 'with topics.in_play: 1, the Sidebar shows no Bench line')
        self.hide_bench()
        s.show(windows['topic-bench-visit-back-c'])
        before = ['topic-bench-visit-back-a', LINE, 'topic-bench-visit-back-c']
        s.wait_rows(lambda rs: self.cards('bench-visit-back', rs) == before,
                    'the Benched card of the Location does not show under the line: %s' % self.cards('bench-visit-back', s.rows()))
        orders = lambda: {i: r.get('order') for i, r in self.records().items() if i.startswith('bench-visit-back-')}
        saved = orders()
        s.act('drag', 'topic-bench-visit-back-c', 'topic-bench-visit-back-c', via='topic-bench-visit-back-a')
        time.sleep(2)
        self.assertEqual(self.cards('bench-visit-back', s.rows()), before, 'the card let go below the line moved')
        self.assertEqual(orders(), saved, 'the card let go below the line changed the order')


if __name__ == '__main__':
    unittest.main()
