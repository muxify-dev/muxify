"""A Remote App Window shows its Host's Topics, and runs with its Host's Config, through the Host Server, `muxify
server` on a channel of the attachment's SSH connection, and its Git View reads, changes and fetches the Host's
repository through the same server, with the Host's ssh asking its questions in the Git View through askpass.

The SSH fixture runs remote commands locally, as remote_session_end's does: the Host's tmux server is the Sandbox
server, the Host's home is `remote-home`, and the Host's Topics are in `remote-home/.local/state/muxify/muxify.db`,
apart from the Mac's own `state/muxify`. The Host's `muxify` is the first one on the fixture's PATH: the Debug app's
own CLI, which serves, or a stand-in with no server mode, which the app must answer with Sessions only and a reason.
The Host's Muxify Worktrees are its own too: their records are in the Host's database and their folders under the
Host's `$XDG_STATE_HOME/muxify/worktrees` (ADR 0090).

An Agent on the Host reaches the Remote App Window through its Host Server's own socket, which
`@muxify_browser_socket` names (ADR 0091): its Browser commands and view verbs run the CLI in a Pane of the Host's
tmux server, with the Host's environment, as an Agent there does.

The Host's Config names a Session Path root under `~`, which only the Host's home has, and the Host's `TMPDIR` is
`remote-tmp`: New Session lists the Host's folders and a dropped file is pasted as its path on the Host, both through
the Host Server's `session_paths` and `upload`.
"""

import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import time
import unittest

from scripts.verify.sandbox import DEBUG_APP, Sandbox, wait
from scripts.verify.topic_records import TopicRecords

CLI = DEBUG_APP/'Contents/Resources/bin/muxify'
OLD_BUILD = 'muxify 0123abc 1600000000'
# A Session Path root of the Host's Config: a folder of the Host's home, not of the Mac's.
HOST_FOLDERS = 'muxify-verify-host-folders'
RECORDER = '''import os, pathlib, sys, termios, tty
output, ready = map(pathlib.Path, sys.argv[1:])
old = termios.tcgetattr(0)
tty.setraw(0)
os.write(1, b'\\x1b[?2004h')
ready.touch()
data = b''
try:
    while not data.endswith(b'\\x1b[201~'):
        data += os.read(0, 1)
    output.write_bytes(data)
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
'''


