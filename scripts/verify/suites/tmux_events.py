"""The tmux control client that tells the app about tmux changes.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.tmux_events
"""

import os
import signal
import subprocess
import threading
import time
import unittest

from scripts.verify.sandbox import Sandbox, alive, wait

# tmux 3.7c keeps a control client whose input closes while the server writes
# notifications to it, and then its server cannot exit. A flood of Window
# renames across the kill makes that race likely.
RENAMERS = 16


class TmuxEvents(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        # No tmux server at launch: the app starts one with its own Session.
        s.launch()

    def setUp(self):
        # A check that kills the app leaves the next one without it.
        if not alive(self.s.pid):
            self.s.launch()

    def control_clients(self):
        listing = self.s.tmux_ok('list-clients', '-F', '#{client_pid} #{client_control_mode}').stdout.split('\n')
        return [int(line.split()[0]) for line in listing if line.endswith(' 1')]

    def rename_until(self, stop):
        n = 0
        while not stop.is_set():
            n += 1
            self.s.tmux_ok('rename-window', '-t', 'main', 'w%d' % n)

    def clients_by_session(self):
        listing = self.s.tmux_ok('list-clients', '-F', '#{client_control_mode} #{session_name}').stdout.split('\n')
        return sorted(line for line in listing if line)

    def test_control_client_listens_from_the_watch_session_that_the_sidebar_never_shows(self):
        # tmux answers a Pane's color query from the first client on its Session, and a control client answers black.
        wait(lambda: '1 muxify-watch' in self.clients_by_session(), 'no control client on muxify-watch')
        clients = self.clients_by_session()
        self.assertEqual([c for c in clients if c.startswith('1 ')], ['1 muxify-watch'], clients)
        self.assertNotIn('0 muxify-watch', clients, 'the app attached its Terminal to the Watch Session')
        watch = self.s.tmux('list-windows', '-t', '=muxify-watch:', '-F', '#{window_id}').split()
        user = self.s.tmux('list-windows', '-t', '=main:', '-F', '#{window_id}').split()
        rows = self.s.wait_rows(lambda rs: any(self.s.has(prefix + w, rs) for w in user
                                               for prefix in ('topic-window-', 'session-window-')),
                                'the Sidebar does not show main')
        shown = [key for key in self.s.ids(rows) if any(key.endswith('-window-' + w) for w in watch)]
        self.assertEqual(shown, [], 'the Sidebar shows the Watch Session')

    def test_the_watch_session_does_not_keep_the_server_running_after_the_last_session_closes(self):
        wait(lambda: '1 muxify-watch' in self.clients_by_session(), 'no control client on muxify-watch')
        server = int(self.s.tmux('display-message', '-p', '#{pid}'))
        # The next check needs the app and a server again; setUp launches the app when it is gone.
        self.addCleanup(lambda: alive(self.s.pid) and os.kill(self.s.pid, signal.SIGKILL))
        for session in self.s.tmux('list-sessions', '-F', '#{session_name}').split('\n'):
            if session != 'muxify-watch':
                self.s.tmux_ok('kill-session', '-t', '=' + session)
        wait(lambda: not alive(server), 'tmux server %d still runs: %s'
             % (server, self.s.tmux_ok('list-sessions', '-F', '#{session_name}').stdout.split()), seconds=10)

    def test_send_keys_from_outside_tmux_works_while_the_control_client_is_newest(self):
        # tmux gives a command from outside tmux the client with the newest activity. A control client that starts
        # again after the app's own client is that client.
        old = wait(lambda: (self.control_clients() or [None])[0], 'app did not start a tmux control client')
        os.kill(old, signal.SIGTERM)
        wait(lambda: [pid for pid in self.control_clients() if pid != old], 'app did not start its control client again')
        target = self.s.tmux('display-message', '-p', '#{client_control_mode}')
        self.assertEqual(target, '1', 'tmux does not give outside commands the control client, so this checks nothing')
        try:
            sent = self.s.tmux_ok('send-keys', '-t', 'main', '-l', 'echo from-outside', timeout=10)
            failure = sent.stderr.strip() if sent.returncode else None
        except subprocess.TimeoutExpired:
            failure = 'no answer in 10 s'
        mode = self.s.tmux_ok('display-message', '-p', '-t', 'main', '#{pane_mode}', timeout=5).stdout.strip()
        shown = self.s.tmux_ok('capture-pane', '-p', '-M', '-t', 'main', timeout=5).stdout.strip()[-500:]
        self.assertIsNone(failure, 'send-keys from outside tmux failed: %s; pane mode %r shows %r' % (failure, mode, shown))

    def test_control_client_exits_when_app_is_killed(self):
        client = wait(lambda: (self.control_clients() or [None])[0], 'app did not start a tmux control client')
        server = int(self.s.tmux('display-message', '-p', '#{pid}'))
        stop = threading.Event()
        renamers = [threading.Thread(target=self.rename_until, args=(stop,)) for _ in range(RENAMERS)]
        for renamer in renamers:
            renamer.start()
        time.sleep(.3)

        os.kill(self.s.pid, signal.SIGKILL)
        wait(lambda: not alive(self.s.pid), 'app %d still runs after SIGKILL' % self.s.pid, seconds=5)
        time.sleep(1)
        stop.set()
        for renamer in renamers:
            renamer.join()

        wait(lambda: not alive(client), 'control client %d still runs after the app was killed' % client, seconds=5)
        self.s.tmux_ok('kill-server')
        wait(lambda: not alive(server), 'tmux server %d still runs after kill-server' % server, seconds=5)


if __name__ == '__main__':
    unittest.main()
