"""The shell of the App Window: the menu bar, the frames of the App Window's parts, and the behaviours of the windows.

The menu bar and the frames are records of the SwiftUI shell: `fixtures/app_window_menu_bar.txt` and PARTS. Another
shell must match them. The driver reads the menu bar while the app stays in the background, so the record has what
each menu holds before it opens: AppKit adds some items, such as View › Enter Full Screen, only while a menu opens in
the active app.

The focused App Window changes only through a choice of Environment while the app is in the background, so the Show
Panes check opens a Remote App Window. Its SSH fixture runs remote commands locally, so the Remote Environment's tmux
server is the Sandbox server.
"""

import difflib
import re
import shlex
import subprocess
import time
import unittest

from scripts.verify.sandbox import REPO, Sandbox, alive, wait

MENU_BAR = REPO/'scripts/verify/fixtures/app_window_menu_bar.txt'
LAUNCH_ARGS = ['-sidebarVisible', 'YES']
# The App Window's size at launch, at which PARTS were recorded.
WINDOW_SIZE = (1500, 920)
# The frame of each part with the Browser shown: x, y, width and height in points from the App Window's top left corner.
PARTS = {
    'traffic-light-close': (8, 8, 16, 16),
    'traffic-light-minimize': (31, 8, 16, 16),
    'traffic-light-zoom': (54, 8, 16, 16),
    'header-bar': (0, 0, 1500, 30),
    'sidebar-panel': (0, 0, 260, 920),
    'terminal-panel': (261, 30, 681, 890),
    'browser-panel': (943, 0, 558, 920),
}
KEYS = {'\r': '↩', '\t': '⇥', '\x1b': '⎋', ' ': 'Space', '\x08': '⌫', '\x7f': '⌫', '': '↑', '': '↓',
        '': '←', '': '→', '': '⌦'}
MODIFIERS = [('function', 'fn'), ('control', '⌃'), ('option', '⌥'), ('shift', '⇧'), ('command', '⌘')]


def shortcut(item):
    """The key equivalent as the menu shows it, such as ⇧⌘N. AppKit reads an upper-case letter as the letter with ⇧."""
    key, modifiers = item['key'], set(item['modifiers'])
    if not key:
        return ''
    if key.isalpha() and key.isupper():
        key, modifiers = key.lower(), modifiers | {'shift'}
    code = ord(key[0])
    name = 'F%d' % (code - 0xF703) if 0xF704 <= code <= 0xF726 else KEYS.get(key, key.upper())
    return ''.join(symbol for flag, symbol in MODIFIERS if flag in modifiers) + name


def menu_lines(items, path=()):
    """A line for each item that the user sees, in order, named by its title path, such as
    `File › New Muxify Window | ⇧⌘N`, with `disabled`, `checked`, `mixed` or `alternate` after it. A separator is `---`."""
    lines = []
    for item in items:
        if item.get('hidden'):
            continue
        if item.get('separator'):
            lines.append(' › '.join(path + ('---',)))
            continue
        here = path + (item['title'],)
        words = [' › '.join(here), shortcut(item), '' if item['enabled'] else 'disabled',
                 {'on': 'checked', 'mixed': 'mixed'}.get(item['state'], ''), 'alternate' if item['alternate'] else '']
        lines.append(' | '.join(word for word in words if word))
        # macOS fills Services with the services of the apps on this Mac.
        if 'items' in item and here[1:] != ('Services',):
            lines += menu_lines(item['items'], here)
    return lines


def rect(row):
    """x, y, width and height of a dump row's accessibilityFrame, in screen points from the bottom left."""
    return tuple(map(float, re.findall(r'-?[\d.]+', row['accessibilityFrame'])))


