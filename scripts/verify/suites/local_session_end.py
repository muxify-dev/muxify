"""The end of a Local Session: when its last Window closes, the Terminal opens another Session, and Muxify closes when
no Session is left."""

import os
import signal
import time
import unittest

from scripts.verify.sandbox import Sandbox, alive, wait


class LocalSessionEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(cls.s.teardown)
        cls.s.app_env['SHELL'] = '/bin/sh'

    def setUp(self):
        # A check that closes the last Session also closes Muxify, so each check starts its own app when none runs.
        if self.s.pid is None or not alive(self.s.pid):
            self.s.tmux_ok('new-session', '-d', '-s', 'start', '-c', str(self.s.root), '/bin/sh')
            self.s.launch()
        self.client()

    def client(self):
        """The tty of the Terminal's Client, and its Session."""
        def attached():
            listed = self.s.tmux_ok('list-clients', '-F', '#{client_control_mode}|#{client_tty}|#{session_name}').stdout
            return next((line.split('|')[1:] for line in listed.splitlines() if line.startswith('0|')), None)
        return wait(attached, 'the Terminal\'s Client is not attached')

    def stop_app(self):
        if alive(self.s.pid):
            os.kill(self.s.pid, signal.SIGKILL)
            wait(lambda: not alive(self.s.pid), 'app %d still runs after SIGKILL' % self.s.pid, seconds=5)

    def open_alone(self, session):
        """Makes a Session with one Window and shows it."""
        window = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', session, '-c', str(self.s.root),
                             '/bin/sh')
        self.s.show(window)
        return window

    def test_closing_the_last_window_of_a_session_opens_another_session(self):
        self.s.tmux('new-session', '-d', '-s', 'survivor', '-c', str(self.s.root), '/bin/sh')
        window = self.open_alone('ending')
        self.s.tmux('kill-window', '-t', window)
        sessions = set(self.s.tmux('list-sessions', '-F', '#{session_name}').split()) - {'muxify-watch'}
        wait(lambda: self.client()[1] in sessions, 'the Terminal did not open another Session after ending closed')
        self.assertTrue(alive(self.s.pid), 'Muxify closed although Sessions are left')

    def test_closing_the_last_window_of_the_last_session_closes_muxify(self):
        window = self.open_alone('last')
        for other in self.s.tmux('list-sessions', '-F', '#{session_name}').split():
            if other not in ('last', 'muxify-watch'):
                self.s.tmux('kill-session', '-t', '=' + other)
        self.s.tmux('kill-window', '-t', window)
        wait(lambda: not alive(self.s.pid), 'Muxify did not close after the last Session closed')

    def test_a_detach_keeps_the_session_and_opens_no_other(self):
        # The next check needs an attached Terminal; setUp starts the app again when it is gone.
        self.addCleanup(self.stop_app)
        self.s.tmux('new-session', '-d', '-s', 'other', '-c', str(self.s.root), '/bin/sh')
        self.open_alone('detached')
        tty, _ = self.client()
        self.s.tmux('detach-client', '-t', tty)
        wait(lambda: any(r.get('accessibilityValue') == 'Detached from tmux' for r in self.s.rows()),
             'the app does not show the detach')
        time.sleep(3)
        clients = self.s.tmux_ok('list-clients', '-F', '#{client_control_mode}').stdout.split()
        self.assertNotIn('0', clients, 'a detach opened another Session')
        self.assertTrue(alive(self.s.pid), 'a detach closed Muxify')

    def test_a_stopped_server_keeps_muxify_open(self):
        # The next check needs an attached Terminal; setUp starts the app again when it is gone.
        self.addCleanup(self.stop_app)
        self.open_alone('stopped')
        socket = self.s.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(socket.startswith(str(self.s.root)) or socket.startswith('/private' + str(self.s.root)), socket)
        self.s.tmux('kill-server')
        wait(lambda: any(r.get('accessibilityValue') == 'tmux server is not running' for r in self.s.rows()),
             'the app does not show that the server stopped')
        self.assertTrue(alive(self.s.pid), 'a stopped server closed Muxify')
