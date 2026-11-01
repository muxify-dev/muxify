"""The Git View: opening it, the Changes list and a file's diff, History, a comparison with a marked base,
e and the editor, an Empty Topic page, and closing with q.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_diff
"""

import json
import re
import shlex
import time

from scripts.verify.git_view_fixture import GitViewFixture, MAIN_COMMITS, SHELL
from scripts.verify.sandbox import remove_topic, wait


class GitViewDiff(GitViewFixture):
    def selected_row(self, rs):
        return next((r for r in self.rows_with_prefix('git-row-', rs) if 'selected=1' in r.get('accessibilityValue', '')), {})

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

    def comparing(self, rs=None):
        """The toolbar's part about the comparison, or None."""
        return next((part for part in self.toolbar(rs).split(' · ') if 'Comparing' in part or '→' in part), None)

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

    def test_q_closes_the_git_view(self):
        self.assertTrue(self.is_open(), 'the Git View is not open')
        self.key('q')
        wait(lambda: not self.is_open(), 'q did not close the Git View', seconds=10)
        self.assertFalse(self.s.has('git-toolbar'), 'the toolbar stays after q')
