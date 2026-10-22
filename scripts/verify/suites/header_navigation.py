"""Session identity, Git entry point and adaptive tmux Window navigation in the titlebar."""

import re
import subprocess
import unittest

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/zsh -f'


class HeaderNavigation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        s.tmux('new-session', '-d', '-s', 'header-bootstrap', SHELL)
        s.tmux('set-option', '-g', 'base-index', '1')
        s.launch()
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(),
             'the app attached no tmux client')

    def setUp(self):
        self.name = self.id().rsplit('.', 1)[-1]
        self.repo = self.s.root/self.name
        self.repo.mkdir()
        self.git('init', '-b', 'header-main')
        self.git('-c', 'user.name=Verify', '-c', 'user.email=verify@example.test',
                 '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-m', 'Fixture')
        self.window = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}',
                                  '-s', self.name, '-n', 'fish', '-c', str(self.repo), SHELL)
        self.select_window(self.window)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args],
                                       env=self.s.env, text=True, stderr=subprocess.DEVNULL).strip()

    def select_window(self, window):
        for client in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').splitlines():
            if client.endswith(' 0'):
                self.s.tmux('switch-client', '-c', client.split()[0], '-t', window)
        self.s.wait_shown(window)

    def wait_head(self, expected):
        rs = self.s.wait_rows(lambda rs: self.s.row('toggle-git-view', rs).get('accessibilityLabel') == expected,
                              'header did not show Git HEAD ' + expected)
        self.assertEqual(self.s.row('toggle-git-view', rs)['accessibilityLabel'], expected)

    def test_session_name_follows_tmux_rename(self):
        self.s.tmux('rename-session', '-t', self.name, 'header-renamed')
        rs = self.s.wait_rows(lambda rs: self.s.row('header-session-name', rs).get('accessibilityValue') == 'header-renamed',
                              'header did not follow Session rename')
        self.assertEqual(self.s.row('header-session-name', rs)['accessibilityValue'], 'header-renamed')

    def test_session_name_uses_available_space_instead_of_a_fixed_width_cap(self):
        name = 'session-name-long-enough-to-use-more-than-two-hundred-points'
        self.s.tmux('rename-session', '-t', self.name, name)
        rs = self.s.wait_rows(lambda rs: self.s.row('header-session-name', rs).get('accessibilityValue') == name,
                             'header did not show the long Session name')
        _, _, width, _ = bounds(self.s.row('header-session-name', rs))
        self.assertGreater(width, 300, 'Session name is still limited to a fixed width: %s' % width)

    def test_oversized_session_name_shrinks_without_pushing_controls_out_of_the_header(self):
        name = 'a-very-long-session-name-' * 40
        self.s.tmux('rename-session', '-t', self.name, name)
        rs = self.s.wait_rows(lambda rs: self.s.row('header-session-name', rs).get('accessibilityValue') == name,
                             'header did not show the oversized Session name')
        app_window = next(row for row in rs if row.get('accessibilityRole') == 'AXWindow')
        left, _, window_width, _ = bounds(app_window)
        name_x, _, name_width, _ = bounds(self.s.row('header-session-name', rs))
        git_x, _, _, _ = bounds(self.s.row('toggle-git-view', rs))
        self.assertGreater(name_width, 200, 'Session name did not use the available width')
        self.assertLessEqual(name_x + name_width, git_x, 'Session name overlaps the Git button')
        for key in ['toggle-git-view', 'header-environment-selector', 'toggle-maximize',
                    'toggle-sidebar', 'toggle-terminal', 'toggle-browser']:
            x, _, width, _ = bounds(self.s.row(key, rs))
            self.assertGreaterEqual(x, left, key + ' moved before the App Window')
            self.assertLessEqual(x + width, left + window_width + 1, key + ' overflowed the App Window')

    def test_status_line_header_can_be_disabled_live_without_hiding_git_or_controls(self):
        self.wait_head('header-main')
        config = self.s.root/'config/muxify/config.yaml'
        self.addCleanup(config.unlink, missing_ok=True)
        config.write_text('ui:\n  status_line_header: false\n')
        rs = self.s.wait_rows(lambda rs: not self.s.has('header-session-name', rs)
                             and not any(key.startswith('header-window-') for key in self.s.ids(rs)),
                             'status_line_header: false did not hide Session and Window navigation')
        for key in ['toggle-git-view', 'header-environment-selector', 'toggle-sidebar',
                    'toggle-terminal', 'toggle-browser', 'toggle-maximize']:
            self.assertTrue(self.s.has(key, rs), key + ' disappeared with status_line_header: false')
        self.assertEqual(self.s.row('toggle-git-view', rs)['accessibilityLabel'], 'header-main')
        self.s.act('click', 'toggle-git-view')
        self.s.wait_rows(lambda rs: self.s.has('git-view', rs), 'Git View stopped opening with the Session header hidden')
        self.s.act('press', 'toggle-git-view')
        config.write_text('')
        rs = self.s.wait_rows(lambda rs: self.s.has('header-session-name', rs)
                             and self.s.has('header-window-' + self.window, rs),
                             'removing status_line_header did not restore Session and Window navigation')
        self.assertEqual(self.s.row('header-window-' + self.window, rs)['accessibilityValue'], 'selected')

    def test_branch_button_opens_git_view_and_is_before_environment_on_the_right(self):
        self.wait_head('header-main')
        rs = self.s.rows()
        buttons = [r for r in rs if r.get('accessibilityIdentifier') == 'toggle-git-view']
        self.assertEqual(len(buttons), 1, 'the right header still has a duplicate Git button')
        git_x = float(re.findall(r'-?[\d.]+', buttons[0]['accessibilityFrame'])[0])
        window_x = float(re.findall(r'-?[\d.]+', self.s.row('header-window-' + self.window, rs)['accessibilityFrame'])[0])
        environment_x = float(re.findall(r'-?[\d.]+', self.s.row('header-environment-selector', rs)['accessibilityFrame'])[0])
        self.assertLess(window_x, git_x, 'Git button is not after the Window strip')
        self.assertLess(git_x, environment_x, 'Git button is not before the Environment selector')
        self.s.act('click', 'toggle-git-view')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-view', rs),
                              'branch click did not open Git View')
        self.assertEqual(self.s.row('toggle-git-view', rs)['accessibilityValue'], 'on')
        self.s.act('press', 'toggle-git-view')

    def test_branch_follows_checkout_without_opening_git_view(self):
        self.wait_head('header-main')
        self.git('checkout', '-b', 'header-feature')
        self.wait_head('header-feature')
        self.assertEqual(self.s.row('toggle-git-view')['accessibilityValue'], 'off')

    def test_detached_head_shows_short_commit(self):
        self.git('checkout', '--detach')
        self.wait_head(self.git('rev-parse', '--short', 'HEAD'))

    def new_window(self, name):
        return self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', self.name + ':',
                           '-n', name, '-c', str(self.repo), SHELL)

    def test_window_click_switches_and_highlights_it_and_follows_tmux(self):
        second = self.new_window('opencode')
        other = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'other-header-session', SHELL)
        rs = self.s.wait_rows(lambda rs: self.s.has('header-window-' + second, rs),
                              'second Window did not appear in header')
        self.assertFalse(self.s.has('header-window-' + other, rs), 'header lists another Session\'s Windows')
        keys = [key for key in self.s.ids(rs) if key.startswith('header-window-')]
        self.assertEqual(keys, ['header-window-' + self.window, 'header-window-' + second])
        self.s.act('click', 'header-window-' + second)
        self.s.wait_shown(second)
        rs = self.s.wait_rows(lambda rs: self.s.row('header-window-' + second, rs).get('accessibilityValue') == 'selected',
                              'clicked Window was not highlighted')
        self.assertNotEqual(self.s.row('header-window-' + self.window, rs).get('accessibilityValue'), 'selected')
        self.select_window(self.window)
        rs = self.s.wait_rows(lambda rs: self.s.row('header-window-' + self.window, rs).get('accessibilityValue') == 'selected',
                              'header did not follow tmux Window selection')
        self.assertNotEqual(self.s.row('header-window-' + second, rs).get('accessibilityValue'), 'selected')

    def test_window_list_collapses_when_it_cannot_fit_and_expands_when_it_can(self):
        # Two Windows still need a dropdown when their full names cannot fit. This tests actual
        # available space, rather than a fixed Window-count threshold.
        long_name = 'wide-window-' * 40
        second = self.new_window(long_name)
        self.s.wait_rows(lambda rs: self.s.has('header-window-menu', rs), 'overflow did not become a dropdown')
        index = self.s.tmux('display-message', '-p', '-t', second, '#{window_index}')
        # HeaderWindowSelector exposes each dropdown choice as an accessibility action, so the
        # check switches through the dropdown without opening a native menu and taking focus.
        self.s.act('action', 'header-window-menu', 'Select %s: %s' % (index, long_name))
        self.s.wait_shown(second)
        rs = self.s.wait_rows(lambda rs: self.s.row('header-window-menu', rs).get('accessibilityValue') == index + ': ' + long_name,
                              'dropdown did not follow its selected Window')
        self.assertEqual(self.s.row('header-window-menu', rs)['accessibilityValue'], index + ': ' + long_name)
        self.s.tmux('rename-window', '-t', second, 'opencode')
        rs = self.s.wait_rows(lambda rs: self.s.has('header-window-' + second, rs),
                              'Window list did not expand once it fit')
        self.assertFalse(self.s.has('header-window-menu', rs), 'dropdown stayed after the list fit inline')
        self.assertEqual(self.s.row('header-window-' + second, rs)['accessibilityValue'], 'selected')

    def test_git_label_clears_when_active_pane_leaves_repository(self):
        self.wait_head('header-main')
        second = self.s.tmux('split-window', '-P', '-F', '#{pane_id}', '-t', self.window,
                             '-c', str(self.s.root), SHELL)
        self.wait_head('Git')
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', self.window, '#{pane_id}'), second)


def bounds(row):
    return tuple(map(float, re.findall(r'-?[\d.]+', row['accessibilityFrame'])))


if __name__ == '__main__':
    unittest.main()
