"""Working marks: Core Animation moves them, so a moving mark costs the app no CPU (docs/development.md, "Agent marks").

A SwiftUI clock under a Working mark updated and laid out the whole App Window on each tick: with Agents at work the
main thread was busy almost all the time, and a swipe between Topics and Sessions waited for it.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.working_marks
"""

import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox

CONFIG = '''ui:
  pulse: %s
sidebar:
  agents_scope:
    topics: all
    sessions: all
'''
AGENTS = 4
# Seconds of CPU time to read the app's use over. The app reads tmux once a second, so take several reads.
SPAN = 4


class WorkingMarks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text(CONFIG % 'true')
        project = s.root/'projects/working'
        project.mkdir(parents=True, exist_ok=True)
        cls.panes = []
        for number in range(AGENTS):
            pane = s.tmux('new-session', '-d', '-P', '-F', '#{pane_id}', '-s', 'working-%d' % number,
                          '-c', str(project), 'sleep 600')
            s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude',
                   ';', 'set-option', '-p', '-t', pane, '@muxify_agent_status', 'working')
            cls.panes.append(pane)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES'])
        s.wait_rows(lambda rs: all(s.has('agent-' + pane, rs) for pane in cls.panes),
                    'the Agents section does not list every Working Agent')

    def cpu_seconds(self):
        """The app's user and system CPU time so far."""
        out = subprocess.run(['/bin/ps', '-o', 'time=', '-p', str(self.s.pid)], capture_output=True, text=True,
                             check=True).stdout.strip()
        minutes, seconds = out.split(':')
        return int(minutes) * 60 + float(seconds)

    def cpu_share(self):
        """The share of one core the app used over SPAN seconds."""
        start, began = self.cpu_seconds(), time.monotonic()
        time.sleep(SPAN)
        return (self.cpu_seconds() - start) / (time.monotonic() - began)

    def set_pulse(self, pulse):
        self.config.write_text(CONFIG % ('true' if pulse else 'false'))
        # The Config reload shows in no row, so wait out the reload and the frames it draws.
        time.sleep(2)

    def test_moving_working_marks_cost_the_app_no_cpu(self):
        self.addCleanup(self.config.write_text, CONFIG % 'true')
        self.set_pulse(False)
        still = self.cpu_share()
        self.set_pulse(True)
        rs = self.s.rows()
        self.assertTrue(all(self.s.has('agent-' + pane, rs) for pane in self.panes), 'a Working Agent row is gone')
        moving = self.cpu_share()
        # Under SwiftUI's clock the moving marks took tens of percent of a core more than still ones.
        self.assertLess(moving - still, 0.05, 'moving Working marks use %.0f%% of a core, still ones %.0f%%'
                        % (moving * 100, still * 100))


if __name__ == '__main__':
    unittest.main()
