"""The muxify topic, window and agent commands of the command line tool that the Debug app bundles, on the sandbox's
tmux server.

The checks run the tool as a user does in a shell, without the app: the Topic commands change the Topic records and
tmux in the tool's own process. Nothing here starts the app or takes the focus.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_cli
"""

import json
import subprocess
import time
import unittest

from scripts.verify.sandbox import DEBUG_APP, Sandbox, wait

CLI = DEBUG_APP/'Contents/Resources/bin/muxify'


class TopicsCli(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.projects = s.root/'projects'
        (s.root/'config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(cls.projects) + '/*\n')
        s.tmux('new-session', '-d', '-s', 'base', '-c', str(s.root))

    def muxify(self, *args, pane, env=None):
        environment = dict(self.s.env, TMUX_PANE=pane, **(env or {}))
        return subprocess.run([str(CLI), *args], env=environment, capture_output=True, text=True, timeout=30)

    def test_topic_forget_removes_live_and_settled_topics(self):
        project = self.projects/'cli-forget'
        project.mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        for settled in [False, True]:
            made = self.muxify('topic', 'new', 'Forget CLI', '--directory', str(project), pane=pane)
            self.assertEqual(made.returncode, 0, made.stderr)
            topic = made.stdout.strip()
            self.assertTrue(self.s.tmux('display-message', '-p', '#{socket_path}').startswith(str(self.s.root) + '/'))
            if settled:
                result = self.muxify('topic', 'settle', '--topic', topic, pane=pane)
                self.assertEqual(result.returncode, 0, result.stderr)
            result = self.muxify('topic', 'forget', '--topic', topic, '--json', pane=pane)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.s.root/'state/muxify/topics'/(topic + '.json')).exists())
            self.assertNotEqual(self.s.tmux_ok('has-session', '-t', '=cli-forget/forget-cli').returncode, 0)

    def test_topic_new_from_a_pane_outside_any_topic_prints_an_id_that_topic_list_shows(self):
        project = self.projects/'cli-new'
        project.mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=base:', '@muxify_topic'), '', 'base is outside any Topic')

        made = self.muxify('topic', 'new', 'CLI check', '--directory', str(project), pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = made.stdout.strip()
        self.assertTrue(topic_id and '\n' not in topic_id, 'topic new printed no single id: %r' % made.stdout)
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=cli-new/cli-check:', '@muxify_topic'), topic_id,
                         'the new Session is not in the Topic')
        record = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertEqual(record.get('title'), 'CLI check', record)

        listed = self.muxify('topic', 'list', pane=pane)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn(topic_id + '\tCLI check\t', listed.stdout.splitlines(), 'topic list does not show the new Topic')

    def fake_agent(self, session, status, unread=False, conversation=None):
        """A Pane that runs a program, as an Agent does, with the pane options its Extension and Muxify write."""
        pane = self.s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', '=' + session + ':', '/bin/sleep', '600')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'claude')
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_status', status)
        if unread:
            self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_unread', '1')
        if conversation:
            self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent_conversation', conversation)
        wait(lambda: self.s.tmux('display-message', '-p', '-t', pane, '#{pane_current_command}') == 'sleep',
             'fake Agent has not left its startup shell', seconds=10)
        return pane

    def test_topic_show_lists_both_sessions_of_the_topic_and_the_status_of_its_agent(self):
        for name in ('cli-show-home', 'cli-show-tools'):
            (self.projects/name).mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        made = self.muxify('topic', 'new', 'Show check', '--directory', str(self.projects/'cli-show-home'), pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = made.stdout.strip()
        added = self.muxify('topic', 'add-session', str(self.projects/'cli-show-tools'), '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)
        agent = self.fake_agent('cli-show-tools/show-check', 'working')

        shown = self.muxify('topic', 'show', '--json', pane=agent)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        topic = json.loads(shown.stdout)['topic']
        self.assertEqual(topic['id'], topic_id, shown.stdout)
        self.assertEqual([s['name'] for s in topic['sessions']], ['cli-show-home/show-check', 'cli-show-tools/show-check'],
                         shown.stdout)
        panes = [p for s in topic['sessions'] for w in s['windows'] for p in w['panes']]
        self.assertIn({'kind': 'claude', 'status': 'working', 'unread': False, 'conversation': None}, [p['agent'] for p in panes], shown.stdout)

    def test_agent_list_shows_an_agent_with_its_status_unread_and_topic(self):
        (self.projects/'cli-agents').mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        made = self.muxify('topic', 'new', 'Agents check', '--directory', str(self.projects/'cli-agents'), pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = made.stdout.strip()
        agent = self.fake_agent('cli-agents/agents-check', 'done', unread=True)

        listed = self.muxify('agent', 'list', '--unread', '--json', pane=pane)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        row = next((r for r in json.loads(listed.stdout)['agents'] if r['pane_id'] == agent), None)
        self.assertIsNotNone(row, 'agent list --unread does not show the Unread Agent: %s' % listed.stdout)
        self.assertEqual(row['agent'], {'kind': 'claude', 'status': 'done', 'unread': True, 'conversation': None}, row)
        self.assertEqual(row['topic'], {'id': topic_id, 'label': 'Agents check', 'tags': []}, row)

        text = self.muxify('agent', 'list', '--topic', 'Agents check', pane=pane)
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertEqual(text.stdout, '\t'.join([agent, 'claude', 'done', 'unread', 'Agents check', 'cli-agents/agents-check']) + '\n')

    def test_agent_conversation_reads_the_transcript_of_a_panes_agent_without_its_tool_entries(self):
        (self.projects/'cli-conversation').mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        made = self.muxify('topic', 'new', 'Conversation check', '--directory', str(self.projects/'cli-conversation'), pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        agent = self.fake_agent('cli-conversation/conversation-check', 'done', conversation='conv-check')
        claude = self.s.root/'claude'
        transcript = claude/'projects/-work/conv-check.jsonl'
        transcript.parent.mkdir(parents=True)
        transcript.write_text('\n'.join(json.dumps(r) for r in [
            {'type': 'user', 'message': {'role': 'user', 'content': 'run the tests'}},
            {'type': 'assistant', 'message': {'role': 'assistant', 'content': [
                {'type': 'thinking', 'thinking': 'not an Entry'},
                {'type': 'tool_use', 'id': 't1', 'name': 'Bash', 'input': {'command': 'make test'}}]}},
            {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': 'PASS'}]}},
            {'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': 'The tests pass.'}]}},
        ]) + '\n')

        read = self.muxify('agent', 'conversation', agent, '--json', pane=pane, env={'CLAUDE_CONFIG_DIR': str(claude)})
        self.assertEqual(read.returncode, 0, read.stderr)
        lines = [json.loads(line) for line in read.stdout.splitlines()]
        self.assertEqual(lines[0]['conversation'], 'conv-check', read.stdout)
        self.assertEqual([(e['index'], e['role'], e['text']) for e in lines[1:]],
                         [(0, 'user', 'run the tests'), (3, 'assistant', 'The tests pass.')], read.stdout)
        self.assertIn('2 tool Entries hidden', read.stderr)

        listed = self.muxify('topic', 'show', '--conversations', pane=agent)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn('conversation\tclaude\tconv-check\n', listed.stdout)

    def test_window_move_moves_a_window_that_is_not_the_callers_and_it_shows_under_the_topic(self):
        (self.projects/'cli-move').mkdir(parents=True)
        caller = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        made = self.muxify('topic', 'new', 'Move check', '--directory', str(self.projects/'cli-move'), pane=caller)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = made.stdout.strip()
        self.s.tmux('new-session', '-d', '-s', 'cli-loose', '-c', str(self.s.root))
        self.s.tmux('new-window', '-d', '-t', '=cli-loose:', '-c', str(self.s.root))
        window = self.s.tmux('display-message', '-p', '-t', '=cli-loose:', '#{window_id}')

        moved = self.muxify('window', 'move', '--window', window, '--topic', 'Move check', pane=caller)
        self.assertEqual(moved.returncode, 0, moved.stderr)
        self.assertEqual(moved.stdout.strip(), topic_id)
        shown = self.muxify('topic', 'show', '--topic', topic_id, '--json', pane=caller)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        windows = [w['id'] for s in json.loads(shown.stdout)['topic']['sessions'] for w in s['windows']]
        self.assertIn(window, windows, 'the moved Window is not under the Topic: %s' % shown.stdout)
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=base:', '@muxify_topic'), '', 'the caller Window stays outside')

    def test_topic_exec_prints_each_sessions_folder_and_types_into_no_pane(self):
        for name in ('cli-exec-home', 'cli-exec-tools'):
            (self.projects/name).mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        made = self.muxify('topic', 'new', 'Exec check', '--directory', str(self.projects/'cli-exec-home'), pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = made.stdout.strip()
        added = self.muxify('topic', 'add-session', str(self.projects/'cli-exec-tools'), '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)
        sessions = ['cli-exec-home/exec-check', 'cli-exec-tools/exec-check']
        heard = []
        for session in sessions:
            self.s.tmux('split-window', '-d', '-t', '=' + session + ':')
            for pane in self.s.tmux('list-panes', '-s', '-t', '=' + session, '-F', '#{pane_id}').split():
                heard.append(self.s.root/('heard-' + pane[1:]))
                heard[-1].write_text('')
                self.s.tmux('respawn-pane', '-k', '-t', pane, 'cat >> ' + str(heard[-1]))

        ran = self.muxify('topic', 'exec', '--topic', topic_id, '--', 'pwd', pane=pane)
        self.assertEqual(ran.returncode, 0, ran.stderr)
        expected = ''.join('==> %s <==\n%s\n' % (session, (self.projects/session.split('/')[0]).resolve()) for session in sessions)
        self.assertEqual(ran.stdout, expected)
        time.sleep(0.3)
        for file in heard:
            self.assertEqual(file.read_text(), '', 'a Pane of a Session got input: %s' % file.name)

    def git(self, *args, cwd):
        made = subprocess.run(['/usr/bin/git', '-c', 'user.name=Verify', '-c', 'user.email=verify@example.invalid',
                               '-c', 'commit.gpgSign=false', *args],
                              cwd=cwd, env=self.s.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(made.returncode, 0, made.stderr)
        return made.stdout.strip()

    def test_topic_status_and_diff_read_the_git_sessions_and_give_null_for_a_plain_folder(self):
        plain = self.projects/'cli-git-plain'
        plain.mkdir(parents=True)
        repository = self.projects/'cli-git-repo'
        self.git('init', '-q', '-b', 'main', str(repository), cwd=self.s.root)
        (repository/'readme.txt').write_text('readme\n')
        self.git('add', 'readme.txt', cwd=repository)
        self.git('commit', '-q', '-m', 'first', cwd=repository)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        made = self.muxify('topic', 'new', 'Git check', '--directory', str(plain), pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = made.stdout.strip()
        added = self.muxify('topic', 'add-session', str(repository), '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)
        (repository/'readme.txt').write_text('changed\n')
        (repository/'new.txt').write_text('new\n')

        status = self.muxify('topic', 'status', '--topic', topic_id, '--json', pane=pane)
        self.assertEqual(status.returncode, 0, status.stderr)
        sessions = {s['name']: s['git'] for s in json.loads(status.stdout)['sessions']}
        self.assertIsNone(sessions['cli-git-plain/git-check'], status.stdout)
        self.assertEqual(sessions['cli-git-repo/git-check']['branch'], 'main', status.stdout)
        self.assertEqual([(c['kind'], c['path']) for c in sessions['cli-git-repo/git-check']['changes']],
                         [('changed', 'readme.txt'), ('untracked', 'new.txt')], status.stdout)

        stat = self.muxify('topic', 'diff', '--topic', topic_id, '--stat', pane=pane)
        self.assertEqual(stat.returncode, 0, stat.stderr)
        self.assertEqual([' '.join(line.split()) for line in stat.stdout.splitlines()],
                         ['cli-git-repo/git-check/new.txt | 1 +', 'cli-git-repo/git-check/readme.txt | 2 +-',
                          '2 files changed, 2 insertions(+), 1 deletion(-)'])
        self.assertEqual(self.git('status', '--porcelain', cwd=repository), 'M readme.txt\n?? new.txt',
                         'topic diff staged nothing')

    def test_add_session_with_worktree_makes_a_worktree_that_settle_removes(self):
        home = self.projects/'cli-wt-home'
        home.mkdir(parents=True)
        repository = self.projects/'cli-wt-repo'
        self.git('init', '-q', '-b', 'main', str(repository), cwd=self.s.root)
        self.git('commit', '-q', '--allow-empty', '-m', 'first', cwd=repository)
        commit = self.git('rev-parse', 'HEAD', cwd=repository)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        made = self.muxify('topic', 'new', 'Worktree check', '--directory', str(home), pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = made.stdout.strip()

        added = self.muxify('topic', 'add-session', str(repository), '--worktree', '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)
        worktree = self.s.root/'state/muxify/worktrees/cli-wt-repo/worktree-check'
        self.assertTrue(worktree.is_dir(), 'add-session --worktree made no Worktree folder at %s' % worktree)
        record = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        session = next((s for s in record.get('sessions', []) if s.get('branch') == 'worktree-check'), None)
        self.assertIsNotNone(session, 'the record remembers no Session on the Topic branch: %r' % record)
        self.assertIs(session.get('worktree_created'), True, session)
        self.assertEqual(session.get('base'), commit, session)

        settled = self.muxify('topic', 'settle', '--kill-sessions', '--remove-worktrees', '--topic', topic_id, pane=pane)
        self.assertEqual(settled.returncode, 0, settled.stderr)
        self.assertFalse(worktree.exists(), 'Settle kept the Worktree that the Topic made')


if __name__ == '__main__':
    unittest.main()
