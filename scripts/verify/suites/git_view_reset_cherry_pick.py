"""The Git View's resets and cherry-picks: g and its soft, mixed and hard reset, and copying commits
with C and pasting them with V.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_reset_cherry_pick
"""

import subprocess
import time

from scripts.verify.git_view_fixture import GitViewFixture, MAIN_COMMITS, SHELL
from scripts.verify.sandbox import wait


class GitViewResetCherryPick(GitViewFixture):
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
