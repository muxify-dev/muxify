"""A long shown Bench scrolls smoothly: a scroll draws no Benched card again.

The driver's `scroll` with `by` and `steps` moves the Topics list down in steps, one each tick, as a wheel does, and
`counts` reads how often each counted view's body ran since the last reset (`BodyCount` in App/BodyCount.swift).

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_bench_scroll_sidebar
"""

import time
import unittest

from scripts.verify.sandbox import frame, wait
from scripts.verify.topics_sidebar import TopicsSidebar

LINE = 'topics-bench-line'
BENCHED = 40
STEPS = 20
BY = 600
# Longer than the app's one-second read of tmux and the Topic records, so a list at rest saw a read change nothing.
REST = 1.5
REST_LIMIT = 20


class TopicsBenchScrollSidebar(TopicsSidebar):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        # BodyCount counts only while Diagnostics is on, which it is not by default.
        cls.config_text += 'diagnostics:\n  enabled: true\n'
        cls.config.write_text(cls.config_text)
        wait(lambda: any('on: pid %d' % cls.s.pid in path.read_text(errors='replace')
                         for path in (cls.s.root/'logs').glob('muxify-*.log')), 'Diagnostics did not turn on', 10)

    def long_bench(self, prefix):
        """A shown Bench of BENCHED closed cards under one card In Play, scrolled to its top. Returns the identifiers of
        the Benched cards in list order."""
        s = self.s
        self.addCleanup(self.config.write_text, self.config_text)
        # An Open Place that a check leaves would take the In Play place of the next check.
        self.addCleanup(self.store.set_open_places, [])
        self.config.write_text(self.config_text + 'topics:\n  in_play: 1\n')
        topic = prefix + '-a'
        self.write_topic(topic, topic.capitalize(), self.beta, order=0)
        self.new_session('beta/' + topic, self.beta, topic=topic)
        bench = []
        for order in range(1, BENCHED + 1):
            topic = '%s-t%02d' % (prefix, order)
            self.write_topic(topic, topic.capitalize(), self.beta, order=order)
            bench.append('topic-' + topic)
        s.wait_rows(lambda rs: s.has(LINE, rs) and s.has('topic-%s-a' % prefix, rs), 'the Topics list has no Bench line')
        if s.row(LINE).get('accessibilityLabel') == 'Bench':
            s.act('press', LINE)
        s.wait_rows(lambda rs: s.row(LINE, rs).get('accessibilityLabel') == 'Hide Bench', 'the Bench did not show')
        s.wait_rows(lambda rs: all(s.has(key, rs) for key in bench), 'the Bench does not show every Benched card')
        s.wait_rows(lambda rs: frame(s.row(bench[-1], rs))[1] < frame(s.row('topics-list', rs))[0],
                    'the long Bench fits in the Sidebar')
        s.act('scroll', 'topics-list', from_end=100000)
        s.wait_rows(lambda rs: frame(s.row(bench[0], rs))[1] < frame(s.row(LINE, rs))[0],
                    'the Bench did not scroll back to its top')
        return bench

    def wait_at_rest(self):
        """Waits until the Topics list runs no body for REST seconds. Under load, the fixture's last changes reach the
        list late, and a whole-list pass that they cause during the scroll is not the scroll's."""
        s = self.s
        deadline = time.monotonic() + REST_LIMIT
        while True:
            s.driver('counts', reset=True)
            time.sleep(REST)
            counts = s.driver('counts')['counts']
            if not counts:
                return
            if time.monotonic() > deadline:
                self.fail('the Topics list did not come to rest in %d s; bodies in the last %.1f s: %s' % (REST_LIMIT, REST, counts))

    def test_a_scroll_of_the_bench_draws_no_benched_card_again(self):
        s = self.s
        bench = self.long_bench('bench-scroll')
        self.wait_at_rest()
        s.driver('counts', reset=True)
        before = frame(s.row(bench[-1]))[1]
        scrolled = s.act('scroll', 'topics-list', by=BY, steps=STEPS)
        counts = s.driver('counts')['counts']
        after = frame(s.row(bench[-1]))[1]
        # Screen points grow upwards, so a card that scrolls up has a higher top.
        self.assertGreater(after - before, BY / 2, 'the Bench did not scroll: the last card moved up %.0f points' % (after - before))
        cards = counts.get('TopicCard', 0)
        per_step = {name: round(count / STEPS, 1) for name, count in sorted(counts.items())}
        self.assertLessEqual(
            cards, 2,
            'a scroll of %d points in %d steps ran TopicCard.body %d times (%.1f each step) over %d cards, in %.2f s; '
            'bodies each step: %s' % (BY, STEPS, cards, cards / STEPS, BENCHED + 1, scrolled['seconds'], per_step))
