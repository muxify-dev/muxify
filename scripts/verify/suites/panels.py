"""The header's panel toggles, Maximize and Focus: what a Window shows of its Sidebar, Terminal and Browser.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.panels
"""

import re
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/zsh -f'
PAGE = 'data:text/html,panels'
PANELS = {'sidebar-panel': 'sidebar', 'terminal-panel': 'terminal', 'browser-panel': 'browser'}
# The app reads tmux once per second.
SETTLE = 2.0


class Panels(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'panels', '-x', '200', '-y', '50', SHELL)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES'])
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(), 'the app attached no tmux client')

    def setUp(self):
        self.window = self.new_window(self.id().rsplit('.', 1)[-1][:24])

    def new_window(self, name, tabs=True):
        """A Window that shows its Terminal and, with tabs, its Browser, selected with the Sidebar shown."""
        # One tmux call, so the app never reads the Window without its Browser options.
        options = [arg for option, value in [('@muxify_tabs', PAGE), ('@muxify_active_tab', '0'), ('@muxify_browser', 'on')]
                   for arg in (';', 'set-option', '-w', '-t', 'panels:' + name, option, value)] if tabs else []
        self.s.tmux('new-window', '-d', '-t', self.session + ':', '-n', name, SHELL, *options)
        window = self.s.tmux('display-message', '-p', '-t', 'panels:' + name, '#{window_id}')
        self.select_window(window)
        if self.s.row('toggle-sidebar').get('accessibilityValue') == 'off':
            self.s.act('press', 'toggle-sidebar')
        self.wait_panels({'sidebar', 'terminal', 'browser'} if tabs else {'sidebar', 'terminal'},
                         'the new Window %s does not show its panels' % window)
        return window

    def select_window(self, window):
        """Moves the app's tmux client to the Window, as tmux navigation does."""
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').split('\n'):
            if tty.endswith(' 0'):
                self.s.tmux('switch-client', '-c', tty.split()[0], '-t', window)
        self.s.wait_shown(window)

    def panels(self, rs=None):
        return {name for key, name in PANELS.items() if self.s.has(key, rs)}

    def wait_panels(self, expected, message):
        return self.s.wait_rows(lambda rs: self.panels(rs) == expected,
                                '%s: shows %s, not %s' % (message, sorted(self.panels()), sorted(expected)))

    def option(self, name):
        return self.s.tmux('show-options', '-wqv', '-t', self.window, name)

    def wait_options(self, expected, message):
        """The app writes its state onto the tmux Window a moment after the change."""
        wait(lambda: all(self.option(name) == value for name, value in expected.items()),
             '%s: %s' % (message, {name: self.option(name) for name in expected}))

    def client_width(self):
        widths = self.s.tmux('list-clients', '-F', '#{client_control_mode} #{client_width}').split('\n')
        return [line.split()[1] for line in widths if line.startswith('0 ')]

    def test_terminal_toggle_hides_the_terminal_and_the_browser_fills_its_room(self):
        self.s.act('press', 'toggle-terminal')
        rs = self.wait_panels({'sidebar', 'browser'}, 'the Terminal toggle did not hide the Terminal')
        _, sidebar_right = horizontal(self.s.row('sidebar-panel', rs))
        browser_left, _ = horizontal(self.s.row('browser-panel', rs))
        self.assertLess(abs(browser_left - sidebar_right), 3,
                        'the Browser starts at %.0f, not at the Sidebar edge %.0f' % (browser_left, sidebar_right))
        self.wait_options({'@muxify_browser': 'only'}, 'the tmux Window does not say the Browser is alone')
        self.s.act('press', 'toggle-terminal')
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'the Terminal toggle did not show the Terminal again')

    def test_browser_toggle_does_nothing_while_the_browser_is_the_only_side(self):
        self.s.act('press', 'toggle-terminal')
        self.wait_panels({'sidebar', 'browser'}, 'the Terminal toggle did not hide the Terminal')
        self.s.driver('press', 'toggle-browser')
        self.s.driver('press', 'Hide Browser')
        time.sleep(SETTLE)
        self.assertEqual(self.panels(), {'sidebar', 'browser'}, 'the Browser toggle hid the only side shown')
        self.s.act('press', 'toggle-terminal')

    def test_the_toggles_mark_the_maximized_side_and_the_side_it_hides(self):
        self.s.act('press', 'Maximize Terminal')
        self.wait_panels({'terminal'}, 'Maximize Terminal did not show the Terminal alone')
        self.wait_toggles({'toggle-terminal': 'maximized', 'toggle-browser': 'hidden'},
                          'the toggles do not mark the Maximized Terminal and the hidden Browser')
        self.s.act('press', 'toggle-maximize')
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'Restore did not show what the toggles say')
        self.wait_toggles({'toggle-terminal': 'on', 'toggle-browser': 'on'}, 'the toggles kept a Maximize mark after Restore')

    def test_the_zoom_pane_command_zooms_the_current_pane(self):
        target = 'panels:' + self.id().rsplit('.', 1)[-1][:24]
        self.s.tmux('split-window', '-d', '-t', target, SHELL)
        self.run_command('Zoom Pane')
        wait(lambda: self.s.tmux('display-message', '-p', '-t', target, '#{window_zoomed_flag}') == '1',
             'the Zoom Pane Command did not zoom the current Pane')
        self.run_command('Zoom Pane')
        wait(lambda: self.s.tmux('display-message', '-p', '-t', target, '#{window_zoomed_flag}') == '0',
             'the Zoom Pane Command did not show all the Panes again')

    def run_command(self, title):
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', title)
        key = 'palette-row-command-' + title
        self.s.wait_rows(lambda rs: self.s.has(key, rs), '%s was missing from Commands' % title)
        self.s.act('press', key)

    def wait_toggles(self, expected, message):
        values = lambda rs: {key: self.s.row(key, rs).get('accessibilityValue') for key in expected}
        return self.s.wait_rows(lambda rs: values(rs) == expected, '%s: %s' % (message, values(self.s.rows())))

    def test_maximize_hides_the_sidebar_and_the_other_side_and_restore_shows_both(self):
        self.s.act('press', 'Maximize Browser')
        self.wait_panels({'browser'}, 'Maximize Browser did not show the Browser alone')
        self.wait_options({'@muxify_maximize': 'browser', '@muxify_browser': 'on'},
                          'the tmux Window does not keep the toggles with the Browser Maximized')
        self.s.act('press', 'toggle-maximize')
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'Restore did not show what the toggles say')
        self.wait_options({'@muxify_maximize': ''}, 'Maximize stayed on the tmux Window')

    def test_maximize_of_a_hidden_browser_shows_it_alone_with_a_blank_tab_until_restore(self):
        self.window = self.new_window('hidden-browser', tabs=False)
        self.s.act('press', 'Maximize Browser')
        self.wait_panels({'browser'}, 'Maximize Browser did not show the hidden Browser alone')
        self.s.act('press', 'Maximize Browser')
        self.wait_panels({'sidebar', 'terminal'}, 'Restore did not hide the Browser again')
        self.wait_options({'@muxify_tabs': ''}, 'the blank Tab stayed after Restore')

    def test_a_toggle_while_maximized_keeps_what_is_on_screen_then_applies(self):
        self.s.act('press', 'Maximize Terminal')
        self.wait_panels({'terminal'}, 'Maximize Terminal did not show the Terminal alone')
        self.s.act('press', 'toggle-sidebar')
        self.wait_panels({'sidebar', 'terminal'}, 'the Sidebar toggle while Maximized did not keep the Terminal alone')
        self.wait_options({'@muxify_browser': '', '@muxify_maximize': ''},
                          'the toggles on the tmux Window are not the Terminal alone without Maximize')

    def test_maximize_belongs_to_its_window(self):
        other = self.new_window('maximize-other')
        self.select_window(self.window)
        self.s.act('press', 'Maximize Terminal')
        self.wait_panels({'terminal'}, 'Maximize Terminal did not hide the Sidebar')
        self.select_window(other)
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'a Window without Maximize does not show the Sidebar')
        self.select_window(self.window)
        self.wait_panels({'terminal'}, 'the Maximized Window did not hide the Sidebar again')
        self.s.act('press', 'toggle-maximize')
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'Restore did not show what the toggles say')

    def test_focus_terminal_shows_a_hidden_terminal(self):
        self.s.act('press', 'toggle-terminal')
        self.wait_panels({'sidebar', 'browser'}, 'the Terminal toggle did not hide the Terminal')
        self.s.act('press', 'Focus Terminal')
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'Focus Terminal did not show the hidden Terminal')
        self.wait_options({'@muxify_browser': 'on'}, 'Focus Terminal did not turn the Terminal toggle on')
        self.wait_focus('terminal', 'Focus Terminal did not give the Terminal Focus')

    def test_focus_browser_restores_a_maximized_terminal(self):
        self.s.act('press', 'Maximize Terminal')
        self.wait_panels({'terminal'}, 'Maximize Terminal did not show the Terminal alone')
        self.s.act('press', 'Focus Browser')
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'Focus Browser did not restore the Maximized Terminal')
        self.wait_options({'@muxify_maximize': '', '@muxify_browser': 'on'},
                          'Focus Browser did not restore the toggles on the tmux Window')
        self.wait_focus('browser', 'Focus Browser did not give the Browser Focus')

    def test_the_focus_browser_command_gives_the_browser_focus(self):
        self.s.act('press', 'Focus Terminal')
        self.wait_focus('terminal', 'Focus Terminal did not give the Terminal Focus')
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Focus Browser')
        key = 'palette-row-command-Focus Browser'
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Focus Browser was missing from Commands')
        self.s.act('press', key)
        self.wait_focus('browser', 'the Focus Browser Command did not give the Browser Focus')

    def wait_focus(self, side, message):
        def has_focus():
            responders = self.s.driver('responder')['responders']
            return any(name.startswith(FOCUS_CLASSES[side]) for name in responders)
        wait(has_focus, message)

    def test_the_tmux_client_keeps_its_width_while_the_terminal_is_hidden(self):
        time.sleep(SETTLE)
        before = self.client_width()
        self.s.act('press', 'toggle-terminal')
        self.wait_panels({'sidebar', 'browser'}, 'the Terminal toggle did not hide the Terminal')
        time.sleep(SETTLE)
        self.assertEqual(self.client_width(), before, 'tmux resized the client while the Terminal is hidden')
        self.s.act('press', 'toggle-terminal')
        self.wait_panels({'sidebar', 'terminal', 'browser'}, 'the Terminal toggle did not show the Terminal again')
        time.sleep(SETTLE)
        self.assertEqual(self.client_width(), before, 'tmux resized the client when the Terminal came back')


FOCUS_CLASSES = {'terminal': ('TerminalSurfaceView',), 'browser': ('WKWebView', 'WKContentView', 'NSTextView')}


def horizontal(row):
    """(left, right) of a dump row's accessibilityFrame, in screen points."""
    x, _, width, _ = map(float, re.findall(r'-?[\d.]+', row['accessibilityFrame']))
    return x, x + width


if __name__ == '__main__':
    unittest.main()
