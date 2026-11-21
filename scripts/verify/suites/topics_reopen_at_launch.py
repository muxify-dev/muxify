"""Reopen at launch (`topics.reopen_at_launch`): a launch on a tmux server with none of the user's Sessions Reopens
every Dormant open Topic, and never a Settled or Empty one.

ReopenAtLaunchTests proves the rule without the key and after a tmux restart while Muxify runs.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_reopen_at_launch
"""

import json
import time
import unittest
import uuid

from scripts.verify.sandbox import Sandbox, wait

LAUNCH_ARGS = ['-sidebarVisible', 'YES']


def remembered(topic_id, folder):
    """A Session that the Topic remembers, with two Windows."""
    return {'id': str(uuid.uuid4()), 'name': 'work/' + topic_id, 'directory': folder,
            'windows': [{'name': 'editor', 'directory': folder}, {'name': 'logs', 'directory': folder}]}


def launch(test_case):
    """A sandbox whose records hold a Dormant Pinned Topic, a Dormant one In Play, a Settled one that remembers a
    Session and an Empty one, launched with reopen_at_launch on and no tmux server running."""
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
        wait(lambda: {'work/pinned', 'work/alpha'} <= set(sessions(cls.s)),
             lambda: 'the Dormant Topics were not Reopened: %s' % sessions(cls.s), seconds=30)

    def test_a_launch_reopens_every_dormant_topic_with_its_windows(self):
        found = sessions(self.s)
        self.assertEqual(found.get('work/pinned'), 2, found)
        self.assertEqual(found.get('work/alpha'), 2, found)

    def test_a_launch_reopens_no_settled_or_empty_topic_and_opens_no_start_a_session_palette(self):
        time.sleep(2)
        self.assertEqual(set(sessions(self.s)), {'work/pinned', 'work/alpha'})
        self.assertFalse(self.s.has('palette-search'), 'the Start a Session palette opened')

