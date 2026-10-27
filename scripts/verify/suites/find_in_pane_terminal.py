"""Find in Pane: the find bar over the Terminal searches the active Pane's history through tmux copy mode.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.find_in_pane_terminal
"""

import shlex
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait


class FindInPaneTerminal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        # Three needles, far enough apart that the older two are in the history.
        lines = ['line %d' % n if n % 100 else 'needle %d' % n for n in range(1, 301)]
        cls.output = s.root/'output.txt'
        cls.output.write_text('\n'.join(lines) + '\n')
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'find', '-x', '160', '-y', '40',
                             '/bin/zsh -f')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES'])
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(), 'the app attached no tmux client')

    def setUp(self):
        name = self.id().rsplit('.', 1)[-1][:24]
        command = 'cat %s; exec sleep 100000' % shlex.quote(str(self.output))
        self.pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{pane_id}', '-t', self.session + ':', '-n', name, command)
        wait(lambda: 'needle 300' in self.s.tmux('capture-pane', '-p', '-t', self.pane), 'the Pane did not print its output')
        self.s.show(self.s.tmux('display-message', '-p', '-t', self.pane, '#{window_id}'))

    def pane_format(self, format):
        return self.s.tmux('display-message', '-p', '-t', self.pane, format)

    def status(self, rs=None):
        row = self.s.row('terminal-find-status', rs)
        return row.get('accessibilityValue') or row.get('accessibilityLabel') or row.get('accessibilityTitle') or ''

    def find(self, query):
        self.s.act('action', 'terminal-panel', 'Find in Pane')
        self.s.wait_rows(lambda rs: self.s.has('terminal-find-field', rs), 'Find in Pane did not show the find bar')
        self.s.act('focus', 'terminal-find-field')
        self.s.act('set', 'terminal-find-field', query)

    def wait_status(self, expected, message):
        try:
            self.s.wait_rows(lambda rs: self.status(rs) == expected, message)
        except AssertionError:
            self.fail('%s: the status is %r, not %r' % (message, self.status(), expected))

    def test_find_counts_from_the_newest_match_and_next_goes_up(self):
        self.find('needle')
        self.wait_status('1 of 3', 'Find in Pane did not count the matches from the newest')
        self.assertEqual(self.pane_format('#{pane_mode} #{pane_search_string}'), 'copy-mode needle',
                         'the Pane is not in copy mode with the query')
        self.s.act('press', 'terminal-find-next')
        self.wait_status('2 of 3', 'Find Next did not go up to the older match')
        self.assertGreater(int(self.pane_format('#{scroll_position}')), 0, 'Find Next did not scroll the Pane up')
        self.s.act('press', 'terminal-find-previous')
        self.wait_status('1 of 3', 'Find Previous did not go back down')

    def test_a_query_with_no_match_is_not_found(self):
        self.find('haystack')
        self.wait_status('Not found', 'Find in Pane found a query that the Pane does not show')

    def test_done_closes_the_bar_and_leaves_copy_mode(self):
        self.find('needle')
        self.wait_status('1 of 3', 'Find in Pane did not find the needles')
        self.s.act('press', 'terminal-find-done')
        self.s.wait_rows(lambda rs: not self.s.has('terminal-find-field', rs), 'Done did not close Find in Pane')
        wait(lambda: self.pane_format('#{pane_mode}') == '', 'Done left the Pane in copy mode')

    def test_the_find_keys_of_the_field_step_and_close(self):
        self.find('needle')
        self.wait_status('1 of 3', 'Find in Pane did not find the needles')
        # The defaults of keybindings.find, delivered as key presses without the keyboard.
        self.s.act('action', 'quick-switch-input', 'Send Return')
        self.wait_status('2 of 3', 'Return in the find field did not go to the next match')
        self.s.act('action', 'quick-switch-input', 'Send Shift Return')
        self.wait_status('1 of 3', 'Shift Return in the find field did not go to the previous match')
        self.s.act('action', 'quick-switch-input', 'Send Escape')
        self.s.wait_rows(lambda rs: not self.s.has('terminal-find-field', rs), 'Esc in the find field did not close Find in Pane')
        wait(lambda: self.pane_format('#{pane_mode}') == '', 'Esc left the Pane in copy mode')

    def focus_terminal(self):
        # Runs the keybinds of a key without the keyboard (README: "Do not take focus").
        wait(lambda: self.s.driver('action', 'quick-switch-input', 'Press ⇧⌘J')['pressed'], 'the app offers no Press ⇧⌘J')
        wait(lambda: 'TerminalSurfaceView' in self.s.driver('responder')['responders'],
             'Focus Terminal did not give the Terminal Focus')

    def test_escape_in_the_terminal_closes_the_bar_while_the_searched_pane_is_active(self):
        self.find('needle')
        self.wait_status('1 of 3', 'Find in Pane did not find the needles')
        self.focus_terminal()
        self.s.act('action', 'quick-switch-input', 'Send Escape')
        self.s.wait_rows(lambda rs: not self.s.has('terminal-find-field', rs), 'Esc in the Terminal did not close Find in Pane')
        wait(lambda: self.pane_format('#{pane_mode}') == '', 'Esc left the Pane in copy mode')

    def test_escape_in_another_pane_keeps_the_bar(self):
        other = self.s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', self.pane, 'exec sleep 100000')
        self.find('needle')
        self.wait_status('1 of 3', 'Find in Pane did not find the needles')
        self.s.tmux('select-pane', '-t', other)
        self.focus_terminal()
        self.s.act('action', 'quick-switch-input', 'Send Escape')
        time.sleep(1)
        self.assertTrue(self.s.has('terminal-find-field'), 'Esc in another Pane closed Find in Pane')
        self.assertEqual(self.pane_format('#{pane_mode}'), 'copy-mode', 'Esc in another Pane ended the search')

    def test_the_searched_pane_shows_the_find_colors_until_done(self):
        style = lambda name: self.s.tmux('show-options', '-pqv', '-t', self.pane, name)
        self.find('needle')
        self.wait_status('1 of 3', 'Find in Pane did not find the needles')
        # The defaults of ui.find_colors.
        self.assertEqual(style('copy-mode-match-style'), 'bg=#ffd54f,fg=#000000')
        self.assertEqual(style('copy-mode-current-match-style'), 'bg=#ff9600,fg=#000000')
        self.s.act('press', 'terminal-find-done')
        wait(lambda: style('copy-mode-match-style') == '' and style('copy-mode-current-match-style') == '',
             'Done left the find colors on the Pane')

    def test_the_find_field_keeps_the_terminals_focus(self):
        self.find('needle')
        self.wait_status('1 of 3', 'Find in Pane did not find the needles')
        responders = self.s.driver('responder')['responders']
        self.assertNotIn('TerminalSurfaceView', responders, 'the find field does not have Focus')
        self.s.act('press', 'terminal-find-done')
        wait(lambda: 'TerminalSurfaceView' in self.s.driver('responder')['responders'],
             'Done did not give Focus back to the Terminal')


if __name__ == '__main__':
    unittest.main()
