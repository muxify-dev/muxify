"""A switch never waits for a Colour Report: Muxify writes the report of the target Session and runs the switch at
once. Before, it waited for tmux's answers, counted over the Listener's whole life, so one lost answer made every later
switch wait a full second. With Sessions of 11 and 8 Panes this broke at about the tenth switch.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.colour_report_switch_terminal
"""

import time
import unittest

from scripts.verify.sandbox import Sandbox, wait

# How long a switch may take, from the request to the Terminal's Client in the target Window.
LIMIT = .5


class ColourReportSwitchTerminal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(cls.sandbox.teardown)
        # Each Pane in a Window of its own, so that the Session's Panes have room.
        for session, panes in [('big', 11), ('small', 8)]:
            cls.sandbox.tmux('new-session', '-d', '-s', session, '-x', '80', '-y', '24')
            for _ in range(panes - 1):
                cls.sandbox.tmux('new-window', '-d', '-t', session + ':')
        cls.sandbox.launch()
        wait(lambda: '@muxify_client_' in cls.sandbox.tmux('show-options', '-s'), 'Muxify did not register its Client')

    @classmethod
    def windows(cls, session):
        return cls.sandbox.tmux('list-windows', '-t', session + ':', '-F', '#{window_id}').split()

    def client_window(self):
        """The Window of the Terminal's Client: the one Client that is not in control mode."""
        lines = self.sandbox.tmux('list-clients', '-F', '#{client_control_mode} #{window_id}').splitlines()
        return next((line.split()[1] for line in lines if line.startswith('0 ')), None)

    def switch(self, window):
        """Asks the app to show the Window, and returns the seconds until the Terminal's Client is there."""
        start = time.monotonic()
        self.sandbox.select(window)
        wait(lambda: self.client_window() == window, 'the Terminal did not move to %s' % window, seconds=10, step=.01)
        return time.monotonic() - start

    def test_twelve_switches_between_big_sessions_and_inside_one_never_wait_for_a_colour_report(self):
        big, small = self.windows('big'), self.windows('small')
        self.sandbox.show(small[-1])
        targets = [window for pair in zip(big, small) for window in pair][:12]
        targets += small[:3]

        took = [(window, self.switch(window)) for window in targets]

        slow = [(window, round(seconds, 2)) for window, seconds in took if seconds >= LIMIT]
        self.assertEqual(slow, [], 'switches that took %s s or more, of %s' % (LIMIT, [round(s, 2) for _, s in took]))
        log = (self.sandbox.root/'logs/app.log').read_text(errors='replace')
        self.assertEqual([line for line in log.splitlines() if 'colour report' in line], [])


if __name__ == '__main__':
    unittest.main()