class RemoteHostTopics(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.home = home = s.root/'remote-home'
        (home/'.config/muxify').mkdir(parents=True)
        cls.remote_tmp = remote_tmp = s.root/'remote-tmp'
        remote_tmp.mkdir()
        cls.host_folder = home/HOST_FOLDERS/'host-folder-alpha'
        cls.host_folder.mkdir(parents=True)
        cls.projects = s.root/'host-projects'
        cls.projects.mkdir()
        # The Host's own Config: its Session Paths, where `muxify topic add-session` starts a Session, and a root under
        # `~`, which names a folder only in the Host's home.
        (home/'.config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(cls.projects) + '/*\n'
                                                       '    - path: ~/' + HOST_FOLDERS + '/*\n')
        cls.host_store = TopicRecords(home/'.local/state/muxify')
        (s.root/'config/muxify/config.yaml').write_text(
            'remote_environments:\n  - name: Fixture\n    host: unused\n    username: unused\n')

        # The Host's muxify: `serving` links the Debug app's CLI, `old` holds a CLI from before `muxify server`.
        cls.bins = {'serving': s.root/'bin-serving', 'old': s.root/'bin-old'}
        for directory in cls.bins.values():
            directory.mkdir()
        (cls.bins['serving']/'muxify').symlink_to(CLI)
        old = cls.bins['old']/'muxify'
        old.write_text('#!/bin/sh\ncase "$1" in\n    --version) echo %s ;;\n    *) echo "muxify: unknown command $1" >&2; exit 2 ;;\nesac\n'
                       % shlex.quote(OLD_BUILD))
        old.chmod(0o755)
        cls.host_bin = s.root/'host-bin'

        fake = s.root/'ssh'
        fake.write_text('''#!/bin/bash
unset TMUX TMUX_PANE XDG_CONFIG_HOME XDG_STATE_HOME
export TMUX_TMPDIR=%s TMPDIR=%s HOME=%s PATH=%s:"$PATH"
for arg do
    if [ "$arg" = -O ]; then exit 0; fi
    if [ "$arg" = -tt ]; then exec 2>&1; fi
    command=$arg
done
exec /bin/sh -c "$command"
''' % tuple(shlex.quote(str(p)) for p in [s.root/'tmux', remote_tmp, home, cls.host_bin]))
        fake.chmod(0o755)
        s.app_env['MUXIFY_TEST_SSH'] = str(fake)
        # The install chain finds a CLI on the PATH; an old one would be updated from here, which serves nothing.
        s.app_env['MUXIFY_CLI_BASE_URL'] = 'http://127.0.0.1:9/'
        # The Host's muxify on the PATH serves, or has no server mode: never the Debug app's own build/host-cli upload.
        s.debug_host_cli = False
        cls.mode = None
        # A repository on the Host, which the Host's Session Paths find, for New Worktree to start from.
        cls.repository = cls.projects/'tree-repo'
        for args in (['init', '-q', '-b', 'main', str(cls.repository)], ['-C', str(cls.repository), 'commit', '-q', '--allow-empty', '-m', 'init']):
            subprocess.run(['/usr/bin/git', '-c', 'user.name=Verify', '-c', 'user.email=verify@example.invalid', '-c', 'commit.gpgSign=false',
                            *args], env=s.env, check=True, capture_output=True, timeout=30)
        s.tmux('new-session', '-d', '-s', 'start', '-c', str(cls.projects), '/bin/sh')
        # A Topic that the Host CLI wrote before the app started.
        cls.before_launch = cls.new_topic('Before Launch', 'before-launch')

    @classmethod
    def host_muxify(cls, *args):
        """Runs the Debug app's CLI as an Agent on the Host would: the Host's home, its tmux server, no Mac state."""
        environment = {k: v for k, v in cls.s.env.items() if k not in ('TMUX', 'TMUX_PANE', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME')}
        environment.update(HOME=str(cls.home), TMUX_TMPDIR=str(cls.s.root/'tmux'))
        result = subprocess.run([str(CLI), *args], env=environment, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, 'muxify %s failed: %s' % (' '.join(args), result.stderr)
        return result.stdout

    @classmethod
    def new_topic(cls, title, folder):
        """A Topic with one Session, made on the Host by its CLI; returns the Topic's id."""
        (cls.projects/folder).mkdir()
        topic = json.loads(cls.host_muxify('topic', 'new', title, '--json'))['changed']['topic_id']
        cls.host_muxify('topic', 'add-session', str(cls.projects/folder), '--topic', topic)
        return topic

    def use(self, mode):
        """Runs the app on a Host whose muxify is `mode`'s, starting it again when the Host changed."""
        if self.mode == mode and self.s.pid is not None:
            return
        if self.host_bin.is_symlink():
            self.host_bin.unlink()
        self.host_bin.symlink_to(self.bins[mode])
        args = ('-selectedEnvironment', 'Fixture', '-sidebarVisible', 'YES', '-sessionsVisible', 'YES')
        if self.s.pid is None:
            self.s.launch(args=args)
        else:
            self.s.restart_app(args=args)
        type(self).mode = mode

    @classmethod
    def agent_muxify(cls, pane, *args):
        """Runs the CLI as an Agent in a Pane on the Host does: TMUX_PANE names its Pane."""
        environment = {k: v for k, v in cls.s.env.items() if k not in ('TMUX', 'TMUX_PANE', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME')}
        environment.update(HOME=str(cls.home), TMUX_TMPDIR=str(cls.s.root/'tmux'), TMUX_PANE=pane)
        return subprocess.run([str(CLI), *args], env=environment, capture_output=True, text=True, timeout=60)

    def agent_ok(self, pane, *args):
        result = self.agent_muxify(pane, *args)
        self.assertEqual(result.returncode, 0, 'muxify %s in a Host Pane: %s' % (' '.join(args), result.stderr))
        return result.stdout

    def host_server_socket(self):
        """The Host Server socket that `@muxify_browser_socket` names, once the Remote App Window's server claimed it."""
        return wait(lambda: (lambda path: path if re.search(r'\.muxify-browser\.\d+$', path) else None)(
            self.s.tmux('show-options', '-sqv', '@muxify_browser_socket')),
            'the Remote App Window\'s Host Server did not name its socket in @muxify_browser_socket', seconds=30)

    def topic_row(self, topic, message):
        return self.s.wait_rows(lambda rs: self.s.has('topic-' + topic, rs), message, seconds=30)

    def test_a_remote_app_window_shows_the_topics_that_muxify_topic_wrote_on_the_host(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Remote App Window does not show the Host\'s Topic')
        self.assertIsNone(TopicRecords(self.s.root/'state/muxify').get(self.before_launch),
                          'the Mac keeps a copy of the Host\'s Topic')

    def test_a_topic_written_on_the_host_appears_without_a_palette_action(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Remote App Window does not show the Host\'s Topics')
        live = self.new_topic('Written Live', 'written-live')
        self.topic_row(live, 'a Topic that the Host CLI wrote does not appear in the Sidebar')

    def test_a_topic_action_from_the_palette_changes_the_hosts_database(self):
        self.use('serving')
        topic = self.new_topic('Pin From Mac', 'pin-from-mac')
        self.topic_row(topic, 'the Host\'s Topic does not appear')
        window = next(line.split()[0] for line in self.s.tmux('list-windows', '-a', '-F', '#{window_id} #{@muxify_topic}').splitlines()
                      if line.split()[1:] == [topic])
        # The Terminal's Client moves to the Topic's Window, as tmux navigation on the Host does.
        tty = next(line.split()[1] for line in self.s.tmux('list-clients', '-F', '#{client_control_mode} #{client_tty}').splitlines()
                   if line.startswith('0 '))
        self.s.tmux('switch-client', '-c', tty, '-t', window)
        # A Remote App Window's title names its Environment too, so the selected row says that it shows the Window.
        self.s.wait_rows(lambda rs: self.s.row('topic-window-' + window, rs).get('accessibilityValue') == 'selected',
                         'the app does not show the Topic\'s Window', seconds=20)
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'the Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Pin Topic')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-command-Pin Topic', rs), 'Pin Topic is missing from Commands')
        self.s.act('press', 'palette-row-command-Pin Topic')
        wait(lambda: self.host_store.get(topic).get('pinned') is True, 'Pin Topic did not Pin the Topic in the Host\'s database')

    def test_a_config_edit_on_the_host_changes_the_remote_app_window_without_reload_config(self):
        """The Host Server's `config` subscription pushes the edit: nothing reloads, and no Command Palette opens."""
        self.use('serving')
        self.topic_row(self.before_launch, 'the Remote App Window does not show the Host\'s Topics')
        self.s.wait_rows(lambda rs: self.s.has('header-session-name', rs), 'the header shows no Session name', seconds=20)
        config = self.home/'.config/muxify/config.yaml'
        original = config.read_text()
        self.addCleanup(config.write_text, original)
        config.write_text(original + 'ui:\n  status_line:\n    enabled: false\n')
        self.s.wait_rows(lambda rs: not self.s.has('header-session-name', rs) and self.s.has('toggle-sidebar', rs),
                         'status_line.enabled: false in the Host\'s Config did not hide the Session name without Reload Config',
                         seconds=20)
        config.write_text(original)
        self.s.wait_rows(lambda rs: self.s.has('header-session-name', rs),
                         'removing status_line.enabled from the Host\'s Config did not show the Session name again', seconds=20)

    def test_new_worktree_from_a_remote_app_window_makes_the_worktree_and_its_record_on_the_host(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Host Server does not serve the Remote App Window')
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'the Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'New Worktree')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-command-New Worktree', rs), 'New Worktree is missing from Commands', seconds=30)
        self.s.act('press', 'palette-row-command-New Worktree')
        checkout = 'palette-row-' + os.path.realpath(self.repository)
        self.s.wait_rows(lambda rs: self.s.has(checkout, rs), 'New Worktree does not list the Host\'s repository')
        self.s.act('press', checkout)
        self.s.wait_rows(lambda rs: self.s.has('palette-accept', rs), 'New Worktree did not ask for a name')
        self.s.act('set', 'palette-search', 'from-mac')
        self.s.act('press', 'palette-accept')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-head', rs), 'New Worktree did not go on to the start step', seconds=30)
        self.s.act('press', 'palette-row-head')

        folder = self.home/'.local/state/muxify/worktrees/tree-repo/from-mac'
        wait(lambda: (folder/'.git').exists(), 'no Worktree under the Host\'s $XDG_STATE_HOME/muxify/worktrees', seconds=30)
        records = wait(lambda: [r for r in self.host_store.worktrees() if r['name'] == 'from-mac'],
                       'the Host\'s database has no record of the Worktree', seconds=15)
        self.assertEqual(records[0]['path'], os.path.realpath(folder), records)
        self.assertEqual([r for r in TopicRecords(self.s.root/'state/muxify').worktrees() if r['name'] == 'from-mac'], [],
                         'the Mac keeps a record of the Host\'s Worktree')
        listed = json.loads(self.host_muxify('worktree', 'list', '--all', '--json'))['worktrees']
        self.assertIn('from-mac', [w['name'] for w in listed], 'muxify worktree on the Host does not list it')

    def test_browser_commands_in_a_host_pane_are_served_by_the_remote_app_windows_browser_without_taking_focus(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Remote App Window does not show the Host\'s Topics')
        socket = self.host_server_socket()
        self.assertTrue(socket.startswith(self.s.tmux('display-message', '-p', '#{socket_path}') + '.muxify-browser.'), socket)
        page = self.s.root/'host-page.html'
        page.write_text('<!doctype html><html><head><meta charset="utf-8"><title>Host fixture</title></head><body>Host</body></html>\n')
        window, pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-t', 'start:', '-n', 'agent',
                                   '/bin/sh').split()
        before = self.s.driver('responder')['responders']

        tab = json.loads(self.agent_ok(pane, 'browser', 'open', '--json', page.as_uri()))
        self.assertEqual((tab['url'], tab['title']), (page.as_uri(), 'Host fixture'), 'open returns after the page loaded')
        tabs = json.loads(self.agent_ok(pane, 'browser', 'tabs', '--json'))
        self.assertEqual([(t['id'], t['active']) for t in tabs], [(tab['id'], True)])
        # The Remote App Window's Browser of that Window keeps the Tab on the Host's tmux Window.
        wait(lambda: self.s.tmux('show-options', '-wqv', '-t', window, '@muxify_tabs').split() == [page.as_uri()],
             'the Remote App Window\'s Browser does not keep the Tab that the Host Pane opened')
        self.assertEqual(self.s.driver('responder')['responders'], before, 'a Browser command from the Host moved the focus')

    def test_window_open_in_a_host_pane_shows_that_window(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Remote App Window does not show the Host\'s Topics')
        self.host_server_socket()
        session = next(line.split()[0] for line in self.s.tmux('list-sessions', '-F', '#{session_id} #{@muxify_topic}').splitlines()
                       if line.split()[1:] == [self.before_launch])
        # A Window that the Terminal does not show, in a Session of a Topic In Play.
        window, pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-t', session + ':', '-n', 'shown',
                                   '/bin/sh').split()

        self.agent_ok(pane, 'window', 'open')
        def terminal():
            return [line.split()[1] for line in self.s.tmux('list-clients', '-F', '#{client_control_mode} #{window_id}').splitlines()
                    if line.startswith('0 ')]
        wait(lambda: terminal() == [window], lambda: 'the Remote App Window\'s Terminal shows %s, not %s' % (terminal(), window),
             seconds=20)
        self.s.wait_rows(lambda rs: self.s.row('topic-window-' + window, rs).get('accessibilityValue') == 'selected',
                         'muxify window open in a Host Pane did not show its Window in the Sidebar', seconds=20)

    def test_browser_commands_on_a_sessions_only_host_cannot_reach_muxify_and_open_falls_back(self):
        self.use('old')
        self.s.wait_rows(lambda rs: self.s.has('topics-unavailable', rs), 'the window does not show Sessions only', seconds=30)
        window, pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id} #{pane_id}', '-t', 'start:', '-n', 'fallback',
                                   '/bin/sh').split()
        result = self.agent_muxify(pane, 'browser', 'snapshot')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertTrue(result.stderr.startswith('muxify: cannot reach Muxify'), result.stderr)
        # Only tabs falls back: it lists the Tabs that tmux stores on the Window, none here (ADR 0084).
        result = self.agent_muxify(pane, 'browser', 'tabs')
        self.assertEqual((result.returncode, result.stdout), (0, ''), result.stderr)
        url = 'http://127.0.0.1:9/fallback'
        self.agent_ok(pane, 'browser', 'open', url)
        # The Tab waits in @muxify_open for the window's next read, which opens it and clears the option.
        stored = self.s.tmux('show-options', '-wqv', '-t', window, '@muxify_open').split()
        tabs = self.s.tmux('show-options', '-wqv', '-t', window, '@muxify_tabs').split()
        self.assertTrue(stored == [url] or tabs == [url], 'browser open did not fall back to @muxify_open: %r, %r' % (stored, tabs))

    def host_git(self, repo, *args):
        return subprocess.run(['/usr/bin/git', '-C', str(repo), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid',
                               '-c', 'commit.gpgsign=false', *args], check=True, capture_output=True, text=True).stdout

    def host_repository(self, name):
        """A repository on the Host with one commit of host.txt, and host.txt changed since."""
        repo = self.projects/name
        repo.mkdir()
        self.host_git(repo, 'init', '-q', '-b', 'main')
        # The Host's home has no git identity, and git cannot make one from a host name with no domain: a commit that
        # the Git View runs on the Host takes the repository's own.
        self.host_git(repo, 'config', 'user.name', 'Verifier')
        self.host_git(repo, 'config', 'user.email', 'verifier@example.invalid')
        (repo/'host.txt').write_text('first line\n')
        self.host_git(repo, 'add', 'host.txt')
        self.host_git(repo, 'commit', '-q', '-m', 'first')
        (repo/'host.txt').write_text('first line\nchanged on the host\n')
        return repo

    def open_git_view(self, repo):
        """Shows a new Session in the repository in the Remote App Window, and opens its Git View there."""
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', repo.name, '-c', str(repo), '/bin/sh')
        window = self.s.tmux('display-message', '-p', '-t', session + ':', '#{window_id}')
        tty = next(line.split()[1] for line in self.s.tmux('list-clients', '-F', '#{client_control_mode} #{client_tty}').splitlines()
                   if line.startswith('0 '))
        self.s.tmux('switch-client', '-c', tty, '-t', window)
        def selected(rs):
            return any(self.s.row(prefix + window, rs).get('accessibilityValue') == 'selected'
                       for prefix in ('session-window-', 'topic-window-'))
        self.s.wait_rows(selected, 'the Remote App Window does not show the repository\'s Window', seconds=20)

        def opened():
            self.s.driver('press', 'Show Git View')
            return self.s.has('git-view')
        wait(opened, 'the Git View did not open in the Remote App Window', seconds=20, step=.5)

    def close_git_view(self):
        self.s.act('action', 'git-view', 'q')
        wait(lambda: not self.s.has('git-view'), 'the Git View did not close', seconds=10)

    def test_the_git_view_shows_the_hosts_changes_and_diff_and_follows_a_change_on_the_host(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Host Server does not serve the Remote App Window')
        repo = self.host_repository('host-repo')
        self.open_git_view(repo)
        # Changes open on the first file, so its diff shows the line written on the Host.
        self.s.wait_rows(lambda rs: self.s.has('git-row-change:host.txt', rs), 'the Git View does not list the Host\'s change',
                         seconds=20)
        self.s.wait_rows(lambda rs: any(r.get('accessibilityIdentifier', '').startswith('git-line-')
                                        and r.get('accessibilityLabel') == 'changed on the host' for r in rs),
                         'the Git View does not show the Host\'s diff', seconds=20)
        # A file written on the Host shows by itself: the Host Server's `repository` subscription, no key and no palette.
        (repo/'z-written-on-host.txt').write_text('later\n')
        self.s.wait_rows(lambda rs: self.s.has('git-row-change:z-written-on-host.txt', rs),
                         'the Git View did not follow a change on the Host', seconds=8)
        self.close_git_view()

    def test_stage_and_commit_from_the_git_view_change_the_hosts_repository(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Host Server does not serve the Remote App Window')
        repo = self.host_repository('commit-repo')
        self.open_git_view(repo)
        # Changes open on the only change, unstaged.
        def unstaged(rs):
            value = self.s.row('git-row-change:host.txt', rs).get('accessibilityValue', '')
            return 'selected=1' in value and 'status=" M"' in value
        self.s.wait_rows(unstaged, 'the Git View does not select the Host\'s change', seconds=20)
        # Space stages it: the Host Server runs the stage in the Host's repository.
        self.s.act('action', 'git-view', 'space')
        wait(lambda: self.host_git(repo, 'status', '--porcelain') == 'M  host.txt\n',
             'space in the Git View did not stage host.txt in the Host\'s repository', seconds=15)
        # The Git View reads the stage back from the Host, and only then has something to commit.
        self.s.wait_rows(lambda rs: 'status="M "' in self.s.row('git-row-change:host.txt', rs).get('accessibilityValue', ''),
                         'the Git View does not show host.txt staged', seconds=10)
        # c opens the commit box; its Commit commits on the Host, and the change leaves the Git View by itself.
        self.s.act('action', 'git-view', 'c')
        self.s.wait_rows(lambda rs: self.s.has('git-commit-box', rs), 'c did not open the commit box', seconds=10)
        self.s.act('set', 'git-commit-summary', 'Committed from the Mac')
        self.s.act('action', 'git-commit-box', 'Commit')
        wait(lambda: self.host_git(repo, 'log', '-1', '--format=%s').strip() == 'Committed from the Mac',
             'the commit box did not commit in the Host\'s repository', seconds=15)
        self.assertEqual(self.host_git(repo, 'status', '--porcelain'), '', 'the commit left a change in the Host\'s repository')
        self.s.wait_rows(lambda rs: not self.s.has('git-commit-box', rs) and not self.s.has('git-row-change:host.txt', rs),
                         'the committed change stays in the Git View', seconds=10)
        self.close_git_view()
    def own_client_tty(self):
        return wait(lambda: next((line.split()[1] for line in self.s.tmux('list-clients', '-F', '#{client_control_mode} #{client_tty}')
                                  .splitlines() if line.startswith('0 ')), None), 'the Terminal\'s Client did not attach')

    def open_go_to(self):
        """Presses the Go to… menu item until the palette shows: a press while SwiftUI rebuilds the menu can miss."""
        def opened():
            self.s.driver('press', 'Go to…')
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if self.s.has('palette-search'):
                    return True
            return False
        wait(opened, 'Go to… did not open', seconds=20)

    def test_new_session_in_a_remote_app_window_offers_the_hosts_folders(self):
        self.use('serving')
        # A Remote App Window whose Terminal is not up yet starts the Session through a new connection, whose Host Server
        # serves a moment later: the next check starts the app again rather than act before it serves.
        self.addCleanup(setattr, type(self), 'mode', None)
        self.topic_row(self.before_launch, 'the Host Server does not serve the Remote App Window')
        self.assertFalse((pathlib.Path.home()/HOST_FOLDERS).exists(), 'the Mac has the Host\'s folder too, so the check proves nothing')
        self.open_go_to()
        row = 'palette-row-session-path:' + str(self.host_folder)
        def listed():
            self.s.act('focus', 'palette-search')
            self.s.act('set', 'palette-search', 'host-folder-alpha')
            return self.s.has(row)
        wait(listed, 'Go to… does not offer the Host\'s folder %s' % self.host_folder, seconds=20)
        self.s.act('press', row)
        def started():
            listed = self.s.tmux('list-sessions', '-F', '#{session_name}|#{session_path}').splitlines()
            return next((line for line in listed if line.split('|', 1)[1] == str(self.host_folder)), None)
        session = wait(started, 'the Host\'s folder started no Session on the Host', seconds=20).split('|')[0]
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', '=' + session)
        self.assertEqual(session, 'host-folder-alpha')

    def test_a_dropped_file_is_pasted_as_a_path_on_the_host(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Host Server does not serve the Remote App Window')
        recorder = self.s.root/'record.py'
        recorder.write_text(RECORDER)
        output, ready = self.s.root/'dropped.input', self.s.root/'dropped.ready'
        pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{pane_id}', '-t', '=start:', '-n', 'dropped',
                           shlex.join([sys.executable, str(recorder), str(output), str(ready)]))
        wait(ready.exists, 'the Pane recorder did not start')
        tty = self.own_client_tty()
        self.s.tmux('switch-client', '-c', tty, '-t', pane)
        wait(lambda: self.s.tmux('display-message', '-p', '-c', tty, '#{pane_id}') == pane, 'the Client did not move to the recorder')
        source = self.s.root/"Dropped ' $(file).bin"
        content = bytes(range(256)) * 1024
        source.write_bytes(content)
        (self.s.root/'paste-file').write_text(str(source))

        self.s.act('action', 'client-input', 'Drop Fixture File')
        data = wait(lambda: output.read_bytes() if output.exists() else None, 'the Pane received no paste', seconds=30)
        self.assertTrue(data.startswith(b'\x1b[200~') and data.endswith(b'\x1b[201~'), data)
        words = shlex.split(data[6:-6].decode())
        self.assertEqual(len(words), 1, words)
        uploaded = pathlib.Path(words[0])
        self.assertTrue(uploaded.is_relative_to(self.remote_tmp), 'the pasted path is not on the Host: %s' % uploaded)
        self.assertEqual(uploaded.name, source.name)
        self.assertEqual(uploaded.read_bytes(), content, 'the Host\'s file is not the dropped file')

    def test_a_fetch_from_the_git_view_asks_the_hosts_ssh_passphrase_hidden_and_the_answer_reaches_git(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Host Server does not serve the Remote App Window')
        repo = self.host_repository('fetch-repo')
        origin = self.s.root/'fetch-origin.git'
        self.host_git(self.s.root, 'init', '-q', '--bare', '-b', 'main', str(origin))
        self.host_git(repo, 'push', '-q', str(origin), 'main')
        # An ssh on the Host that asks for a passphrase through SSH_ASKPASS, as ssh does under SSH_ASKPASS_REQUIRE=force,
        # and serves the repository only for the answer `right`. Its name is ssh, so git takes it for OpenSSH.
        (self.s.root/'fetch-ssh-bin').mkdir()
        answers, ssh = self.s.root/'fetch-answers', self.s.root/'fetch-ssh-bin/ssh'
        ssh.write_text('#!/bin/sh\n'
                       'answer=$("$SSH_ASKPASS" "Enter passphrase for key \'/fake/id\': ") || exit 255\n'
                       f'printf \'%s\\n\' "$answer" >> {shlex.quote(str(answers))}\n'
                       '[ "$answer" = right ] || { echo "Permission denied (publickey)." >&2; exit 255; }\n'
                       'for last; do :; done\n'
                       'exec /bin/sh -c "$last"\n')
        ssh.chmod(0o755)
        self.host_git(repo, 'remote', 'add', 'origin', 'ssh://fake.invalid' + str(origin))
        self.host_git(repo, 'config', 'core.sshCommand', shlex.quote(str(ssh)))
        self.open_git_view(repo)
        self.s.wait_rows(lambda rs: self.s.has('git-row-change:host.txt', rs), 'the Git View does not list the Host\'s change',
                         seconds=20)
        # f fetches on the Host; the Host Server's askpass helper asks the Remote App Window, hidden.
        self.s.act('action', 'git-view', 'f')
        question = "Enter passphrase for key '/fake/id':"
        rs = self.s.wait_rows(lambda rs: self.s.row('git-prompt', rs).get('accessibilityLabel') == question,
                              'the Remote App Window did not ask the Host\'s ssh passphrase', seconds=20)
        self.assertTrue(self.s.has('git-prompt-secret', rs), 'the passphrase is not hidden')
        self.s.act('set', 'git-prompt-field', 'right')
        self.s.act('action', 'git-prompt', 'enter')
        def fetched():
            try:
                return self.host_git(repo, 'rev-parse', '--verify', '-q', 'origin/main').strip() != ''
            except subprocess.CalledProcessError:
                return False
        wait(fetched, lambda: 'the answer did not reach git on the Host: no origin/main after the fetch; answers %r, banner %r, toolbar %r'
             % (answers.read_text() if answers.exists() else None, self.s.row('git-write-error').get('accessibilityValue'),
                self.s.row('git-toolbar').get('accessibilityLabel')), seconds=20)
        self.assertEqual(answers.read_text().split(), ['right'])
        self.assertFalse(self.s.has('git-write-error'), 'the fetch failed')
        self.close_git_view()

    def test_the_listener_of_a_sessions_only_window_follows_the_terminal_and_makes_no_session(self):
        self.use('old')
        self.s.wait_rows(lambda rs: self.s.has('topics-unavailable', rs), 'the window does not show Sessions only', seconds=30)

        def placement():
            """The tty and Session of the Terminal's Client, which the bootstrap's marker names, and the Sessions of
            the Listeners."""
            markers = [self.s.tmux('show-options', '-sqv', line.split()[0]).split('\u241f')
                       for line in self.s.tmux('show-options', '-s').splitlines() if line.startswith('@muxify_client_')]
            ttys = [m[1] for m in markers if len(m) == 5 and m[4] == 'remote']
            clients = [line.split('|') for line in self.s.tmux(
                'list-clients', '-F', '#{client_control_mode}|#{client_tty}|#{session_id}').splitlines()]
            terminal = next(((tty, session) for mode, tty, session in clients if mode == '0' and tty in ttys), (None, None))
            return terminal + ([session for mode, _, session in clients if mode == '1'],)

        def listener_in(session):
            return lambda: (lambda _, terminal, listeners: terminal == session and listeners == [session])(*placement())

        tty, terminal, _ = wait(lambda: (lambda p: p if p[0] else None)(placement()), 'the Terminal\'s Client is not attached')
        # The Listener makes no Session: it sits in the Terminal's.
        wait(listener_in(terminal), lambda: 'the Listener is not in the Terminal\'s Session: %s' % (placement(),))
        other = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'listener-follows', '/bin/sh')
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', other)
        self.s.tmux('switch-client', '-c', tty, '-t', other)
        wait(listener_in(other), lambda: 'the Listener did not follow the Terminal: %s' % (placement(),))

    def test_a_host_whose_muxify_has_no_server_mode_shows_sessions_only_and_why(self):
        self.use('old')
        expected = 'Topics are unavailable on Fixture: the Host\'s muxify is too old (%s).' % OLD_BUILD
        def note(rs):
            row = self.s.row('topics-unavailable', rs)
            return (row.get('accessibilityLabel', '') + row.get('accessibilityValue', '')) == expected
        rs = self.s.wait_rows(note, 'the Sidebar does not say why Topics are unavailable', seconds=30)
        self.assertFalse(self.s.has('topic-' + self.before_launch, rs), 'a Sessions-only window shows a Topic')
        self.assertTrue(any(r.get('accessibilityIdentifier', '').startswith('session-window-') for r in rs),
                        'a Sessions-only window shows no Session')


if __name__ == '__main__':
    unittest.main()
