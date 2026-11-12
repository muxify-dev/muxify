"""Guest Sessions in the Topics list (ADR 0018, ADR 0079): Make a Guest, Bench, New Topic from a Guest Session and Kill.

A Guest Session is a No Topic Session with a Lock, the tmux option @muxify_lock. The Session card header in
UI/SidebarView.swift gives "Make a Guest" as an accessibility action, and the card of a Guest Session gives "Bench" and
"New Topic from this Session", so the checks reach them without a context menu.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_locks_sidebar
"""

import json
import unittest

from scripts.verify.sandbox import frame, wait
from scripts.verify.topics_sidebar import TopicsSidebar


class TopicsLocksSidebar(TopicsSidebar):
    def lock_option(self, sid):
        return self.s.tmux('show-options', '-qv', '-t', sid, '@muxify_lock')

    def above(self, upper, lower, rs):
        return self.s.has(upper, rs) and self.s.has(lower, rs) and frame(self.s.row(upper, rs))[1] > frame(self.s.row(lower, rs))[1]

    def guest_session(self, name, order):
        """A No Topic Session that has a Lock at `order`, as tmux keeps a Guest Session; returns (session id, card key)."""
        sid = self.new_session(name, self.beta)
        self.s.tmux('set-option', '-t', sid, '@muxify_lock', str(order))
        key = 'locked-' + sid
        self.find(key, 'no card for the Guest Session ' + name)
        return sid, key

    def test_make_a_guest_gives_a_card_under_the_in_play_places_and_sets_the_session_option(self):
        s = self.s
        self.write_topic('guest-first', 'Guest first', self.beta, order=0)
        self.write_topic('guest-last', 'Guest last', self.beta, order=1)
        self.write_topic('guest-pinned', 'Guest pinned', self.beta, order=0, pinned=True)
        sid = self.new_session('guest-notes', self.beta)
        self.select_window(sid + ':')
        card = 'no-topic-session-' + sid
        self.find(card, 'the selected No Topic Session has no card')
        s.act('action', card, 'Make a Guest')

        key = 'locked-' + sid
        rs = self.find(key, 'Make a Guest gave the Session no card')
        rs = s.wait_rows(lambda rs: self.above('topic-guest-last', key, rs) and self.above('topic-guest-pinned', 'topic-guest-first', rs)
                         and self.above('topics-guests-line', key, rs),
                         'the Guest Session is not under the Guests line, after the Topics In Play')
        value = s.row(key, rs).get('accessibilityValue', '')
        self.assertIn('Guest', value, self.describe(key, rs))
        self.assertNotIn('Locked', value, self.describe(key, rs))
        self.assertTrue(value.startswith('expanded'), 'the card of the Active Guest Session is not open: ' + value)
        self.assertNotIn(card, s.ids(rs), 'the Session still has the No Topic card')
        order = wait(lambda: self.lock_option(sid), 'Make a Guest did not set @muxify_lock')
        self.assertGreater(float(order), 1, '@muxify_lock %s is not after the last Topic' % order)

        self.show_view('sessions')
        rs = self.find('session-' + sid)
        self.assertIn('Guest', s.row('session-' + sid, rs).get('accessibilityValue', ''), self.describe('session-' + sid, rs))
        self.show_view('topics')

    def test_bench_of_a_guest_session_removes_the_card_and_the_session_option(self):
        s = self.s
        sid, key = self.guest_session('bench-notes', 7)
        s.act('action', key, 'Bench')
        s.wait_rows(lambda rs: not s.has(key, rs), 'Bench kept the card of the Guest Session')
        wait(lambda: self.lock_option(sid) == '', 'Bench kept @muxify_lock', seconds=10)

    def test_a_lock_that_an_older_muxify_kept_among_the_topics_goes_to_the_guests(self):
        s = self.s
        self.write_topic('gather-upper', 'Gather upper', self.beta, order=0)
        self.write_topic('gather-lower', 'Gather lower', self.beta, order=2)
        sid, key = self.guest_session('gather-notes', 1)
        s.wait_rows(lambda rs: self.above('topic-gather-lower', key, rs) and self.above('topics-guests-line', key, rs),
                    'the Guest Session is not under the Guests line')
        def gathered():
            lower = self.records().get('gather-lower', {}).get('order')
            lock = self.lock_option(sid)
            return lower is not None and lock != '' and float(lock) > lower
        wait(gathered, lambda: 'the Lock is not after the Topics on disk: @muxify_lock %s, records %s'
             % (self.lock_option(sid), {i: r.get('order') for i, r in self.records().items()}), seconds=10)

    def test_new_topic_from_a_guest_session_takes_its_place_and_its_guest_mark_and_removes_the_option(self):
        s = self.s
        self.write_topic('take-upper', 'Take upper', self.beta, order=0)
        self.write_topic('take-lower', 'Take lower', self.beta, order=1)
        sid, key = self.guest_session('take-notes', 5)
        s.wait_rows(lambda rs: self.above('topic-take-lower', key, rs), 'the Guest Session is not under the two Topics')
        before = set(self.records())
        s.act('action', key, 'New Topic from this Session')
        s.wait_rows(lambda rs: s.has('palette-row-new-topic', rs), 'New Topic from this Session did not open Move')
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', 'Taken place')
        s.wait_rows(lambda rs: 'Taken place' in s.row('palette-row-new-topic', rs).get('accessibilityLabel', ''),
                    'the New Topic row does not show the typed title')
        s.act('press', 'palette-row-new-topic')
        record = wait(lambda: next((r for i, r in self.records().items() if i not in before and r.get('title') == 'Taken place'), None),
                      'no Topic record for the Guest Session')
        self.addCleanup(self.store.remove, record['id'])
        self.assertEqual((record.get('order'), record.get('guest')), (5, True), json.dumps(record))
        wait(lambda: self.lock_option(sid) == '', 'the Topic made from the Guest Session kept @muxify_lock', seconds=10)
        self.assertEqual(s.tmux('show-options', '-qv', '-t', sid, '@muxify_topic'), record['id'])
        topic = 'topic-' + record['id']
        rs = s.wait_rows(lambda rs: self.above('topic-take-lower', topic, rs) and self.above('topics-guests-line', topic, rs)
                         and key not in s.ids(rs), 'the new Topic did not take the place of the Guest Session')
        self.assertIn('Guest', s.row(topic, rs).get('accessibilityValue', ''), self.describe(topic, rs))

    def test_killing_a_guest_session_removes_its_card(self):
        s = self.s
        sid, key = self.guest_session('kill-guest-notes', 4)
        self.end_session(sid)
        s.wait_rows(lambda rs: not s.has(key, rs), 'the card stayed after its Guest Session ended')


if __name__ == '__main__':
    unittest.main()
