"""The Git View: opening it, the Changes list and a file's diff, History, and closing.

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
The diff pane builds only the lines on screen, so keep a fixture's diffs short.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view
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
        (s.root/'config/muxify/config.yaml').write_text('git_view:\n  editor: ' + json.dumps(command) + '\n')
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

    def close_git_view(self):
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

    def test_q_closes_the_git_view(self):
        self.assertTrue(self.is_open(), 'the Git View is not open')
        self.key('q')
        wait(lambda: not self.is_open(), 'q did not close the Git View', seconds=10)
        self.assertFalse(self.s.has('git-toolbar'), 'the toolbar stays after q')


if __name__ == '__main__':
    unittest.main()
