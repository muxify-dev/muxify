"""Diagnostics: on by default, the app logs into the sandbox's logs folder, one Diagnostics log file a day, with a
`minute` record each minute, a `burst` record for each Burst and `digest` records for each sample
(docs/development.md)."""

import re
import subprocess
import time
import unittest

from scripts.verify.sandbox import DEBUG_APP, Sandbox, wait
from scripts.verify.suites.sidebar_swipe import SwipeSteps
from scripts.verify.topic_records import TopicRecords

CONFIG = 'diagnostics:\n  enabled: %s\nsessions:\n  diagnostics_probe: 1\n'
CLI = DEBUG_APP/'Contents/Resources/bin/muxify'
# The libraries of SwiftUI's view graph. A digest of SwiftUI-bound work leads with one of them.
SWIFTUI = {'AttributeGraph', 'SwiftUI', 'SwiftUICore'}


def records(logs, kind):
    """The fields of every `kind` record in the day files of `logs`, in order."""
    text = ''.join(path.read_text(errors='replace') for path in sorted(logs.glob('muxify-*.log')))
    return [dict(word.split('=', 1) for word in line.split(' ')[3:])
            for line in text.splitlines() if re.match(r'\S+ \S+ %s ' % kind, line)]


def finished_burst_samples(logs):
    return {path.name for path in logs.glob('burst-*.txt') if 'Binary Images:' in path.read_text(errors='replace')}


def burst_naming(logs, sample):
    """The `burst` record whose samples name `sample`, or None."""
    return next((fields for fields in records(logs, 'burst') if sample in fields.get('samples', '').split(',')), None)


def libraries(logs, sample):
    """The digest's libraries of `sample`, the highest share first, as [(name, share)]."""
    head = next((fields for fields in records(logs, 'digest') if fields.get('sample') == sample and 'libraries' in fields),
                None)
    assert head, 'no digest record names %s' % sample
    return [(name, float(share)) for name, share in (item.rsplit(':', 1) for item in head['libraries'].split(','))]


def summary_burst(test, logs, sample):
    """The lines of the Burst whose digest names `sample` in `muxify diagnostics summary`'s Bursts section."""
    result = subprocess.run([str(CLI), 'diagnostics', 'summary', '--folder', str(logs)], capture_output=True, text=True,
                            timeout=30)
    test.assertEqual(0, result.returncode, result.stdout + result.stderr)
    lines = result.stdout.splitlines()
    test.assertTrue(any(line.startswith('Bursts ') for line in lines), result.stdout)
    section = lines[next(index for index, line in enumerate(lines) if line.startswith('Bursts ')):]
    section = section[:section.index('')] if '' in section else section
    entries, entry = [], None
    for line in section:
        if re.match(r'  \d+\. ', line):
            entry = [line]
            entries.append(entry)
        elif entry is not None:
            entry.append(line)
    found = next((entry for entry in entries if any(line.strip().startswith('digest %s ' % sample) for line in entry)), None)
    test.assertIsNotNone(found, 'the summary lists no Burst with the digest of %s:\n%s' % (sample, '\n'.join(section)))
    return found


def summary_line(entry, label):
    """The text after `label` on the line of a summary Burst that starts with it."""
    return next(line.strip()[len(label) + 1:] for line in entry if line.strip().startswith(label + ' '))


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
        path = wait(finished_samples, 'no finished freeze sample in %s' % self.logs, 5)[0]
        sample = path.read_text(errors='replace')
        # The call graph lists the main thread first.
        threads = re.split(r'\n    \d+ Thread_', sample[sample.index('Call graph:'):])
        main = threads[1]
        self.assertIn('sleepForTimeInterval', main, 'the sample does not show the main thread in the stall')

        # The app folds the sample's main thread into three digest records that name the file.
        def digests():
            records = [dict(word.split('=', 1) for word in line.split(' ')[3:]) for line in self.log_text().splitlines()
                       if re.match(r'\S+ \S+ digest ', line)]
            named = [fields for fields in records if fields.get('sample') == path.name]
            return named if len(named) == 3 else None
        records = wait(digests, 'no three digest records name %s in %s' % (path.name, self.logs), 10)
        head = next(fields for fields in records if 'libraries' in fields)
        self.assertGreater(int(head['samples']), 0, head)
        # The stall sleeps on the main thread outside the run loop's wait, so it is busy time.
        self.assertGreater(float(head['busy']), 20, head)
        self.assertNotEqual('none', head['libraries'], head)
        symbols = next(fields for fields in records if 'symbols' in fields)['symbols'].split(',')
        self.assertTrue(all('@' in item and float(item.rsplit(':', 1)[1]) >= 0 for item in symbols), symbols)
        frames = next(fields for fields in records if 'frames' in fields)['frames'].split(',')
        # The TestDriver runs the stall, so its frame holds most of the busy time.
        shares = dict(item.rsplit(':', 1) for item in frames)
        self.assertGreater(float(shares.get('static_TestDriver.run(_:)', 0)), 50, frames)

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


