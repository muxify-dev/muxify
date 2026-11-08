"""Reopen at launch (`topics.reopen_at_launch`): a launch on a tmux server with none of the user's Sessions Reopens
every Dormant open Topic, and never a Settled or Empty one. A tmux restart while Muxify runs Reopens nothing.

Each class launches its own app on a fresh throwaway server, because a check here changes what the launch left.

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


def launch(test_case, reopen_at_launch):
    """A sandbox whose records hold a Dormant Pinned Topic, a Dormant one In Play, a Settled one that remembers a
    Session and an Empty one, launched with no tmux server running."""
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
    if reopen_at_launch is not None:
        (s.root/'config/muxify/config.yaml').write_text('topics:\n  reopen_at_launch: %s\n' % reopen_at_launch)
    s.launch(LAUNCH_ARGS)
    return s


def sessions(s):
    """Each Session of the user's on the sandbox server, by name, with its Window count; none when no server runs."""
    try:
        lines = s.tmux('list-sessions', '-F', '#{session_name} #{session_windows}').splitlines()
    except Exception:
        return {}
    return {name: int(count) for name, count in (line.rsplit(' ', 1) for line in lines) if name != 'muxify-watch'}


class ReopenAtLaunchOn(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = launch(cls, 'true')
        wait(lambda: {'work/pinned', 'work/alpha'} <= set(sessions(cls.s)),
             lambda: 'the Dormant Topics were not Reopened: %s' % sessions(cls.s), seconds=30)

    def test_a_launch_reopens_every_dormant_topic_with_its_windows(self):
        found = sessions(self.s)
        self.assertEqual(found.get('work/pinned'), 2, found)
        self.assertEqual(found.get('work/alpha'), 2, found)

    def test_a_launch_reopens_no_settled_or_empty_topic(self):
        time.sleep(2)
        self.assertEqual(set(sessions(self.s)), {'work/pinned', 'work/alpha'})

    def test_start_a_session_does_not_open_once_topics_were_reopened(self):
        time.sleep(2)
        self.assertFalse(self.s.has('palette-search'), 'the Start a Session palette opened')


class ReopenAtLaunchOnce(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = launch(cls, 'true')
        wait(lambda: {'work/pinned', 'work/alpha'} <= set(sessions(cls.s)),
             lambda: 'the Dormant Topics were not Reopened: %s' % sessions(cls.s), seconds=30)

    def test_a_tmux_restart_while_muxify_runs_reopens_nothing(self):
        self.s.tmux_ok('kill-server')
        wait(lambda: not sessions(self.s), 'the tmux server did not stop')
        self.s.tmux('new-session', '-d', '-s', 'other', '-c', str(self.s.root))
        time.sleep(5)
        self.assertEqual(set(sessions(self.s)), {'other'})


class ReopenAtLaunchOff(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = launch(cls, None)

    def test_without_the_key_a_launch_reopens_no_topic(self):
        time.sleep(5)
        self.assertEqual(sessions(self.s), {})
