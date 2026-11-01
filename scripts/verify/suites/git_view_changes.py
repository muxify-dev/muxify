"""The Git View in Changes: the Discard changes menu and its Agent guard, the reset options, stashing,
applying, popping and dropping a stash, committing with c, and amending with A.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_changes
"""

import time

from scripts.verify.git_view_fixture import GitViewFixture
from scripts.verify.sandbox import wait


class GitViewChanges(GitViewFixture):
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

    def test_the_root_row_holds_every_change_and_space_on_it_stages_them_all(self):
        self.addCleanup(self.restore_fixture, len(self.stashes()))
        self.wait_change('new.txt', bool, 'Changes do not list new.txt')
        self.assertEqual(self.s.row('git-row-folder:changes:.').get('accessibilityLabel'), '/', 'Changes have no / row above their files')
        self.select_row('git-row-folder:changes:.')
        self.key('space')
        self.wait_change('new.txt', lambda row: self.status(row) == 'A ', 'space on / did not stage new.txt')
        self.assertEqual(sorted(self.porcelain()), ['A  new.txt', 'M  staged.txt', 'M  tracked.txt'], 'space on / did not stage every change')

    def open_reset_options(self):
        self.key('shift+d')
        return self.s.wait_rows(lambda rs: self.menu(rs).get('accessibilityLabel') == 'Reset options', 'D did not open the reset options')

    def test_shift_d_offers_lazygits_reset_options_and_c_deletes_only_the_untracked_files(self):
        self.addCleanup(self.restore_fixture, len(self.stashes()))
        # Every choice is offered only with a staged change, so wait until the Git View has read the staged file again.
        self.wait_change('staged.txt', lambda row: self.status(row) == 'M ', 'Changes do not show staged.txt staged')
        tree = self.porcelain()
        rs = self.open_reset_options()
        titles = {'x': 'Nuke working tree', 'u': 'Discard unstaged changes', 'c': 'Discard untracked files',
                  'shift+s': 'Discard staged changes', 's': 'Soft reset', 'm': 'Mixed reset', 'h': 'Hard reset'}
        for key, title in titles.items():
            self.assertEqual(self.s.row('git-menu-choice-' + key, rs).get('accessibilityLabel'), title)
            self.assertIn('enabled=1', self.s.row('git-menu-choice-' + key, rs).get('accessibilityValue', ''), title + ' is not offered')
        self.s.act('action', 'git-menu', 'escape')
        self.s.wait_rows(lambda rs: not self.s.has('git-menu', rs), 'escape did not close the menu')
        time.sleep(1)
        self.assertEqual(self.porcelain(), tree, 'escape changed the tree')
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
