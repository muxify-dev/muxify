"""The Git View in Changes: the Discard changes menu and its Agent guard, the reset options, stashing, popping a
stash, amending with A, and reading the repository again by itself after a commit typed in a Pane.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_changes
"""

import shlex

from scripts.verify.git_view_fixture import GitViewFixture
from scripts.verify.sandbox import wait


class GitViewChanges(GitViewFixture):
    def wait_change(self, name, predicate, message):
        """Reads the repository again with R, so the check does not depend on the Git View noticing the change
        itself, and waits for the change's row."""
        self.key('shift+r')
        return self.s.wait_rows(lambda rs: predicate(self.s.row('git-row-change:' + name, rs)), message, seconds=10)

    def test_a_commit_in_a_pane_takes_the_files_out_of_changes_without_r(self):
        # The Git View watches the repository, so it reads it again by itself well within the 10 seconds of its
        # timer. No key is pressed: the file shows in Changes, then leaves them after a commit typed in the Pane.
        name = 'z-watch-commit.txt'
        message = 'watched commit'
        path = self.repo/name

        def clean_up():
            if self.git('log', '-1', '--format=%s').strip() == message:
                self.git('reset', '-q', '--soft', 'HEAD~1')
            self.git('reset', '-q', '--', name)
            path.unlink(missing_ok=True)
        self.addCleanup(clean_up)
        path.write_text('watched\n')
        self.s.wait_rows(lambda rs: self.s.has('git-row-change:' + name, rs),
                         'Changes do not list %s without R' % name, seconds=6)
        # Only this file is committed: staged.txt stays staged for the checks that follow.
        command = 'cd %s && git add -- %s && git commit -q -m %s -- %s' % (
            shlex.quote(str(self.repo)), name, shlex.quote(message), name)
        self.s.tmux('send-keys', '-t', self.window, '-l', command)
        self.s.tmux('send-keys', '-t', self.window, 'Enter')
        wait(lambda: self.git('log', '-1', '--format=%s').strip() == message, 'the Pane did not commit', seconds=10)
        self.s.wait_rows(lambda rs: not self.s.has('git-row-change:' + name, rs),
                         'the committed file stays in Changes without R', seconds=6)

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

    def test_discard_names_an_agent_working_in_the_worktree_and_x_still_discards(self):
        path = self.repo/'z-discard-agent.txt'
        path.write_text('kept\n')
        try:
            self.wait_change('z-discard-agent.txt', bool, 'Changes do not list z-discard-agent.txt')
            # A working Agent in a folder inside the Worktree is named in the Discard menu, and x still discards from it.
            self.agent_pane('gv-agent-inside', self.repo/'.git', 'working')
            self.assertEqual(self.discard_names_agents('z-discard-agent.txt', True), 'Claude Code in gv-agent-inside')
            self.select_change('z-discard-agent.txt')
            self.open_discard_menu()
            self.s.act('action', 'git-menu', 'x')
            wait(lambda: not path.exists(), 'x did not delete the file after the guarded menu', seconds=10)
        finally:
            path.unlink(missing_ok=True)

    def open_reset_options(self):
        self.key('shift+d')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Reset options', 'D did not open the reset options')

    def test_shift_d_opens_the_reset_options_and_c_deletes_only_the_untracked_files(self):
        self.addCleanup(self.restore_fixture, len(self.stashes()))
        # c is offered only once the Git View has read the untracked file.
        self.wait_change('new.txt', lambda row: self.status(row) == '??', 'Changes do not show new.txt untracked')
        tree = self.porcelain()
        self.open_reset_options()
        self.s.act('action', 'git-menu', 'c')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'c did not close the menu')
        wait(lambda: not (self.repo/'new.txt').exists(), 'c did not delete the untracked file', seconds=10)
        self.assertEqual(self.porcelain(), [line for line in tree if not line.startswith('??')], 'c changed more than the untracked files')
        self.wait_change('new.txt', lambda row: not row, 'the deleted file stays in Changes')

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
        self.key('s')
        self.type_in_prompt('my note')
        self.addCleanup(self.restore_fixture, len(before))
        wait(lambda: self.stashes()[:1] == ['On main: my note'], 'the stash is not git\'s stash of "my note"', seconds=10)
        self.assertEqual(self.porcelain(), ['?? new.txt'], 'the tree is not as git stash push leaves it')
        # The new stash shows in Stashes, with its count, and Changes lists what is left.
        rs = self.s.wait_rows(lambda rs: not self.s.has('git-row-change:tracked.txt', rs) and self.s.has('git-row-change:new.txt', rs),
                              'Changes list what the stash took', seconds=15)
        self.assertEqual(len(before) + 1, len(self.stashes()))
        self.key('4')
        self.s.wait_rows(lambda rs: sum(r.get('accessibilityLabel') == 'my note' for r in
                                        self.rows_with_prefix('git-row-stash:', rs)) == 1, 'Stashes do not list the new stash', seconds=15)
        self.key('1')

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

    def test_g_on_a_stash_pops_it_after_asking(self):
        sha = self.make_stash('pop me')
        before = len(self.stashes())
        self.select_stash(sha)
        self.ask_stash('g', 'Pop stash')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: len(self.stashes()) == before - 1, 'y did not drop the popped stash', seconds=10)
        self.assertEqual((self.repo/'stashed.txt').read_text(), 'one\nentry pop me\n', 'pop did not apply the stash')
        self.s.wait_rows(lambda rs: not self.has_stash_row(sha, rs), 'Stashes still list the popped stash', seconds=15)
        self.key('1')
        self.wait_change('stashed.txt', lambda row: self.status(row) == ' M', 'Changes do not list the popped stash\'s file')

    def test_shift_a_asks_then_amends_the_last_commit(self):
        self.wait_change('staged.txt', bool, 'Changes do not list staged.txt')
        before = self.git('rev-parse', 'HEAD').strip()
        count = self.git('rev-list', '--count', 'HEAD').strip()
        self.addCleanup(self.take_back, before)
        self.key('shift+a')
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Amend last commit', 'shift+a did not ask')
        self.s.act('action', 'git-menu', 'y')
        wait(lambda: self.git('rev-parse', 'HEAD').strip() != before, 'the last commit was not amended', seconds=10)
        self.assertEqual(self.git('rev-list', '--count', 'HEAD').strip(), count, 'amend added a commit')
        self.assertFalse(self.s.has('git-write-error'), 'the amend failed')
