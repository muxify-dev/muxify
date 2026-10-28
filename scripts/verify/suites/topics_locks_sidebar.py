"""Locked Sessions in the Topics list (ADR 0018): Lock, Unlock, New Topic from a Locked Session and Kill.

The Session card header in UI/SidebarView.swift gives "Lock Session" as an accessibility action, and the Locked card
header gives "Unlock Session" and "New Topic from this Session", so the checks reach them without a context menu.

The fixture and the helpers that several suites use are in scripts/verify/topics_sidebar.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_locks_sidebar
"""

import json
import unittest

from scripts.verify.sandbox import frame, remove_topic, wait
from scripts.verify.topics_sidebar import TopicsSidebar


class TopicsLocksSidebar(TopicsSidebar):
    def lock_option(self, sid):
        return self.s.tmux('show-options', '-qv', '-t', sid, '@muxify_lock')

    def above(self, upper, lower, rs):
        return self.s.has(upper, rs) and self.s.has(lower, rs) and frame(self.s.row(upper, rs))[1] > frame(self.s.row(lower, rs))[1]

    def locked_session(self, name, order):
        """A No Topic Session that is already Locked at `order`, as tmux keeps a Lock; returns (session id, card key)."""
        sid = self.new_session(name, self.beta)
        self.s.tmux('set-option', '-t', sid, '@muxify_lock', str(order))
        key = 'locked-' + sid
        self.find(key, 'no Locked card for ' + name)
        return sid, key

    def test_lock_gives_a_card_after_the_unpinned_topics_and_sets_the_session_option(self):
        s = self.s
        self.write_topic('lock-first', 'Lock first', self.beta, order=0)
        self.write_topic('lock-last', 'Lock last', self.beta, order=1)
        self.write_topic('lock-pinned', 'Lock pinned', self.beta, order=0, pinned=True)
        sid = self.new_session('lock-notes', self.beta)
        self.select_window(sid + ':')
        card = 'no-topic-session-' + sid
        self.find(card, 'the selected No Topic Session has no card')
        s.act('action', card, 'Lock Session')

        key = 'locked-' + sid
        rs = self.find(key, 'Lock gave the Session no Locked card')
        rs = s.wait_rows(lambda rs: self.above('topic-lock-last', key, rs) and self.above('topic-lock-pinned', 'topic-lock-first', rs),
                         'the Locked card is not after the Topics that are not Pinned')
        value = s.row(key, rs).get('accessibilityValue', '')
        self.assertIn('Locked', value, self.describe(key, rs))
        self.assertTrue(value.startswith('expanded'), 'the Locked card of the Active Session is not open: ' + value)
        self.assertNotIn(card, s.ids(rs), 'the Session still has the No Topic card')
        order = wait(lambda: self.lock_option(sid), 'Lock did not set @muxify_lock')
        self.assertGreater(float(order), 1, '@muxify_lock %s is not after the last Topic' % order)

        self.show_view('sessions')
        rs = self.find('session-' + sid)
        self.assertIn('Locked', s.row('session-' + sid, rs).get('accessibilityValue', ''), self.describe('session-' + sid, rs))
        self.show_view('topics')

    def test_unlock_removes_the_card_and_the_session_option(self):
        s = self.s
        sid, key = self.locked_session('unlock-notes', 7)
        s.act('action', key, 'Unlock Session')
        s.wait_rows(lambda rs: not s.has(key, rs), 'Unlock kept the Locked card')
        wait(lambda: self.lock_option(sid) == '', 'Unlock kept @muxify_lock', seconds=10)

    def test_new_topic_from_a_locked_session_takes_its_place_and_removes_the_option(self):
        s = self.s
        self.write_topic('take-upper', 'Take upper', self.beta, order=0)
        self.write_topic('take-lower', 'Take lower', self.beta, order=2)
        sid, key = self.locked_session('take-notes', 1)
        s.wait_rows(lambda rs: self.above('topic-take-upper', key, rs) and self.above(key, 'topic-take-lower', rs),
                    'the Locked card is not between the two Topics')
        before = set(self.records())
        s.act('action', key, 'New Topic from this Session')
        s.wait_rows(lambda rs: s.has('palette-row-new-topic', rs), 'New Topic from this Session did not open Move')
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', 'Taken place')
        s.wait_rows(lambda rs: 'Taken place' in s.row('palette-row-new-topic', rs).get('accessibilityLabel', ''),
                    'the New Topic row does not show the typed title')
        s.act('press', 'palette-row-new-topic')
        record = wait(lambda: next((r for i, r in self.records().items() if i not in before and r.get('title') == 'Taken place'), None),
                      'no Topic record for the Locked Session')
        self.addCleanup(remove_topic, self.topics_dir/(record['id'] + '.json'))
        self.assertEqual(record.get('order'), 1, json.dumps(record))
        wait(lambda: self.lock_option(sid) == '', 'the Topic made from the Locked Session kept @muxify_lock', seconds=10)
        self.assertEqual(s.tmux('show-options', '-qv', '-t', sid, '@muxify_topic'), record['id'])
        topic = 'topic-' + record['id']
        s.wait_rows(lambda rs: self.above('topic-take-upper', topic, rs) and self.above(topic, 'topic-take-lower', rs)
                    and key not in s.ids(rs), 'the new Topic did not take the place of the Locked card')

    def test_killing_a_locked_session_removes_its_card(self):
        s = self.s
        sid, key = self.locked_session('kill-lock-notes', 4)
        self.end_session(sid)
        s.wait_rows(lambda rs: not s.has(key, rs), 'the Locked card stayed after its Session ended')


if __name__ == '__main__':
    unittest.main()
