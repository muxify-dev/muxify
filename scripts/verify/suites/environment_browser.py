"""Remote Browser writes and final persistence use the Remote server only."""

import json
import subprocess
import shlex
import unittest

from scripts.verify.sandbox import Sandbox, wait
from scripts.verify.topic_records import TopicRecords


class RemoteEnvironmentFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.local = local = Sandbox(cls.__module__.rsplit('.', 1)[-1])
        cls.addClassCleanup(local.teardown)
        cls.remote = remote = Sandbox(cls.__module__.rsplit('.', 1)[-1] + '_server')
        cls.addClassCleanup(remote.teardown)
        home = remote.root/'home'
        home.mkdir()
        (local.root/'config/muxify/config.yaml').write_text(
            'remote_environments:\n  - name: Fixture\n    host: unused\n    username: unused\n')
        fake = local.root/'ssh'
        fake.write_text('''#!/bin/bash
unset TMUX TMUX_PANE MUXIFY_CONFIG
export TMUX_TMPDIR=%s TMPDIR=%s HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s
for arg do
    if [ "$arg" = -O ]; then exit 0; fi
    command=$arg
done
exec /bin/sh -c "$command"
''' % tuple(shlex.quote(str(p)) for p in [remote.root/'tmux', remote.root, home, remote.root/'config', remote.root/'state']))
        fake.chmod(0o755)
        local.app_env['MUXIFY_TEST_SSH'] = str(fake)
        cls.prepare_remote(local, remote, home, fake)
        for sandbox, url in [(local, 'https://local.invalid/'), (remote, 'https://remote.invalid/')]:
            sandbox.tmux('new-session', '-d', '-s', 'browser', '/bin/sh')
            sandbox.tmux('set-option', '-w', '-t', '@0', '@muxify_tabs', url,
                         ';', 'set-option', '-w', '-t', '@0', '@muxify_browser', 'on')
        local.launch(args=('-selectedEnvironment', 'Fixture'))
        local.wait_rows(lambda rows: any('Connected to Fixture' in str(row.get('accessibilityValue', ''))
                                         for row in rows), 'Remote Environment did not connect')
        local.wait_rows(lambda rows: local.has('browser-new-tab', rows), 'Remote Browser did not show')

    @classmethod
    def prepare_remote(cls, local, remote, home, fake):
        pass

    def tabs(self, server):
        return server.tmux('show-option', '-wqv', '-t', '@0', '@muxify_tabs').split()


class EnvironmentBrowser(RemoteEnvironmentFixture):
    def test_remote_browser_and_final_save_leave_local_unchanged(self):
        self.assertEqual(self.local.tmux('display-message', '-p', '-t', '@0', '#{window_id}'),
                         self.remote.tmux('display-message', '-p', '-t', '@0', '#{window_id}'))
        self.local.act('press', 'browser-new-tab')
        expected = ['https://remote.invalid/', 'about:blank']
        wait(lambda: self.tabs(self.remote) == expected, 'Remote Browser did not save its new Tab')
        self.assertEqual(self.tabs(self.local), ['https://local.invalid/'])
        self.local.act('action', 'client-input', 'New Tab and Close App Window')
        expected.append('about:blank')
        wait(lambda: self.tabs(self.remote) == expected, 'App Window close lost its final Browser state')
        wait(lambda: not self.remote.tmux('list-clients', '-F', '#{client_tty}').strip(),
             'Closed App Window retained its Remote Client')
        self.assertEqual(self.tabs(self.local), ['https://local.invalid/'])


class EnvironmentTopicURL(RemoteEnvironmentFixture):
    def test_topic_url_starts_local_and_keeps_the_request(self):
        subprocess.run(['open', '-g', '-a', str(self.local.app),
                        'muxify://topic/new?title=Queued%20before%20Local'], check=True, capture_output=True)
        def created_topic():
            for record in TopicRecords(self.local.root/'state/muxify').records().values():
                if record.get('title') == 'Queued before Local':
                    return record
        record = wait(created_topic, 'Topic URL was lost before the Local connection started')
        self.assertEqual(record.get('sessions', []), [])


class EnvironmentLocalClocks(RemoteEnvironmentFixture):
    def test_remote_only_app_window_wakes_local_topic(self):
        import datetime
        records = TopicRecords(self.local.root/'state/muxify')
        deadline = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=3)
        records.put(dict(id='remote-clock', title='Local clock', sessions=[],
                         snoozed_until=deadline.isoformat().replace('+00:00', 'Z')))
        wait(lambda: records.get('remote-clock').get('snoozed_until') is None,
             'Local Snooze did not wake while only the Remote App Window was open', seconds=10)
        self.assertEqual(records.get('remote-clock')['title'], 'Local clock')
