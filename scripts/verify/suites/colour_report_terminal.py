"""Colour Reports (ADR 0095): a program in a Session that Muxify shows gets Muxify's Terminal colours as the answer
to OSC 11, also after another control Client, such as Muxify Mobile, reported other colours for its Pane.

Each check runs `fixtures/colour_probe.py` in a Pane of its own Session. The probe asks for the background at once on
each colour-scheme notice and every half second, and logs each notice and each answer.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.colour_report_terminal
"""

import sys
import time
import unittest

from scripts.verify.sandbox import REPO, Sandbox, wait

PROBE = REPO/'scripts/verify/fixtures/colour_probe.py'
# The report of another screen: Muxify's own Terminal in the sandbox is never pure white.
OTHER = 'rgb:ffff/ffff/ffff'


class ColourReportTerminal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(cls.sandbox.teardown)
        cls.sandbox.tmux('new-session', '-d', '-s', 'phone')
        cls.start_probe('base-colours')
        cls.sandbox.launch()
        wait(lambda: '@muxify_client_' in cls.sandbox.tmux('show-options', '-s'), 'Muxify did not register its Client')
        cls.sandbox.show(cls.window('base-colours'))
        # The Listener writes the report once it sits in the Terminal's Session, which at launch is after it found the
        # Terminal's Client, so the first answers can be tmux's own: Muxify's colours are the answer that stays.
        wait(lambda: cls.answers('base-colours'), 'the shown Session answered no colour')
        time.sleep(3)
        cls.muxify = wait(lambda: cls.settled(cls.answers('base-colours')), 'the shown Session answered no settled colour')
        assert cls.muxify != OTHER, 'the Terminal is white, so a check cannot tell the reports apart'
        # A control Client of the check's, as Muxify Mobile is one: its reports stay while it is attached.
        cls.phone = cls.sandbox.tmux_control('phone')
        cls.addClassCleanup(cls.phone.terminate)

    @classmethod
    def start_probe(cls, session):
        log = cls.sandbox.root/(session + '.log')
        log.touch()
        cls.sandbox.tmux('new-session', '-d', '-s', session, '-x', '80', '-y', '24',
                         '%s %s %s' % (sys.executable, PROBE, log))

    @classmethod
    def window(cls, session):
        return cls.sandbox.tmux('display-message', '-p', '-t', session + ':', '#{window_id}').strip()

    @classmethod
    def lines(cls, session):
        return (cls.sandbox.root/(session + '.log')).read_text().splitlines()

    @staticmethod
    def settled(answers):
        """The last answer, once the probe gave it three times in a row."""
        return answers[-1] if len(answers) >= 3 and len(set(answers[-3:])) == 1 else None

    @classmethod
    def answers(cls, session):
        return [line.split()[1] for line in cls.lines(session) if line.startswith('answer ')]

    def report_other_colour(self, session):
        """Writes the other screen's background for the Session's Pane, and waits until the probe gets it."""
        pane = self.sandbox.tmux('display-message', '-p', '-t', session + ':', '#{pane_id}').strip()
        self.phone.stdin.write(('refresh-client -r "%s:\\033]11;%s\\033\\\\"\n' % (pane, OTHER)).encode())
        self.phone.stdin.flush()
        wait(lambda: self.answers(session)[-1:] == [OTHER],
             lambda: 'the probe did not get the other report: %s' % self.lines(session)[-5:])

    def test_the_app_window_becoming_key_reports_muxifys_colours_over_another_screens_report(self):
        session = 'focus-colours'
        self.start_probe(session)
        self.sandbox.show(self.window(session))
        wait(lambda: self.answers(session)[-1:] == [self.muxify], 'the shown Session did not answer Muxify\'s colour')
        self.report_other_colour(session)

        self.sandbox.act('key')

        wait(lambda: self.answers(session)[-1:] == [self.muxify],
             lambda: 'the key App Window did not report its colours: %s' % self.lines(session)[-5:])

    def test_a_switch_that_muxify_starts_reports_muxifys_colours(self):
        """The Listener writes the report when it hears the Terminal move, so a program that asks after the switch gets
        Muxify's colours. Measured on tmux 3.8 with Muxify's Terminal: a report written after the switch sends the
        Pane no colour-scheme notice, so a program that asked before the switch keeps its answer until it asks again."""
        session = 'switch-colours'
        self.start_probe(session)
        self.report_other_colour(session)
        before = len(self.lines(session))

        self.sandbox.show(self.window(session))

        wait(lambda: [line for line in self.lines(session)[before:] if line.startswith('answer ')][-1:] == ['answer ' + self.muxify],
             lambda: 'the switch that Muxify started did not get Muxify\'s colours: %s' % self.lines(session)[before:][-5:])

    def test_a_switch_inside_tmux_reports_muxifys_colours(self):
        session = 'inside-colours'
        self.start_probe(session)
        self.report_other_colour(session)
        tty = next(line.split()[1] for line in self.sandbox.tmux('list-clients', '-F', '#{client_control_mode} #{client_tty}')
                   .splitlines() if line.startswith('0 '))

        self.sandbox.tmux('switch-client', '-c', tty, '-t', session + ':')

        wait(lambda: self.answers(session)[-1:] == [self.muxify],
             lambda: 'the switch inside tmux did not get Muxify\'s colours: %s' % self.lines(session)[-5:])


    def test_another_screen_that_detaches_leaves_muxifys_colours(self):
        session = 'detach-colours'
        self.start_probe(session)
        self.sandbox.show(self.window(session))
        wait(lambda: self.answers(session)[-1:] == [self.muxify], 'the shown Session did not answer Muxify\'s colour')
        screen = self.sandbox.tmux_control(session)
        self.addCleanup(screen.terminate)
        pane = self.sandbox.tmux('display-message', '-p', '-t', session + ':', '#{pane_id}').strip()
        screen.stdin.write(('refresh-client -r "%s:\\033]11;%s\\033\\\\"\n' % (pane, OTHER)).encode())
        screen.stdin.flush()
        wait(lambda: self.answers(session)[-1:] == [OTHER],
             lambda: 'the probe did not get the other screen\'s report: %s' % self.lines(session)[-5:])

        screen.stdin.close()
        screen.wait(timeout=5)

        wait(lambda: self.answers(session)[-1:] == [self.muxify],
             lambda: 'the other screen\'s detach did not give back Muxify\'s colours: %s' % self.lines(session)[-5:])


if __name__ == '__main__':
    unittest.main()
