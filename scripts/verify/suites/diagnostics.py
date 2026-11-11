"""Diagnostics: on by default, the app logs into the sandbox's logs folder, one Diagnostics log file a day, with a
`minute` record each minute and a `burst` record for each Burst (docs/development.md)."""

import re
import time
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
        # A Session keeps the Sandbox's tmux server running, for the minute record's tmux group.
        s.tmux('new-session', '-d', '-s', 'diagnostics', '/bin/sh')
        s.launch()

    def log_text(self):
        """The day files in order, so a run across local midnight reads on into the next day's file."""
        return ''.join(path.read_text(errors='replace') for path in sorted(self.logs.glob('muxify-*.log')))

    def test_launch_is_logged_in_the_sandbox(self):
        today = self.logs/time.strftime('muxify-%Y-%m-%d.log')
        wait(lambda: today.exists() and 'launch: pid %d' % self.s.pid in today.read_text(errors='replace'),
             'no launch line in %s' % today, 10)
        self.assertFalse((self.logs/'muxify.log').exists(), 'the app still writes muxify.log')

    def test_a_minute_record_says_the_app_was_idle_and_what_it_showed(self):
        # The first minute ends a minute after Diagnostics starts at launch. A verify run gives the app no key press,
        # click or scroll: the driver acts through the accessibility tree.
        def minutes():
            return [line for line in self.log_text().splitlines() if re.match(r'\S+ \S+ minute ', line)]
        line = wait(minutes, 'no minute record in %s' % self.logs, 90)[0]
        fields = dict(word.split('=', 1) for word in line.split(' ')[3:])
        for key in ['cpu.app.avg', 'cpu.app.peak', 'main.busy', 'mem.app', 'threads', 'open_files', 'input', 'window',
                    'working_marks', 'marks_move', 'sidebar', 'topic_cards', 'session_rows']:
            self.assertIn(key, fields, line)
        self.assertEqual('idle', fields['input'], line)
        self.assertEqual('topics', fields['sidebar'], line)
        self.assertGreaterEqual(float(fields['cpu.app.peak']), float(fields['cpu.app.avg']), line)
        self.assertNotIn(' resources: ', self.log_text(), 'the app still writes the resources line')

    def test_a_minute_record_gives_the_sandbox_tmux_servers_cpu_and_memory(self):
        # The Sandbox's server is the app's only Local server, so it is the one the tmux group reads. The group
        # counts from its second read after the first snapshot names the server, well inside the first minute.
        server = int(self.s.tmux('display', '-p', '-t', 'diagnostics', '#{pid}'))
        def with_tmux():
            return [line for line in self.log_text().splitlines()
                    if re.match(r'\S+ \S+ minute ', line) and ' cpu.tmux.avg=' in line]
        line = wait(with_tmux, 'no minute record with cpu.tmux for server %d in %s' % (server, self.logs), 150)[0]
        fields = dict(word.split('=', 1) for word in line.split(' ')[3:])
        for key in ['cpu.tmux.avg', 'cpu.tmux.peak', 'mem.tmux']:
            self.assertGreaterEqual(float(fields[key]), 0, line)
        self.assertGreater(float(fields['mem.tmux']), 0, line)
        self.assertGreaterEqual(float(fields['cpu.tmux.peak']), float(fields['cpu.tmux.avg']), line)
        # The app's commands, such as its tmux control client, are read too.
        self.assertIn('cpu.commands.avg', fields, line)

    def test_a_burst_is_sampled_and_recorded_when_it_ends(self):
        # A busy stall spins a thread off the main thread: a Burst with no freeze. Launch can make a Burst of its own
        # that takes the minute's one Burst sample, so the spin goes on until the Burst's sample is written.
        def finished_samples():
            return [path for path in self.logs.glob('burst-*.txt') if 'Binary Images:' in path.read_text(errors='replace')]
        deadline = time.monotonic() + 70
        while not finished_samples() and time.monotonic() < deadline:
            self.s.act('stall', seconds=5, busy=True)
        sample = wait(finished_samples, 'no finished Burst sample in %s' % self.logs, 10)[0]

        def bursts():
            records = [line for line in self.log_text().splitlines() if re.match(r'\S+ \S+ burst ', line)]
            return [dict(word.split('=', 1) for word in line.split(' ')[3:]) for line in records
                    if sample.name in line.split(' samples=', 1)[-1].split(' ')[0].split(',')]
        # The Burst ends 3 seconds after the spin.
        fields = wait(bursts, 'no burst record names %s in %s' % (sample.name, self.logs), 20)[0]
        for key in ['start', 'length', 'cpu.avg', 'cpu.peak', 'main.busy.peak', 'input', 'window', 'working_marks',
                    'marks_move', 'sidebar', 'topic_cards', 'session_rows', 'samples']:
            self.assertIn(key, fields, fields)
        self.assertNotIn('open', fields, fields)
        self.assertGreaterEqual(float(fields['length']), 3, fields)
        self.assertGreaterEqual(float(fields['cpu.peak']), 30, fields)
        self.assertGreaterEqual(float(fields['cpu.peak']), float(fields['cpu.avg']), fields)
        self.assertEqual('idle', fields['input'], fields)
        self.assertEqual('topics', fields['sidebar'], fields)
        self.assertIn('Thread_', sample.read_text(errors='replace'))
        self.assertEqual([], list(self.logs.glob('cpu-*.txt')), 'the app still takes the old cpu- sample')

    def test_muxify_message_reaches_the_log(self):
        wait(lambda: 'unknown key "sessions.diagnostics_probe"' in self.log_text(), 'no Config problem in the log', 10)

    def test_freeze_is_logged_with_a_sample_taken_during_it(self):
        # sample takes about a second to start recording, and the app starts it a second into a freeze.
        self.s.act('stall', seconds=4)
        wait(lambda: 'freeze: main thread busy for 4.' in self.log_text(), 'no freeze line in the log', 10)

        def finished_samples():
            return [path for path in self.logs.glob('freeze-*.txt') if 'Binary Images:' in path.read_text(errors='replace')]
        # Under load, sample can start recording seconds after the app starts it, when the first stall has ended.
        # Stalling on until the sample is written keeps the main thread in the stall while it records.
        deadline = time.monotonic() + 20
        while not finished_samples() and time.monotonic() < deadline:
            self.s.act('stall', seconds=1.5)
        sample = wait(finished_samples, 'no finished freeze sample in %s' % self.logs, 5)[0].read_text(errors='replace')
        # The call graph lists the main thread first.
        threads = re.split(r'\n    \d+ Thread_', sample[sample.index('Call graph:'):])
        main = threads[1]
        self.assertIn('sleepForTimeInterval', main, 'the sample does not show the main thread in the stall')

    def test_display_link_probe_is_off_unless_the_config_turns_it_on(self):
        wait(lambda: 'launch: pid %d' % self.s.pid in self.log_text(), 'no launch line in the log', 10)
        # While the probe runs, a freeze line ends with the leaked display links it counted, beside its own
        # `animation #` and `display link` lines (sidebar_pager_scroll).
        self.s.act('stall', seconds=1.3)
        wait(lambda: 'freeze: main thread busy for 1.' in self.log_text(), 'no freeze line in the log', 10)
        probe = [line for line in self.log_text().splitlines() if ' animation #' in line or ' display link' in line]
        self.assertEqual([], probe, 'the display-link probe wrote lines with no diagnostics.display_links')

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
