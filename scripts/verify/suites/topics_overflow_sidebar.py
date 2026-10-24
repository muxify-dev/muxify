"""Topics in the Sidebar: the "N more below" line under a Topics list that does not fit.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_overflow_sidebar
"""

import re
import unittest

from scripts.verify.sandbox import frame
from scripts.verify.topics_sidebar import TopicsSidebar

COUNT = 30


class TopicsOverflowSidebar(TopicsSidebar):
    def more_below(self, rs):
        found = re.search(r'(\d+) more below', self.s.row('topics-more-below', rs).get('accessibilityLabel', ''))
        return int(found.group(1)) if found else None

    def cards_below_list(self, rs):
        """The cards whose frame ends below the Topics list, in list order."""
        edge, _ = frame(self.s.row('topics-list', rs))
        cards = [key for key in self.s.ids(rs)
                 if key in self.topic_rows(rs) or (key.startswith(('locked-', 'no-topic-session-')) and not key.endswith('-more'))]
        return [key for key in cards if frame(self.s.row(key, rs))[0] < edge - 1]

    def test_more_below_line_counts_hidden_cards_scrolls_to_them_and_goes_away_at_the_end(self):
        s = self.s
        ids = ['overflow-%02d' % i for i in range(COUNT)]
        for topic_id in ids:
            self.write_topic(topic_id, 'Overflow ' + topic_id[-2:], self.beta)
        rs = s.wait_rows(lambda rs: (self.more_below(rs) or 0) > 0,
                         'a Topics list of %d Topics shows no "more below" line' % COUNT)
        hidden = self.cards_below_list(rs)
        self.assertEqual(self.more_below(rs), len(hidden),
                         'the line %r does not count the cards below the list: %s' % (s.row('topics-more-below', rs), hidden))

        s.act('press', 'topics-more-below')
        list_top = frame(s.row('topics-list', rs))[1]
        rs = s.wait_rows(lambda rs: abs(frame(s.row(hidden[0], rs))[1] - list_top) < 12,
                         'a click on the line did not scroll the first hidden card %s to the top of the list' % hidden[0])
        self.assertEqual(self.more_below(rs), len(self.cards_below_list(rs)),
                         'after the click, the line %r does not count the cards below the list' % s.row('topics-more-below', rs))
        self.assertLess(self.more_below(rs), len(hidden), 'the click did not reduce the count')

        s.reveal(self.topic_rows(rs)[-1])
        end = s.wait_rows(lambda rs: not s.has('topics-more-below', rs),
                          'the "more below" line stays when the list is scrolled to its end')
        self.assertEqual(frame(s.row('topics-list', end)), frame(s.row('topics-list', rs)),
                         'the Topics list changed its size when the line went away, so its cards moved')

    def test_more_below_line_slides_out_with_the_end_of_the_list(self):
        s = self.s
        for i in range(COUNT):
            self.write_topic('slide-%02d' % i, 'Slide %02d' % i, self.beta)
        # The check before may leave the list at its end, where the line does not show, so wait for the cards, not
        # the line, and then scroll.
        s.wait_rows(lambda rs: all(s.has('topic-slide-%02d' % i, rs) for i in range(COUNT)),
                    'the Topics list does not show the %d Slide Topics' % COUNT)

        def line_drop(rs):
            """How far the line is below its place at the bottom of the list."""
            return frame(s.row('topics-list', rs))[0] - frame(s.row('topics-more-below', rs))[0]

        # The list's padding is 4 points below the last card, and the line is 30 points high.
        s.act('scroll', 'topics-list', from_end=200)
        rs = s.wait_rows(lambda rs: s.has('topics-more-below', rs) and line_drop(rs) == 0,
                         'far from the end, the line is not at the bottom of the list')
        s.act('scroll', 'topics-list', from_end=14)
        rs = s.wait_rows(lambda rs: s.has('topics-more-below', rs) and abs(line_drop(rs) - 20) <= 1,
                         'with the last card 10 points below the edge, the line did not move down 20 points with it')
        s.act('scroll', 'topics-list', from_end=0)
        s.wait_rows(lambda rs: not s.has('topics-more-below', rs), 'at the end of the list, the line stays')


if __name__ == '__main__':
    unittest.main()
