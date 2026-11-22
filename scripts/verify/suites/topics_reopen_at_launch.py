"""Reopen at launch (`topics.reopen_at_launch`): a launch on a tmux server with none of the user's Sessions Reopens
every Dormant open Topic and every Dormant Guest Session, and never a Settled or Empty Topic.

ReopenAtLaunchTests proves the rule without the key and after a tmux restart while Muxify runs.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_reopen_at_launch
"""

import json
import time
import unittest
import uuid

from scripts.verify.sandbox import Sandbox, wait
from scripts.verify.topic_records import TopicRecords

LAUNCH_ARGS = ['-sidebarVisible', 'YES']


def remembered(topic_id, folder):
    """A Session that the Topic remembers, with two Windows."""
    return {'id': str(uuid.uuid4()), 'name': 'work/' + topic_id, 'directory': folder,
            'windows': [{'name': 'editor', 'directory': folder}, {'name': 'logs', 'directory': folder}]}


GUEST = 'guest-notes'


def launch(test_case):
    """A sandbox whose records hold a Dormant Pinned Topic, a Dormant one In Play, a Settled one that remembers a
    Session and an Empty one, and the Lock of a Guest Session `notes` with two Windows, launched with reopen_at_launch on
    and no tmux server running."""
    s = Sandbox(test_case.__module__.rsplit('.', 1)[-1])
    test_case.addClassCleanup(s.teardown)
    folder = s.root/'work'
    folder.mkdir()
    records = [
        {'id': 'pinned', 'title': 'Pinned', 'slug': 'pinned', 'order': 0, 'pinned': True,
         'sessions': [remembered('pinned', str(folder))]},
        {'id': 'alpha', 'title': 'Alpha', 'slug': 'alpha', 'order': 1, 'sessions': [remembered('alpha', str(folder))]},
        {'id': 'settled', 'title': 'Settled', 'slug': 'settled', 'order': 2, 'settled_at': '2026-11-02T10:00:00Z',
         'sessions': [remembered('settled', str(folder))]},
        {'id': 'empty', 'title': 'Empty', 'slug': 'empty', 'order': 3},
    ]
    (s.root/'state/muxify/topics.json').write_text(json.dumps({'records': records, 'open_places': []}))
    TopicRecords(s.root/'state/muxify').put_board_session({'id': GUEST, 'order': 4, 'session': {
        'id': GUEST, 'name': 'notes', 'base_name': 'notes', 'directory': str(folder),
        'windows': [{'name': 'notes', 'directory': str(folder)}, {'name': 'scratch', 'directory': str(folder)}]}})
    (s.root/'config/muxify/config.yaml').write_text('topics:\n  reopen_at_launch: true\n')
    s.launch(LAUNCH_ARGS)
    return s


def sessions(s):
    """Each Session on the sandbox server, by name, with its Window count; none when no server runs."""
    try:
        lines = s.tmux('list-sessions', '-F', '#{session_name} #{session_windows}').splitlines()
    except Exception:
        return {}
    return {name: int(count) for name, count in (line.rsplit(' ', 1) for line in lines)}


class ReopenAtLaunchOn(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = launch(cls)
        # Reopen makes each Session first and its other Windows with later tmux commands, so wait for the Windows too.
        wait(lambda: all(sessions(cls.s).get(name) == 2 for name in ('work/pinned', 'work/alpha', 'notes')),
             lambda: 'the Dormant Topics and Guest Session were not Reopened with their Windows: %s' % sessions(cls.s), seconds=30)

    def test_a_launch_reopens_every_dormant_topic_with_its_windows(self):
        found = sessions(self.s)
        self.assertEqual(found.get('work/pinned'), 2, found)
        self.assertEqual(found.get('work/alpha'), 2, found)

    def test_a_launch_reopens_a_dormant_guest_session_with_its_windows_and_its_lock(self):
        found = sessions(self.s)
        self.assertEqual(found.get('notes'), 2, found)
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=notes:', '@muxify_session_id'), GUEST,
                         'the Reopened Session does not point at its Lock')
        card = 'locked-' + GUEST
        self.s.wait_rows(lambda rs: self.s.has(card, rs) and 'Dormant' not in self.s.row(card, rs).get('accessibilityValue', ''),
                         lambda: 'the Guest Session has no live card: %s' % next(
                             (r for r in self.s.rows() if r.get('accessibilityIdentifier') == card), 'no card'))

    def test_a_launch_reopens_no_settled_or_empty_topic_and_opens_no_start_a_session_palette(self):
        time.sleep(2)
        self.assertEqual(set(sessions(self.s)), {'work/pinned', 'work/alpha', 'notes'})
        self.assertFalse(self.s.has('palette-search'), 'the Start a Session palette opened')

