"""The Git View in Branches and History: checking out, a branch of another Worktree, the new, rename and
check-out prompts, and deleting a local or a remote branch.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_branches
"""

import subprocess
import time

from scripts.verify.git_view_fixture import GitViewFixture, MAIN_COMMITS, SHELL
from scripts.verify.sandbox import wait


class GitViewBranches(GitViewFixture):
    def head(self):
        """The branch the fixture is on, or '' when HEAD is detached."""
        return self.git('branch', '--show-current').strip()

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
        self.close_git_view()
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
        self.open_git_view()
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
        # The menu offers the delete by the HEAD that the Git View read last, so wait until it has read that main is out.
        self.key('shift+r')
        self.go_to('2')
        self.s.wait_rows(lambda rs: self.history_subjects(rs)[:1] == MAIN_COMMITS[:1], 'History does not start at main', seconds=15)
        rs = self.ask_to_delete('main', refresh=False)
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
