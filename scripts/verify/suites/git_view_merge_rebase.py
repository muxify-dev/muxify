"""The Git View's merges and rebases: the operation menu of m, M and its merge menu, and r and its simple
rebase.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_merge_rebase
"""

from scripts.verify.git_view_fixture import GitViewFixture
from scripts.verify.sandbox import wait


class GitViewMergeRebase(GitViewFixture):
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

    def test_m_aborts_a_conflicted_merge(self):
        self.merge_fixture('conflict')
        head = self.git('rev-parse', 'HEAD').strip()
        self.git_try('merge', 'm-side')
        self.key('shift+r')
        self.s.wait_rows(lambda rs: 'Merging' in self.s.row('git-toolbar', rs).get('accessibilityLabel', ''), 'the toolbar does not say Merging', seconds=10)
        self.ask_operation('Merge options')
        self.s.act('action', 'git-menu', 'a')
        wait(lambda: not self.in_progress(), 'a did not abort the merge', seconds=10)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), head)
        self.assertEqual(self.git('status', '--porcelain').strip(), '')

    def merge_fixture(self, kind):
        """Sets the fixture's changes aside and makes `m-side`, one commit: `ahead` on a new file, and main stays where
        it was, so main can fast-forward to it; `conflict` on `conflict.txt`, which main then also changes. Everything is
        put back after the check."""
        self.git('stash', 'push', '-q', '-u', '-m', 'e2e merge')
        self.addCleanup(self.git, 'stash', 'pop', '-q', '--index')
        self.addCleanup(self.undo_merge, self.git('rev-parse', 'HEAD').strip())
        self.git('checkout', '-q', '-b', 'm-side')
        name = 'conflict.txt' if kind == 'conflict' else 'merged.txt'
        (self.repo/name).write_text('side\n')
        self.git('add', name)
        self.git('commit', '-q', '-m', 'side change')
        self.git('checkout', '-q', 'main')
        if kind == 'conflict':
            (self.repo/name).write_text('main\n')
            self.git('add', name)
            self.git('commit', '-q', '-m', 'main change')

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

    def test_shift_m_then_f_fast_forwards_and_shows_a_pill_that_names_the_branch(self):
        self.merge_fixture('ahead')
        self.ask_merge()
        self.s.act('action', 'git-menu', 'f')
        # The Pill lives 1.5 seconds, so it is read as soon as it shows.
        rs = self.s.wait_rows(lambda rs: self.s.has('pill', rs), 'the merge showed no Pill', seconds=10)
        pill = self.s.row('pill', rs)
        self.assertEqual((pill.get('accessibilityLabel'), pill.get('accessibilityValue')), ('Merged', 'confirmation: m-side'))
        wait(lambda: self.git('rev-parse', 'HEAD').strip() == self.git('rev-parse', 'm-side').strip(), 'f did not fast-forward', seconds=10)
        self.assertEqual(self.parents(), 1, 'a fast-forward made a merge commit')
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
        self.git_try('rebase', '--abort')
        self.git_retry('checkout', '-q', '-f', 'main')
        self.git_retry('branch', '-q', '-D', 'r-work')
        self.git_retry('branch', '-q', '-D', 'r-base')
        self.git_retry('reset', '-q', '--hard', before)
        self.git_retry('stash', 'pop', '-q', '--index')
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

    def test_r_offers_the_simple_rebase_and_s_rebases_onto_the_branch(self):
        self.rebase_fixture('clean')
        base = self.git('rev-parse', 'r-base').strip()
        rs = self.ask_rebase()
        self.assertEqual(self.s.row('git-menu-choice-s', rs).get('accessibilityLabel'), "Simple rebase onto 'r-base'")
        self.s.act('action', 'git-menu', 's')
        wait(lambda: self.git('rev-parse', 'HEAD^').strip() == base, 's did not rebase onto r-base', seconds=10)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD').strip(), 'r-work')
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), 'work change')
        self.assertFalse(self.in_progress(), 'a clean rebase stayed in progress')
        self.assertFalse(self.s.has('git-write-error'), 'the rebase failed')

    def test_a_rebase_that_conflicts_stops_with_the_conflicts_and_staging_them_asks_and_enter_continues_it(self):
        self.rebase_fixture('conflict')
        base = self.git('rev-parse', 'r-base').strip()
        self.ask_rebase()
        self.s.act('action', 'git-menu', 's')
        rs = self.s.wait_rows(lambda rs: self.s.has('git-write-error', rs), 'the conflicting rebase did not say so', seconds=10)
        self.assertIn("Rebasing 'r-work' onto 'r-base' conflicted", self.s.row('git-write-error', rs).get('accessibilityValue', ''))
        self.assertTrue(self.in_progress(), 'the conflicting rebase did not stay in progress')
        self.s.wait_rows(lambda rs: 'Rebasing' in self.s.row('git-toolbar', rs).get('accessibilityLabel', ''), 'the toolbar does not say Rebasing', seconds=10)
        self.key('1')
        self.resolve_and_stage()
        self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Continue the rebase?', 'staging did not ask to continue')
        self.s.act('action', 'git-menu', 'enter')
        wait(lambda: not self.in_progress(), 'enter did not continue the rebase', seconds=10)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD').strip(), 'r-work')
        self.assertEqual(self.git('log', '-1', '--format=%s').strip(), 'work change')
        self.assertEqual(self.git('rev-parse', 'HEAD^').strip(), base, 'the continued rebase is not onto r-base')
        self.assertEqual((self.repo/'conflict.txt').read_text(), 'resolved\n')
