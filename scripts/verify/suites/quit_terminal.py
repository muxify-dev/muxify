"""Quit from the Terminal: Ghostty's `quit` keybind action quits the app, and the app does not hang on it."""

import unittest

from scripts.verify.sandbox import Sandbox, alive, wait


class QuitTerminal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        s.app_env['SHELL'] = '/bin/sh'
        s.tmux('new-session', '-d', '-s', 'quit', '-c', str(s.root), '/bin/sh')
        s.launch()
        wait(lambda: s.tmux_ok('list-clients').returncode == 0 and s.tmux('list-clients').strip(),
             'the app did not attach its Terminal')

    def test_the_quit_keybind_in_the_terminal_quits_the_app(self):
        # The driver performs the keybind on the Terminal itself, as its key does, so libghostty calls back inside it.
        self.s.act('binding', text='quit')
        wait(lambda: not alive(self.s.pid), 'the app did not quit in 15 s; see driver/stall-*.txt for its main thread', 15)
        self.assertEqual(self.s.tmux('list-clients').strip(), '', 'the quit left the Terminal\'s Client attached')
