"""Guest Sessions in the Topics list (ADR 0018, ADR 0081): Make a Guest, Bench, New Topic from a Guest Session or from its
only Window, and Kill.

A Guest Session is a No Topic Session with a Lock: a row of the `guest_sessions` table in the state database, which
the Session points at with its tmux option @muxify_session_id. Its card is `locked-<Lock id>`. A check makes a Guest
Session as an older Muxify did, with the tmux option @muxify_lock, which the app imports into the table. The Session
card header in UI/SidebarView.swift gives "Make a Guest" as an accessibility action, and the card of a Guest Session
gives "Bench" and "New Topic from this Session", so the checks reach them without a context menu.

What a tmux restart keeps is in topics_dormant_guests_sidebar, because a restart ends every Session of the fixture.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_locks_sidebar
"""

import json
import unittest

from scripts.verify.sandbox import frame, wait
from scripts.verify.topics_sidebar import TopicsSidebar


class TopicsLocksSidebar(TopicsSidebar):
    def legacy_option(self, sid):
        return self.s.tmux('show-options', '-qv', '-t', sid, '@muxify_lock')

    def lock_id(self, sid):
        """The id of the Session's Lock, once the Session points at one."""
        return wait(lambda: self.s.tmux('show-options', '-qv', '-t', sid, '@muxify_session_id'),
                    'the Session %s points at no Lock' % sid)

    def lock(self, lock_id):
        """The Lock's row in the state database, or None."""
        return next((lock for lock in self.store.locks() if lock['id'] == lock_id), None)

    def above(self, upper, lower, rs):
        return self.s.has(upper, rs) and self.s.has(lower, rs) and frame(self.s.row(upper, rs))[1] > frame(self.s.row(lower, rs))[1]

    def guest_session(self, name, order):
        """A No Topic Session that an older Muxify Locked at `order`, with @muxify_lock, which the app imports;
        returns (session id, card key, Lock id)."""
        sid = self.new_session(name, self.beta)
        self.s.tmux('set-option', '-t', sid, '@muxify_lock', str(order))
        lock_id = self.lock_id(sid)
        self.addCleanup(self.store.remove_lock, lock_id)
        key = 'locked-' + lock_id
        self.find(key, 'no card for the Guest Session ' + name)
        return sid, key, lock_id

    def test_make_a_guest_gives_a_card_under_the_in_play_places_and_writes_its_lock(self):
        s = self.s
        self.write_topic('guest-first', 'Guest first', order=0)
        self.write_topic('guest-last', 'Guest last', order=1)
        self.write_topic('guest-pinned', 'Guest pinned', order=0, pinned=True)
        sid = self.new_session('guest-notes', self.beta)
        self.select_window(sid + ':')
        card = 'no-topic-session-' + sid
        self.find(card, 'the selected No Topic Session has no card')
        s.act('action', card, 'Make a Guest')

        lock_id = self.lock_id(sid)
        self.addCleanup(self.store.remove_lock, lock_id)
        key = 'locked-' + lock_id
        rs = self.find(key, 'Make a Guest gave the Session no card')
        rs = s.wait_rows(lambda rs: self.above('topic-guest-last', key, rs) and self.above('topic-guest-pinned', 'topic-guest-first', rs)
                         and self.above('topics-guests-line', key, rs),
                         'the Guest Session is not under the Guests line, after the Topics In Play')
        value = s.row(key, rs).get('accessibilityValue', '')
        self.assertIn('Guest', value, self.describe(key, rs))
        self.assertNotIn('Locked', value, self.describe(key, rs))
        self.assertTrue(value.startswith('expanded'), 'the card of the Active Guest Session is not open: ' + value)
        self.assertNotIn(card, s.ids(rs), 'the Session still has the No Topic card')
        lock = wait(lambda: self.lock(lock_id), 'Make a Guest wrote no Lock')
        self.assertGreater(lock['order'], 1, 'the Lock %s is not after the last Topic' % lock)
        self.assertEqual(lock['session'].get('name'), 'guest-notes', 'the Lock remembers its Session: %s' % lock)
        self.assertEqual(self.legacy_option(sid), '', 'Make a Guest wrote @muxify_lock')

        self.s.show_sidebar_mode('sessions')
        rs = self.find('session-' + sid)
        self.assertIn('Guest', s.row('session-' + sid, rs).get('accessibilityValue', ''), self.describe('session-' + sid, rs))
        self.s.show_sidebar_mode('topics')

    def test_bench_of_a_guest_session_removes_the_card_and_the_lock(self):
        s = self.s
        sid, key, lock_id = self.guest_session('bench-notes', 7)
        self.assertEqual(self.legacy_option(sid), '', 'the import kept @muxify_lock')
        s.act('action', key, 'Bench')
        s.wait_rows(lambda rs: not s.has(key, rs), 'Bench kept the card of the Guest Session')
        wait(lambda: self.lock(lock_id) is None, 'Bench kept the Lock', seconds=10)

    def test_a_lock_that_an_older_muxify_kept_among_the_topics_goes_to_the_guests(self):
        s = self.s
        self.write_topic('gather-upper', 'Gather upper', order=0)
        self.write_topic('gather-lower', 'Gather lower', order=2)
        sid, key, lock_id = self.guest_session('gather-notes', 1)
        s.wait_rows(lambda rs: self.above('topic-gather-lower', key, rs) and self.above('topics-guests-line', key, rs),
                    'the Guest Session is not under the Guests line')
        def gathered():
            lower = self.records().get('gather-lower', {}).get('order')
            lock = self.lock(lock_id)
            return lower is not None and lock is not None and lock['order'] > lower
        wait(gathered, lambda: 'the Lock is not after the Topics on disk: Lock %s, records %s'
             % (self.lock(lock_id), {i: r.get('order') for i, r in self.records().items()}), seconds=10)

    def test_new_topic_from_a_guest_session_takes_its_place_and_its_guest_mark_and_ends_its_lock(self):
        s = self.s
        self.write_topic('take-upper', 'Take upper', order=0)
        self.write_topic('take-lower', 'Take lower', order=1)
        sid, key, lock_id = self.guest_session('take-notes', 5)
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
        wait(lambda: self.lock(lock_id) is None, 'the Topic made from the Guest Session kept its Lock', seconds=10)
        self.assertEqual(s.tmux('show-options', '-qv', '-t', sid, '@muxify_topic'), record['id'])
        topic = 'topic-' + record['id']
        rs = s.wait_rows(lambda rs: self.above('topic-take-lower', topic, rs) and self.above('topics-guests-line', topic, rs)
                         and key not in s.ids(rs), 'the new Topic did not take the place of the Guest Session')
        self.assertIn('Guest', s.row(topic, rs).get('accessibilityValue', ''), self.describe(topic, rs))

    def test_new_topic_from_the_only_window_of_a_guest_session_takes_its_place(self):
        s = self.s
        sid, key, _ = self.guest_session('window-notes', 8)
        _, later, later_lock = self.guest_session('window-later', 9)
        s.wait_rows(lambda rs: self.above(key, later, rs), 'the first Guest Session is not above the second')
        window = s.tmux('list-windows', '-t', sid, '-F', '#{window_id}')
        self.select_window(sid + ':')
        self.expand(key)
        s.wait_rows(lambda rs: s.has('topic-window-' + window, rs), 'the Guest Session shows no row for its Window')
        before = set(self.records())
        # "New Topic from this Window" and "Move Window to Topic…" open the same Move step; SidebarView gives the Window
        # row the second as an accessibility action (topicMembershipActions), because the context menu takes the mouse.
        s.act('action', 'topic-window-' + window, 'Move Window to Topic…')
        s.wait_rows(lambda rs: s.has('palette-row-new-topic', rs), 'Move Window to Topic did not open Move')
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', 'Window place')
        s.wait_rows(lambda rs: 'Window place' in s.row('palette-row-new-topic', rs).get('accessibilityLabel', ''),
                    'the New Topic row does not show the typed title')
        s.act('press', 'palette-row-new-topic')
        record = wait(lambda: next((r for i, r in self.records().items() if i not in before and r.get('title') == 'Window place'), None),
                      'no Topic record for the Window')
        self.addCleanup(self.store.remove, record['id'])
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', window)
        self.assertEqual((record.get('order'), record.get('guest')), (8, True), json.dumps(record))
        topic = 'topic-' + record['id']
        rs = s.wait_rows(lambda rs: self.above(topic, later, rs) and key not in s.ids(rs),
                         'the new Topic did not take the place of the Guest Session that its Window ended')
        self.assertIn('Guest', s.row(topic, rs).get('accessibilityValue', ''), self.describe(topic, rs))
        self.assertEqual(self.lock(later_lock)['order'], 9, 'the other Guest Session moved')

    def test_a_guest_session_that_ends_on_the_same_server_ends_its_card_and_its_lock(self):
        s = self.s
        sid, key, lock_id = self.guest_session('kill-guest-notes', 4)
        self.end_session(sid)
        s.wait_rows(lambda rs: not s.has(key, rs), 'the card stayed after its Guest Session ended')
        wait(lambda: self.lock(lock_id) is None, 'the Lock stayed after its Guest Session ended on the same server', seconds=10)


if __name__ == '__main__':
    unittest.main()