class DiagnosticsBodies(SwipeSteps, unittest.TestCase):
    """The `minute` record's `bodies`: the SwiftUI bodies of the counted views that ran, in every build."""

    TOPICS = ['bodies-%d' % number for number in range(3)]

    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1] + '_bodies')
        cls.addClassCleanup(s.teardown)
        cls.logs = s.root/'logs'
        project = s.root/'project'
        project.mkdir()
        (s.root/'config/muxify/config.yaml').write_text('sidebar:\n  agents: false\n  animate_switching: true\n')
        store = TopicRecords(s.root/'state/muxify')
        for topic in cls.TOPICS:
            store.put(dict(id=topic, title='Bodies ' + topic[-1], slug=topic))
            session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', topic, '-c', str(project), '/bin/zsh -f')
            s.tmux('set-option', '-t', session, '@muxify_topic', topic)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])

    def minutes(self):
        text = ''.join(path.read_text(errors='replace') for path in sorted(self.logs.glob('muxify-*.log')))
        return [dict(word.split('=', 1) for word in line.split(' ')[3:])
                for line in text.splitlines() if re.match(r'\S+ \S+ minute ', line)]

    def test_a_minute_record_during_swipes_names_the_card_or_page_bodies(self):
        self.s.wait_rows(lambda rs: all(self.s.has('topic-' + topic, rs) for topic in self.TOPICS),
                         'the Sidebar does not show the Topics')
        self.wait_mode('topics')
        # The verify checks reset the counter as they read it; Diagnostics reads on across a reset.
        self.s.driver('counts', reset=True)
        # Swipe on until the minute that the swipes run in is written.
        deadline = time.monotonic() + 90
        number = 0
        while not self.minutes() and time.monotonic() < deadline:
            self.sample('Swipe right' if number % 2 else 'Swipe left')
            self.wait_mode('topics' if number % 2 else 'sessions')
            number += 1
        fields = wait(self.minutes, 'no minute record in %s' % self.logs, 10)[0]
        self.assertIn('bodies', fields, fields)
        self.assertNotEqual('none', fields['bodies'], fields)
        bodies = dict(item.rsplit(':', 1) for item in fields['bodies'].split(','))
        self.assertTrue(all(int(count) > 0 for count in bodies.values()), fields['bodies'])
        named = [name for name in ('SidebarCard', 'TopicsSection', 'SessionsSection') if name in bodies]
        self.assertTrue(named, 'the minute names no card or page root body: %s' % fields['bodies'])


# Views under the idle clock (`TestDriverCosts.idleClockViews`, which gives the CPU measured), and the Agents at work.
IDLE_CLOCK_VIEWS = 1600
IDLE_AGENTS = 4


class DiagnosticsIdleCost(unittest.TestCase):
    """Case 1: a SwiftUI clock under Working-mark-like views while nobody touches the app, as the Working marks were
    before #114. The Diagnostics log alone must name it: an idle Burst, with Working marks, of SwiftUI's view graph."""

    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1] + '_idle')
        cls.addClassCleanup(s.teardown)
        cls.logs = s.root/'logs'
        (s.root/'config/muxify/config.yaml').write_text('sidebar:\n  agents_scope:\n    topics: all\n    sessions: all\n')
        project = s.root/'projects/working'
        project.mkdir(parents=True)
        cls.panes = []
        for number in range(IDLE_AGENTS):
            pane = s.tmux('new-session', '-d', '-P', '-F', '#{pane_id}', '-s', 'idle-%d' % number, '-c', str(project),
                          'sleep 600')
            s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude',
                   ';', 'set-option', '-p', '-t', pane, '@muxify_agent_status', 'working')
            cls.panes.append(pane)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES'])

    def test_an_idle_swiftui_clock_is_an_idle_burst_with_working_marks_and_a_swiftui_digest(self):
        self.s.wait_rows(lambda rs: all(self.s.has('agent-' + pane, rs) for pane in self.panes),
                         'the Agents section does not list every Working Agent')
        before = finished_burst_samples(self.logs)
        self.addCleanup(self.s.act, 'idle_clock', views=0)
        self.s.act('idle_clock', views=IDLE_CLOCK_VIEWS)
        # A Burst at launch can take the minute's one sample, so the clock runs on until a sample of its own is written.
        # The driver acts through the accessibility tree, so the app sees no input while it waits.
        def new_samples():
            return sorted(finished_burst_samples(self.logs) - before)
        sample = wait(new_samples, 'the idle clock made no sampled Burst in %s' % self.logs, 80)[0]
        self.s.act('idle_clock', views=0)
        # The Burst ends 3 seconds after the clock stops.
        fields = wait(lambda: burst_naming(self.logs, sample), 'no burst record names %s' % sample, 20)
        self.assertEqual('idle', fields['input'], fields)
        self.assertGreater(int(fields['working_marks']), 0, fields)
        shares = libraries(self.logs, sample)
        self.assertIn(shares[0][0], SWIFTUI, 'the digest of %s does not lead with SwiftUI: %s' % (sample, shares))

        entry = summary_burst(self, self.logs, sample)
        self.assertEqual('idle', summary_line(entry, 'input'), entry)
        moving = dict(word.split('=', 1) for word in summary_line(entry, 'moving').split(' '))
        self.assertGreater(int(moving['working_marks']), 0, entry)
        self.assertIn(summary_line(entry, 'libraries').split(' ', 1)[0], SWIFTUI, entry)


