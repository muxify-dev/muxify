"""The close of the shown Window when its Session keeps other Windows: tmux moves the Terminal's Client to a Window of
its choosing, and Muxify follows it without a switch of its own."""

import time
import unittest

from scripts.verify.sandbox import Sandbox, wait


class WindowClose(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(cls.s.teardown)
        cls.s.app_env['SHELL'] = '/bin/sh'
        cls.s.tmux_ok('new-session', '-d', '-s', 'start', '-c', str(cls.s.root), '/bin/sh')
        cls.s.launch()

    def client_window(self):
        """The Window of the Terminal's Client."""
        listed = self.s.tmux_ok('list-clients', '-F', '#{client_control_mode}|#{window_id}').stdout
        return next((line.split('|')[1] for line in listed.splitlines() if line.startswith('0|')), None)

    def test_closing_the_shown_window_stays_on_the_window_tmux_chose(self):
        first = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'closing', '-c', str(self.s.root),
                            '/bin/sh')
        second, third = (self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', 'closing:',
                                     '-c', str(self.s.root), '/bin/sh') for _ in range(2))
        # Shown in this order, tmux's last Window is the third, while the closed Window's earlier index neighbour is
        # the first: a Muxify that picks by index would move the Client away from tmux's choice.
        for window in (first, third, second):
            self.s.show(window)
        flags = self.s.tmux('list-windows', '-t', 'closing', '-F', '#{window_id} #{window_last_flag}')
        self.assertIn(third + ' 1', flags.splitlines(), 'tmux\'s last Window is not the third: %s' % flags)

        self.s.tmux('kill-window', '-t', second)
        wait(lambda: self.client_window() == third, lambda: 'tmux did not move the Client to %s: it is on %s'
             % (third, self.client_window()))
        self.s.wait_shown(third)
        seen = set()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            seen.add(self.client_window())
            time.sleep(.1)
        self.assertEqual(seen, {third}, 'the Client left tmux\'s choice %s after the close' % third)
        self.s.wait_shown(third, seconds=2)
