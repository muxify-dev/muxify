"""Colour Reports (ADR 0095) before Reopen types an Agent's resume command: an Agent in a Reopened Session that the
Terminal does not show gets Muxify's colours as the answer to OSC 11. Without the report, tmux answers nothing there.

The Agent is a `claude` on PATH that runs `fixtures/colour_probe.py`, which logs each answer to the file that the
conversation id names.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.colour_report_reopen
"""

import json
import sys
import unittest
import uuid

from scripts.verify.sandbox import REPO, Sandbox, wait

PROBE = REPO/'scripts/verify/fixtures/colour_probe.py'


class ColourReportReopen(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        folder = s.root/'work'
        folder.mkdir()
        claude = s.root/'bin/claude'
        claude.parent.mkdir()
        claude.write_text('#!/bin/sh\nexec %s %s "$2"\n' % (sys.executable, PROBE))
        claude.chmod(0o755)
        s.app_env['PATH'] = '%s:%s' % (claude.parent, s.app_env['PATH'])

        def session(name):
            pane = {'directory': str(folder), 'active': True, 'agent': 'claude',
                    'agent_conversation': str(s.root/(name + '.log'))}
            return {'id': str(uuid.uuid4()), 'name': 'work/' + name, 'directory': str(folder),
                    'windows': [{'name': 'agent', 'directory': str(folder), 'panes': [pane]}]}
        records = [{'id': 'colours', 'title': 'Colours', 'slug': 'colours', 'order': 0, 'pinned': True,
                    'sessions': [session('shown'), session('hidden')]}]
        (s.root/'state/muxify/topics.json').write_text(json.dumps({'records': records, 'open_places': []}))
        (s.root/'config/muxify/config.yaml').write_text('topics:\n  reopen_at_launch: true\n')
        s.launch(['-sidebarVisible', 'YES'])

    def answers(self, name):
        log = self.sandbox.root/(name + '.log')
        return [line.split()[1] for line in log.read_text().splitlines() if line.startswith('answer ')] if log.exists() else []

    def test_an_agent_in_a_reopened_session_that_no_client_shows_gets_muxifys_colours(self):
        clients = lambda: self.sandbox.tmux('list-clients', '-F', '#{client_control_mode} #{session_name}').splitlines()
        shown = wait(lambda: next((line.split(' ', 1)[1] for line in clients() if line.startswith('0 ')), None),
                     'the Terminal did not attach')
        hidden = 'hidden' if shown == 'work/shown' else 'shown'
        muxify = wait(lambda: self.answers(shown.split('/')[1])[-1:], 'the shown Agent got no answer')[0]

        wait(lambda: self.answers(hidden)[-1:], lambda: 'the hidden Agent got no answer: %s' % clients())
        self.assertEqual(set(self.answers(hidden)), {muxify})
        self.assertEqual(clients().count('0 work/' + hidden), 0, 'a Client shows the hidden Session')


if __name__ == '__main__':
    unittest.main()
