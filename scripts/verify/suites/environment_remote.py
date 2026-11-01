"""Copied Remote watch uses Remote records and reuses its installed build."""

import hashlib
import json
import os

from scripts.verify.sandbox import wait
from scripts.verify.suites.environment_browser import RemoteEnvironmentFixture
from scripts.verify.topic_records import TopicRecords


class EnvironmentRemote(RemoteEnvironmentFixture):
    @classmethod
    def prepare_remote(cls, local, remote, home, fake):
        cls.install_root = home/'.local/share/muxify/bin'
        for index in (1, 2):
            directory = cls.install_root/(str(index) * 64)
            directory.mkdir(parents=True)
            (directory/'muxify').write_text('old build')
            os.utime(directory, (index, index))

    def test_remote_topics_install_reuse_and_cleanup(self):
        s = self.local
        binary = s.app/'Contents/Resources/bin/muxify'
        version = hashlib.sha256(binary.read_bytes()).hexdigest()
        installed = self.install_root/version/'muxify'
        self.assertEqual(installed.read_bytes(), binary.read_bytes())
        self.assertEqual({p.name for p in self.install_root.iterdir()}, {'2' * 64, version})
        before = installed.stat().st_mtime_ns
        s.act('press', 'New Topic…')
        s.wait_rows(lambda rows: s.has('palette-search', rows), 'Remote New Topic did not open')
        s.act('focus', 'palette-search')
        s.act('set', 'palette-search', 'Remote record only')
        s.act('press', 'palette-accept')
        remote = TopicRecords(self.remote.root/'state/muxify')
        record = wait(lambda: next((r for r in remote.records().values() if r.get('title') == 'Remote record only'), None),
                      'Remote Topic was not saved on the Remote machine')
        self.assertFalse(any(r.get('title') == 'Remote record only' for r in TopicRecords(s.root/'state/muxify').records().values()))
        s.wait_rows(lambda rows: 'Add a Session' in str(s.row('palette-breadcrumb', rows)),
                    'Remote Topic receipt did not reach its presentation')
        s.act('press', 'palette-cancel')
        s.wait_rows(lambda rows: s.row('empty-topic-title', rows).get('accessibilityValue') == record['title'],
                    'Remote Empty Topic page did not show')
        s.restart_app(args=('-selectedEnvironment', 'Fixture'))
        s.wait_rows(lambda rows: any('Connected to Fixture' in str(row.get('accessibilityValue', '')) for row in rows),
                    'Remote did not reconnect')
        self.assertEqual(installed.stat().st_mtime_ns, before, 'Reconnect copied an installed build again')
        s.wait_rows(lambda rows: s.has('topic-' + record['id'], rows), 'Remote Topic did not survive reconnect')
        s.act('action', 'client-input', 'Close App Window')
        wait(lambda: not self.remote.tmux('list-clients', '-F', '#{client_tty}').strip(),
             'Remote watch or Terminal Client survived App Window close')
