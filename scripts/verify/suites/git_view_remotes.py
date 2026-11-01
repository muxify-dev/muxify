"""The Git View and remotes: fetching and the credential prompt, pushing, pulling, and o, which opens
a branch's pull request or a commit's page in the browser.

The Git View's keys and accessibility identifiers are in git_view_fixture.py.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.git_view_remotes
"""

import shlex
import subprocess
import time

from scripts.verify.git_view_fixture import GitViewFixture
from scripts.verify.sandbox import wait


class GitViewRemotes(GitViewFixture):
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

    def commit_here(self, message):
        """An empty commit on main, taken back after the check."""
        before = self.git('rev-parse', 'HEAD').strip()
        self.git('commit', '-q', '--allow-empty', '-m', message)
        self.addCleanup(self.take_back, before)

    def test_shift_p_pushes_the_branch_in_every_tab_and_the_toolbar_says_pushing(self):
        origin = self.bare_remote('push-plain')
        self.commit_here('to push')
        self.key('f')
        # Without an upstream the counts are against main, which is origin/main too, so a read from before
        # `push -u` set the upstream shows the same counts, and shift+p would ask for an upstream.
        self.s.wait_rows(lambda rs: 'no upstream' not in self.toolbar(rs) and '↑1 ↓0 vs origin/main' in self.toolbar(rs),
                         'the Git View does not count the commit as unpushed to the upstream', seconds=15)
        self.key('3')
        self.key('shift+p')
        try:
            wait(lambda: self.remote_main(origin) == self.git('rev-parse', 'HEAD').strip(), 'shift+p did not push main', seconds=15)
        except AssertionError:
            rs = self.s.rows()
            self.fail('shift+p did not push main: the toolbar says %r, the error says %r' % (
                self.toolbar(rs), self.s.row('git-write-error', rs).get('accessibilityLabel')))
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

    def test_o_does_nothing_in_changes(self):
        self.addCleanup(self.close_browser_tabs)
        self.track('main', 'git@git.muxify.test:owner/repo.git')
        self.go_to('1')
        self.key('o')
        time.sleep(.5)
        self.assertEqual(self.stored_tabs(), [], 'o opened a page in Changes')
        self.assertFalse(self.s.has('git-write-error'))
        self.assertTrue(self.is_open())

    def test_o_on_a_commit_in_history_opens_its_page_on_origin_and_closes_the_popup(self):
        self.addCleanup(self.close_browser_tabs)
        self.git('remote', 'add', 'origin', 'git@git.muxify.test:owner/repo.git')
        self.addCleanup(self.git, 'remote', 'remove', 'origin')
        head = self.git('rev-parse', 'HEAD').strip()
        self.go_to('2')
        self.select_row('git-row-commit:' + head)
        self.key('o')
        link = 'https://git.muxify.test/owner/repo/commit/' + head
        wait(lambda: link in self.stored_tabs(), 'o did not open %s; Tabs are %s' % (link, self.stored_tabs()), seconds=10)
        self.assertEqual(len(self.stored_tabs()), 1)
        wait(lambda: not self.is_open(), 'the popup Git View did not close', seconds=10)

    def test_o_on_a_commit_with_no_origin_says_so_and_opens_nothing(self):
        self.addCleanup(self.close_browser_tabs)
        self.go_to('2')
        self.key('o')
        self.assertEqual(self.banner(), "There is no 'origin' remote")
        time.sleep(.5)
        self.assertEqual(self.stored_tabs(), [], 'o opened a page')
        self.assertTrue(self.is_open(), 'the Git View closed')
