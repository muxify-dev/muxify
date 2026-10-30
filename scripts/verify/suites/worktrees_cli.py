"""The muxify worktree commands of the command line tool that the Debug app bundles, on the sandbox's tmux server
(ADR 0062).

The checks run the tool as a user does in a shell, in a repository folder, without the app. Nothing here starts the
app or takes the focus.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.worktrees_cli
"""

import json
import subprocess
import unittest

from scripts.verify.sandbox import DEBUG_APP, Sandbox, wait

CLI = DEBUG_APP/'Contents/Resources/bin/muxify'

SETUP = """// The user's script reads this file too.
{
  "sync": {
    "copyFiles": [".envrc", "missing.env",],
    "symlinkDirs": ["shared"],
  },
  "hooks": {
    "postCreate": ["echo \\"$MUXIFY_WORKTREE_NAME\\" > post-created.log"],
    "preDelete": ["echo \\"$MUXIFY_WORKTREE_BRANCH\\" >> ../pre-deleted.log"],
  },
}
"""


class WorktreesCli(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.projects = s.root/'projects'
        cls.projects.mkdir(parents=True)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text('sessions:\n  paths:\n    - path: ' + str(cls.projects) + '/*\n')
        s.tmux('new-session', '-d', '-s', 'base', '-c', str(s.root))
        cls.pane = s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        cls.records = s.root/'state/muxify/worktrees'

    def muxify(self, *args, cwd, pane=None):
        environment = dict(self.s.env, TMUX_PANE=pane or self.pane)
        return subprocess.run([str(CLI), *args], cwd=cwd, env=environment, capture_output=True, text=True, timeout=60)

    def git(self, *args, cwd):
        made = subprocess.run(['/usr/bin/git', '-c', 'user.name=Verify', '-c', 'user.email=verify@example.invalid',
                               '-c', 'commit.gpgSign=false', *args],
                              cwd=cwd, env=self.s.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(made.returncode, 0, made.stderr)
        return made.stdout.strip()

    def repository(self, name, setup=SETUP):
        """A repository with an uncommitted .worktree.json and the local files it copies and links, all ignored."""
        repository = self.projects/name
        self.git('init', '-q', '-b', 'main', str(repository), cwd=self.s.root)
        (repository/'.gitignore').write_text('.worktree.json\n.envrc\nshared\n*.log\n')
        self.git('add', '.gitignore', cwd=repository)
        self.git('commit', '-q', '-m', 'first', cwd=repository)
        if setup:
            (repository/'.worktree.json').write_text(setup)
        (repository/'.envrc').write_text('export SECRET=1\n')
        (repository/'shared').mkdir()
        return repository

    def records_of(self, name):
        return [json.loads(f.read_text()) for f in self.records.glob('*.json') if json.loads(f.read_text())['name'] == name]

    def test_worktree_create_syncs_runs_post_create_and_makes_a_no_topic_session(self):
        repository = self.repository('wt-create')
        made = self.muxify('worktree', 'create', 'fix-login', '--no-open', '--json', cwd=repository)
        self.assertEqual(made.returncode, 0, made.stderr)
        change = json.loads(made.stdout)['changed']
        worktree = self.records/'wt-create/fix-login'
        self.assertEqual(change['session_name'], 'wt-create/fix-login', change)
        self.assertIn('skip copy (missing): missing.env', change['output'], change)
        self.assertEqual((worktree/'.envrc').read_text(), 'export SECRET=1\n', 'the setup did not copy .envrc')
        self.assertTrue((worktree/'shared').is_symlink(), 'the setup did not link shared')
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD', cwd=worktree), 'fix-login')
        wait(lambda: (worktree/'post-created.log').exists(), 'postCreate did not run in the new Session', seconds=15)
        self.assertEqual((worktree/'post-created.log').read_text(), 'fix-login\n')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=wt-create/fix-login:', '@muxify_topic'), '', 'the Session has a Topic')
        [record] = self.records_of('fix-login')
        self.assertEqual((record['id'], record['branch'], record['path']), (change['worktree_id'], 'fix-login', str(worktree.resolve())), record)

        again = self.muxify('worktree', 'create', 'fix-login', '--no-open', cwd=repository)
        self.assertNotEqual(again.returncode, 0)
        self.assertIn('is already a Muxify Worktree', again.stderr)

    def test_worktree_create_checks_out_a_branch_that_exists_from_another_worktree(self):
        repository = self.repository('wt-branch', setup=None)
        self.git('branch', 'feature', cwd=repository)
        first = self.muxify('worktree', 'create', 'first', '--no-open', cwd=repository)
        self.assertEqual(first.returncode, 0, first.stderr)
        # From inside a Muxify Worktree, the next one belongs to the same repository folder.
        made = self.muxify('worktree', 'create', 'feature', '--no-open', cwd=self.records/'wt-branch/first')
        self.assertEqual(made.returncode, 0, made.stderr)
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD', cwd=self.records/'wt-branch/feature'), 'feature')

    def test_worktree_list_shows_only_the_muxify_worktrees_of_the_repository(self):
        repository = self.repository('wt-list', setup=None)
        other = self.repository('wt-list-other', setup=None)
        self.git('worktree', 'add', '-q', '-b', 'by-hand', str(self.projects/'wt-list-by-hand'), cwd=repository)
        for folder, name in [(repository, 'listed'), (other, 'elsewhere')]:
            made = self.muxify('worktree', 'create', name, '--no-open', cwd=folder)
            self.assertEqual(made.returncode, 0, made.stderr)
        listed = self.muxify('worktree', 'list', cwd=repository)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        rows = [line.split('\t') for line in listed.stdout.splitlines()]
        self.assertEqual([row[:3] + [row[4]] for row in rows], [['listed', 'listed', 'clean', 'wt-list/listed']], listed.stdout)
        every = self.muxify('worktree', 'list', '--all', '--json', cwd=self.s.root)
        names = {w['name'] for w in json.loads(every.stdout)['worktrees']}
        self.assertTrue({'listed', 'elsewhere'} <= names and 'by-hand' not in names, names)

    def test_worktree_remove_needs_kill_for_a_used_worktree_runs_pre_delete_and_keeps_the_branch(self):
        repository = self.repository('wt-remove')
        made = self.muxify('worktree', 'create', 'remove-me', '--no-open', cwd=repository)
        self.assertEqual(made.returncode, 0, made.stderr)
        worktree = self.records/'wt-remove/remove-me'
        wait(lambda: (worktree/'post-created.log').exists(), 'postCreate did not run', seconds=15)

        refused = self.muxify('worktree', 'remove', 'remove-me', cwd=repository)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn('wt-remove/remove-me', refused.stderr)
        self.assertTrue(worktree.exists(), 'a refused Remove removed the Worktree')

        removed = self.muxify('worktree', 'remove', 'remove-me', '--kill', cwd=repository)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(worktree.exists(), 'Remove kept the Worktree')
        self.assertEqual((self.records/'wt-remove/pre-deleted.log').read_text(), 'remove-me\n', 'preDelete did not run in the Worktree')
        self.assertNotEqual(self.s.tmux_ok('has-session', '-t', '=wt-remove/remove-me').returncode, 0, '--kill kept the Session')
        self.assertEqual(self.git('branch', '--list', 'remove-me', cwd=repository), 'remove-me', 'Remove deleted the branch')
        self.assertEqual(self.records_of('remove-me'), [], 'Remove kept the record')

    def test_worktree_remove_refuses_changes_and_a_failed_hook_unless_forced(self):
        repository = self.repository('wt-force', setup='{"hooks": {"preDelete": ["exit 4"]}}')
        made = self.muxify('worktree', 'create', 'dirty', '--no-open', cwd=repository)
        self.assertEqual(made.returncode, 0, made.stderr)
        self.s.tmux('kill-session', '-t', '=wt-force/dirty')
        worktree = self.records/'wt-force/dirty'
        (worktree/'new.txt').write_text('change\n')
        changed = self.muxify('worktree', 'remove', 'dirty', cwd=repository)
        self.assertIn('uncommitted changes', changed.stderr)
        (worktree/'new.txt').unlink()
        hooked = self.muxify('worktree', 'remove', 'dirty', cwd=repository)
        self.assertIn('preDelete stopped: exit 4 exited with 4.', hooked.stderr)
        self.assertTrue(worktree.exists(), 'a failed preDelete removed the Worktree')
        forced = self.muxify('worktree', 'remove', str(worktree), '--force', cwd=repository)
        self.assertEqual(forced.returncode, 0, forced.stderr)
        self.assertFalse(worktree.exists())

    def test_worktree_root_path_and_worktree_path_choose_the_folder(self):
        repository = self.repository('wt-root', setup=None)
        original = self.config.read_text()
        self.addCleanup(self.config.write_text, original)
        self.config.write_text(original + 'worktrees:\n  root_path: ' + str(self.s.root/'trees') + '\n')
        made = self.muxify('worktree', 'create', 'rooted', '--no-open', cwd=repository)
        self.assertEqual(made.returncode, 0, made.stderr)
        self.assertTrue((self.s.root/'trees/wt-root/rooted').is_dir(), 'worktrees.root_path did not place the Worktree')
        (repository/'.worktree.json').write_text('{"worktreePath": "../wt-root-trees"}')
        made = self.muxify('worktree', 'create', 'per-project', '--no-open', cwd=repository)
        self.assertEqual(made.returncode, 0, made.stderr)
        self.assertTrue((self.projects/'wt-root-trees/per-project').is_dir(), 'worktreePath did not replace the root')

    def test_a_topics_worktree_gets_a_record_and_remove_makes_the_topic_forget_it(self):
        repository = self.repository('wt-topic')
        made = self.muxify('topic', 'new', 'Worktree topic', '--json', cwd=repository)
        topic_id = json.loads(made.stdout)['changed']['topic_id']
        added = self.muxify('topic', 'add-session', str(repository), '--worktree', '--topic', topic_id, cwd=repository)
        self.assertEqual(added.returncode, 0, added.stderr)
        worktree = self.records/'wt-topic/worktree-topic'
        self.assertEqual((worktree/'.envrc').read_text(), 'export SECRET=1\n', 'the Topic Worktree did not get its sync')
        wait(lambda: (worktree/'post-created.log').exists(), 'postCreate did not run in the Topic Session', seconds=15)
        [record] = self.records_of('worktree-topic')
        topic = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertIn(record['id'], [s.get('worktree_id') for s in topic['sessions']], topic)
        listed = self.muxify('worktree', 'list', '--json', cwd=repository)
        [shown] = [w for w in json.loads(listed.stdout)['worktrees'] if w['id'] == record['id']]
        self.assertEqual(shown['topic'], 'Worktree topic', shown)

        removed = self.muxify('worktree', 'remove', 'worktree-topic', '--kill', cwd=repository)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        topic = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertEqual([s for s in topic['sessions'] if s.get('worktree_path')], [], 'the Topic still remembers the removed Worktree')


if __name__ == '__main__':
    unittest.main()
