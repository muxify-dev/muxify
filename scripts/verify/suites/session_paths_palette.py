"""The Session Paths that a palette lists right after the app starts, before discovery finishes, and Start a Session
on a server with no Session of the user's.

The app saves each discovery's output in the state folder. After a restart the palette lists those Session Paths at
once, and the new discovery replaces them when it finishes. A `git` first in the app's PATH makes discovery slow
after the restart, so the check sees the saved list before the new one.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.session_paths_palette
"""

import os
import shutil
import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait

SLOW_DISCOVERY = 30
LAUNCH_ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES']


class SessionPathsPalette(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.projects = s.root/'projects'
        cls.saved = cls.projects/'saved-repo'
        cls.saved.mkdir(parents=True)
        subprocess.run(['/usr/bin/git', 'init', '-q', '-b', 'main', str(cls.saved)], check=True)
        (s.root/'config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(cls.projects) + '/*\n'
                                                       'command_palettes:\n'
                                                       '  - {name: Go to…, sources: [sessions]}\n')
        cls.cache = s.root/'state/muxify/session-paths/local.json'
        s.tmux('new-session', '-d', '-s', 'base', '-c', str(s.root), '/bin/zsh -f')
        s.launch(LAUNCH_ARGS)

    def open_palette(self):
        """Presses the View menu item until the palette shows. SwiftUI rebuilds the menu a moment after the app
        starts, and a press in that moment can miss."""
        def opened():
            self.s.driver('press', 'Go to…')
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if self.s.has('palette-search'):
                    return True
            return False
        wait(opened, 'the palette did not open', seconds=20)

    def row(self, path):
        return 'palette-row-session-path:' + str(path)

    def search(self, text):
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', text)

    def sessions(self):
        """The Session names on the sandbox server; none when no server runs."""
        listed = self.s.tmux_ok('list-sessions', '-F', '#{session_name}')
        return listed.stdout.split() if listed.returncode == 0 else []

    def test_a_server_with_no_session_starts_one_through_start_session(self):
        """With no Session of the user's, the app starts none, not even `main`. It opens the palette on Start a Session;
        Cancel leaves the "No tmux Sessions" page, whose Start a Session… button opens the palette again; a row starts
        a No Topic Session in its folder, named after it. Every step is a press, so the check takes no focus."""
        socket = self.s.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(os.path.realpath(socket).startswith(os.path.realpath(self.s.root)), socket)
        self.s.tmux_ok('kill-server')
        self.s.restart_app(LAUNCH_ARGS)

        home_row = 'palette-row-home-folder'
        wait(lambda: self.s.has(home_row), 'the palette did not open on Start a Session at launch', seconds=20)
        self.assertNotIn('main', self.sessions(), 'the app made main')
        self.s.act('press', 'palette-cancel')
        wait(lambda: not self.s.has('palette-search'), 'Cancel did not close the palette')
        self.assertTrue(self.s.has('no-sessions-start-session'), 'the page has no Start a Session… button')
        time.sleep(1.5)
        self.assertEqual(self.sessions(), [], 'closing the palette started a Session')

        self.s.act('press', 'no-sessions-start-session')
        wait(lambda: self.s.has(home_row), 'Start a Session… did not open the palette')
        def listed():
            self.search('saved')
            return self.s.has(self.row(self.saved))
        wait(listed, 'Start a Session does not list the Session Path', seconds=20)
        self.s.act('press', self.row(self.saved))
        wait(lambda: 'saved-repo' in self.sessions(), 'the row started no Session named after its folder: %s' % self.sessions())
        self.s.wait_shown('saved-repo')
        path = self.s.tmux('display-message', '-p', '-t', '=saved-repo:', '#{session_path}')
        self.assertEqual(os.path.realpath(path), os.path.realpath(self.saved))
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=saved-repo', '@muxify_topic'), '', 'the Session has a Topic')
        self.assertNotIn('main', self.sessions())

    def test_the_last_found_session_paths_show_right_after_a_restart_until_discovery_finishes(self):
        wait(self.cache.exists, 'the first discovery saved no output at %s' % self.cache, seconds=20)
        newcomer = self.projects/'newcomer'
        newcomer.mkdir()
        shim = self.s.root/'slow-git'
        shim.mkdir()
        real_git = shutil.which('git', path=self.s.app_env['PATH']) or '/usr/bin/git'
        (shim/'git').write_text('#!/bin/sh\ncase " $* " in *" config --bool core.bare "*) sleep %d ;; esac\nexec %s "$@"\n'
                                % (SLOW_DISCOVERY, real_git))
        os.chmod(shim/'git', 0o755)
        self.s.app_env['PATH'] = str(shim) + ':' + self.s.app_env['PATH']

        started = time.monotonic()
        self.s.restart_app(LAUNCH_ARGS)
        self.open_palette()
        def listed():
            self.search('repo')
            return self.s.has(self.row(self.saved))
        wait(listed, 'the saved Session Path is not in the palette after the restart', seconds=10)
        shown = time.monotonic() - started
        self.assertLess(shown, SLOW_DISCOVERY, 'the row showed only after discovery could finish')
        self.search('newcomer')
        time.sleep(1)
        self.assertFalse(self.s.has(self.row(newcomer)),
                         'a folder made after the save is listed %.1f s after the restart, so the list is not the saved one' % shown)

        def discovered():
            self.search('newcomer')
            return self.s.has(self.row(newcomer))
        wait(discovered, 'the finished discovery did not replace the saved Session Paths', seconds=SLOW_DISCOVERY + 30)


if __name__ == '__main__':
    unittest.main()
