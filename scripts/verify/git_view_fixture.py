"""The fixture and helpers of the git_view_* suites: a repository with commits, a branch, a stash and Changes, its
Session, and an editor command that writes the file and line it was given.

GitViewFixture has no checks. Each suite subclasses it, so each suite makes its own Sandbox and app.

The driver cannot type keys, so a check performs each Git View key as an accessibility action of the
`git-view` element (`GitNavigator` in UI/GitViewPanel.swift). An action is named by the key's Config
spelling (`j`, `enter`, `shift+r`, `alt+down`), there is one for each entry of `GitView.keyMap`, and it does
what its key does under the same rules: it needs the keys' focus, and it does nothing where the key does
nothing. The Git View opens through its View menu item, "Show Git View".

Accessibility identifiers of the Git View:
    git-view                 the Git View; its actions are the keys
    git-toolbar              the toolbar; its label is the text it shows, joined by " · ": the repository,
                             its tags, and "↑<ahead> ↓<behind> vs <base>"
    git-tab-<tab>            a tab, for changes, history, branches and stashes; its value is "selected" or ""
    git-row-<item id>        a list row, for change:<path>, folder:<list>:<path>, commit:<sha>, stash:<sha>,
                             branch:<name> and file:<path>; its label is its name (a change's file name, a
                             commit's subject, a branch's name), and its value is `selected=<0|1>` and, for a
                             change or a file of the Diff files, ` status="<index><worktree>"` (`"M "`, `" M"`,
                             `"??"`) or ` status="<letter>"`, then ` base=1` on the base that W marked
    git-card                 the commit, branch, stash, comparison or folder card above a diff; its label is its
                             title, for a comparison "<base> → <selection>", or "Comparing <base>" on the base
    The toolbar's label ends with "Comparing <base>" or "<base> → <selection>" while a base is marked. A base or
    selection is named by its branch name, its stash ref, or a commit's 7-character hash.
    git-file-header          the bar above one file's diff; its label is the file's path
    git-file-bar-<n>         a file's bar in a diff of several files; its label is the file's path
    git-line-<n>             a diff line in the unified layout, and git-line-<n>-old and git-line-<n>-new
                             the two sides in the split layout; its label is the code, and its value is
                             `kind=<context|added|removed|note> old=<number|-> new=<number|->`, then
                             ` marks=<start>..<<end>,...` when it has changed words: their columns in the
                             code as shown, tabs expanded to the next multiple of 4
    git-write-error          the banner of a failed write or of an `e` that found its file gone; its value is the message
    git-menu                 an open Git View menu, such as Discard changes; its label is its title, and its
                             actions are each choice's key, then enter, escape, j and k
    git-menu-choice-<key>    a choice of the menu, by its key's Config spelling; its label is its title, and its
                             value is `highlighted=<0|1> enabled=<0|1>`
    git-menu-agents          the Agent guard's warning in a menu, only while an Agent that is working or blocked has a
                             Pane in the Worktree; its label is one line for each Agent, "<kind> in <Topic or Session>"
    git-menu-cancel          the menu's Cancel button
    git-commit-box           the commit message box that c opens in Changes
    git-prompt               an open Git View prompt, such as the stash message that s asks for; its label is its title,
                             and its actions are enter (submit) and escape (cancel)
    git-prompt-field         the prompt's one-line field: `set` it to type; its label is the prompt's title
    git-prompt-secret        the prompt's "Hidden" mark, only while what is typed is hidden, as for a password
    git-prompt-cancel        the prompt's Cancel button
    git-prompt-submit        the prompt's submit button, such as Stash
    git-prompt-suggestion-<n>  a suggestion of a prompt that offers some, such as the branch names `c` in Branches
                             takes; its label is the name, and its value is `chosen` for the one ↓/↑ chose. The
                             prompt's actions then include down and up
    The Branches keys n, R, - and c ask in the prompts `New branch name (branch is off of '<branch>')`, `Rename branch`
    and `Check out`; ↩ checks out through the same path as space does.
    A branch with an upstream also offers `git-menu-choice-r` ("Delete remote branch") and `git-menu-choice-b`
    ("Delete local and remote branch") in `delete-branch`; each asks first in the menu `delete-remote-branch`, whose
    choice `git-menu-choice-y` runs `git push <remote> --delete <branch>`.
    d in Branches asks in the menus `delete-branch` ("Delete branch", the choice `git-menu-choice-c`, "Delete local
    branch", disabled on the current branch) and, for a branch git finds unmerged, `force-delete-branch` ("Force delete
    branch", the choice `git-menu-choice-y`). A branch of another Worktree is left to git, whose message shows in
    `git-write-error`. `git-menu-footnote` is the line beside Cancel, such as which Topics remember the branch.
    The Stashes keys ask in the menus `stash-apply`, `stash-pop` and `stash-drop` (labels "Apply stash", "Pop stash" and
    "Drop stash"), each with the one choice `git-menu-choice-y`. space in Branches and History checks out; it asks
    only in the menu `checkout` ("Check out", while an Agent is working in the Worktree) and in `autostash`
    ("Autostash?", when Changes are in the way), each with the one choice `git-menu-choice-y`. space on a branch that
    another Worktree has checked out asks in the menu `other-worktree` ("Go to Worktree?") instead, with the one
    choice `git-menu-choice-y`: it goes to a Window with a Pane in that Worktree, else opens Go to… on its Session Path.
P pushes beside the writes and p pulls in the write queue, in every tab; the toolbar's label ends with "Pushing…" or
"Pulling…" until it ends. Without an upstream they ask in `git-prompt` ("Enter upstream as '<remote> <branch>'", its
`git-prompt-field` starting at `origin <branch>`); a push of a branch behind its upstream asks in the menu `force-push`
("Force push?", with the one choice `git-menu-choice-y`), and a detached HEAD says in `git-write-error` why it can't.
A in Changes asks in the menu `amend` ("Amend last commit", with the one choice `git-menu-choice-y`) and amends the last
commit with what's staged; with nothing staged or an operation in progress, `git-write-error` says why.
With more than one row on top, Changes have the row `git-row-folder:changes:.`, labelled "/", above the rest: space and d
on it stage and discard everything. D in Changes asks in the menu `reset-options` ("Reset options") with lazygit's choices
`git-menu-choice-x` (Nuke working tree), `-u` (Discard unstaged changes), `-c` (Discard untracked files), `-shift+s`
(Discard staged changes), `-s`, `-m` and `-h` (soft, mixed and hard reset to HEAD), each run at once; a choice with
nothing to do is disabled, and with a clean tree `git-write-error` says so and nothing opens.
m, in every tab, while a merge, rebase, cherry-pick, revert or `git am` is in progress, asks in the menu `operation`
("Merge options", "Rebase options" and so on) with the choices `git-menu-choice-c` (Continue), `-s` (Skip, not for a
merge) and `-a` (Abort); with nothing in progress `git-write-error` says so. Staging the last conflicted file asks in
the menu `continue` ("Continue the rebase?", with the one choice `git-menu-choice-y`).
M on a branch in Branches other than the one you're on asks in the menu `merge` ("Merge '<branch>' into '<head>'") with
the choices `git-menu-choice-f` (fast-forward), `-n` (merge commit), `-s` (squash and commit) and `-u` (squash and leave
uncommitted); on the current branch `git-write-error` says it can't merge a branch into itself.
r on a branch in Branches other than the one you're on asks in the menu `rebase` ("Rebase '<head>'") with the one choice
`git-menu-choice-s` ("Simple rebase onto '<branch>'"); on the current branch `git-write-error` says it can't rebase a
branch onto itself.
g on a commit in History or a branch's commits, or a branch in Branches, asks in the menu `reset` ("Reset to <name>") with
the choices `git-menu-choice-s` (soft), `-m` (mixed) and `-h` (hard); `h` with Changes asks in the menu `reset-hard`
(with the one choice `git-menu-choice-y`, "Discard N files and reset"), which names any working Agent in
`git-menu-agents`; a hard reset with no Changes goes through the same guard (menu `agents`) only while an Agent works.
C on a commit in History or a branch's commits copies it, or takes it out again: its row's `accessibilityValue` then
has `copied=1`, and the toolbar's label has "N copied". V in History asks in the menu `cherry-pick` ("Cherry-pick", with
the one choice `git-menu-choice-y`, which names any working Agent in `git-menu-agents`) and cherry-picks the copies
onto the branch you're on, oldest first, then forgets them; ⌃r forgets them. They are shared by the Git View of every
Window in any Worktree of the repository.
f in Changes fetches beside the writes; the toolbar's label ends with "Fetching…" until it ends. A credential question
of git or ssh is asked in `git-prompt`, whose label is the question; ⎋ stops the fetch, and `git-write-error` says
"Fetch cancelled.".
e goes to the editor's Window only while the Git View's Window is still the Location; a move made while the diff
or tmux answered wins, and the editor's Window opens behind it. An Empty Topic page shows no Git View, and the
Window's Git View shows again, as it was left, when the Window is the Location again.
The diff pane builds only the lines on screen, so keep a fixture's diffs short.
"""

