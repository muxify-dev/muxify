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


def is_light(colour):
    """Whether tmux takes the `rgb:rrrr/gggg/bbbb` background for a light colour scheme."""
    red, green, blue = (int(part[:2], 16) for part in colour[len('rgb:'):].split('/'))
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 127


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

    def report_other_colour(self, session, colour=OTHER, screen=None):
        """Writes the other screen's background for the Session's Pane, and waits until the probe gets it."""
        pane = self.sandbox.tmux('display-message', '-p', '-t', session + ':', '#{pane_id}').strip()
        screen = screen or self.phone
        screen.stdin.write(('refresh-client -r "%s:\\033]11;%s\\033\\\\"\n' % (pane, colour)).encode())
        screen.stdin.flush()
        wait(lambda: self.answers(session)[-1:] == [colour],
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
        """tmux 3.8 tells a program with mode 2031 of the new colour scheme at the switch, and the program asks at once,
        as Claude Code does. A report written after the switch would change the answer but send no notice, so the
        program would keep the other screen's look. Muxify runs its switch on the Listener after the report, so the
        answer at the notice is Muxify's. The other screen sits in the probe's Session, so tmux tells the probe of its
        colour, which is of the other kind: the switch then sends a notice."""
        session = 'switch-colours'
        self.start_probe(session)
        screen = self.sandbox.tmux_control(session)
        self.addCleanup(screen.terminate)
        # tmux tells a program of a colour scheme only when it changes after the program turned on mode 2031, which
        # the probe does before it asks.
        wait(lambda: self.answers(session), 'the probe did not start')
        other = 'rgb:0000/0000/0000' if is_light(self.muxify) else OTHER
        start = len(self.lines(session))
        self.report_other_colour(session, other, screen)
        wait(lambda: 'notice' in self.lines(session)[start:],
             lambda: 'the probe was not told the other screen\'s colour scheme: %s' % self.lines(session))
        before = len(self.lines(session))

        self.sandbox.show(self.window(session))

        def at_notice():
            after = self.lines(session)[before:]
            notice = after.index('notice') if 'notice' in after else None
            return next((line for line in after[notice:] if line.startswith('answer ')), None) if notice is not None else None
        answer = wait(at_notice, lambda: 'the switch sent the program no notice of Muxify\'s colour scheme: %s'
                      % self.lines(session)[before:][-5:])
        self.assertEqual(answer, 'answer ' + self.muxify, 'the program that asked at the switch\'s notice got other colours')
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

    def test_the_terminals_next_click_takes_back_a_window_that_another_screen_took(self):
        """Another screen in the Terminal's Session writes its colours and selects a Pane, as Muxify Mobile does when
        its user taps one. tmux does not say whose focus change it was, and the Terminal had no input, so Muxify
        writes nothing; its Terminal's next input writes the Window's Panes again, as it takes the Window's size back.
        The driver types no key, so the input is a click: the Terminal's key and mouse input share one entry point."""
        session = 'taken-colours'
        self.start_probe(session)
        self.sandbox.tmux('split-window', '-d', '-t', session + ':')
        self.sandbox.show(self.window(session))
        wait(lambda: self.answers(session)[-1:] == [self.muxify], 'the shown Session did not answer Muxify\'s colour')
        screen = self.sandbox.tmux_control(session)
        self.addCleanup(screen.terminate)
        other_pane = self.sandbox.tmux('display-message', '-p', '-t', session + ':.1', '#{pane_id}').strip()
        # A focus change within half a second of Muxify's switch counts as Muxify's own.
        time.sleep(1)

        self.report_other_colour(session, screen=screen)
        screen.stdin.write(('select-pane -t %s\n' % other_pane).encode())
        screen.stdin.flush()
        wait(lambda: self.sandbox.tmux('display-message', '-p', '-t', session + ':', '#{pane_id}').strip() == other_pane,
             'the other screen did not select its Pane')
        time.sleep(2)
        self.assertEqual(self.answers(session)[-1:], [OTHER],
                         'Muxify wrote its colours for a focus change that another screen made: %s' % self.lines(session)[-5:])

        self.sandbox.act('click', 'terminal-panel')

        wait(lambda: self.answers(session)[-1:] == [self.muxify],
             lambda: 'the Terminal\'s next input did not take the Window\'s colours back: %s' % self.lines(session)[-5:])


if __name__ == '__main__':
    unittest.main()