# Topics with a Session each, so each page has as many cards, and the views each card lays out again on each switch
# (`TestDriverCosts.cardRebuildViews`, which gives the CPU measured).
SWIPE_CARDS = 15
CARD_REBUILD_VIEWS = 2000


class DiagnosticsSwipeCost(SwipeSteps, unittest.TestCase):
    """Case 2: every Sidebar card's body runs again on each Sidebar switch, as the cards did while they read the Quick
    Switch Hints before #119. The Diagnostics log alone must name it: a Burst during the switches, with the cards'
    bodies, of SwiftUI's view graph."""

    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1] + '_swipe')
        cls.addClassCleanup(s.teardown)
        cls.logs = s.root/'logs'
        project = s.root/'project'
        project.mkdir()
        (s.root/'config/muxify/config.yaml').write_text('sidebar:\n  agents: false\n  animate_switching: true\n')
        store = TopicRecords(s.root/'state/muxify')
        cls.topics = ['swipe-cost-%02d' % number for number in range(SWIPE_CARDS)]
        for topic in cls.topics:
            store.put(dict(id=topic, title='Swipe cost ' + topic[-2:], slug=topic))
            session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', topic, '-c', str(project),
                             '/bin/zsh -f')
            s.tmux('set-option', '-t', session, '@muxify_topic', topic)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])

    def test_card_rebuilds_on_each_switch_are_a_burst_with_the_switches_card_bodies_and_a_swiftui_digest(self):
        self.s.wait_rows(lambda rs: any(self.s.has('topic-' + topic, rs) for topic in self.topics),
                         'the Sidebar shows none of the %d Topics' % SWIPE_CARDS)
        self.wait_mode('topics')
        self.require_motion()
        before = finished_burst_samples(self.logs)
        self.addCleanup(self.s.act, 'card_rebuild', views=0)
        self.s.act('card_rebuild', views=CARD_REBUILD_VIEWS)
        # Swipe on until a Burst's sample is written; a Burst at launch can take the minute's one sample.
        swipes = []
        deadline = time.monotonic() + 80
        while not finished_burst_samples(self.logs) - before and time.monotonic() < deadline:
            left = len(swipes) % 2 == 0
            swipes.append(time.time())
            self.sample('Swipe left' if left else 'Swipe right')
            self.wait_mode('sessions' if left else 'topics')
        sample = wait(lambda: sorted(finished_burst_samples(self.logs) - before),
                      'the swipes made no sampled Burst in %s' % self.logs, 10)[0]
        # The Burst ends 3 seconds after the swipes stop.
        fields = wait(lambda: burst_naming(self.logs, sample), 'no burst record names %s' % sample, 20)
        start = time.mktime(time.strptime(fields['start'].split('.')[0], '%Y-%m-%dT%H:%M:%S'))
        start += float('0.' + fields['start'].split('.')[1])
        # The swipes made well inside the Burst, a second from either end, so the clocks' rounding cannot move one out.
        inside = [moment for moment in swipes if start + 1 <= moment <= start + float(fields['length']) - 1]
        self.assertTrue(inside, 'no swipe falls inside the Burst %s: swipes at %s' % (fields, swipes))
        switches = dict(item.split(':') for item in fields['input'].split(',')).get('sidebar_switches', '0')
        self.assertGreaterEqual(int(switches), len(inside), fields)
        bodies = dict(item.rsplit(':', 1) for item in fields['bodies'].split(',')) if fields['bodies'] != 'none' else {}
        # Each switch runs at least one page's cards again; without the rebuild a whole burst runs at most
        # sidebar_swipe.CARD_BODIES_PER_BURST.
        self.assertGreater(int(bodies.get('SidebarCard', 0)), len(inside) * SWIPE_CARDS, fields)
        shares = libraries(self.logs, sample)
        self.assertIn(shares[0][0], SWIFTUI, 'the digest of %s does not lead with SwiftUI: %s' % (sample, shares))

        entry = summary_burst(self, self.logs, sample)
        counts = dict(item.split(':') for item in summary_line(entry, 'input').split(','))
        self.assertGreaterEqual(int(counts['sidebar_switches']), len(inside), entry)
        named = dict(item.rsplit(':', 1) for item in summary_line(entry, 'bodies').split(','))
        self.assertGreater(int(named.get('SidebarCard', 0)), len(inside) * SWIPE_CARDS, entry)
        self.assertIn(summary_line(entry, 'libraries').split(' ', 1)[0], SWIFTUI, entry)


if __name__ == '__main__':
    unittest.main()
