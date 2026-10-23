"""The Git View: opening it, the Changes list and a file's diff, History, the Discard changes menu and its Agent guard, stashing from Changes, applying, popping and dropping a stash, checking out, and closing.

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
    git-prompt-cancel        the prompt's Cancel button
    git-prompt-submit        the prompt's submit button, such as Stash
    git-prompt-suggestion-<n>  a suggestion of a prompt that offers some, such as the branch names `c` in Branches
                             takes; its label is the name, and its value is `chosen` for the one ↓/↑ chose. The
                             prompt's actions then include down and up
    The Branches keys n, R, - and c ask in the prompts `New branch name (branch is off of '<branch>')`, `Rename branch`
    and `Check out`; ↩ checks out through the same path as space does.
    The Stashes keys ask in the menus `stash-apply`, `stash-pop` and `stash-drop` (labels "Apply stash", "Pop stash" and
    "Drop stash"), each with the one choice `git-menu-choice-y`. space in Branches and History checks out; it asks
    only in the menu `checkout` ("Check out", while an Agent is working in the Worktree) and in `autostash`
    ("Autostash?", when Changes are in the way), each with the one choice `git-menu-choice-y`. space on a branch that
    another Worktree has checked out asks in the menu `other-worktree` ("Go to Worktree?") instead, with the one
    choice `git-menu-choice-y`: it goes to a Window with a Pane in that Worktree, else opens Go to… on its Session Path.
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

from scripts.verify.sandbox import Sandbox, wait

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
        self.s.tmux('select-window', '-t', self.window)
        self.s.wait_shown(self.window)
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
        # In History: no menu either.
        self.key('2')
        for key in ['g', 'd']:
            self.key(key)
            time.sleep(.5)
            self.assertFalse(self.s.has('git-menu'), key + ' asked in History')
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
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty}').split():
            self.s.tmux('switch-client', '-c', tty, '-t', self.window)
        self.s.wait_shown(self.window)

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

    def test_q_closes_the_git_view(self):
        self.assertTrue(self.is_open(), 'the Git View is not open')
        self.key('q')
        wait(lambda: not self.is_open(), 'q did not close the Git View', seconds=10)
        self.assertFalse(self.s.has('git-toolbar'), 'the toolbar stays after q')


if __name__ == '__main__':
    unittest.main()
