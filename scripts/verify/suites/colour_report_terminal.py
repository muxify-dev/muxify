"""Colour Reports (ADR 0095): a program in a Session that Muxify shows gets Muxify's Terminal colours as the answer
to OSC 11, also after another control Client, such as Muxify Mobile, reported other colours for its Pane.

Each check runs `fixtures/colour_probe.py` in a Pane of its own Session. The probe asks for the background at once on
each colour-scheme notice and every half second, and logs each notice and each answer.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.colour_report_terminal
"""

import sys
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
        cls.muxify = wait(lambda: cls.answers('base-colours')[-1:], 'the shown Session answered no colour')[0]
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

    def test_a_switch_that_muxify_starts_sends_a_notice_whose_answer_is_muxifys_colours(self):
        session = 'switch-colours'
        self.start_probe(session)
        self.report_other_colour(session)
        before = len(self.lines(session))

        self.sandbox.show(self.window(session))

        def first_answer_after_notice():
            lines = self.lines(session)[before:]
            after = lines[lines.index('notice'):] if 'notice' in lines else []
            return next((line for line in after if line.startswith('answer ')), None)
        first = wait(first_answer_after_notice,
                     lambda: 'no notice and answer after the switch: %s' % self.lines(session)[before:])
        self.assertEqual(first, 'answer ' + self.muxify,
                         'the first answer after the switch notice: %s' % self.lines(session)[before:])

    def test_a_switch_inside_tmux_reports_muxifys_colours_after_the_next_read(self):
        session = 'inside-colours'
        self.start_probe(session)
        self.report_other_colour(session)
        tty = next(line.split()[1] for line in self.sandbox.tmux('list-clients', '-F', '#{client_control_mode} #{client_tty}')
                   .splitlines() if line.startswith('0 '))

        self.sandbox.tmux('switch-client', '-c', tty, '-t', session + ':')

        wait(lambda: self.answers(session)[-1:] == [self.muxify],
             lambda: 'the switch inside tmux did not get Muxify\'s colours: %s' % self.lines(session)[-5:])


if __name__ == '__main__':
    unittest.main()
