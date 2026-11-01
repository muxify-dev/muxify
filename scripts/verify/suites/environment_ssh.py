"""The copied watch uses a private OpenSSH server and the Terminal's master."""

import getpass
import json
import os
import shlex
import socket
import signal
import subprocess

from scripts.verify.suites.environment_browser import RemoteEnvironmentFixture
from scripts.verify.sandbox import wait
from scripts.verify.topic_records import TopicRecords


class EnvironmentSSH(RemoteEnvironmentFixture):
    @classmethod
    def prepare_remote(cls, local, remote, home, fake):
        root = remote.root
        key, host_key = root/'client-key', root/'host-key'
        for path in (key, host_key):
            subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path)],
                           check=True, capture_output=True)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        wrapper = root/'remote-command'
        wrapper.write_text('''#!/bin/sh
unset TMUX TMUX_PANE MUXIFY_CONFIG
export TMUX_TMPDIR=%s TMPDIR=%s HOME=%s XDG_CONFIG_HOME=%s XDG_STATE_HOME=%s
exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
''' % tuple(shlex.quote(str(p)) for p in [root/'tmux', root, home, root/'config', root/'state']))
        wrapper.chmod(0o700)
        authorized = root/'authorized_keys'
        authorized.write_text('command="%s" %s' % (wrapper, key.with_suffix('.pub').read_text()))
        config = root/'sshd_config'
        config.write_text('''Port %d
ListenAddress 127.0.0.1
HostKey %s
PidFile %s
AuthorizedKeysFile %s
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers %s
LogLevel VERBOSE
''' % (port, host_key, root/'sshd.pid', authorized, getpass.getuser()))
        log = open(root/'sshd.log', 'w')
        cls.addClassCleanup(log.close)
        environment = dict(remote.env)
        environment.pop('TMUX', None)
        environment.pop('TMUX_PANE', None)
        daemon = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], env=environment,
                                  stdout=log, stderr=subprocess.STDOUT)
        cls.addClassCleanup(lambda: remote._terminate([daemon.pid]) if daemon.poll() is None else None)
        def listening():
            if daemon.poll() is not None:
                raise AssertionError('Isolated sshd failed: ' + (root/'sshd.log').read_text())
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    return True
            except OSError:
                return False
        wait(listening, 'Isolated sshd did not listen')
        known_hosts = root/'known_hosts'
        known_hosts.write_text('[127.0.0.1]:%d %s' % (port, host_key.with_suffix('.pub').read_text()))
        fake.write_text('''#!/bin/sh
unset TMUX TMUX_PANE
exec /usr/bin/ssh -F /dev/null -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes "$@"
''' % shlex.quote(str(known_hosts)))
        (local.root/'config/muxify/config.yaml').write_text('''remote_environments:
  - name: Fixture
    host: 127.0.0.1
    username: %s
    port: %d
    identity_file: %s
''' % (getpass.getuser(), port, key))
        cls.daemon = daemon

    def test_master_loss_stops_watch_and_reconnects_without_recopy(self):
        s = self.local
        installed = next((self.remote.root/'home/.local/share/muxify/bin').glob('*/muxify'))
        stamp = installed.stat().st_mtime_ns
        s.act('press', 'browser-new-tab')
        wait(lambda: self.tabs(self.remote) == ['https://remote.invalid/', 'about:blank'],
             'The SSH watch did not save Remote Browser state')
        rows = [line.split(None, 2) for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,comm='], text=True).splitlines()]
        children = [int(pid) for pid, parent, command in rows if int(parent) == self.daemon.pid and 'sshd' in command]
        self.assertTrue(children, 'The fixture has no SSH connection to interrupt')
        for pid in children:
            os.kill(pid, signal.SIGKILL)
        s.wait_rows(lambda rows: any('Reconnecting' in str(row.get('accessibilityValue', ''))
                                    or 'Connecting' in str(row.get('accessibilityValue', '')) for row in rows),
                    'The app did not detect loss of its SSH master')
        s.wait_rows(lambda rows: any('Connected to Fixture' in str(row.get('accessibilityValue', '')) for row in rows),
                    'The Terminal did not acquire a replacement master')
        self.assertEqual(installed.stat().st_mtime_ns, stamp)
        self.assertEqual(self.tabs(self.remote), ['https://remote.invalid/', 'about:blank'])
        records = TopicRecords(self.remote.root/'state/muxify')
        records.put(dict(id='last-session', title='Last Session', slug='last-session', sessions=[]))
        self.remote.tmux('set-option', '-t', '$0', '@muxify_topic', 'last-session')
        s.wait_rows(lambda rows: s.has('topic-last-session', rows), 'Remote Topic did not appear')
        s.act('action', 'topic-last-session', 'Forget Topic…')
        s.wait_rows(lambda rows: s.has('palette-row-session-$0', rows) and s.has('palette-accept', rows),
                    'Remote Forget query did not list the last Session')
        self.assertTrue(self.remote.tmux('display-message', '-p', '#{socket_path}').startswith(str(self.remote.root) + '/'))
        s.act('press', 'palette-accept')
        wait(lambda: records.get('last-session') is None, 'Forget killed its Client before removing the Topic record')
        wait(lambda: self.remote.tmux_ok('has-session').returncode != 0,
             'Forget retained the last Remote Session')
