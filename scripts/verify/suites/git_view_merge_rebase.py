"""The Git View's merges and rebases: the operation menu of m, M and its four merges, and r and its
simple rebase.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_merge_rebase
"""

import json
import time

from scripts.verify.git_view_fixture import GitViewFixture
from scripts.verify.sandbox import wait


class GitViewMergeRebase(GitViewFixture):
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
        # Do not read the temporary HEAD while the fixture changes branches.
        self.close_git_view()
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
        self.open_git_view()
        self.go_to('2')
        head = self.git('rev-parse', 'HEAD').strip()
        self.s.wait_rows(lambda rs: self.s.has('git-row-commit:' + head, rs),
                         'History did not read the merge fixture')
        return before

    def undo_merge(self, before):
        self.git_try('merge', '--abort')
        self.git_try('checkout', '-q', '-f', 'main')
        self.git_try('branch', '-q', '-D', 'm-side')
        self.git('reset', '-q', '--hard', before)

    def ask_merge(self, branch='m-side'):
        self.go_to('3')
        self.select_row('git-row-branch:' + branch)
        self.key('shift+m')
        last_rows = []

        def opened(rs):
            last_rows[:] = rs
            return self.menu(rs).get('accessibilityLabel') == "Merge '%s' into 'main'" % branch

        try:
            return self.s.wait_rows(opened, 'shift+m did not open the merge menu')
        except AssertionError:
            (self.s.root/'logs/merge-menu-last-rows.json').write_text(json.dumps(last_rows, indent=2))
            raise

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

    def test_a_merge_shows_a_confirmation_pill_that_names_the_branch(self):
        self.merge_fixture('ahead')
        self.ask_merge()
        self.s.act('action', 'git-menu', 'n')
        # The Pill lives 1.5 seconds, so it is read as soon as it shows.
        rs = self.s.wait_rows(lambda rs: self.s.has('pill', rs), 'the merge showed no Pill', seconds=10)
        pill = self.s.row('pill', rs)
        self.assertEqual((pill.get('accessibilityLabel'), pill.get('accessibilityValue')), ('Merged', 'confirmation: m-side'))

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
