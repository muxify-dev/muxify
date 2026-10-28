"""Diagnostics: with `diagnostics.enabled` in the Config, the app logs into the sandbox's logs folder (docs/development.md)."""

import re
import unittest

from scripts.verify.sandbox import Sandbox, wait

CONFIG = 'diagnostics:\n  enabled: %s\nsessions:\n  diagnostics_probe: 1\n'


class Diagnostics(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text(CONFIG % 'true')
        cls.logs = s.root/'logs'
        s.launch()

    def log_text(self):
        path = self.logs/'muxify.log'
        return path.read_text() if path.exists() else ''

    def test_launch_is_logged_in_the_sandbox(self):
        wait(lambda: 'launch: pid %d' % self.s.pid in self.log_text(), 'no launch line in %s' % (self.logs/'muxify.log'), 10)

    def test_muxify_message_reaches_the_log(self):
        wait(lambda: 'unknown key "sessions.diagnostics_probe"' in self.log_text(), 'no Config problem in the log', 10)

    def test_freeze_is_logged_with_a_sample_taken_during_it(self):
        # sample takes about a second to start recording, and the app starts it a second into a freeze.
        self.s.act('stall', seconds=4)
        wait(lambda: 'freeze: main thread busy for 4.' in self.log_text(), 'no freeze line in the log', 10)

        def finished_samples():
            return [path for path in self.logs.glob('freeze-*.txt') if 'Binary Images:' in path.read_text(errors='replace')]
        sample = wait(finished_samples, 'no finished freeze sample in %s' % self.logs, 20)[0].read_text(errors='replace')
        # The call graph lists the main thread first.
        threads = re.split(r'\n    \d+ Thread_', sample[sample.index('Call graph:'):])
        main = threads[1]
        self.assertIn('sleepForTimeInterval', main, 'the sample does not show the main thread in the stall')

    def test_the_config_turns_it_off_and_on_without_a_restart(self):
        wait(lambda: 'launch: pid %d' % self.s.pid in self.log_text(), 'no launch line in the log', 10)
        self.addCleanup(self.config.write_text, CONFIG % 'true')
        self.config.write_text(CONFIG % 'false')
        wait(lambda: self.log_text().endswith(' off\n'), 'no off line after the Config turned it off', 10)
        off = len(self.log_text())

        self.s.act('stall', seconds=1.5)
        self.config.write_text(CONFIG % 'true')
        wait(lambda: ' on: pid %d' % self.s.pid in self.log_text()[off:], 'no on line after the Config turned it on', 10)
        self.assertNotIn('freeze:', self.log_text()[off:], 'a freeze was logged while diagnostics was off')


if __name__ == '__main__':
    unittest.main()
