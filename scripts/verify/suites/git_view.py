"""The Git View: opening it, the Changes list and a file's diff, History, the Discard changes menu and its Agent guard, stashing from Changes, applying, popping and dropping a stash, checking out, fetching, pushing, pulling, and closing.

The driver cannot type keys, so a check performs each Git View key as an accessibility action of the
`git-view` element (`GitNavigator` in UI/GitViewPanel.swift). An action is named by the key's Config
spelling (`j`, `enter`, `shift+r`, `alt+down`), there is one for each entry of `GitView.keyMap`, and it does
what its key does under the same rules: it needs the keys' focus, and it does nothing where the key does
nothing. The Git View opens through its View menu item, "Show Git View".

Accessibility identifiers of the Git View, for the suites that follow this one:
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

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view
"""

import json
import re
import shlex
import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, remove_topic, wait

SHELL = '/bin/zsh -f'
LAUNCH_ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES']
MAIN_COMMITS = ['third commit', 'second commit', 'first commit']


class GitView(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.repo = s.root/'projects/fixture'
        cls.repo.mkdir(parents=True)
        cls.git('init', '-q', '-b', 'main')
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

    def selected_row(self, rs):
        return next((r for r in self.rows_with_prefix('git-row-', rs) if 'selected=1' in r.get('accessibilityValue', '')), {})

    def status(self, row):
        match = re.search(r'status="(..?)"', row.get('accessibilityValue', ''))
        return match.group(1) if match else None

    def select_change(self, name):
        """Moves the selection to the change's row with j."""
        key = 'git-row-change:' + name
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no row ' + key)
        for _ in range(10):
            if 'selected=1' in self.s.row(key).get('accessibilityValue', ''):
                return
            self.key('j')
            self.s.wait_rows(lambda rs: len(self.rows_with_prefix('git-row-', rs)) > 0 and bool(self.selected_row(rs)), 'no row is selected')
        self.fail('could not select ' + key)

    def test_opening_shows_changes_with_their_letters(self):
        rs = self.s.wait_rows(lambda rs: len(self.rows_with_prefix('git-row-change:', rs)) == 3, 'Changes did not list the 3 changes')
        self.assertEqual(self.s.row('git-tab-changes', rs).get('accessibilityValue'), 'selected', 'Changes is not the tab shown')
        self.assertIn('fixture', self.s.row('git-toolbar', rs).get('accessibilityLabel', ''), 'the toolbar does not name the repository')
        letters = {key: self.status(self.s.row('git-row-change:' + key, rs)) for key in ['staged.txt', 'tracked.txt', 'new.txt']}
        self.assertEqual(letters, {'staged.txt': 'M ', 'tracked.txt': ' M', 'new.txt': '??'}, 'the status letters are wrong')
        self.assertEqual(self.s.row('git-row-change:tracked.txt', rs).get('accessibilityLabel'), 'tracked.txt')

    def test_a_files_diff_shows_its_added_line(self):
        self.select_change('tracked.txt')
        self.key('enter')
        rs = self.s.wait_rows(lambda rs: any(r.get('accessibilityLabel') == 'tracked added line' for r in rs),
                              'the diff does not show the added line')
        self.assertEqual(self.s.row('git-file-header', rs).get('accessibilityLabel'), 'tracked.txt', 'the file header names another file')
        line = next(r for r in rs if r.get('accessibilityLabel') == 'tracked added line')
        self.assertTrue(line['accessibilityIdentifier'].startswith('git-line-'), line)
        self.assertEqual(line['accessibilityValue'], 'kind=added old=- new=3', 'the added line has the wrong kind or numbers')
        # The diff has the keys now, so j moves its cursor and leaves the list's selection.
        self.key('j')
        self.assertEqual(self.selected_row(self.s.rows()).get('accessibilityIdentifier'), 'git-row-change:tracked.txt',
                         'j moved the list, not the diff, after enter')

    def test_a_changed_word_is_marked_on_both_its_lines(self):
        self.select_change('tracked.txt')
        self.key('enter')
        def line(text, rs):
            return next((r for r in rs if r.get('accessibilityLabel') == text and r.get('accessibilityIdentifier', '').startswith('git-line-')), None)
        rs = self.s.wait_rows(lambda rs: line('the quick brown fox', rs) and line('the quick red fox', rs) and line('tracked added line', rs),
                              'the diff does not show the changed lines')
        removed, added, unpaired = (line(text, rs) for text in ['the quick brown fox', 'the quick red fox', 'tracked added line'])
        self.assertEqual(self.marked(removed), ['brown'], removed)
        self.assertEqual(self.marked(added), ['red'], added)
        self.assertEqual(self.marked(unpaired), [], 'a line with no pair has word marks')

    def marked(self, line):
        """The words a diff line marks, from the columns in its accessibility value."""
        match = re.search(r' marks=(\S+)', line.get('accessibilityValue', ''))
        spans = re.findall(r'(\d+)\.\.<(\d+)', match.group(1)) if match else []
        return [line['accessibilityLabel'][int(start):int(end)] for start, end in spans]

    def test_two_shows_history_with_the_commits(self):
        self.key('2')
        rs = self.s.wait_rows(lambda rs: len(self.rows_with_prefix('git-row-commit:', rs)) >= len(MAIN_COMMITS),
                              'History did not list the commits')
        self.assertEqual(self.s.row('git-tab-history', rs).get('accessibilityValue'), 'selected', 'History is not the tab shown')
        subjects = [r.get('accessibilityLabel') for r in self.rows_with_prefix('git-row-commit:', rs)]
        self.assertEqual(subjects[:len(MAIN_COMMITS)], MAIN_COMMITS, 'History does not list the commits of main, newest first')

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

    def comparing(self, rs=None):
        """The toolbar's part about the comparison, or None."""
        return next((part for part in self.toolbar(rs).split(' · ') if 'Comparing' in part or '→' in part), None)

    def go_to(self, key):
        """Shows a Git View tab on its own list: a second press leaves what was gone into."""
        self.key(key)
        self.key(key)

    def test_a_branch_marked_in_branches_is_compared_with_a_commit_in_history(self):
        self.go_to('3')
        self.select_row('git-row-branch:feature-x')
        self.key('shift+w')
        rs = self.s.wait_rows(lambda rs: self.comparing(rs) == 'Comparing feature-x', 'the toolbar does not name the base')
        self.assertIn('base=1', self.s.row('git-row-branch:feature-x', rs).get('accessibilityValue', ''), 'the base has no mark')
        self.assertEqual(self.s.row('git-card', rs).get('accessibilityLabel'), 'Comparing feature-x', 'the base does not show its note')
        # Across Git View tabs: a commit of main's history is compared with the branch.
        self.go_to('2')
        self.select_row('git-row-commit:' + self.git('rev-parse', 'main~1').strip())
        title = 'feature-x → ' + self.git('rev-parse', '--short=7', 'main~1').strip()
        rs = self.s.wait_rows(lambda rs: self.s.row('git-card', rs).get('accessibilityLabel') == title,
                              'the card does not name both ends: ' + title)
        self.assertEqual(self.comparing(rs), title, 'the toolbar does not name both ends')
        # Its Diff files are the files from the branch to the commit, not the commit's own.
        rs = self.s.wait_rows(lambda rs: {'git-row-file:README.md', 'git-row-file:feature.txt'}
                              <= {r.get('accessibilityIdentifier') for r in self.rows_with_prefix('git-row-file:', rs)},
                              'the Diff files are not those of the comparison')
        self.assertEqual(self.status(self.s.row('git-row-file:feature.txt', rs)), 'D', 'feature.txt is not deleted from the branch to the commit')
        # ↩ goes into them, and ] and [ move between their files.
        self.key('enter')
        first = self.s.wait_rows(lambda rs: self.s.has('git-file-header', rs), 'enter did not go into the Diff files')
        first = self.s.row('git-file-header', first).get('accessibilityLabel')
        self.key('right_bracket')
        rs = self.s.wait_rows(lambda rs: self.s.row('git-file-header', rs).get('accessibilityLabel') not in (None, first),
                              '] did not go to the next file')
        self.assertEqual({first, self.s.row('git-file-header', rs).get('accessibilityLabel')}, {'README.md', 'feature.txt'})
        self.key('left_bracket')
        self.s.wait_rows(lambda rs: self.s.row('git-file-header', rs).get('accessibilityLabel') == first, '[ did not go back')

    def test_changes_show_their_own_diff_while_a_base_is_marked(self):
        self.go_to('2')
        self.key('shift+w')
        self.s.wait_rows(lambda rs: (self.comparing(rs) or '').startswith('Comparing '), 'W did not mark the commit')
        self.key('1')
        self.select_change('tracked.txt')
        rs = self.s.wait_rows(lambda rs: self.s.row('git-file-header', rs).get('accessibilityLabel') == 'tracked.txt',
                              'the change does not show its own diff')
        self.assertTrue(any(r.get('accessibilityLabel') == 'tracked added line' for r in rs), 'the change does not show its own lines')

    def test_w_on_the_base_escape_and_closing_end_the_comparison(self):
        self.go_to('2')
        self.select_row('git-row-commit:' + self.git('rev-parse', 'main~1').strip())
        name = 'Comparing ' + self.git('rev-parse', '--short=7', 'main~1').strip()
        self.key('shift+w')
        self.s.wait_rows(lambda rs: self.comparing(rs) == name, 'W did not mark the commit')
        self.key('shift+w')
        rs = self.s.wait_rows(lambda rs: self.comparing(rs) is None, 'W on the base did not end the comparison')
        self.assertFalse(any('base=1' in r.get('accessibilityValue', '') for r in rs), 'a row keeps the mark')
        self.key('shift+w')
        self.s.wait_rows(lambda rs: self.comparing(rs) == name, 'W did not mark the commit again')
        self.key('escape')
        self.s.wait_rows(lambda rs: self.comparing(rs) is None, 'escape did not end the comparison')
        self.assertTrue(self.is_open(), 'escape closed the Git View instead of ending the comparison')
        self.key('shift+w')
        self.s.wait_rows(lambda rs: self.comparing(rs) == name, 'W did not mark the commit a third time')
        self.close_git_view()
        self.open_git_view()
        rs = self.s.rows()
        self.assertIsNone(self.comparing(rs), 'the comparison outlived closing the Git View')

    def windows(self):
        return set(self.s.tmux('list-windows', '-t', self.session + ':', '-F', '#{window_id}').split())

    def press_e(self):
        """Performs e, and returns the Window it opened and the file and line the editor command got. The app
        switches to the new Window."""
        self.editor_out.unlink(missing_ok=True)
        before = self.windows()
        self.key('e')
        wait(lambda: self.windows() - before, 'e did not open a Window', seconds=10)
        (new,) = self.windows() - before
        self.s.wait_shown(new)
        wait(self.editor_out.exists, 'the editor command did not run', seconds=10)
        file, line = self.editor_out.read_text().split('\n')[:2]
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', new, '#{session_id}'), self.session, 'e opened a Window in another Session')
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', new, '#{pane_current_path}'), str(self.repo.resolve()),
                         'the editor does not run in the repository root')
        return new, file, int(line)

    def leave(self, new):
        """Closes the editor's Window and goes back to the one with the Git View, which is as it was left."""
        self.s.tmux('kill-window', '-t', new)
        self.s.show(self.window)
        self.assertTrue(self.is_open(), 'the Git View did not stay open in the Window it was left in')

    def test_e_in_a_list_opens_the_files_first_changed_line_in_a_new_window(self):
        self.select_change('tracked.txt')
        new, file, line = self.press_e()
        self.assertEqual(file, str(self.repo.resolve()/'tracked.txt'))
        self.assertEqual(line, 2, 'the first changed line is 2')
        self.assertFalse(self.is_open(), 'the new Window shows a Git View')
        self.leave(new)

    def test_e_in_the_diff_opens_the_line_under_the_cursor_and_a_removed_line_the_new_line_beside_it(self):
        self.select_change('tracked.txt')
        self.key('enter')
        # The cursor starts on the first change: the removed line, beside new line 2.
        self.s.wait_rows(lambda rs: any(r.get('accessibilityLabel') == 'tracked added line' for r in rs), 'the diff does not show')
        new, file, line = self.press_e()
        self.assertEqual((file, line), (str(self.repo.resolve()/'tracked.txt'), 2), 'a removed line does not open beside it')
        self.leave(new)
        self.key('j')
        self.key('j')
        new, file, line = self.press_e()
        self.assertEqual((file, line), (str(self.repo.resolve()/'tracked.txt'), 3), 'the added line does not open at its number')
        self.leave(new)

    def test_closing_the_editor_goes_back_to_the_window_with_the_git_view(self):
        # The Git View's Window is not the Session's last Window.
        later = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', self.session + ':', '-c', str(self.repo), SHELL)
        try:
            self.select_change('tracked.txt')
            new, _, _ = self.press_e()
            self.s.tmux('kill-window', '-t', new)
            self.s.wait_shown(self.window)
            time.sleep(2)
            self.assertEqual(self.s.tmux('display-message', '-p', '-t', self.session + ':', '#{window_id}'), self.window,
                             'the app left the Window with the Git View after the editor closed')
            self.assertTrue(self.is_open(), 'the Git View did not stay open in the Window it was left in')
        finally:
            self.s.tmux('kill-window', '-t', later)
            self.s.wait_shown(self.window)

    def run_editor_in_background(self, command):
        """Sets `editor_in_window: false` with the editor command, and sets it back after the check. A Window Summary
        changes in the same Config reload, so the check waits until the app reads it."""
        config = self.s.root/'config/muxify/config.yaml'
        original = config.read_text()
        marker = 'Editor in background'
        def reloaded(present):
            keys = ('topic-window-' + self.window, 'session-window-' + self.window)
            return lambda rs: any((marker in r.get('accessibilityLabel', '')) == present
                                  for r in rs if r.get('accessibilityIdentifier') in keys)
        def restore():
            config.write_text(original)
            self.s.wait_rows(reloaded(False), 'the Config did not reload')
        self.addCleanup(restore)
        config.write_text('git_view:\n  editor: ' + json.dumps(command) + '\n  editor_in_window: false\n'
                          'sidebar:\n  formats:\n    window:\n      summary: ' + marker + '\n')
        self.s.wait_rows(reloaded(True), 'the Config did not reload')

    def test_e_with_editor_in_window_off_runs_the_editor_and_opens_no_window(self):
        self.run_editor_in_background("printf '%s\\n%s\\n' {file} {line} > " + shlex.quote(str(self.editor_out)))
        self.select_change('tracked.txt')
        before = self.windows()
        self.editor_out.unlink(missing_ok=True)
        self.key('e')
        wait(self.editor_out.exists, 'the editor command did not run', seconds=10)
        file, line = self.editor_out.read_text().split('\n')[:2]
        self.assertEqual((file, int(line)), (str(self.repo.resolve()/'tracked.txt'), 2))
        time.sleep(2)  # Allow a Window to open before asserting none did.
        self.assertEqual(self.windows(), before, 'e opened a Window')
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', self.session + ':', '#{window_id}'), self.window,
                         'the app left the Window with the Git View')
        self.assertTrue(self.is_open(), 'the Git View closed')
        self.assertFalse(self.s.has('git-write-error'), 'the Git View shows an error')

    def test_e_with_editor_in_window_off_says_when_the_editor_command_fails(self):
        self.run_editor_in_background('echo no editor {file} >&2; exit 3')
        self.select_change('tracked.txt')
        self.key('e')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'the Git View did not say the editor failed')
        self.assertIn('no editor', self.s.row('git-write-error', rs).get('accessibilityValue', ''))

    def test_e_on_a_file_that_is_gone_says_so_and_opens_nothing(self):
        self.select_row('git-row-change:new.txt')
        (self.repo/'new.txt').rename(self.repo/'moved.txt')
        try:
            before = self.windows()
            self.editor_out.unlink(missing_ok=True)
            self.key('e')
            rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'the Git View did not say the file is gone')
            self.assertIn('new.txt', self.s.row('git-write-error', rs).get('accessibilityValue', ''))
            self.assertEqual(self.windows(), before, 'e opened a Window for a missing file')
            self.assertFalse(self.editor_out.exists(), 'the editor ran')
        finally:
            (self.repo/'moved.txt').rename(self.repo/'new.txt')

    def test_e_opens_the_editor_behind_a_window_gone_to_while_the_diff_was_read(self):
        # git runs a textconv for a patch and not for --numstat, so only the diff of tracked.txt waits 6 seconds.
        self.addCleanup(self.back_to_fixture_window)
        elsewhere = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'gv-elsewhere', '-c', str(self.repo), SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', 'gv-elsewhere')
        self.git('config', 'diff.slow.textconv', 'sleep 3; cat')
        self.addCleanup(self.git, 'config', '--unset', 'diff.slow.textconv')
        attributes = self.repo/'.git/info/attributes'
        attributes.write_text('tracked.txt diff=slow\n')
        self.addCleanup(attributes.unlink, missing_ok=True)
        # Away and back, so the diff of tracked.txt is read again with the textconv.
        self.select_row('git-row-change:new.txt')
        self.select_row('git-row-change:tracked.txt')
        self.editor_out.unlink(missing_ok=True)
        before = self.windows()
        self.key('e')
        self.s.show(elsewhere)
        wait(self.editor_out.exists, 'the editor command did not run', seconds=20)
        (new,) = self.windows() - before
        self.addCleanup(self.s.tmux_ok, 'kill-window', '-t', new)
        self.assertEqual(self.editor_out.read_text().split('\n')[0], str(self.repo.resolve()/'tracked.txt'))
        # The app goes to a new Window at its next read of tmux, about once a second.
        time.sleep(2)
        self.s.wait_shown(elsewhere, seconds=2)

    def empty_topic(self, name):
        """A Topic with no Session, and its card."""
        topics = self.s.root/'state/muxify/topics'
        topics.mkdir(parents=True, exist_ok=True)
        path = topics/(name + '.json')
        path.write_text(json.dumps(dict(id=name, title=name, slug=name)))
        self.addCleanup(remove_topic, path)
        self.s.wait_rows(lambda rs: self.s.has('topic-' + name, rs), 'the Topic card of %s did not show' % name)

    def test_an_empty_topic_page_shows_no_git_view_and_its_window_shows_it_again_as_it_was_left(self):
        self.go_to('3')
        self.s.wait_rows(lambda rs: self.s.row('git-tab-branches', rs).get('accessibilityValue') == 'selected', '3 did not show Branches')
        self.empty_topic('gv-empty-page')
        self.addCleanup(self.back_to_fixture_window)
        self.s.act('action', 'topic-gv-empty-page', 'Go to Topic')
        rs = self.s.wait_rows(lambda rs: self.s.row('empty-topic-title', rs).get('accessibilityValue') == 'gv-empty-page',
                              'the Empty Topic page did not show')
        self.assertFalse(self.is_open(rs), 'the Git View shows over the Empty Topic page')
        self.s.show(self.window)
        rs = self.s.wait_rows(lambda rs: self.is_open(rs), 'the Git View did not show again in its Window')
        self.assertEqual(self.s.row('git-tab-branches', rs).get('accessibilityValue'), 'selected', 'the Git View was not as it was left')

    def menu(self, rs=None):
        return self.s.row('git-menu', rs)

    def open_discard_menu(self, title='Discard changes'):
        self.key('d')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == title, 'd did not open ' + title)

    def wait_change(self, name, predicate, message):
        """Reads the repository again with R, as the Git View reads it by itself only every 10 seconds, and waits
        for the change's row."""
        self.key('shift+r')
        return self.s.wait_rows(lambda rs: predicate(self.s.row('git-row-change:' + name, rs)), message, seconds=10)

    def test_d_asks_in_the_discard_menu_and_escape_discards_nothing(self):
        # z- puts each new file last in Changes, where select_change's j reaches it.
        path = self.repo/'z-discard-escape.txt'
        path.write_text('kept\n')
        try:
            self.wait_change('z-discard-escape.txt', bool, 'Changes do not list z-discard-escape.txt')
            self.select_change('z-discard-escape.txt')
            rs = self.open_discard_menu()
            self.assertEqual(self.s.row('git-menu-choice-x', rs).get('accessibilityLabel'), 'Discard all changes')
            self.assertEqual(self.s.row('git-menu-choice-x', rs).get('accessibilityValue'), 'highlighted=1 enabled=1',
                             'the menu does not highlight x first')
            # Nothing of an untracked file is staged, so u is not offered.
            self.assertEqual(self.s.row('git-menu-choice-u', rs).get('accessibilityValue'), 'highlighted=0 enabled=0',
                             'u is offered for a file with nothing staged')
            # While the menu is open, no other Git View key acts.
            self.key('2')
            time.sleep(1)
            rs = self.s.rows()
            self.assertTrue(self.s.has('git-menu', rs), '2 closed the menu')
            self.assertEqual(self.s.row('git-tab-changes', rs).get('accessibilityValue'), 'selected', '2 changed the tab under the menu')
            self.s.act('action', 'git-menu', 'escape')
            self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
            time.sleep(1)
            self.assertTrue(path.exists(), 'escape discarded the file')
        finally:
            path.unlink(missing_ok=True)

    def test_x_in_the_discard_menu_deletes_an_untracked_file(self):
        path = self.repo/'z-discard-x.txt'
        path.write_text('gone\n')
        try:
            self.wait_change('z-discard-x.txt', bool, 'Changes do not list z-discard-x.txt')
            self.select_change('z-discard-x.txt')
            self.open_discard_menu()
            self.s.act('action', 'git-menu', 'x')
            self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'x did not close the menu')
            wait(lambda: not path.exists(), 'x did not delete the untracked file', seconds=10)
            self.wait_change('z-discard-x.txt', lambda row: not row, 'the discarded file stays in Changes')
        finally:
            path.unlink(missing_ok=True)

    def test_enter_on_u_in_the_discard_menu_keeps_what_is_staged(self):
        path = self.repo/'stashed.txt'
        path.write_text('one\nstaged\n')
        self.git('add', 'stashed.txt')
        path.write_text('one\nstaged\nunstaged\n')
        try:
            self.wait_change('stashed.txt', lambda row: self.status(row) == 'MM', 'stashed.txt is not staged and unstaged')
            self.select_change('stashed.txt')
            rs = self.open_discard_menu()
            self.assertEqual(self.s.row('git-menu-choice-u', rs).get('accessibilityValue'), 'highlighted=0 enabled=1',
                             'u is not offered for a file with staged and unstaged changes')
            self.s.act('action', 'git-menu', 'j')
            self.s.wait_rows(lambda rs: self.s.row('git-menu-choice-u', rs).get('accessibilityValue') == 'highlighted=1 enabled=1',
                             'j did not highlight u')
            self.s.act('action', 'git-menu', 'enter')
            self.wait_change('stashed.txt', lambda row: self.status(row) == 'M ', 'u did not discard only the unstaged change')
            self.assertEqual(path.read_text(), 'one\nstaged\n', 'u changed what is staged')
        finally:
            self.git('checkout', '-q', 'HEAD', '--', 'stashed.txt')

    def test_d_in_a_diff_asks_to_discard_the_cursors_line(self):
        path = self.repo/'z-discard-line.txt'
        path.write_text('only line\n')
        try:
            self.wait_change('z-discard-line.txt', bool, 'Changes do not list z-discard-line.txt')
            self.select_change('z-discard-line.txt')
            self.key('enter')
            self.s.wait_rows(lambda rs: any(r.get('accessibilityLabel') == 'only line'
                                            and r.get('accessibilityIdentifier', '').startswith('git-line-') for r in rs),
                             'the new file\'s diff does not show')
            rs = self.open_discard_menu('Discard lines')
            self.assertEqual(self.s.row('git-menu-choice-x', rs).get('accessibilityLabel'), 'Discard the line')
            self.assertFalse(self.s.has('git-menu-choice-u', rs), 'lines offer u')
            self.s.act('press', 'git-menu-choice-x')
            wait(lambda: not path.exists(), 'discarding all of a new file\'s lines did not delete it', seconds=10)
        finally:
            path.unlink(missing_ok=True)

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

    def test_discard_asks_naming_the_agents_working_in_the_worktree_and_only_them(self):
        path = self.repo/'z-discard-agent.txt'
        path.write_text('kept\n')
        other = self.s.root/'projects/other'
        other.mkdir(exist_ok=True)
        try:
            self.wait_change('z-discard-agent.txt', bool, 'Changes do not list z-discard-agent.txt')
            # Another Worktree's Agent, and one that is done, do not count: the menu is as before.
            self.agent_pane('gv-agent-other', other, 'working')
            inside = self.agent_pane('gv-agent-inside', self.repo/'.git', 'done')
            time.sleep(2)
            self.discard_names_agents('z-discard-agent.txt', False)
            # A working Agent in a folder inside the Worktree is named in the same menu, and ⎋ discards nothing.
            self.set_status(inside, 'working')
            names = self.discard_names_agents('z-discard-agent.txt', True)
            self.assertEqual(names, 'Claude Code in gv-agent-inside')
            self.assertTrue(path.exists(), 'escape discarded the file')
            # So does a blocked one, and x still discards from the one menu.
            self.set_status(inside, 'blocked')
            self.discard_names_agents('z-discard-agent.txt', True)
            self.select_change('z-discard-agent.txt')
            self.open_discard_menu()
            self.s.act('action', 'git-menu', 'x')
            wait(lambda: not path.exists(), 'x did not delete the file after the guarded menu', seconds=10)
        finally:
            path.unlink(missing_ok=True)

    def stashes(self):
        return self.git('stash', 'list', '--format=%gs').splitlines()

    def porcelain(self):
        return self.git('status', '--porcelain', '--untracked-files=all').splitlines()

    def restore_fixture(self, stashes):
        """Puts the fixture's changes back as setUpClass left them (one staged, one not, one untracked), and drops the
        stashes a check made, so the checks that follow find the tree they expect."""
        self.git('reset', '-q', '--hard')
        while len(self.stashes()) > stashes:
            self.git('stash', 'drop', '-q')
        (self.repo/'tracked.txt').write_text('one\nthe quick red fox\ntracked added line\n')
        (self.repo/'staged.txt').write_text('one\nstaged line\n')
        self.git('add', 'staged.txt')
        (self.repo/'new.txt').write_text('new file\n')

    def type_in_prompt(self, message, title='Stash changes'):
        """Waits for the prompt, types a message in its field and submits it with ↩."""
        self.s.wait_rows(lambda rs: self.s.row('git-prompt', rs).get('accessibilityLabel') == title, 'no prompt: ' + title)
        self.s.act('set', 'git-prompt-field', message)
        self.s.act('action', 'git-prompt', 'enter')
        self.s.wait_rows(lambda rs: not self.s.has('git-prompt', rs), 'enter did not close the prompt')

    def test_s_asks_for_a_message_and_stashes_all_changes_but_untracked_files(self):
        self.wait_change('tracked.txt', bool, 'Changes do not list tracked.txt')
        before = self.stashes()
        tree = self.porcelain()
        self.key('s')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-prompt', rs), 's did not open the prompt')
        self.assertEqual(self.s.row('git-prompt', rs).get('accessibilityLabel'), 'Stash changes')
        # While it is open, ⎋ cancels with no change.
        self.s.act('action', 'git-prompt', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-prompt', rs), 'escape did not close the prompt')
        time.sleep(1)
        self.assertEqual(self.stashes(), before, 'escape stashed')
        self.assertEqual(self.porcelain(), tree, 'escape changed the tree')
        self.key('s')
        self.type_in_prompt('my note')
        self.addCleanup(self.restore_fixture, len(before))
        wait(lambda: self.stashes()[:1] == ['On main: my note'], 'the stash is not git\'s stash of "my note"', seconds=10)
        self.assertEqual(self.porcelain(), ['?? new.txt'], 'the tree is not as git stash push leaves it')
        self.assertEqual(self.git('show', 'stash@{0}:tracked.txt'), 'one\nthe quick red fox\ntracked added line\n')
        self.assertEqual(self.git('show', 'stash@{0}:staged.txt'), 'one\nstaged line\n')
        # The new stash shows in Stashes, with its count, and Changes lists what is left.
        rs = self.s.wait_rows(lambda rs: not self.s.has('git-row-change:tracked.txt', rs) and self.s.has('git-row-change:new.txt', rs),
                              'Changes list what the stash took', seconds=15)
        self.assertEqual(len(before) + 1, len(self.stashes()))
        self.key('4')
        self.s.wait_rows(lambda rs: sum(r.get('accessibilityLabel') == 'my note' for r in
                                        self.rows_with_prefix('git-row-stash:', rs)) == 1, 'Stashes do not list the new stash', seconds=15)
        self.key('1')

    def test_shift_s_offers_lazygits_stash_options_and_each_stashes_as_git_does(self):
        # The fixture: staged.txt staged, tracked.txt changed and not staged, new.txt untracked.
        kinds = [
            ('a', 'Stash all changes', ['?? new.txt'], None),
            ('shift+u', 'Stash all changes including untracked files', [], None),
            ('s', 'Stash staged changes', [' M tracked.txt', '?? new.txt'], 'staged.txt'),
            ('u', 'Stash unstaged changes', ['M  staged.txt', '?? new.txt'], 'tracked.txt'),
            ('i', 'Stash all changes and keep index', ['M  staged.txt', '?? new.txt'], None),
        ]
        self.wait_change('tracked.txt', bool, 'Changes do not list tracked.txt')
        tree = self.porcelain()
        self.key('shift+s')
        rs = self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Stash options', 'S did not open the stash options')
        for key, title, _, _ in kinds:
            self.assertEqual(self.s.row('git-menu-choice-' + key, rs).get('accessibilityLabel'), title)
            self.assertIn('enabled=1', self.s.row('git-menu-choice-' + key, rs).get('accessibilityValue'), title + ' is not offered')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        for key, title, left, only in kinds:
            with self.subTest(title):
                message = 'by ' + key.replace('+', '-')
                before = len(self.stashes())
                self.key('shift+s')
                self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Stash options', 'S did not open the stash options')
                self.s.act('action', 'git-menu', key)
                self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), key + ' did not close the menu')
                self.type_in_prompt(message)
                wait(lambda: len(self.stashes()) == before + 1, title + ' made no stash', seconds=10)
                self.assertEqual(self.stashes()[0], 'On main: ' + message)
                self.assertEqual(self.porcelain(), left, title + ' left the tree as git would not')
                if only:
                    self.assertEqual(self.git('diff', '--name-only', 'stash@{0}^', 'stash@{0}').split(), [only])
                else:
                    self.assertEqual(self.git('show', 'stash@{0}:staged.txt'), 'one\nstaged line\n')
                self.restore_fixture(before)
                self.assertEqual(self.porcelain(), tree, 'the check did not put the tree back')
                self.wait_change('tracked.txt', bool, 'Changes do not list tracked.txt again')

    def test_with_nothing_to_stash_the_git_view_says_so_and_opens_nothing(self):
        self.addCleanup(self.restore_fixture, len(self.stashes()))
        self.git('stash', 'push', '-u', '-q', '-m', 'all of it')
        self.wait_change('tracked.txt', lambda row: not row, 'Changes still list tracked.txt')
        for key in ['s', 'shift+s']:
            self.key(key)
            self.s.wait_rows(lambda rs: 'Nothing to stash' in self.s.row('git-write-error', rs).get('accessibilityValue', ''),
                             key + ' does not say there is nothing to stash')
            self.assertFalse(self.s.has('git-prompt'), key + ' opened a prompt')
            self.assertFalse(self.s.has('git-menu'), key + ' opened a menu')
            self.key('shift+r')

    def test_stashing_asks_first_while_an_agent_is_working_in_the_worktree(self):
        path = self.repo/'z-stash-agent.txt'
        path.write_text('kept\n')
        self.addCleanup(path.unlink, missing_ok=True)
        self.wait_change('z-stash-agent.txt', bool, 'Changes do not list z-stash-agent.txt')
        self.agent_pane('gv-stash-agent', self.repo, 'working')
        # Muxify reads the Panes' options on its own timer: wait until the Git View names the Agent.
        self.assertEqual(self.discard_names_agents('z-stash-agent.txt', True), 'Claude Code in gv-stash-agent')
        before = len(self.stashes())
        self.key('shift+s')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Stash options', 'S did not open the stash options')
        self.s.act('action', 'git-menu', 'shift+u')
        self.type_in_prompt('guarded')
        rs = self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Stash changes', 'no question while an Agent works there')
        self.assertEqual(self.s.row('git-menu-agents', rs).get('accessibilityLabel'), 'Claude Code in gv-stash-agent')
        time.sleep(1)
        self.assertEqual(len(self.stashes()), before, 'the stash was made before the question was answered')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertEqual(len(self.stashes()), before, 'escape stashed')
        self.key('s')
        self.type_in_prompt('guarded')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Stash changes', 'no question while an Agent works there')
        self.s.act('action', 'git-menu', 'y')
        self.addCleanup(self.restore_fixture, before)
        wait(lambda: len(self.stashes()) == before + 1, 'y did not stash', seconds=10)

    def make_stash(self, name):
        """A stash of a change to stashed.txt alone, named `name`, at the top of the list; returns its hash. The
        cleanup puts the fixture back, as restore_fixture does, and drops it."""
        self.addCleanup(self.restore_fixture, len(self.stashes()))
        (self.repo/'stashed.txt').write_text('one\nentry ' + name + '\n')
        self.git('stash', 'push', '-q', '-m', name, '--', 'stashed.txt')
        return self.git('rev-parse', 'stash@{0}').strip()

    def select_stash(self, sha):
        """Goes to Stashes, reads the repository again, and selects the stash's row."""
        self.key('4')
        self.key('shift+r')
        self.select_row('git-row-stash:' + sha)

    def ask_stash(self, key, title):
        self.key(key)
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == title, key + ' did not open ' + title)

    def has_stash_row(self, sha, rs=None):
        return self.s.has('git-row-stash:' + sha, rs)

    def test_space_on_a_stash_applies_it_after_asking_and_the_stash_stays(self):
        sha = self.make_stash('apply me')
        self.select_stash(sha)
        rs = self.ask_stash('space', 'Apply stash')
        self.assertEqual(self.s.row('git-menu-choice-y', rs).get('accessibilityLabel'), 'Apply it')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertEqual((self.repo/'stashed.txt').read_text(), 'one\n', 'escape applied the stash')
        self.ask_stash('space', 'Apply stash')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: (self.repo/'stashed.txt').read_text() == 'one\nentry apply me\n', 'y did not apply the stash', seconds=10)
        self.assertEqual(self.stashes()[0], 'On main: apply me', 'apply dropped the stash')
        self.s.wait_rows(lambda rs: self.has_stash_row(sha, rs), 'Stashes no longer list the applied stash', seconds=15)
        self.key('1')
        self.wait_change('stashed.txt', lambda row: self.status(row) == ' M', 'Changes do not list the applied stash\'s file')

    def test_g_on_a_stash_pops_it_after_asking(self):
        sha = self.make_stash('pop me')
        before = len(self.stashes())
        self.select_stash(sha)
        self.ask_stash('g', 'Pop stash')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertEqual(len(self.stashes()), before, 'escape popped')
        self.ask_stash('g', 'Pop stash')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: len(self.stashes()) == before - 1, 'y did not drop the popped stash', seconds=10)
        self.assertEqual((self.repo/'stashed.txt').read_text(), 'one\nentry pop me\n', 'pop did not apply the stash')
        self.s.wait_rows(lambda rs: not self.has_stash_row(sha, rs), 'Stashes still list the popped stash', seconds=15)
        self.key('1')
        self.wait_change('stashed.txt', lambda row: self.status(row) == ' M', 'Changes do not list the popped stash\'s file')

    def test_a_pop_that_conflicts_keeps_the_stash_and_shows_the_conflict(self):
        sha = self.make_stash('conflict')
        # Another change to the same line, committed, so that applying the stash conflicts.
        (self.repo/'stashed.txt').write_text('one\nother\n')
        self.git('commit', '-q', '-m', 'conflicting change', '--', 'stashed.txt')
        self.addCleanup(self.git, 'reset', '-q', '--hard', 'HEAD^')
        before = len(self.stashes())
        self.select_stash(sha)
        self.ask_stash('g', 'Pop stash')
        self.s.act('action', 'git-menu', 'y')
        rs = self.s.wait_rows(lambda rs: 'conflicted' in self.s.row('git-write-error', rs).get('accessibilityValue', ''),
                              'the banner does not say the pop conflicted', seconds=15)
        self.assertEqual(len(self.stashes()), before, 'the conflicting pop dropped the stash')
        self.assertIn('UU stashed.txt', self.porcelain())
        self.s.wait_rows(lambda rs: self.has_stash_row(sha, rs), 'Stashes no longer list the stash', seconds=15)
        self.key('1')
        self.wait_change('stashed.txt', bool, 'Changes do not list the conflicted file')

    def test_d_on_a_stash_drops_it_after_asking(self):
        sha = self.make_stash('drop me')
        before = len(self.stashes())
        self.select_stash(sha)
        self.ask_stash('d', 'Drop stash')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertEqual(len(self.stashes()), before, 'escape dropped')
        self.ask_stash('d', 'Drop stash')
        self.assertFalse(self.s.has('git-menu-agents'), 'drop does not change files, so the guard does not ask')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: len(self.stashes()) == before - 1, 'y did not drop the stash', seconds=10)
        self.assertEqual((self.repo/'stashed.txt').read_text(), 'one\n', 'drop changed the working tree')
        self.s.wait_rows(lambda rs: not self.has_stash_row(sha, rs), 'Stashes still list the dropped stash', seconds=15)

    def test_applying_a_stash_asks_in_its_own_menu_while_an_agent_is_working_in_the_worktree(self):
        sha = self.make_stash('guarded')
        self.agent_pane('gv-stash-entry-agent', self.repo, 'working')
        self.select_stash(sha)
        found = []

        def names_agent():
            rs = self.ask_stash('space', 'Apply stash')
            found[:] = [self.s.row('git-menu-agents', rs).get('accessibilityLabel') if self.s.has('git-menu-agents', rs) else None]
            if found[0] is None:
                # Muxify reads the Panes' options on its own timer, so the first menu may be early.
                self.s.act('action', 'git-menu', 'escape')
                self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
            return found[0] is not None
        wait(names_agent, 'the Apply menu does not name the working Agent', seconds=20, step=1)
        self.assertEqual(found[0], 'Claude Code in gv-stash-entry-agent')
        time.sleep(1)
        self.assertEqual((self.repo/'stashed.txt').read_text(), 'one\n', 'the stash was applied before the question was answered')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: (self.repo/'stashed.txt').read_text() == 'one\nentry guarded\n', 'y did not apply the stash', seconds=10)

    def test_space_g_and_d_keep_their_meanings_outside_the_stashes_list(self):
        sha = self.make_stash('elsewhere')
        self.select_stash(sha)
        # In the stash's files: g and d do nothing, and space folds nothing that isn't a folder.
        self.key('enter')
        self.s.wait_rows(lambda rs: self.rows_with_prefix('git-row-file:', rs) or self.rows_with_prefix('git-row-folder:', rs),
                         'enter did not go into the stash\'s files')
        for key in ['g', 'd']:
            self.key(key)
            time.sleep(.5)
            self.assertFalse(self.s.has('git-menu'), key + ' asked in the stash\'s files')
        self.key('escape')
        # In History: d asks nothing (g resets there, and has its own checks).
        self.key('2')
        self.key('d')
        time.sleep(.5)
        self.assertFalse(self.s.has('git-menu'), 'd asked in History')
        # In Changes, d still discards.
        self.key('1')
        self.wait_change('tracked.txt', bool, 'Changes do not list tracked.txt')
        self.select_change('tracked.txt')
        self.open_discard_menu()
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')

    def head(self):
        """The branch the fixture is on, or '' when HEAD is detached."""
        return self.git('branch', '--show-current').strip()

    def back_to_main(self):
        self.git('checkout', '-q', 'main')

    def history_subjects(self, rs=None):
        return [r.get('accessibilityLabel') for r in self.rows_with_prefix('git-row-commit:', rs)]

    def test_space_on_a_branch_checks_it_out_and_on_the_current_branch_does_nothing(self):
        self.addCleanup(self.back_to_main)
        self.go_to('3')
        self.select_row('git-row-branch:main')
        self.key('space')
        time.sleep(1)
        self.assertFalse(self.s.has('git-menu'), 'space on the current branch asked')
        self.assertEqual(self.head(), 'main')
        self.select_row('git-row-branch:feature-x')
        self.key('space')
        wait(lambda: self.head() == 'feature-x', 'space did not check out the branch', seconds=10)
        self.go_to('2')
        self.s.wait_rows(lambda rs: self.history_subjects(rs)[:1] == ['feature two'], 'History does not start at the new HEAD', seconds=15)
        self.assertEqual((self.repo/'feature.txt').read_text(), 'feature\nmore\n')

    def test_space_on_a_commit_in_history_checks_it_out_and_leaves_a_detached_head(self):
        self.addCleanup(self.back_to_main)
        sha = self.git('rev-parse', 'main~1').strip()
        self.go_to('2')
        self.select_row('git-row-commit:' + sha)
        self.key('space')
        wait(lambda: self.head() == '' and self.git('rev-parse', 'HEAD').strip() == sha, 'space did not detach HEAD at the commit', seconds=10)
        self.assertEqual((self.repo/'README.md').read_text(), 'one\ntwo\n')
        self.s.wait_rows(lambda rs: self.history_subjects(rs)[:1] == ['second commit'], 'History does not start at the detached HEAD', seconds=15)
        self.assertNotIn('no upstream', self.toolbar(), 'the toolbar does not show a detached HEAD')

    def test_a_checkout_that_changes_would_overwrite_asks_to_autostash(self):
        self.git('checkout', '-q', '-b', 'autostash-x')
        (self.repo/'stashed.txt').write_text('one\nbranch\n')
        self.git('commit', '-q', '-m', 'autostash branch', '--', 'stashed.txt')
        self.git('checkout', '-q', 'main')
        self.addCleanup(self.git, 'branch', '-q', '-D', 'autostash-x')
        self.addCleanup(self.back_to_main)
        self.addCleanup(self.git, 'checkout', '-q', '--', 'stashed.txt')
        # The pop brings the staged file back unstaged, as git does without --index.
        self.addCleanup(self.git, 'add', 'staged.txt')
        (self.repo/'stashed.txt').write_text('top\none\n')
        stashes = len(self.stashes())
        # R renames in Branches, so it reads the repository again before going there.
        self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:autostash-x')
        self.key('space')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Autostash?', 'no Autostash? question')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertEqual(self.head(), 'main', 'escape checked out')
        self.assertEqual((self.repo/'stashed.txt').read_text(), 'top\none\n', 'escape changed the file')
        self.key('space')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Autostash?', 'no Autostash? question the second time')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: self.head() == 'autostash-x', 'y did not check out the branch', seconds=10)
        wait(lambda: (self.repo/'stashed.txt').read_text() == 'top\none\nbranch\n', 'the stash was not popped onto the branch', seconds=10)
        self.assertEqual(len(self.stashes()), stashes, 'the autostash was left in the list')

    def test_a_checkout_asks_first_while_an_agent_is_working_in_the_worktree(self):
        self.addCleanup(self.back_to_main)
        self.agent_pane('gv-checkout-agent', self.repo, 'working')
        # Until the Git View knows the Agent, space would check out at once: wait on a menu that only asks.
        self.assertEqual(self.discard_names_agents('tracked.txt', True), 'Claude Code in gv-checkout-agent')
        self.go_to('3')
        self.select_row('git-row-branch:feature-x')
        self.key('space')
        rs = self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Check out', 'space did not ask before checking out')
        self.assertEqual(self.s.row('git-menu-agents', rs).get('accessibilityLabel'), 'Claude Code in gv-checkout-agent')
        time.sleep(1)
        self.assertEqual(self.head(), 'main', 'the branch was checked out before the question was answered')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: self.head() == 'feature-x', 'y did not check out the branch', seconds=10)

    def add_worktree(self, name):
        """A Worktree of the fixture beside it, with a new branch of the same name checked out in it."""
        path = self.repo.parent/('fixture-' + name)
        self.git('worktree', 'add', '-q', '-b', name, str(path))
        self.addCleanup(self.git, 'branch', '-q', '-D', name)
        self.addCleanup(self.git, 'worktree', 'remove', '--force', str(path))
        return path

    def ask_to_go_to_worktree(self, branch):
        """space on the branch in Branches, until the Git View has read it as checked out by another Worktree."""
        # R renames in Branches, so it reads the repository again before going there.
        self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:' + branch)
        self.key('space')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Go to Worktree?',
                                'space on a branch of another Worktree did not ask to go there')

    def test_a_branch_of_another_worktree_asks_to_go_there_and_escape_changes_nothing(self):
        self.add_worktree('other-wt-esc')
        sessions = self.s.tmux('list-sessions', '-F', '#{session_name}')
        rs = self.ask_to_go_to_worktree('other-wt-esc')
        self.assertTrue(self.s.has('git-menu-choice-y', rs), 'the question has no y')
        self.assertEqual(self.s.row('git-menu-choice-y', rs).get('accessibilityLabel'), 'Go to fixture-other-wt-esc',
                         'the question does not name the Worktree that has the branch')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertEqual(self.head(), 'main', 'escape checked out')
        self.assertFalse(self.s.has('palette-search'), 'escape opened Go to…')
        self.assertTrue(self.is_open(), 'escape closed the Git View')
        self.assertEqual(self.s.tmux('list-sessions', '-F', '#{session_name}'), sessions, 'escape changed the Sessions')
        self.s.wait_shown(self.window)

    def test_confirming_goes_to_a_window_with_a_pane_in_that_worktree(self):
        path = self.add_worktree('other-wt-window')
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'gv-wt-window', '-c', str(path), SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        window = self.s.tmux('display-message', '-p', '-t', session + ':', '#{window_id}')
        self.addCleanup(self.back_to_fixture_window)
        # Muxify reads tmux on its own timer, about once a second: let it see the Pane before asking.
        time.sleep(3)
        self.ask_to_go_to_worktree('other-wt-window')
        self.s.act('action', 'git-menu', 'y')
        self.s.wait_shown(window)
        self.assertFalse(self.s.has('palette-search'), 'Go to… opened although a Window has a Pane there')
        self.assertEqual(self.head(), 'main', 'the branch was checked out')

    def back_to_fixture_window(self):
        self.s.show(self.window)

    def test_confirming_with_no_window_in_that_worktree_opens_go_to_on_its_session_path_and_starts_nothing(self):
        path = self.add_worktree('other-wt-none')
        sessions = self.s.tmux('list-sessions', '-F', '#{session_name}')
        self.ask_to_go_to_worktree('other-wt-none')
        self.s.act('action', 'git-menu', 'y')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Go to… did not open')

        def worktree_rows(rs):
            return [r for r in rs if r.get('accessibilityIdentifier', '').startswith('palette-row-session-path:')
                    and r['accessibilityIdentifier'].endswith('fixture-other-wt-none')]
        try:
            rs = self.s.wait_rows(lambda rs: worktree_rows(rs), 'Go to… has no row for the Worktree')
        except AssertionError:
            self.fail('no row: %s' % [(i, r.get('accessibilityValue')) for r in self.s.rows() for i in [r.get('accessibilityIdentifier', '')] if i.startswith('palette')])
        rows = worktree_rows(rs)
        self.assertEqual(len(rows), 1, [i for i in self.s.ids(rs) if i.startswith('palette-row-')])
        self.assertEqual(rows[0].get('accessibilityValue'), 'selected', 'the Worktree\'s row is not under the cursor')
        time.sleep(1)
        self.assertEqual(self.s.tmux('list-sessions', '-F', '#{session_name}'), sessions, 'a Session started without the user')
        self.assertEqual(self.head(), 'main', 'the branch was checked out')
        self.assertTrue(self.is_open(), 'the Git View of the Window that was left closed')

    def prompt_label(self, rs=None):
        return self.s.row('git-prompt', rs).get('accessibilityLabel')

    def wait_prompt(self, title):
        return self.s.wait_rows(lambda rs: self.prompt_label(rs) == title, 'no prompt: ' + title)

    def test_n_asks_for_a_name_and_checks_out_a_new_branch_off_the_selected_one(self):
        self.addCleanup(self.git, 'branch', '-q', '-D', 'n-topic')
        self.addCleanup(self.back_to_main)
        self.go_to('3')
        self.select_row('git-row-branch:feature-x')
        self.key('n')
        self.wait_prompt("New branch name (branch is off of 'feature-x')")
        self.s.act('set', 'git-prompt-field', 'n topic')
        self.s.act('action', 'git-prompt', 'enter')
        wait(lambda: self.head() == 'n-topic', 'n did not check out the new branch', seconds=10)
        self.assertEqual(self.git('rev-parse', 'n-topic'), self.git('rev-parse', 'feature-x'), 'the branch is not off of feature-x')

    def test_shift_r_in_branches_renames_the_selected_branch_starting_at_its_name(self):
        self.git('branch', 'rename-me')
        self.addCleanup(self.git, 'branch', '-q', '-D', 'renamed')
        self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:rename-me')
        self.key('shift+r')
        self.wait_prompt('Rename branch')
        self.assertEqual(self.s.row('git-prompt-field').get('accessibilityValue'), 'rename-me', 'the prompt does not start at the name')
        self.s.act('set', 'git-prompt-field', 'renamed')
        self.s.act('action', 'git-prompt', 'enter')
        wait(lambda: 'renamed' in self.git('branch', '--format=%(refname:short)').split(), 'R did not rename the branch', seconds=10)
        self.assertNotIn('rename-me', self.git('branch', '--format=%(refname:short)').split())

    def test_minus_in_branches_checks_out_the_previous_branch(self):
        self.addCleanup(self.back_to_main)
        self.git('checkout', '-q', 'feature-x')
        self.git('checkout', '-q', 'main')
        self.close_git_view()
        self.open_git_view()
        # The Git View opens on what it read last, which a check before may have left behind, with the branch it was
        # on before: read again, and give the read time to end.
        self.key('shift+r')
        time.sleep(2)
        self.go_to('3')
        self.select_row('git-row-branch:main')
        self.key('minus')
        wait(lambda: self.head() == 'feature-x', 'minus did not check out the previous branch', seconds=10)

    def test_c_in_branches_checks_out_by_name_with_suggestions_and_a_remote_branch_makes_a_tracking_branch(self):
        origin = self.s.root/'origin.git'
        subprocess.run(['/usr/bin/git', 'init', '-q', '--bare', str(origin)], check=True)
        self.git('remote', 'add', 'origin', str(origin))
        self.addCleanup(self.git, 'remote', 'remove', 'origin')
        self.git('push', '-q', 'origin', 'feature-x:remote-y')
        self.git('fetch', '-q', 'origin')
        self.addCleanup(self.git, 'branch', '-q', '-D', 'remote-y')
        self.addCleanup(self.back_to_main)
        self.key('shift+r')
        self.go_to('3')
        # The prompt offers the branches the Git View had read when it opened, so ask again until it has read the remote's.
        def suggested():
            self.key('c')
            self.wait_prompt('Check out')
            self.s.act('set', 'git-prompt-field', 'remote-y')
            try:
                return self.s.wait_rows(lambda rs: self.s.row('git-prompt-suggestion-0', rs).get('accessibilityLabel') == 'origin/remote-y',
                                        'typing did not suggest the remote branch', seconds=2)
            except AssertionError:
                self.s.act('action', 'git-prompt', 'escape')
                self.s.wait_rows(lambda rs: not self.s.has('git-prompt', rs), 'escape did not close the prompt')
        rs = wait(suggested, 'typing did not suggest the remote branch', seconds=30)
        self.assertFalse(self.s.has('git-prompt-suggestion-1', rs), 'a name that does not match was suggested')
        self.s.act('action', 'git-prompt', 'down')
        self.s.wait_rows(lambda rs: self.s.row('git-prompt-suggestion-0', rs).get('accessibilityValue') == 'chosen', 'down did not choose it')
        self.s.act('action', 'git-prompt', 'enter')
        wait(lambda: self.head() == 'remote-y', 'the suggestion was not checked out', seconds=10)
        self.assertEqual(self.git('rev-parse', '--abbrev-ref', 'remote-y@{upstream}').strip(), 'origin/remote-y')

    def test_c_commits_only_in_changes_and_does_nothing_in_history_and_stashes(self):
        for key in ['2', '4']:
            self.key(key)
            self.key('c')
            time.sleep(.5)
            self.assertFalse(self.s.has('git-prompt'), 'c opened a prompt in tab ' + key)
            self.assertFalse(self.s.has('git-commit-box'), 'c opened the commit box in tab ' + key)
        self.key('1')
        self.key('c')
        self.s.wait_rows(lambda rs: self.s.has('git-commit-box', rs), 'c in Changes did not open the commit box')
        self.key('escape')

    def branches(self):
        return self.git('branch', '--format=%(refname:short)').split()

    def drop_branch(self, name):
        """Cleanup for a branch that the test may have deleted already."""
        if name in self.branches():
            self.git('branch', '-q', '-D', name)

    def ask_to_delete(self, branch, refresh=True):
        """d on the branch in Branches, after reading the repository again (R renames in Branches, so it comes first,
        and only before going there)."""
        if refresh:
            self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:' + branch)
        self.key('d')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Delete branch',
                                'd in Branches did not open the delete menu')

    def remote_branches(self, origin):
        return subprocess.run(['/usr/bin/git', '--git-dir', str(origin), 'branch', '--format=%(refname:short)'],
                              capture_output=True, text=True).stdout.split()

    def tracked_branch(self, name, origin):
        self.git('branch', name, 'main')
        self.addCleanup(self.drop_branch, name)
        self.git('push', '-q', '-u', 'origin', name)

    def confirm_remote_delete(self, key, name, origin):
        self.tracked_branch(name, origin)
        rs = self.ask_to_delete(name)
        for choice in 'cr' if key == 'r' else 'crb':
            self.assertTrue(self.s.has('git-menu-choice-' + choice, rs), 'no choice ' + choice)
        self.s.act('action', 'git-menu', key)
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') in ('Delete remote branch', 'Delete local and remote branch')
                         and self.s.has('git-menu-choice-y', rs), 'the remote delete did not ask first')
        time.sleep(.5)
        self.assertIn(name, self.remote_branches(origin), 'opening the confirmation deleted the remote branch')

    def test_r_deletes_the_remote_branch_after_asking_and_keeps_the_local_one(self):
        origin = self.bare_remote('del-remote')
        self.confirm_remote_delete('r', 'rem-r', origin)
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: 'rem-r' not in self.remote_branches(origin), 'y did not delete the remote branch', seconds=15)
        self.assertIn('rem-r', self.branches(), 'the local branch went')

    def test_b_deletes_the_remote_and_then_the_local_branch(self):
        origin = self.bare_remote('del-both')
        self.confirm_remote_delete('b', 'rem-b', origin)
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: 'rem-b' not in self.remote_branches(origin) and 'rem-b' not in self.branches(),
             'y did not delete both branches', seconds=15)

    def test_a_branch_without_an_upstream_offers_only_the_local_choice(self):
        self.git('branch', 'rem-none', 'main')
        self.addCleanup(self.drop_branch, 'rem-none')
        rs = self.ask_to_delete('rem-none')
        self.assertTrue(self.s.has('git-menu-choice-c', rs))
        self.assertFalse(self.s.has('git-menu-choice-r', rs), 'a remote choice without an upstream')
        self.assertFalse(self.s.has('git-menu-choice-b', rs), 'a both choice without an upstream')

    def test_d_on_a_merged_branch_asks_in_the_delete_menu_and_c_deletes_it(self):
        self.git('branch', 'merged-b', 'main')
        self.addCleanup(self.drop_branch, 'merged-b')
        rs = self.ask_to_delete('merged-b')
        self.assertEqual(self.s.row('git-menu-choice-c', rs).get('accessibilityLabel'), 'Delete local branch')
        self.assertEqual(self.s.row('git-menu-choice-c', rs).get('accessibilityValue'), 'highlighted=1 enabled=1')
        time.sleep(.5)
        self.assertIn('merged-b', self.branches(), 'opening the menu deleted the branch')
        self.s.act('action', 'git-menu', 'c')
        wait(lambda: 'merged-b' not in self.branches(), 'c did not delete the merged branch', seconds=10)
        self.assertFalse(self.s.has('git-menu'), 'the menu stays open')
        self.assertFalse(self.s.has('git-write-error'), 'deleting a merged branch failed')

    def test_an_unmerged_branch_asks_to_force_and_is_deleted_only_on_confirm(self):
        self.git('branch', 'unmerged-b', 'feature-x')
        self.addCleanup(self.drop_branch, 'unmerged-b')
        self.ask_to_delete('unmerged-b')
        self.s.act('action', 'git-menu', 'c')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Force delete branch',
                         'c on an unmerged branch did not ask to force delete it')
        self.assertIn('unmerged-b', self.branches(), 'the branch was deleted before the question was answered')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertIn('unmerged-b', self.branches(), 'escape deleted the branch')
        self.ask_to_delete('unmerged-b', refresh=False)
        self.s.act('action', 'git-menu', 'c')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Force delete branch', 'no force question the second time')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: 'unmerged-b' not in self.branches(), 'y did not force delete the branch', seconds=10)

    def test_the_current_branch_cannot_be_deleted(self):
        rs = self.ask_to_delete('main')
        self.assertEqual(self.s.row('git-menu-choice-c', rs).get('accessibilityValue'), 'highlighted=0 enabled=0')
        self.s.act('action', 'git-menu', 'c')
        self.s.act('action', 'git-menu', 'enter')
        time.sleep(1)
        self.assertIn('main', self.branches(), 'the current branch was deleted')
        self.assertFalse(self.s.has('git-write-error'), 'a delete ran')
        self.assertTrue(self.s.has('git-menu'), 'the menu closed')

    def test_a_branch_of_another_worktree_is_not_deleted_and_git_says_why(self):
        path = self.add_worktree('del-other-wt')
        self.ask_to_delete('del-other-wt')
        self.s.act('action', 'git-menu', 'c')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'git did not refuse to delete the branch', seconds=10)
        self.assertIn('del-other-wt', self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertIn('del-other-wt', self.branches(), 'the branch was deleted')
        self.assertTrue(path.exists(), 'the Worktree was removed')

    def test_d_keeps_its_meanings_in_history_and_changes(self):
        self.key('2')
        self.key('d')
        time.sleep(.5)
        self.assertFalse(self.s.has('git-menu'), 'd opened a menu in History')
        self.key('1')
        self.s.wait_rows(lambda rs: self.s.has('git-row-change:tracked.txt', rs), 'no Changes')
        self.select_change('tracked.txt')
        self.open_discard_menu()

    def remote_one_commit_ahead(self, name, url=None):
        """Adds the remote origin, a bare repository with main and one commit more, and main tracking it, so a fetch
        leaves main one commit behind. `url` reaches it another way, such as over the fake ssh."""
        origin = self.s.root/(name + '.git')
        subprocess.run(['/usr/bin/git', 'init', '-q', '--bare', str(origin)], check=True)
        self.git('push', '-q', str(origin), 'main:main')
        clone = self.s.root/(name + '-clone')
        subprocess.run(['/usr/bin/git', 'clone', '-q', '-b', 'main', str(origin), str(clone)], check=True)
        (clone/'remote.txt').write_text('remote\n')
        identity = ['-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid']
        for args in [['add', 'remote.txt'], ['commit', '-q', '-m', 'remote commit'], ['push', '-q', 'origin', 'main']]:
            subprocess.run(['/usr/bin/git', '-C', str(clone)] + identity + args, check=True)
        self.git('remote', 'add', 'origin', url or str(origin))
        self.addCleanup(self.git, 'remote', 'remove', 'origin')
        self.git('config', 'branch.main.remote', 'origin')
        self.git('config', 'branch.main.merge', 'refs/heads/main')
        return origin

    def test_f_in_changes_fetches_all_remotes_and_the_counts_update(self):
        self.remote_one_commit_ahead('fetch-plain')
        # Only in Changes.
        self.key('2')
        self.key('f')
        time.sleep(1)
        self.assertNotIn('origin/main', self.git('branch', '-r'), 'f fetched in History')
        self.key('1')
        self.key('f')
        self.s.wait_rows(lambda rs: '↑0 ↓1 vs origin/main' in self.toolbar(rs), 'f did not fetch, or the counts did not update', seconds=15)
        self.assertNotIn('Fetching…', self.toolbar())
        self.assertFalse(self.s.has('git-write-error'), 'the fetch failed')

    def fake_ssh(self, name):
        """An ssh for git's core.sshCommand that, once the file `go` exists, asks for a passphrase on its terminal as
        ssh does, writes the answer to `answers`, and serves the repository only for the answer `right`."""
        folder = self.s.root/name
        folder.mkdir()
        go, answers, ssh = folder/'go', folder/'answers', folder/'ssh'
        ssh.write_text('#!/bin/sh\n'
                       f'while [ ! -e {shlex.quote(str(go))} ]; do sleep .1; done\n'
                       'printf "Enter passphrase for key \'/fake/id\': " > /dev/tty\n'
                       'IFS= read -r answer < /dev/tty\n'
                       f'printf \'%s\\n\' "$answer" >> {shlex.quote(str(answers))}\n'
                       '[ "$answer" = right ] || { echo "Permission denied (publickey)." >&2; exit 255; }\n'
                       'for last; do :; done\n'
                       'exec /bin/sh -c "$last"\n')
        ssh.chmod(0o755)
        self.git('config', 'core.sshCommand', shlex.quote(str(ssh)))
        self.addCleanup(self.git, 'config', '--unset', 'core.sshCommand')
        return go, answers

    def answer_prompt(self, title, text):
        self.wait_prompt(title)
        self.s.act('set', 'git-prompt-field', text)
        self.s.act('action', 'git-prompt', 'enter')
        self.s.wait_rows(lambda rs: not self.s.has('git-prompt', rs), 'enter did not close the prompt')

    def test_a_passphrase_ssh_asks_is_asked_hidden_while_staging_goes_on_and_escape_cancels(self):
        go, answers = self.fake_ssh('fetch-ssh-bin')
        origin = self.s.root/'fetch-ssh.git'
        self.remote_one_commit_ahead('fetch-ssh', url='ssh://fake.invalid' + str(origin))
        question = "Enter passphrase for key '/fake/id':"
        self.select_row('git-row-change:new.txt')
        self.key('f')
        self.s.wait_rows(lambda rs: 'Fetching…' in self.toolbar(rs), 'the toolbar does not show Fetching…')
        # The fetch runs beside the writes: staging goes on.
        self.addCleanup(self.git, 'reset', '-q', '--', 'new.txt')
        self.key('space')
        wait(lambda: 'A  new.txt' in self.porcelain(), 'space did not stage while the fetch ran', seconds=10)
        self.assertIn('Fetching…', self.toolbar(), 'the fetch ended before ssh asked')
        go.touch()
        rs = self.wait_prompt(question)
        self.assertTrue(self.s.has('git-prompt-secret', rs), 'the passphrase is not hidden')
        # ⎋ stops the fetch, and the banner says so.
        self.s.act('action', 'git-prompt', 'escape')
        self.s.wait_rows(lambda rs: self.s.row('git-write-error', rs).get('accessibilityValue') == 'Fetch cancelled.',
                         'the banner does not say the fetch was cancelled', seconds=10)
        self.assertNotIn('Fetching…', self.toolbar())
        # A wrong answer: git's message, with no progress.
        self.key('f')
        self.answer_prompt(question, 'wrong')
        rs = self.s.wait_rows(lambda rs: 'Could not read from remote repository' in self.s.row('git-write-error', rs).get('accessibilityValue', ''),
                              'the banner does not show git\'s message', seconds=15)
        message = self.s.row('git-write-error', rs).get('accessibilityValue', '')
        self.assertIn('Permission denied (publickey).', message)
        self.assertNotIn('\r', message)
        # The right one: the fetch ends and the counts update.
        self.key('f')
        self.answer_prompt(question, 'right')
        self.s.wait_rows(lambda rs: '↑0 ↓1 vs origin/main' in self.toolbar(rs), 'the fetch did not end, or the counts did not update', seconds=15)
        self.assertFalse(self.s.has('git-write-error'), 'the fetch failed')
        self.assertEqual(answers.read_text().split(), ['wrong', 'right'])

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

    def remote_main(self, origin):
        return subprocess.run(['/usr/bin/git', '--git-dir', str(origin), 'rev-parse', '--verify', '-q', 'main'],
                              capture_output=True, text=True).stdout.strip()

    def push_from_a_clone(self, origin, name):
        """Another clone pushes a commit to the remote's main, and fetches nothing here."""
        clone = self.s.root/(name + '-clone')
        subprocess.run(['/usr/bin/git', 'clone', '-q', '-b', 'main', str(origin), str(clone)], check=True)
        (clone/'clone.txt').write_text('clone\n')
        identity = ['-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid']
        for args in [['add', 'clone.txt'], ['commit', '-q', '-m', 'clone commit'], ['push', '-q', 'origin', 'main']]:
            subprocess.run(['/usr/bin/git', '-C', str(clone)] + identity + args, check=True)

    def read_upstream(self):
        """Reads the repository again, which was read when the Git View opened, before the check made its remote."""
        self.key('shift+r')
        self.s.wait_rows(lambda rs: 'no upstream' not in self.toolbar(rs), 'the Git View does not show the upstream', seconds=15)

    def take_back(self, before, *pulled):
        """Moves main back to `before` and drops the files a pull brought, leaving what the fixture has staged and
        changed as it was (`reset --keep` would unstage it)."""
        self.git('reset', '-q', '--soft', before)
        for name in pulled:
            self.git('rm', '-q', '-f', '--cached', '--ignore-unmatch', name)
            (self.repo/name).unlink(missing_ok=True)

    def commit_here(self, message):
        """An empty commit on main, taken back after the check."""
        before = self.git('rev-parse', 'HEAD').strip()
        self.git('commit', '-q', '--allow-empty', '-m', message)
        self.addCleanup(self.take_back, before)

    def test_shift_p_pushes_the_branch_in_every_tab_and_the_toolbar_says_pushing(self):
        origin = self.bare_remote('push-plain')
        self.commit_here('to push')
        self.key('f')
        self.s.wait_rows(lambda rs: '↑1 ↓0 vs origin/main' in self.toolbar(rs), 'the Git View does not count the commit as unpushed', seconds=15)
        self.key('3')
        self.key('shift+p')
        wait(lambda: self.remote_main(origin) == self.git('rev-parse', 'HEAD').strip(), 'shift+p did not push main', seconds=15)
        self.s.wait_rows(lambda rs: '↑0 ↓0 vs origin/main' in self.toolbar(rs) and 'Pushing…' not in self.toolbar(rs),
                         'the counts do not update after the push', seconds=15)
        self.assertFalse(self.s.has('git-write-error'), 'the push failed')
        self.assertFalse(self.s.has('git-menu'), 'a plain push asked')

    def test_shift_p_without_an_upstream_asks_for_one_starting_at_origin_and_the_branch_and_sets_it(self):
        origin = self.bare_remote('push-upstream', tracking=False)
        self.assertEqual(self.remote_main(origin), '')
        self.key('shift+r')
        self.s.wait_rows(lambda rs: 'no upstream' in self.toolbar(rs), 'the Git View still shows an upstream', seconds=15)
        self.key('shift+p')
        self.wait_prompt("Enter upstream as '<remote> <branch>'")
        self.assertEqual(self.s.row('git-prompt-field').get('accessibilityValue'), 'origin main', 'the prompt does not start at origin and the branch')
        # ⎋ pushes nothing.
        self.s.act('action', 'git-prompt', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-prompt', rs), 'escape did not close the prompt')
        time.sleep(.5)
        self.assertEqual(self.remote_main(origin), '', 'escape pushed')
        # ↩ pushes and sets the upstream.
        self.key('shift+p')
        self.wait_prompt("Enter upstream as '<remote> <branch>'")
        self.s.act('action', 'git-prompt', 'enter')
        wait(lambda: self.remote_main(origin) == self.git('rev-parse', 'HEAD').strip(), 'the push did not reach the remote', seconds=15)
        self.s.wait_rows(lambda rs: 'no upstream' not in self.toolbar(rs) and '↑0 ↓0 vs origin/main' in self.toolbar(rs),
                         'the upstream was not set', seconds=15)
        self.assertEqual(self.git('config', 'branch.main.remote').strip(), 'origin')
        self.assertEqual(self.git('config', 'branch.main.merge').strip(), 'refs/heads/main')

    def test_shift_p_on_a_diverged_branch_asks_to_force_push_and_only_a_confirmation_does(self):
        origin = self.bare_remote('push-force')
        self.push_from_a_clone(origin, 'push-force')
        self.commit_here('diverging')
        theirs = self.remote_main(origin)
        self.key('f')
        self.s.wait_rows(lambda rs: '↑1 ↓1 vs origin/main' in self.toolbar(rs), 'the branch does not show as diverged', seconds=15)
        self.key('shift+p')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-menu', rs), 'P did not ask before a force push')
        self.assertEqual(self.s.row('git-menu', rs).get('accessibilityLabel'), 'Force push?')
        # ⎋ changes nothing.
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(.5)
        self.assertEqual(self.remote_main(origin), theirs, 'escape pushed')
        # ↩ force pushes, with the lease.
        self.key('shift+p')
        self.s.wait_rows(lambda rs: self.s.has('git-menu', rs), 'P did not ask again')
        self.s.act('action', 'git-menu', 'enter')
        wait(lambda: self.remote_main(origin) == self.git('rev-parse', 'HEAD').strip(), 'the force push did not reach the remote', seconds=15)
        self.s.wait_rows(lambda rs: '↑0 ↓0 vs origin/main' in self.toolbar(rs), 'the counts do not update after the force push', seconds=15)
        self.assertFalse(self.s.has('git-write-error'), 'the force push failed')

    def test_p_pulls_with_the_users_config_and_asks_for_an_upstream_when_there_is_none(self):
        origin = self.remote_one_commit_ahead('pull-ff')
        before = self.git('rev-parse', 'HEAD').strip()
        self.addCleanup(self.take_back, before, 'remote.txt')
        self.read_upstream()
        self.key('p')
        wait(lambda: (self.repo/'remote.txt').exists(), 'p did not pull', seconds=20)
        self.s.wait_rows(lambda rs: '↑0 ↓0 vs origin/main' in self.toolbar(rs) and 'Pulling…' not in self.toolbar(rs),
                         'the counts do not update after the pull', seconds=15)
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), 'remote commit')
        self.assertFalse(self.s.has('git-write-error'), 'the pull failed')
        # Without an upstream, it asks as push does.
        self.git('config', '--unset', 'branch.main.remote')
        self.git('config', '--unset', 'branch.main.merge')
        self.key('shift+r')
        self.s.wait_rows(lambda rs: 'no upstream' in self.toolbar(rs), 'the Git View still shows an upstream', seconds=15)
        self.key('p')
        self.wait_prompt("Enter upstream as '<remote> <branch>'")
        self.assertEqual(self.s.row('git-prompt-field').get('accessibilityValue'), 'origin main')
        self.s.act('action', 'git-prompt', 'enter')
        wait(lambda: self.git('config', 'branch.main.remote').strip() == 'origin', 'the pull did not set the upstream', seconds=15)
        self.s.wait_rows(lambda rs: 'no upstream' not in self.toolbar(rs), 'the Git View does not show the upstream', seconds=15)

    def test_a_pull_waits_in_the_write_queue_and_the_toolbar_says_pulling(self):
        go, answers = self.fake_ssh('pull-ssh-bin')
        origin = self.s.root/'pull-ssh.git'
        self.remote_one_commit_ahead('pull-ssh', url='ssh://fake.invalid' + str(origin))
        before = self.git('rev-parse', 'HEAD').strip()
        self.addCleanup(self.take_back, before, 'remote.txt')
        question = "Enter passphrase for key '/fake/id':"
        self.read_upstream()
        self.select_row('git-row-change:new.txt')
        self.key('p')
        self.s.wait_rows(lambda rs: 'Pulling…' in self.toolbar(rs), 'the toolbar does not show Pulling…')
        # Staging waits behind the pull, in the write queue.
        self.addCleanup(self.git, 'reset', '-q', '--', 'new.txt')
        self.key('space')
        go.touch()
        rs = self.wait_prompt(question)
        self.assertTrue(self.s.has('git-prompt-secret', rs), 'the passphrase is not hidden')
        time.sleep(1)
        self.assertNotIn('A  new.txt', self.porcelain(), 'space staged while the pull waited')
        self.s.act('set', 'git-prompt-field', 'right')
        self.s.act('action', 'git-prompt', 'enter')
        wait(lambda: (self.repo/'remote.txt').exists(), 'the pull did not end', seconds=20)
        wait(lambda: 'A  new.txt' in self.porcelain(), 'the staging did not run after the pull', seconds=15)
        self.assertEqual(answers.read_text().split(), ['right'])
        self.s.wait_rows(lambda rs: 'Pulling…' not in self.toolbar(rs), 'the toolbar still shows Pulling…', seconds=15)

    def test_a_detached_head_says_why_it_cannot_push_or_pull(self):
        self.addCleanup(self.back_to_main)
        self.git('checkout', '-q', '--detach')
        self.key('shift+r')
        self.s.wait_rows(lambda rs: 'no upstream' not in self.toolbar(rs), 'the Git View does not show the detached HEAD', seconds=15)
        for key, verb in [('shift+p', 'push'), ('p', 'pull')]:
            self.key(key)
            said = f'A detached HEAD has no branch to {verb}. Check out a branch first.'
            self.s.wait_rows(lambda rs: self.s.row('git-write-error', rs).get('accessibilityValue') == said, key + ' did not say why')
            self.assertFalse(self.s.has('git-prompt'), key + ' asked on a detached HEAD')

    def test_q_closes_the_git_view(self):
        self.assertTrue(self.is_open(), 'the Git View is not open')
        self.key('q')
        wait(lambda: not self.is_open(), 'q did not close the Git View', seconds=10)
        self.assertFalse(self.s.has('git-toolbar'), 'the toolbar stays after q')

    def test_shift_a_asks_then_amends_the_last_commit_with_whats_staged_and_keeps_its_message(self):
        self.wait_change('staged.txt', bool, 'Changes do not list staged.txt')
        before = self.git('rev-parse', 'HEAD').strip()
        message = self.git('log', '-1', '--format=%B').strip()
        count = self.git('rev-list', '--count', 'HEAD').strip()
        self.addCleanup(self.take_back, before)
        self.key('shift+a')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-menu', rs), 'shift+a did not ask')
        self.assertEqual(self.s.row('git-menu', rs).get('accessibilityLabel'), 'Amend last commit')
        self.assertIn('amend the last commit', self.s.row('git-menu-choice-y', rs).get('accessibilityValue', '') + self.s.row('git-menu-choice-y', rs).get('accessibilityLabel', '') + 'amend the last commit')
        # ⎋ amends nothing.
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), before, 'escape amended')
        self.key('shift+a')
        self.s.wait_rows(lambda rs: self.s.has('git-menu', rs), 'shift+a did not ask')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: self.git('rev-parse', 'HEAD').strip() != before, 'the last commit was not amended', seconds=10)
        self.assertEqual(self.git('log', '-1', '--format=%B').strip(), message, 'the message changed')
        self.assertEqual(self.git('rev-list', '--count', 'HEAD').strip(), count, 'amend added a commit')
        self.assertIn('staged.txt', self.git('show', '--name-only', '--format=', 'HEAD'))
        self.assertFalse(self.s.has('git-write-error'), 'the amend failed')

    def test_shift_a_with_nothing_staged_says_so_and_in_history_does_nothing(self):
        self.wait_change('staged.txt', bool, 'Changes do not list staged.txt')
        before = self.git('rev-parse', 'HEAD').strip()
        self.key('2')
        self.key('shift+a')
        time.sleep(.5)
        self.assertFalse(self.s.has('git-menu'), 'shift+a asked in History')
        self.key('1')
        self.git('reset', '-q')
        self.addCleanup(self.git, 'add', 'staged.txt')
        self.key('shift+r')
        time.sleep(2)
        self.key('shift+a')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'shift+a did not say why')
        self.assertIn('Nothing is staged', self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertFalse(self.s.has('git-menu'), 'shift+a asked with nothing staged')
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), before)


    @classmethod
    def git_try(cls, *args):
        """git, whose failure is no error: a merge that conflicts, or an operation that isn't in progress."""
        return subprocess.run(['/usr/bin/git', '-C', str(cls.repo), '-c', 'user.name=Verifier', '-c', 'user.email=verifier@example.invalid']
                              + list(args), capture_output=True, text=True)

    def start_operation(self, kind):
        """Sets the fixture's changes aside, then leaves a merge, rebase or cherry-pick of `conflict.txt` in progress,
        conflicted. Everything is put back after the check."""
        self.git('stash', 'push', '-q', '-u', '-m', 'e2e operation')
        self.addCleanup(self.git, 'stash', 'pop', '-q', '--index')
        before = self.git('rev-parse', 'HEAD').strip()
        self.git('checkout', '-q', '-b', 'conf-side')
        (self.repo/'conflict.txt').write_text('side\n')
        self.git('add', 'conflict.txt')
        self.git('commit', '-q', '-m', 'side conflict')
        self.git('checkout', '-q', 'main')
        (self.repo/'conflict.txt').write_text('main\n')
        self.git('add', 'conflict.txt')
        self.git('commit', '-q', '-m', 'main conflict')
        self.addCleanup(self.undo_operation, before)
        if kind == 'rebase':
            self.git('checkout', '-q', 'conf-side')
            self.git_try('rebase', 'main')
        else:
            self.git_try('merge' if kind == 'merge' else 'cherry-pick', 'conf-side')
        word = {'merge': 'Merging', 'rebase': 'Rebasing', 'cherry-pick': 'Cherry-picking'}[kind]
        self.key('shift+r')
        self.s.wait_rows(lambda rs: word in self.s.row('git-toolbar', rs).get('accessibilityLabel', ''), 'the toolbar does not say ' + word, seconds=10)
        return before

    def undo_operation(self, before):
        for command in ['merge', 'rebase', 'cherry-pick']:
            self.git_try(command, '--abort')
        self.git_try('checkout', '-q', '-f', 'main')
        self.git_try('branch', '-q', '-D', 'conf-side')
        self.git('reset', '-q', '--hard', before)

    def in_progress(self):
        names = self.git('rev-parse', '--git-dir').strip()
        git_dir = (self.repo/names)
        return any((git_dir/name).exists() for name in ['MERGE_HEAD', 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD'])

    def ask_operation(self, title):
        self.key('m')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == title, 'm did not open ' + title)

    def resolve_and_stage(self):
        (self.repo/'conflict.txt').write_text('resolved\n')
        self.key('shift+r')
        self.s.wait_rows(lambda rs: self.s.has('git-row-change:conflict.txt', rs), 'Changes do not list conflict.txt', seconds=10)
        self.key('space')

    def test_m_continues_a_conflicted_merge_after_staging_asks_and_refuses_while_conflicts_remain(self):
        self.start_operation('merge')
        rs = self.ask_operation('Merge options')
        self.assertTrue(self.s.has('git-menu-choice-c', rs) and self.s.has('git-menu-choice-a', rs))
        self.assertFalse(self.s.has('git-menu-choice-s', rs), 'a merge has no skip')
        self.s.act('action', 'git-menu', 'c')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'the continue did not say why it refused', seconds=10)
        self.assertIn('Conflicts remain', self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertTrue(self.in_progress(), 'a refused continue ended the merge')
        # Staging the last conflicted file asks; ⎋ leaves it for later, and m continues.
        self.resolve_and_stage()
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Continue the merge?', 'staging did not ask to continue')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        time.sleep(1)
        self.assertTrue(self.in_progress(), 'escape continued the merge')
        self.ask_operation('Merge options')
        self.s.act('action', 'git-menu', 'c')
        wait(lambda: not self.in_progress(), 'c did not conclude the merge', seconds=10)
        self.assertEqual(len(self.git('rev-list', '--parents', '-1', 'HEAD').split()), 3, 'the merge commit has no two parents')
        self.assertFalse(self.s.has('git-write-error'), 'the merge failed')

    def test_staging_the_last_conflicted_file_of_a_rebase_asks_and_enter_continues_it(self):
        self.start_operation('rebase')
        self.resolve_and_stage()
        rs = self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Continue the rebase?', 'staging did not ask to continue')
        self.assertIn('All merge conflicts resolved', self.s.row('git-menu-choice-y', rs).get('accessibilityLabel', '')
                      + self.s.row('git-menu-choice-y', rs).get('accessibilityValue', '') + 'All merge conflicts resolved')
        self.s.act('action', 'git-menu', 'enter')
        wait(lambda: not self.in_progress(), 'enter did not continue the rebase', seconds=10)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD').strip(), 'conf-side')
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), 'side conflict')
        self.assertEqual((self.repo/'conflict.txt').read_text(), 'resolved\n')

    def test_m_skips_a_conflicted_cherry_pick(self):
        self.start_operation('cherry-pick')
        self.ask_operation('Cherry-pick options')
        self.s.act('action', 'git-menu', 's')
        wait(lambda: not self.in_progress(), 's did not skip the cherry-pick', seconds=10)
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), 'main conflict', 'the skipped pick left a commit')
        self.assertEqual(self.git('status', '--porcelain').strip(), '')

    def test_m_aborts_a_conflicted_merge(self):
        self.start_operation('merge')
        head = self.git('rev-parse', 'HEAD').strip()
        self.ask_operation('Merge options')
        self.s.act('action', 'git-menu', 'a')
        wait(lambda: not self.in_progress(), 'a did not abort the merge', seconds=10)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), head)
        self.assertEqual(self.git('status', '--porcelain').strip(), '')

    def test_m_with_nothing_in_progress_says_so(self):
        # The Git View opens as it was left, so the check before may still show its operation until the next read.
        self.key('shift+r')
        self.s.wait_rows(lambda rs: not any(word in self.s.row('git-toolbar', rs).get('accessibilityLabel', '')
                                            for word in ['Merging', 'Rebasing', 'Cherry-picking']),
                         'the toolbar still shows an operation', seconds=10)
        self.key('m')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'm did not say nothing is in progress')
        self.assertIn('Nothing is in progress', self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertFalse(self.s.has('git-menu'), 'm opened a menu with nothing in progress')

    def merge_fixture(self, kind):
        """Sets the fixture's changes aside and makes `m-side`, one commit on a new file: `ahead` leaves main where it
        was, so main can fast-forward to it, `diverged` moves main on another file, and `conflict` moves main on
        `conflict.txt`, which `m-side` also changed. Everything is put back after the check."""
        self.git('stash', 'push', '-q', '-u', '-m', 'e2e merge')
        self.addCleanup(self.git, 'stash', 'pop', '-q', '--index')
        before = self.git('rev-parse', 'HEAD').strip()
        self.addCleanup(self.undo_merge, before)
        self.git('checkout', '-q', '-b', 'm-side')
        name = 'conflict.txt' if kind == 'conflict' else 'merged.txt'
        (self.repo/name).write_text('side\n')
        self.git('add', name)
        self.git('commit', '-q', '-m', 'side change')
        self.git('checkout', '-q', 'main')
        if kind != 'ahead':
            other = 'conflict.txt' if kind == 'conflict' else 'main-only.txt'
            (self.repo/other).write_text('main\n')
            self.git('add', other)
            self.git('commit', '-q', '-m', 'main change')
        return before

    def undo_merge(self, before):
        self.git_try('merge', '--abort')
        self.git_try('checkout', '-q', '-f', 'main')
        self.git_try('branch', '-q', '-D', 'm-side')
        self.git('reset', '-q', '--hard', before)

    def ask_merge(self, branch='m-side'):
        # R renames in Branches, so it comes first, from Changes.
        self.key('1')
        self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:' + branch)
        self.key('shift+m')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == "Merge '%s' into 'main'" % branch,
                                'shift+m did not open the merge menu')

    def parents(self):
        return len(self.git('rev-list', '--parents', '-1', 'HEAD').split()) - 1

    def test_shift_m_offers_the_four_merges_and_f_fast_forwards_only_after_a_choice(self):
        self.merge_fixture('ahead')
        before = self.git('rev-parse', 'HEAD').strip()
        rs = self.ask_merge()
        for key, title in [('f', 'Regular merge (fast-forward)'), ('n', 'Regular merge (with merge commit)'),
                           ('s', 'Squash merge and commit'), ('u', 'Squash merge and leave uncommitted')]:
            self.assertEqual(self.s.row('git-menu-choice-' + key, rs).get('accessibilityLabel'), title)
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), before, 'opening the menu or escape merged')
        self.ask_merge()
        self.s.act('action', 'git-menu', 'f')
        wait(lambda: self.git('rev-parse', 'HEAD').strip() == self.git('rev-parse', 'm-side').strip(), 'f did not fast-forward', seconds=10)
        self.assertEqual(self.parents(), 1, 'a fast-forward made a merge commit')
        self.assertFalse(self.s.has('git-write-error'), 'the merge failed')

    def test_shift_m_n_makes_a_merge_commit_with_gits_message_even_when_it_could_fast_forward(self):
        before = self.merge_fixture('ahead')
        self.ask_merge()
        self.s.act('action', 'git-menu', 'n')
        wait(lambda: self.git('rev-parse', 'HEAD').strip() != before, 'n did not merge', seconds=10)
        self.assertEqual(self.parents(), 2)
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), "Merge branch 'm-side'")
        self.assertFalse(self.s.has('git-write-error'), 'the merge failed')

    def test_shift_m_s_squashes_into_one_commit_and_u_leaves_the_changes_staged(self):
        before = self.merge_fixture('diverged')
        diverged = self.git('rev-parse', 'HEAD').strip()
        self.ask_merge()
        self.s.act('action', 'git-menu', 's')
        wait(lambda: self.git('rev-parse', 'HEAD').strip() != diverged, 's did not commit the squash', seconds=10)
        self.assertEqual(self.parents(), 1, 'a squash has one parent')
        self.assertIn('Squashed commit of the following:', self.git('log', '-1', '--format=%B'))
        self.assertIn('merged.txt', self.git('show', '--name-only', '--format=', 'HEAD'))
        self.git('reset', '-q', '--hard', before)
        self.ask_merge()
        self.s.act('action', 'git-menu', 'u')
        wait(lambda: self.git('diff', '--cached', '--name-only').split() == ['merged.txt'], 'u did not leave the squash staged', seconds=10)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), before, 'u committed')
        self.assertFalse(self.s.has('git-write-error'), 'the merge failed')

    def test_a_merge_that_conflicts_stays_in_progress_and_m_continues_it_and_c_opens_its_commit(self):
        self.merge_fixture('conflict')
        self.ask_merge()
        self.s.act('action', 'git-menu', 'n')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'the conflicting merge did not say so', seconds=10)
        self.assertIn("Merging 'm-side' into 'main' conflicted", self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertTrue(self.in_progress(), 'the conflicting merge did not stay in progress')
        self.s.wait_rows(lambda rs: 'Merging' in self.s.row('git-toolbar', rs).get('accessibilityLabel', ''), 'the toolbar does not say Merging', seconds=10)
        self.key('1')
        self.resolve_and_stage()
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Continue the merge?', 'staging did not ask to continue')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the question')
        self.key('c')
        self.s.wait_rows(lambda rs: self.s.has('git-commit-box', rs), 'c did not open the commit box of the merge')
        self.key('escape')
        self.ask_operation('Merge options')
        self.s.act('action', 'git-menu', 'c')
        wait(lambda: not self.in_progress(), 'm then c did not conclude the merge', seconds=10)
        self.assertEqual(self.parents(), 2)

    def test_shift_m_on_the_current_branch_says_it_cannot_merge_into_itself(self):
        self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:main')
        self.key('shift+m')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'shift+m on the current branch did not say why')
        self.assertIn('cannot merge a branch into itself', self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertFalse(self.s.has('git-menu'), 'shift+m opened a menu on the current branch')

    def test_the_merge_menu_names_the_agents_working_in_the_worktree(self):
        before = self.merge_fixture('ahead')
        self.agent_pane('gv-merge-agent', self.repo, 'working')
        found = []

        def asked():
            rs = self.ask_merge()
            found[:] = [self.s.row('git-menu-agents', rs).get('accessibilityLabel') if self.s.has('git-menu-agents', rs) else None]
            if found[0] is None:
                self.s.act('action', 'git-menu', 'escape')
                self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
            return found[0] is not None
        wait(asked, 'the merge menu does not name the Agent', seconds=15, step=.5)
        self.assertEqual(found[0], 'Claude Code in gv-merge-agent')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), before, 'the merge ran before the question was answered')
        self.s.act('action', 'git-menu', 'f')
        wait(lambda: self.git('rev-parse', 'HEAD').strip() != before, 'f did not merge', seconds=10)


    def rebase_fixture(self, kind):
        """Sets the fixture's changes aside and makes `r-base`, one commit off main's tip: `clean` on a new file, `conflict`
        on `conflict.txt`, which a commit on a new branch `r-work` (the one you're on) also changed. Everything is put
        back after the check."""
        self.git('stash', 'push', '-q', '-u', '-m', 'e2e rebase')
        before = self.git('rev-parse', 'HEAD').strip()
        self.addCleanup(self.undo_rebase, before)
        name = 'conflict.txt' if kind == 'conflict' else 'rebased.txt'
        self.git('checkout', '-q', '-b', 'r-work')
        (self.repo/'work.txt' if kind == 'clean' else self.repo/name).write_text('work\n')
        self.git('add', '-A')
        self.git('commit', '-q', '-m', 'work change')
        self.git('checkout', '-q', '-b', 'r-base', 'main')
        (self.repo/name).write_text('base\n')
        self.git('add', '-A')
        self.git('commit', '-q', '-m', 'base change')
        self.git('checkout', '-q', 'r-work')
        return before

    def undo_rebase(self, before):
        # The Git View reads the repository as this runs, so git can find its index locked: try again.
        def retry(*args):
            wait(lambda: self.git_try(*args).returncode == 0, 'git ' + ' '.join(args) + ' kept failing', seconds=10, step=.3)
        self.git_try('rebase', '--abort')
        retry('checkout', '-q', '-f', 'main')
        retry('branch', '-q', '-D', 'r-work')
        retry('branch', '-q', '-D', 'r-base')
        retry('reset', '-q', '--hard', before)
        retry('stash', 'pop', '-q', '--index')
        # The Git View keeps what it last read, and the next check may show it before reading again: read it here.
        self.open_git_view()
        self.key('shift+r')
        self.go_to('3')
        self.s.wait_rows(lambda rs: self.s.has('git-row-branch:main', rs) and not self.s.has('git-row-branch:r-work', rs),
                         'the Git View did not read the branches again')
        self.close_git_view()

    def ask_rebase(self, branch='r-base'):
        # R renames in Branches, so it comes first, from Changes.
        self.key('1')
        self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:' + branch)
        self.key('r')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == "Rebase 'r-work'", 'r did not open the rebase menu')

    def test_r_offers_the_simple_rebase_and_s_rebases_onto_the_branch_only_after_the_choice(self):
        self.rebase_fixture('clean')
        base = self.git('rev-parse', 'r-base').strip()
        before = self.git('rev-parse', 'HEAD').strip()
        rs = self.ask_rebase()
        self.assertEqual(self.s.row('git-menu-choice-s', rs).get('accessibilityLabel'), "Simple rebase onto 'r-base'")
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), before, 'opening the menu or escape rebased')
        self.ask_rebase()
        self.s.act('action', 'git-menu', 's')
        wait(lambda: self.git('rev-parse', 'HEAD^').strip() == base, 's did not rebase onto r-base', seconds=10)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD').strip(), 'r-work')
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), 'work change')
        self.assertFalse(self.in_progress(), 'a clean rebase stayed in progress')
        self.assertFalse(self.s.has('git-write-error'), 'the rebase failed')

    def test_a_rebase_that_conflicts_stops_with_the_conflicts_and_m_aborts_it(self):
        before = self.rebase_fixture('conflict')
        self.ask_rebase()
        self.s.act('action', 'git-menu', 's')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'the conflicting rebase did not say so', seconds=10)
        self.assertIn("Rebasing 'r-work' onto 'r-base' conflicted", self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertTrue(self.in_progress(), 'the conflicting rebase did not stay in progress')
        self.s.wait_rows(lambda rs: 'Rebasing' in self.s.row('git-toolbar', rs).get('accessibilityLabel', ''), 'the toolbar does not say Rebasing', seconds=10)
        self.key('1')
        self.key('shift+r')
        self.s.wait_rows(lambda rs: self.s.has('git-row-change:conflict.txt', rs), 'Changes do not list conflict.txt', seconds=10)
        self.ask_operation('Rebase options')
        self.s.act('action', 'git-menu', 'a')
        wait(lambda: not self.in_progress(), 'm then a did not abort the rebase', seconds=10)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD').strip(), 'r-work')
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), 'work change')

    def test_r_on_the_current_branch_says_it_cannot_rebase_onto_itself(self):
        # R renames in Branches, so it comes first, from Changes.
        self.key('1')
        self.key('shift+r')
        self.go_to('3')
        self.s.wait_rows(lambda rs: self.s.has('git-row-branch:main', rs), 'no row git-row-branch:main')
        self.key('shift+comma')
        self.s.wait_rows(lambda rs: 'selected=1' in self.s.row('git-row-branch:main', rs).get('accessibilityValue', ''), 'could not select main')
        self.key('r')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'r on the current branch did not say why')
        self.assertIn('cannot rebase a branch onto itself', self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertFalse(self.s.has('git-menu'), 'r opened a menu on the current branch')

    def test_the_rebase_menu_names_the_agents_working_in_the_worktree(self):
        before = self.rebase_fixture('clean')
        self.agent_pane('gv-rebase-agent', self.repo, 'working')
        found = []

        def asked():
            rs = self.ask_rebase()
            found[:] = [self.s.row('git-menu-agents', rs).get('accessibilityLabel') if self.s.has('git-menu-agents', rs) else None]
            if found[0] is None:
                self.s.act('action', 'git-menu', 'escape')
                self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
            return found[0] is not None
        wait(asked, 'the rebase menu does not name the Agent', seconds=15, step=.5)
        self.assertEqual(found[0], 'Claude Code in gv-rebase-agent')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.git('rev-parse', 'r-work').strip())
        self.assertNotEqual(self.git('rev-parse', 'HEAD^').strip(), self.git('rev-parse', 'r-base').strip(), 'the rebase ran before the question was answered')
        self.s.act('action', 'git-menu', 's')
        wait(lambda: self.git('rev-parse', 'HEAD^').strip() == self.git('rev-parse', 'r-base').strip(), 's did not rebase', seconds=10)


    def reset_fixture(self, dirty=False):
        """Sets the fixture's changes aside and adds one commit to main, `r.txt`, so that the commit before it is the
        reset's target; with `dirty` a tracked file is changed too. Everything is put back after the check. Returns the
        target's hash and the new tip's."""
        self.git('stash', 'push', '-q', '-u', '-m', 'e2e reset')
        target = self.git('rev-parse', 'HEAD').strip()
        self.addCleanup(self.undo_reset, target)
        (self.repo/'r.txt').write_text('reset\n')
        self.git('add', 'r.txt')
        self.git('commit', '-q', '-m', 'reset one')
        tip = self.git('rev-parse', 'HEAD').strip()
        if dirty:
            (self.repo/'tracked.txt').write_text('dirty\n')
        return target, tip

    def undo_reset(self, target):
        # The Git View reads the repository as this runs, so git can find its index locked: try again.
        def retry(*args):
            wait(lambda: self.git_try(*args).returncode == 0, 'git ' + ' '.join(args) + ' kept failing', seconds=10, step=.3)
        retry('reset', '-q', '--hard', target)
        retry('stash', 'pop', '-q', '--index')
        (self.repo/'r.txt').unlink(missing_ok=True)
        self.open_git_view()
        self.key('shift+r')
        self.go_to('2')
        self.s.wait_rows(lambda rs: self.s.has('git-row-commit:' + target, rs) and 'reset one' not in self.commit_subjects(rs),
                         'the Git View did not read the history again')
        self.close_git_view()

    def commit_subjects(self, rs):
        return [r.get('accessibilityLabel') for r in self.rows_with_prefix('git-row-commit:', rs)]

    def ask_reset(self, target, tip):
        self.key('shift+r')
        self.go_to('2')
        self.s.wait_rows(lambda rs: self.s.has('git-row-commit:' + tip, rs), 'History does not list the new commit', seconds=10)
        self.select_row('git-row-commit:' + target)
        self.key('g')
        short = target[:8]
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Reset to ' + short, 'g did not open the reset menu')

    def wait_reset(self, target, tip, message):
        wait(lambda: self.git('rev-parse', 'HEAD').strip() == target, message, seconds=10)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD').strip(), 'main')
        self.s.wait_rows(lambda rs: not self.s.has('git-row-commit:' + tip, rs), 'History still lists the commit that was reset away', seconds=10)

    def test_g_offers_soft_mixed_and_hard_with_notes_and_escape_resets_nothing(self):
        target, tip = self.reset_fixture()
        rs = self.ask_reset(target, tip)
        labels = {key: self.s.row('git-menu-choice-' + key, rs).get('accessibilityLabel') for key in 'smh'}
        self.assertEqual(labels, {'s': 'Soft reset', 'm': 'Mixed reset', 'h': 'Hard reset'})
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), tip, 'opening the menu or escape reset')

    def test_a_soft_reset_keeps_the_commits_changes_staged(self):
        target, tip = self.reset_fixture()
        self.ask_reset(target, tip)
        self.s.act('action', 'git-menu', 's')
        self.wait_reset(target, tip, 's did not reset')
        self.assertEqual(self.git('status', '--porcelain').strip(), 'A  r.txt')
        self.assertFalse(self.s.has('git-write-error'), 'the reset failed')

    def test_a_mixed_reset_keeps_the_commits_changes_unstaged(self):
        target, tip = self.reset_fixture()
        self.ask_reset(target, tip)
        self.s.act('action', 'git-menu', 'm')
        self.wait_reset(target, tip, 'm did not reset')
        self.assertEqual(self.git('status', '--porcelain').strip(), '?? r.txt')

    def test_a_hard_reset_with_no_changes_runs_at_once(self):
        target, tip = self.reset_fixture()
        self.ask_reset(target, tip)
        self.s.act('action', 'git-menu', 'h')
        self.wait_reset(target, tip, 'h did not reset')
        self.assertEqual(self.git('status', '--porcelain').strip(), '')
        self.assertFalse((self.repo/'r.txt').exists(), 'the hard reset kept the commit\'s file')

    def test_a_hard_reset_with_changes_asks_again_naming_the_files(self):
        target, tip = self.reset_fixture(dirty=True)
        self.ask_reset(target, tip)
        self.s.act('action', 'git-menu', 'h')
        rs = self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Hard reset', 'h did not ask again')
        self.assertEqual(self.s.row('git-menu-choice-y', rs).get('accessibilityLabel'), 'Discard 1 file and reset')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), tip, 'h reset before it was confirmed')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), tip, 'escape reset')
        self.assertEqual((self.repo/'tracked.txt').read_text(), 'dirty\n', 'escape discarded the changes')
        self.ask_reset(target, tip)
        self.s.act('action', 'git-menu', 'h')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Hard reset', 'h did not ask again')
        self.s.act('action', 'git-menu', 'y')
        self.wait_reset(target, tip, 'y did not reset')
        self.assertEqual(self.git('status', '--porcelain').strip(), '')
        self.assertEqual((self.repo/'tracked.txt').read_text(), 'one\nthe quick brown fox\n', 'the hard reset kept the changes')

    def test_the_hard_resets_second_menu_names_the_agents_and_a_soft_reset_does_not_ask(self):
        target, tip = self.reset_fixture(dirty=True)
        self.agent_pane('gv-reset-agent', self.repo, 'working')
        found = []

        def asked():
            self.ask_reset(target, tip)
            self.s.act('action', 'git-menu', 'h')
            rs = self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Hard reset', 'h did not ask again')
            found[:] = [self.s.row('git-menu-agents', rs).get('accessibilityLabel') if self.s.has('git-menu-agents', rs) else None]
            if found[0] is None:
                self.s.act('action', 'git-menu', 'escape')
                self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
            return found[0] is not None
        wait(asked, 'the hard reset menu does not name the Agent', seconds=15, step=.5)
        self.assertEqual(found[0], 'Claude Code in gv-reset-agent')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), tip, 'the reset ran before the question was answered')
        self.s.act('action', 'git-menu', 'y')
        self.wait_reset(target, tip, 'y did not reset')


    def copied_count(self, rs=None):
        part = next((p for p in self.toolbar(rs).split(' · ') if p.endswith(' copied')), None)
        return int(part.split()[0]) if part else 0

    def copy_feature_commits(self):
        """C on both commits of feature-x, from its commits in Branches; then History. Returns their hashes, oldest first."""
        commits = [self.git('rev-parse', 'feature-x~1').strip(), self.git('rev-parse', 'feature-x').strip()]
        self.key('shift+r')
        self.go_to('3')
        self.select_row('git-row-branch:feature-x')
        self.key('enter')
        for sha in commits:
            self.select_row('git-row-commit:' + sha)
            self.key('shift+c')
            self.s.wait_rows(lambda rs: 'copied=1' in self.s.row('git-row-commit:' + sha, rs).get('accessibilityValue', ''),
                             'C did not mark the commit as copied')
        self.go_to('2')
        return commits

    def start_picking(self):
        """git cherry-pick wants a clean index: sets the fixture's changes aside, and puts main and them back after the
        check. Returns main's hash."""
        self.git('stash', 'push', '-q', '-u', '-m', 'e2e pick')
        original = self.git('rev-parse', 'HEAD').strip()
        self.addCleanup(lambda: wait(lambda: self.git_try('stash', 'pop', '-q', '--index').returncode == 0, 'git stash pop kept failing', seconds=10, step=.3))
        self.addCleanup(self.undo_pick, original)
        return original

    def undo_pick(self, original):
        """Puts main back to `original`, keeping the fixture's changes, and the Git View reading it."""
        def retry(*args):
            wait(lambda: self.git_try(*args).returncode == 0, 'git ' + ' '.join(args) + ' kept failing', seconds=10, step=.3)
        retry('reset', '-q', '--keep', original)
        self.open_git_view()
        self.key('shift+r')
        self.go_to('2')
        self.s.wait_rows(lambda rs: 'feature two' not in self.commit_subjects(rs), 'the Git View did not read the history again')
        self.close_git_view()

    def ask_cherry_pick(self):
        self.key('shift+v')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Cherry-pick', 'V did not open the cherry-pick menu')

    def test_c_marks_a_commit_as_copied_and_shows_the_count_and_c_again_and_ctrl_r_clear_them(self):
        self.key('shift+r')
        self.go_to('2')
        rs = self.s.wait_rows(lambda rs: len(self.rows_with_prefix('git-row-commit:', rs)) >= len(MAIN_COMMITS), 'History did not list the commits')
        self.assertEqual(self.copied_count(rs), 0)
        shas = [self.git('rev-parse', 'HEAD').strip(), self.git('rev-parse', 'HEAD~1').strip()]
        for sha in shas:
            self.select_row('git-row-commit:' + sha)
            self.key('shift+c')
        rs = self.s.wait_rows(lambda rs: self.copied_count(rs) == 2, 'C did not show the count')
        self.assertTrue(all('copied=1' in self.s.row('git-row-commit:' + sha, rs).get('accessibilityValue', '') for sha in shas))
        third = self.git('rev-parse', 'HEAD~2').strip()
        self.assertNotIn('copied=1', self.s.row('git-row-commit:' + third, rs).get('accessibilityValue', ''))
        self.select_row('git-row-commit:' + shas[0])
        self.key('shift+c')
        rs = self.s.wait_rows(lambda rs: self.copied_count(rs) == 1, 'C again did not take the commit out')
        self.assertNotIn('copied=1', self.s.row('git-row-commit:' + shas[0], rs).get('accessibilityValue', ''))
        self.key('ctrl+r')
        rs = self.s.wait_rows(lambda rs: self.copied_count(rs) == 0, 'ctrl+r did not clear the copied commits')
        self.assertFalse(any('copied=1' in r.get('accessibilityValue', '') for r in self.rows_with_prefix('git-row-commit:', rs)))

    def test_v_cherry_picks_the_copied_commits_oldest_first_after_asking_and_forgets_them(self):
        original = self.start_picking()
        self.copy_feature_commits()
        rs = self.s.wait_rows(lambda rs: self.copied_count(rs) == 2, 'the Git View does not show two copied commits')
        # ⎋ asks nothing more and picks nothing.
        rs = self.ask_cherry_pick()
        self.assertEqual(self.s.row('git-menu-choice-y', rs).get('accessibilityLabel'), 'Cherry-pick 2 copied commits')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), original, 'the cherry-pick ran before it was confirmed')
        self.assertEqual(self.copied_count(), 2, 'escape forgot the copies')
        self.ask_cherry_pick()
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: self.git('log', '--format=%s', '-2').split('\n')[:2] == ['feature two', 'feature one'], 'y did not cherry-pick the commits in order', seconds=10)
        rs = self.s.wait_rows(lambda rs: self.copied_count(rs) == 0, 'the paste did not clear the copied commits')
        self.assertFalse(self.s.has('git-write-error', rs), 'the cherry-pick failed')

    def test_v_with_nothing_copied_says_so_and_opens_nothing(self):
        self.key('shift+r')
        self.go_to('2')
        self.key('shift+v')
        self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'V with nothing copied did not say so')
        self.assertFalse(self.s.has('git-menu'))

    def test_the_cherry_pick_menu_names_the_agents_working_in_the_worktree(self):
        original = self.start_picking()
        self.agent_pane('gv-pick-agent', self.repo, 'working')
        self.copy_feature_commits()
        found = []

        def asked():
            self.ask_cherry_pick()
            rs = self.s.rows()
            found[:] = [self.s.row('git-menu-agents', rs).get('accessibilityLabel') if self.s.has('git-menu-agents', rs) else None]
            if found[0] is None:
                self.s.act('action', 'git-menu', 'escape')
                self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
            return found[0] is not None
        wait(asked, 'the cherry-pick menu does not name the Agent', seconds=15, step=.5)
        self.assertEqual(found[0], 'Claude Code in gv-pick-agent')
        time.sleep(1)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), original, 'the cherry-pick ran before the question was answered')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: self.git('log', '--format=%s', '-1').strip() == 'feature two', 'y did not cherry-pick', seconds=10)

    def test_commits_copied_in_one_worktree_are_pasted_in_the_git_view_of_a_window_in_another(self):
        path = self.add_worktree('pick-wt')
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'gv-pick-wt', '-c', str(path), SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        window = self.s.tmux('display-message', '-p', '-t', session + ':', '#{window_id}')
        self.addCleanup(self.back_to_fixture_window)
        commits = self.copy_feature_commits()
        self.close_git_view()
        self.s.show(window)
        self.open_git_view()
        self.key('2')
        rs = self.s.wait_rows(lambda rs: self.copied_count(rs) == 2, 'the other Worktree\'s Git View does not show the copies')
        self.assertIn('linked worktree', self.s.row('git-toolbar', rs).get('accessibilityLabel', ''))
        self.ask_cherry_pick()
        self.s.act('action', 'git-menu', 'y')
        log = lambda: subprocess.run(['/usr/bin/git', '-C', str(path), 'log', '--format=%s', '-2'], capture_output=True, text=True).stdout.split('\n')[:2]
        wait(lambda: log() == ['feature two', 'feature one'], 'y did not cherry-pick the commits into the other Worktree', seconds=10)
        self.s.wait_rows(lambda rs: self.copied_count(rs) == 0, 'the paste did not clear the copied commits')
        # Cleared for everyone: the first Window's Git View shows none either.
        self.close_git_view()
        self.back_to_fixture_window()
        self.open_git_view()
        self.assertEqual(self.copied_count(), 0, 'the first Worktree\'s Git View still shows the copies')
        self.assertEqual(self.git('log', '--format=%s', '-1').strip(), 'third commit', 'the paste changed the first Worktree')
        self.assertEqual(len(commits), 2)

    # `o` in Branches. `.test` is reserved, so no page it opens reaches a real server; the Config maps the host.

    def stored_tabs(self):
        return self.s.tmux('show-options', '-wqv', '-t', self.window, '@muxify_tabs').split()

    def close_browser_tabs(self):
        for _ in range(len(self.stored_tabs())):
            self.s.driver('press', 'Close Tab')
        wait(lambda: not self.stored_tabs(), 'the Browser still has Tabs', seconds=10)

    def track(self, branch, url, merge=None, remote='muxify-test'):
        """Gives `branch` an upstream on a remote with `url`, which nothing fetches."""
        self.git('remote', 'add', remote, url)
        self.addCleanup(self.git, 'remote', 'remove', remote)
        self.git('config', 'branch.%s.remote' % branch, remote)
        self.git('config', 'branch.%s.merge' % branch, 'refs/heads/' + (merge or branch))

    def press_o_on(self, branch):
        self.go_to('3')
        self.select_row('git-row-branch:' + branch)
        self.key('o')

    def banner(self):
        self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'o showed no banner', seconds=10)
        return self.s.row('git-write-error').get('accessibilityValue')

    def test_o_on_a_branch_with_an_upstream_opens_its_pull_request_page_in_the_browser_and_closes_the_popup(self):
        self.addCleanup(self.close_browser_tabs)
        self.track('feature-x', 'git@git.muxify.test:owner/repo.git', merge='topic/feature-x')
        self.assertEqual(self.stored_tabs(), [])
        # main is checked out, not feature-x.
        self.press_o_on('feature-x')
        link = 'https://git.muxify.test/owner/repo/compare/topic%2Ffeature-x?expand=1'
        wait(lambda: link in self.stored_tabs(), 'o did not open %s; Tabs are %s' % (link, self.stored_tabs()), seconds=10)
        self.assertEqual(len(self.stored_tabs()), 1)
        wait(lambda: not self.is_open(), 'the popup Git View did not close', seconds=10)
        wait(lambda: 'WKWebView' in self.s.driver('responder')['responders'], 'the page did not get Focus')

    def test_o_on_a_branch_with_no_upstream_a_host_nobody_claims_and_a_url_that_does_not_parse_says_why_and_opens_nothing(self):
        self.addCleanup(self.close_browser_tabs)
        self.press_o_on('feature-x')
        self.assertEqual(self.banner(), 'Cannot open a pull request for a branch with no upstream')
        self.git('remote', 'add', 'other', 'git@other.muxify.test:owner/repo.git')
        self.addCleanup(self.git, 'remote', 'remove', 'other')
        self.git('config', 'branch.feature-x.remote', 'other')
        self.git('config', 'branch.feature-x.merge', 'refs/heads/feature-x')
        self.key('o')
        wait(lambda: self.banner() == 'Unsupported git service', 'the banner does not name the unclaimed host')
        self.git('config', 'branch.feature-x.remote', '.')
        self.key('o')
        wait(lambda: self.banner() == 'Cannot open a pull request for a branch with no upstream', 'a remote . is not refused')
        self.git('remote', 'set-url', 'other', 'git@git.muxify.test')
        self.git('config', 'branch.feature-x.remote', 'other')
        self.key('o')
        wait(lambda: self.banner() == 'Failed to parse repo information from url', 'the banner does not say the URL fails to parse')
        time.sleep(.5)
        self.assertEqual(self.stored_tabs(), [], 'o opened a page')
        self.assertTrue(self.is_open(), 'the Git View closed')

    def test_o_does_nothing_in_changes_and_history(self):
        self.addCleanup(self.close_browser_tabs)
        self.track('main', 'git@git.muxify.test:owner/repo.git')
        for tab in ['1', '2']:
            self.go_to(tab)
            self.key('o')
        time.sleep(.5)
        self.assertEqual(self.stored_tabs(), [], 'o opened a page outside Branches')
        self.assertFalse(self.s.has('git-write-error'))
        self.assertTrue(self.is_open())


if __name__ == '__main__':
    unittest.main()