class AppWindow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        home = s.root/'remote-home'
        home.mkdir()
        remote_tmp = s.root/'remote-tmp'
        remote_tmp.mkdir()
        (s.root/'config/muxify/config.yaml').write_text(
            'command_palettes:\n'
            '  - name: Commands\n    keybinding: cmd+shift+p\n    sources: [commands]\n'
            '  - name: Go to…\n    keybinding: cmd+p\n    sources: [topics, sessions]\n'
            'remote_environments:\n  - name: Fixture\n    host: unused\n    username: unused\n')
        fake = s.root/'ssh'
        fake.write_text('''#!/bin/bash
unset TMUX TMUX_PANE XDG_CONFIG_HOME XDG_STATE_HOME
export TMUX_TMPDIR=%s TMPDIR=%s HOME=%s
for arg do
    if [ "$arg" = -O ]; then exit 0; fi
    if [ "$arg" = -tt ]; then exec 2>&1; fi
    command=$arg
done
exec /bin/sh -c "$command"
''' % tuple(shlex.quote(str(p)) for p in [s.root/'tmux', remote_tmp, home]))
        fake.chmod(0o755)
        s.app_env['MUXIFY_TEST_SSH'] = str(fake)
        cls.window = s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'app-window', '-c', str(s.root), '/bin/sh')
        s.launch(LAUNCH_ARGS)

    def setUp(self):
        # Checks open App Windows, a Remote App Window and Settings, or quit: each check starts from one Local App Window.
        windows = self.windows() if alive(self.s.pid) else []
        if len(windows) != 1 or self.environment(windows[0]) != 'Local':
            self.relaunch()
            windows = self.windows()
            self.assertEqual([self.environment(window) for window in windows], ['Local'], 'the app did not start on one Local App Window')

    def relaunch(self, *args):
        if alive(self.s.pid):
            self.s.restart_app(LAUNCH_ARGS + list(args))
        else:
            self.s.launch(LAUNCH_ARGS + list(args))

    def windows(self, rows=None):
        """The rows of each window: its AXWindow row and the rows after it in the dump, up to the next window's."""
        windows = []
        for row in self.s.rows() if rows is None else rows:
            if row.get('accessibilityRole') == 'AXWindow':
                windows.append([])
            if windows:
                windows[-1].append(row)
        return windows

    def app_windows(self, rows=None):
        return [window for window in self.windows(rows) if self.s.has('header-bar', window)]

    def environment(self, window):
        return self.s.row('header-environment-selector', window).get('accessibilityValue')

    def item(self, *path):
        """The menu bar item at the title path, or None."""
        item = {'items': self.s.act('menus')['menus']}
        for title in path:
            item = next((each for each in item.get('items', []) if each.get('title') == title), None)
            if item is None:
                return None
        return item

    def choose_if_shown(self, *path):
        """Chooses the menu item when the app runs and the menu has it, as a clean-up that puts a toggle back."""
        if alive(self.s.pid) and self.item(*path):
            self.s.act('menu', path=list(path))

    def test_the_menu_bar_matches_the_record_of_the_swiftui_shell(self):
        self.s.show(self.window)
        record = MENU_BAR.read_text().splitlines()
        shown = []

        def matches():
            shown[:] = menu_lines(self.s.act('menus')['menus'])
            return shown == record
        wait(matches, lambda: 'the menu bar differs from %s in each item below:\n%s' % (MENU_BAR.name, '\n'.join(
            difflib.unified_diff(record, shown, 'record', 'menu bar', lineterm='', n=0))), seconds=10)

    def test_the_sidebar_item_names_what_choosing_it_does(self):
        self.assertIsNotNone(self.item('View', 'Hide Sidebar'), 'the View menu has no Hide Sidebar while the Sidebar shows')
        self.addCleanup(self.choose_if_shown, 'View', 'Show Sidebar')
        titles = lambda: [each.get('title') for each in self.item('View')['items']]
        self.s.act('menu', path=['View', 'Hide Sidebar'])
        wait(lambda: not self.s.has('sidebar-panel') and self.item('View', 'Show Sidebar') and not self.item('View', 'Hide Sidebar'),
             lambda: 'after Hide Sidebar the View menu has %s' % titles())
        self.s.act('menu', path=['View', 'Show Sidebar'])
        wait(lambda: self.s.has('sidebar-panel') and self.item('View', 'Hide Sidebar') and not self.item('View', 'Show Sidebar'),
             lambda: 'after Show Sidebar the View menu has %s' % titles())

    def test_the_show_panes_check_follows_the_focused_app_window(self):
        for key in ['selectedEnvironment', 'panesVisible']:
            self.addCleanup(subprocess.run, ['defaults', 'delete', self.s.bundle_id, key], capture_output=True)
        self.relaunch('-selectedEnvironment', 'Fixture')
        environments = lambda: [self.environment(window) for window in self.app_windows()]
        wait(lambda: len(environments()) == 1 and 'Fixture' in (environments()[0] or ''),
             lambda: 'the app did not start on one Remote App Window: %s' % environments())
        # The Local App Window that the link opens stays behind, and the Remote App Window keeps focus.
        self.s.select(self.window)
        wait(lambda: len(self.app_windows()) == 2, 'the select link opened no Local App Window')
        self.assertEqual(self.item('View', 'Show Panes')['state'], 'off', 'Show Panes is checked before it is chosen')
        self.s.act('menu', path=['View', 'Show Panes'])
        wait(lambda: self.item('View', 'Show Panes')['state'] == 'on', 'Show Panes is not checked after it is chosen')
        # A second link brings the Local App Window forward and focuses it.
        self.s.select(self.window)
        wait(lambda: self.item('View', 'Show Panes')['state'] == 'off',
             'Show Panes stays checked after the Local App Window takes focus from the Remote App Window')

    def test_the_window_parts_are_where_the_swiftui_shell_put_them(self):
        self.addCleanup(self.choose_if_shown, 'Browser', 'Hide Browser')
        self.s.act('menu', path=['Browser', 'Show Browser'])
        recorded = dict(PARTS, **{'App Window size': WINDOW_SIZE})
        shown = {}
        differences = lambda: [key for key, value in recorded.items()
                               if key not in shown or any(abs(a - b) > .5 for a, b in zip(shown[key], value))]

        def placed():
            window = self.app_windows()[0]
            x, y, width, height = rect(window[0])
            shown.clear()
            shown['App Window size'] = (width, height)
            for key in PARTS:
                if self.s.has(key, window):
                    left, bottom, part_width, part_height = rect(self.s.row(key, window))
                    shown[key] = (left - x, y + height - bottom - part_height, part_width, part_height)
            return not differences()
        wait(placed, lambda: 'the App Window parts are not where they were recorded:\n' + '\n'.join(
            '%s: recorded %s, shown %s' % (key, recorded[key], shown.get(key, 'nothing')) for key in differences()), seconds=10)

    def test_new_muxify_window_opens_a_second_app_window(self):
        self.s.act('menu', path=['File', 'New Muxify Window'])
        wait(lambda: len(self.app_windows()) == 2,
             lambda: 'New Muxify Window left %d App Windows' % len(self.app_windows()))

    def test_a_select_link_acts_in_the_app_window_and_opens_no_other(self):
        window = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'linked', '-c', str(self.s.root), '/bin/sh')
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', 'linked')
        self.addCleanup(self.s.show, self.window)
        self.s.show(window)
        time.sleep(2)
        self.assertEqual(len(self.app_windows()), 1, 'the select link opened another App Window')

    def test_settings_opens_one_settings_window_on_two_presses(self):
        others = lambda: [window[0].get('accessibilityTitle') for window in self.windows()
                          if not self.s.has('header-bar', window)]
        self.s.act('menu', path=['Muxify', 'Settings…'])
        wait(lambda: len(others()) == 1, lambda: 'Settings… opened %s' % others())
        self.s.act('menu', path=['Muxify', 'Settings…'])
        time.sleep(2)
        self.assertEqual(len(others()), 1, 'a second Settings… opened another window: %s' % others())

    def test_closing_the_last_app_window_quits_the_app(self):
        app = self.s.pid
        self.s.act('press', 'traffic-light-close')
        wait(lambda: not alive(app), 'the app still runs after its last App Window closed', 20)

    # The AppKit shell restores App Windows in task 03 (restore-app-windows-through-appkit).
    @unittest.expectedFailure
    def test_app_windows_and_their_frames_come_back_after_a_relaunch(self):
        subprocess.run(['defaults', 'write', self.s.bundle_id, 'NSQuitAlwaysKeepsWindows', '-bool', 'YES'], check=True)
        self.addCleanup(subprocess.run, ['defaults', 'delete', self.s.bundle_id, 'NSQuitAlwaysKeepsWindows'], capture_output=True)
        self.relaunch()
        frames = lambda: sorted(window[0]['accessibilityFrame'] for window in self.app_windows())
        self.s.act('menu', path=['File', 'New Muxify Window'])
        kept = wait(lambda: (lambda shown: shown if len(shown) == 2 else None)(frames()),
                    'New Muxify Window opened no second App Window')
        # A SIGTERM leaves no saved windows; a quit through AppKit saves them.
        self.s.quit()
        self.s.launch(LAUNCH_ARGS, fresh=False)
        wait(lambda: frames() == kept, lambda: 'after the relaunch the App Windows are %s, not %s' % (frames(), kept))