import json
import re
import shlex
import subprocess
import unittest

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/zsh -f'
LAUNCH_ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES']
MAIN_COMMITS = ['third commit', 'second commit', 'first commit']


class GitViewFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(cls.__module__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.repo = s.root/'projects/fixture'
        cls.repo.mkdir(parents=True)
        cls.git('init', '-q', '-b', 'main')
        cls.git('config', 'user.name', 'Verifier')
        cls.git('config', 'user.email', 'verifier@example.invalid')
        cls.git('config', 'rerere.enabled', 'false')
        cls.git('config', 'commit.gpgsign', 'false')
        for name in ['README.md', 'tracked.txt', 'staged.txt', 'stashed.txt']:
            (cls.repo/name).write_text('one\n')
        (cls.repo/'tracked.txt').write_text('one\nthe quick brown fox\n')
        cls.git('add', '.')
        cls.git('commit', '-q', '-m', 'first commit')
        (cls.repo/'README.md').write_text('one\ntwo\n')
        cls.git('commit', '-q', '-am', 'second commit')
        (cls.repo/'README.md').write_text('one\ntwo\nthree\n')
        cls.git('commit', '-q', '-am', 'third commit')
        cls.git('checkout', '-q', '-b', 'feature-x')
        (cls.repo/'feature.txt').write_text('feature\n')
        cls.git('add', 'feature.txt')
        cls.git('commit', '-q', '-m', 'feature one')
        (cls.repo/'feature.txt').write_text('feature\nmore\n')
        cls.git('commit', '-q', '-am', 'feature two')
        cls.git('checkout', '-q', 'main')
        (cls.repo/'stashed.txt').write_text('one\nstashed\n')
        cls.git('stash', 'push', '-q', '-m', 'stashed work')
        (cls.repo/'staged.txt').write_text('one\nstaged line\n')
        cls.git('add', 'staged.txt')
        # One changed word, then a line with no pair.
        (cls.repo/'tracked.txt').write_text('one\nthe quick red fox\ntracked added line\n')
        (cls.repo/'new.txt').write_text('new file\n')
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'gv-fixture', '-c', str(cls.repo), SHELL)
        cls.window = s.tmux('display-message', '-p', '-t', cls.session + ':', '#{window_id}')
        # The editor writes its file and line to a file, then stays, as a real editor would.
        cls.editor_out = s.root/'editor.out'
        command = "printf '%s\\n%s\\n' {file} {line} > " + shlex.quote(str(cls.editor_out)) + '; sleep 60'
        # Every folder of projects/ is a Session Path, so a Worktree beside the fixture has a Go to… row.
        (s.root/'config/muxify/config.yaml').write_text('git_view:\n  editor: ' + json.dumps(command) + '\n'
                                                       '  services:\n    git.muxify.test: github:git.muxify.test\n'
                                                       'sessions:\n  paths:\n    - path: ' + str(s.root/'projects') + '/*\n')
        s.launch(LAUNCH_ARGS)
        s.wait_shown(cls.window)

    @classmethod
    def git(cls, *args):
        return subprocess.run(['/usr/bin/git', '-C', str(cls.repo), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid']
                              + list(args), check=True, capture_output=True, text=True).stdout

    def setUp(self):
        self.close_git_view()
        self.open_git_view()

    def tearDown(self):
        self.close_palette()
        self.close_git_view()

    def is_open(self, rs=None):
        return self.s.has('git-view', rs)

    def open_git_view(self):
        """Presses the View menu item until the Git View shows. SwiftUI rebuilds the menu a moment after the state
        it reads changes, and a press in that moment can miss."""
        def opened():
            self.s.driver('press', 'Show Git View')
            return self.is_open()
        wait(opened, 'the Git View did not open', seconds=10, step=.3)
        self.s.wait_rows(lambda rs: self.s.has('git-toolbar', rs), 'the Git View did not read the repository')

    def close_palette(self):
        if self.s.has('palette-search'):
            self.s.driver('action', 'palette-search', 'Close')
            self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the palette did not close')

    def close_git_view(self):
        if self.s.has('git-prompt'):
            self.s.act('action', 'git-prompt', 'escape')
            self.s.wait_rows(lambda rs: not self.s.has('git-prompt', rs), 'the Git View prompt did not close')
        if self.s.has('git-menu'):
            self.s.act('action', 'git-menu', 'escape')
            self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'the Git View menu did not close')
        if self.is_open():
            self.key('q')
            wait(lambda: not self.is_open(), 'the Git View did not close', seconds=10)

    def key(self, name):
        """Performs a Git View key through its accessibility action."""
        self.s.act('action', 'git-view', name)

    def rows_with_prefix(self, prefix, rs):
        return [r for r in rs if r.get('accessibilityIdentifier', '').startswith(prefix)]

    def status(self, row):
        match = re.search(r'status="(..?)"', row.get('accessibilityValue', ''))
        return match.group(1) if match else None

    def select_change(self, name):
        self.select_row('git-row-change:' + name)

    def select_row(self, key):
        """Moves the selection to a row of the list shown: to the top with <, then down with j."""
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no row ' + key)
        self.key('shift+comma')
        for _ in range(20):
            if 'selected=1' in self.s.row(key).get('accessibilityValue', ''):
                return
            self.key('j')
        self.fail('could not select ' + key)

    def toolbar(self, rs=None):
        return self.s.row('git-toolbar', rs).get('accessibilityLabel', '')

    def go_to(self, key):
        """Shows a Git View tab on its own list: a second press leaves what was gone into."""
        self.key(key)
        self.key(key)

    def menu(self, rs=None):
        return self.s.row('git-menu', rs)

    def open_discard_menu(self, title='Discard changes'):
        self.key('d')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == title, 'd did not open ' + title)

    def agent_pane(self, name, folder, status):
        """A Pane running `sleep` in its own Session, which Muxify takes for an Agent with this Status."""
        pane = self.s.tmux('new-session', '-d', '-P', '-F', '#{pane_id}', '-s', name, '-c', str(folder), 'sleep 600')
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', name)
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude')
        self.set_status(pane, status)
        return pane

    def set_status(self, pane, status):
        if status:
            self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', status)
        else:
            self.s.tmux('set-option', '-p', '-u', '-t', pane, '@muxify_agent_status')

    def discard_names_agents(self, name, shown):
        """Opens the Discard menu of `name` until the Git View knows the Agents as they are, then returns the
        guard's warning, or None. Muxify reads the Panes' options on its own timer, so the first menu may be early."""
        found = []

        def asked():
            self.select_change(name)
            rs = self.open_discard_menu()
            found[:] = [self.s.row('git-menu-agents', rs).get('accessibilityLabel') if self.s.has('git-menu-agents', rs) else None]
            self.s.act('action', 'git-menu', 'escape')
            self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
            return (found[0] is not None) == shown
        wait(asked, 'the Discard menu %s the Agent' % ('does not name' if shown else 'still names'), seconds=15, step=.5)
        return found[0]

    def stashes(self):
        return self.git('stash', 'list', '--format=%gs').splitlines()

    def porcelain(self):
        return self.git('status', '--porcelain', '--untracked-files=all').splitlines()

    def back_to_main(self):
        self.git('checkout', '-q', 'main')

    def add_worktree(self, name):
        """A Worktree of the fixture beside it, with a new branch of the same name checked out in it."""
        path = self.repo.parent/('fixture-' + name)
        self.git('worktree', 'add', '-q', '-b', name, str(path))
        self.addCleanup(self.git, 'branch', '-q', '-D', name)
        self.addCleanup(self.git, 'worktree', 'remove', '--force', str(path))
        return path

    def back_to_fixture_window(self):
        self.s.show(self.window)

    def prompt_label(self, rs=None):
        return self.s.row('git-prompt', rs).get('accessibilityLabel')

    def wait_prompt(self, title):
        return self.s.wait_rows(lambda rs: self.prompt_label(rs) == title, 'no prompt: ' + title)

    def bare_remote(self, name, tracking=True):
        """Adds the remote origin, an empty bare repository, and with `tracking` pushes main to it, which then is main's
        upstream. Returns its path."""
        origin = self.s.root/(name + '.git')
        subprocess.run(['/usr/bin/git', 'init', '-q', '--bare', str(origin)], check=True)
        self.git('remote', 'add', 'origin', str(origin))
        self.addCleanup(self.git, 'remote', 'remove', 'origin')
        if tracking:
            self.git('push', '-q', '-u', 'origin', 'main')
        return origin

    def take_back(self, before, *pulled):
        """Moves main back to `before` and drops the files a pull brought, leaving what the fixture has staged and
        changed as it was (`reset --keep` would unstage it)."""
        self.git('reset', '-q', '--soft', before)
        for name in pulled:
            self.git('rm', '-q', '-f', '--cached', '--ignore-unmatch', name)
            (self.repo/name).unlink(missing_ok=True)

    @classmethod
    def git_try(cls, *args):
        """git, whose failure is no error: a merge that conflicts, or an operation that isn't in progress."""
        return subprocess.run(['/usr/bin/git', '-C', str(cls.repo), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid']
                              + list(args), capture_output=True, text=True)
