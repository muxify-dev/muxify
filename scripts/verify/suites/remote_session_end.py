"""The end of a Remote Environment's Session: when its last Window closes, the Terminal opens another Session of that
Environment, and Muxify closes when no Session is left.

The SSH fixture runs remote commands locally, so the Remote Environment's tmux server is the Sandbox server.
"""

import shlex
import time
import unittest

from scripts.verify.sandbox import Sandbox, alive, wait


class RemoteSessionEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        home = s.root/'remote-home'
        home.mkdir()
        remote_tmp = s.root/'remote-tmp'
        remote_tmp.mkdir()
        (s.root/'config/muxify/config.yaml').write_text(
            'remote_environments:\n  - name: Fixture\n    host: unused\n    username: unused\n')
        fake = s.root/'ssh'
        fake.write_text('''#!/bin/bash
unset TMUX TMUX_PANE XDG_CONFIG_HOME XDG_STATE_HOME
export TMUX_TMPDIR=%s TMPDIR=%s HOME=%s
for arg do
    if [ "$arg" = -O ]; then exit 0; fi
    # The remote PTY of ssh -tt merges stderr into stdout, where the Terminal reads the snapshot that the remote
    # tmux reports on exit.
    if [ "$arg" = -tt ]; then exec 2>&1; fi
    command=$arg
done
exec /bin/sh -c "$command"
''' % tuple(shlex.quote(str(p)) for p in [s.root/'tmux', remote_tmp, home]))
        fake.chmod(0o755)
        s.app_env['MUXIFY_TEST_SSH'] = str(fake)

    def setUp(self):
        # A check that closes the last Session also closes Muxify, so each check starts its own app when none runs.
        if self.s.pid is None or not alive(self.s.pid):
            self.s.tmux_ok('new-session', '-d', '-s', 'start', '/bin/sh')
            self.s.launch(args=('-selectedEnvironment', 'Fixture'))
        self.client()

    def client(self):
        """The tty of the Terminal's Client, and its Session."""
        def attached():
            listed = self.s.tmux_ok('list-clients', '-F', '#{client_control_mode}|#{client_tty}|#{session_name}').stdout
            return next((line.split('|')[1:] for line in listed.splitlines() if line.startswith('0|')), None)
        return wait(attached, 'the Terminal\'s Client is not attached to the Remote Environment')

    def open_alone(self, session):
        """Makes a Session with one Window, moves the Terminal's Client to it and waits until the app shows it."""
        window = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', session, '/bin/sh')
        tty, _ = self.client()
        self.s.tmux('switch-client', '-c', tty, '-t', window)
        wait(lambda: self.s.row('header-session-name').get('accessibilityValue') == session,
             lambda: 'the app does not show %s: it shows %s' % (session, self.s.row('header-session-name')))
        return window

    def test_closing_the_last_window_of_a_session_opens_another_session(self):
        survivor = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_name}', '-s', 'survivor', '/bin/sh')
        window = self.open_alone('ending')
        self.s.tmux('kill-window', '-t', window)
        sessions = set(self.s.tmux('list-sessions', '-F', '#{session_name}').split())
        self.assertIn(survivor, sessions)
        tty, session = wait(lambda: (lambda c: c if c[1] in sessions else None)(self.client()),
                            'the Terminal did not open another Session after ending closed', 20)
        self.assertNotEqual(session, 'ending')
        self.assertTrue(alive(self.s.pid), 'Muxify closed although Sessions are left')

    def test_closing_the_last_window_of_the_last_session_closes_muxify(self):
        window = self.open_alone('last')
        for other in self.s.tmux('list-sessions', '-F', '#{session_name}').split():
            if other not in ('last', 'muxify-watch'):
                self.s.tmux('kill-session', '-t', other)
        self.s.tmux('kill-window', '-t', window)
        wait(lambda: not alive(self.s.pid), 'Muxify did not close after the last Session closed', 20)

    def test_a_detach_keeps_the_session_and_opens_no_other(self):
        self.s.tmux('new-session', '-d', '-s', 'other', '/bin/sh')
        self.open_alone('detached')
        tty, _ = self.client()
        self.s.tmux('detach-client', '-t', tty)
        wait(lambda: any(r.get('accessibilityValue') == 'Detached from remote tmux.' for r in self.s.rows()),
             'the app does not show the detach')
        time.sleep(3)
        clients = self.s.tmux_ok('list-clients', '-F', '#{client_control_mode}').stdout.split()
        self.assertNotIn('0', clients, 'a detach opened another Session')
        self.assertTrue(alive(self.s.pid), 'a detach closed Muxify')
        self.s.act('press', 'retry-connection')
        self.client()
