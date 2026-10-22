"""The muxify topic, window and agent commands of the command line tool that the Debug app bundles, on the sandbox's
tmux server.

The checks run the tool as a user does in a shell, without the app: the Topic commands change the Topic records and
tmux in the tool's own process. Nothing here starts the app or takes the focus.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_cli
"""

import json
import os
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

    def new_topic(self, title, directory, pane):
        """A Topic with a Session in `directory`, as two bricks: an Empty Topic, then Add a Session."""
        made = self.muxify('topic', 'new', title, '--json', pane=pane)
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = json.loads(made.stdout)['changed']['topic_id']
        added = self.muxify('topic', 'add-session', str(directory), '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)
        return topic_id

    def test_help_lists_each_verb_once_and_every_verb_gives_help(self):
        result = self.muxify('--help', pane='')
        self.assertEqual(result.returncode, 0, result.stderr)
        synopses = [line[7:] for line in result.stdout.splitlines() if line.startswith(('usage: muxify ', '       muxify '))]
        paths = [' '.join(word for word in line.split()[1:3] if word[0].isalpha()) for line in synopses]
        self.assertEqual(len(paths), len(set(paths)), 'a verb is listed twice: %s' % paths)
        for path in ['topic new', 'topic add-session', 'window move', 'session lock', 'agent conversation']:
            self.assertIn(path, paths)
        for path in paths:
            verb = self.muxify(*path.split(), '--help', pane='')
            self.assertEqual((verb.returncode, verb.stdout), (0, result.stdout), path + ' --help')

    def test_topic_forget_removes_live_and_settled_topics(self):
        project = self.projects/'cli-forget'
        project.mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        for settled in [False, True]:
            topic = self.new_topic('Forget CLI', str(project), pane=pane)
            self.assertTrue(self.s.tmux('display-message', '-p', '#{socket_path}').startswith(str(self.s.root) + '/'))
            if settled:
                result = self.muxify('topic', 'settle', '--topic', topic, pane=pane)
                self.assertEqual(result.returncode, 0, result.stderr)
            result = self.muxify('topic', 'forget', '--topic', topic, '--json', pane=pane)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.s.root/'state/muxify/topics'/(topic + '.json')).exists())
            self.assertNotEqual(self.s.tmux_ok('has-session', '-t', '=cli-forget/forget-cli').returncode, 0)

    def test_topic_new_outside_tmux_makes_an_empty_topic_that_topic_list_shows(self):
        sessions = self.s.tmux('list-sessions', '-F', '#{session_id}')
        made = self.muxify('topic', 'new', 'CLI check', '--json', pane='')
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = json.loads(made.stdout)['changed']['topic_id']
        record = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertEqual((record.get('title'), record.get('sessions', [])), ('CLI check', []), record)
        self.assertEqual(self.s.tmux('list-sessions', '-F', '#{session_id}'), sessions, 'topic new started a Session')

        listed = self.muxify('topic', 'list', pane='')
        self.assertEqual(listed.returncode, 0, listed.stderr)
        self.assertIn(topic_id + '\tCLI check\t', listed.stdout.splitlines(), 'topic list does not show the new Topic')

    def test_each_old_form_of_topic_new_fails_and_names_the_new_form(self):
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        records = sorted((self.s.root/'state/muxify/topics').glob('*.json')) if (self.s.root/'state/muxify/topics').exists() else []
        for args, named in [(['topic', 'new'], 'muxify window move --new-topic'),
                            (['topic', 'new', '--pane', pane], 'muxify window move --new-topic'),
                            (['topic', 'new', 'Old form', '--directory', str(self.s.root)], 'muxify topic add-session')]:
            result = self.muxify(*args, pane=pane)
            self.assertEqual(result.returncode, 2, args)
            self.assertIn(named, result.stderr, args)
        after = sorted((self.s.root/'state/muxify/topics').glob('*.json')) if (self.s.root/'state/muxify/topics').exists() else []
        self.assertEqual(after, records, 'an old form wrote a Topic record')

    def test_window_move_new_topic_moves_the_window_into_a_new_titled_topic(self):
        self.s.tmux('new-session', '-d', '-s', 'cli-new-topic', '-c', str(self.s.root))
        window = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', '=cli-new-topic:', '-c', str(self.s.root))
        caller = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        moved = self.muxify('window', 'move', '--new-topic', 'Moved here', '--window', window, '--json', pane=caller)
        self.assertEqual(moved.returncode, 0, moved.stderr)
        topic_id = json.loads(moved.stdout)['changed']['topic_id']
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', window, '@muxify_topic'), topic_id, 'the Window is not in the new Topic')
        record = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertEqual(record.get('title'), 'Moved here', record)
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=base:', '@muxify_topic'), '', 'the caller Window stays outside')

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
        topic_id = self.new_topic('Show check', str(self.projects/'cli-show-home'), pane=pane)
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
        topic_id = self.new_topic('Agents check', str(self.projects/'cli-agents'), pane=pane)
        agent = self.fake_agent('cli-agents/agents-check', 'done', unread=True)

        listed = self.muxify('agent', 'list', '--unread', '--json', pane=pane)
        self.assertEqual(listed.returncode, 0, listed.stderr)
        row = next((r for r in json.loads(listed.stdout)['agents'] if r['pane_id'] == agent), None)
        self.assertIsNotNone(row, 'agent list --unread does not show the Unread Agent: %s' % listed.stdout)
        self.assertEqual(row['agent'], {'kind': 'claude', 'status': 'done', 'unread': True, 'conversation': None}, row)
        self.assertEqual(row['topic'], {'id': topic_id, 'label': 'Agents check', 'pinned': False, 'tags': []}, row)

        text = self.muxify('agent', 'list', '--topic', 'Agents check', pane=pane)
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertEqual(text.stdout, '\t'.join([agent, 'claude', 'done', 'unread', 'Agents check', 'cli-agents/agents-check']) + '\n')

    def test_agent_conversation_reads_the_transcript_of_a_panes_agent_without_its_tool_entries(self):
        (self.projects/'cli-conversation').mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        self.new_topic('Conversation check', self.projects/'cli-conversation', pane=pane)
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
        topic_id = self.new_topic('Move check', str(self.projects/'cli-move'), pane=caller)
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
        topic_id = self.new_topic('Exec check', str(self.projects/'cli-exec-home'), pane=pane)
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
        topic_id = self.new_topic('Git check', str(plain), pane=pane)
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
        topic_id = self.new_topic('Worktree check', str(home), pane=pane)

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


    def topic_sessions(self, topic_id, pane):
        shown = self.muxify('topic', 'show', '--topic', topic_id, '--json', pane=pane)
        self.assertEqual(shown.returncode, 0, shown.stderr)
        return [s['name'] for s in json.loads(shown.stdout)['topic']['sessions']]

    def test_topic_rename_then_settle_reopen_and_start_fresh_bring_the_session_back(self):
        (self.projects/'cli-reopen').mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        topic_id = self.new_topic('Reopen check', str(self.projects/'cli-reopen'), pane=pane)
        renamed = self.muxify('topic', 'rename', 'Reopen renamed', '--topic', topic_id, pane=pane)
        self.assertEqual((renamed.returncode, renamed.stdout.strip()), (0, topic_id), renamed.stderr)
        record = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertEqual(record.get('title'), 'Reopen renamed', record)

        for verb in ('reopen', 'start-fresh'):
            settled = self.muxify('topic', 'settle', '--kill-sessions', '--topic', topic_id, pane=pane)
            self.assertEqual(settled.returncode, 0, settled.stderr)
            self.assertEqual(self.s.tmux('list-sessions', '-F', '#{@muxify_topic}').split().count(topic_id), 0, 'Settle kept a Session')
            reopened = self.muxify('topic', verb, '--topic', topic_id, pane=pane)
            self.assertEqual(reopened.returncode, 0, verb + ': ' + reopened.stderr)
            self.assertEqual(len(self.topic_sessions(topic_id, pane)), 1, verb + ' made no Session')

        missing = self.muxify('topic', 'reopen', pane=pane)
        self.assertEqual(missing.returncode, 2)
        self.assertIn('topic reopen takes the Topic: --topic <id|label>', missing.stderr)

    def test_session_remove_from_topic_with_kill_removes_the_worktree_that_the_topic_made_and_keeps_the_branch(self):
        home = self.projects/'cli-rk-home'
        home.mkdir(parents=True)
        repository = self.projects/'cli-rk-repo'
        self.git('init', '-q', '-b', 'main', str(repository), cwd=self.s.root)
        self.git('commit', '-q', '--allow-empty', '-m', 'first', cwd=repository)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        topic_id = self.new_topic('Remove kill', str(home), pane=pane)
        added = self.muxify('topic', 'add-session', str(repository), '--worktree', '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)
        worktree = self.s.root/'state/muxify/worktrees/cli-rk-repo/remove-kill'
        self.assertTrue(worktree.is_dir(), 'add-session --worktree made no Worktree at %s' % worktree)

        removed = self.muxify('session', 'remove-from-topic', '--kill', '--remove-worktree', '--session', 'cli-rk-repo/remove-kill', pane=pane)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertNotEqual(self.s.tmux_ok('has-session', '-t', '=cli-rk-repo/remove-kill').returncode, 0, 'the Session still runs')
        self.assertFalse(worktree.exists(), 'the Worktree that the Topic made is still there')
        self.assertEqual(self.git('branch', '--list', 'remove-kill', cwd=repository), 'remove-kill', 'the branch is gone')
        self.assertEqual(self.topic_sessions(topic_id, pane), ['cli-rk-home/remove-kill'])

        again = self.muxify('session', 'remove-from-topic', '--kill', '--remove-worktree', '--session', 'cli-rk-home/remove-kill', pane=pane)
        self.assertEqual(again.returncode, 1)
        self.assertIn('no Worktree that Muxify made', again.stderr)
        self.assertEqual(self.s.tmux_ok('has-session', '-t', '=cli-rk-home/remove-kill').returncode, 0, 'a failed request killed the Session')

    def test_session_and_window_remove_from_topic_leave_them_running_in_no_topic(self):
        for name in ('cli-rm-home', 'cli-rm-tools'):
            (self.projects/name).mkdir(parents=True)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')
        topic_id = self.new_topic('Remove check', str(self.projects/'cli-rm-home'), pane=pane)
        added = self.muxify('topic', 'add-session', str(self.projects/'cli-rm-tools'), '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)

        session_id = self.s.tmux('display-message', '-p', '-t', '=cli-rm-tools/remove-check:', '#{session_id}')
        removed = self.muxify('session', 'remove-from-topic', '--session', 'cli-rm-tools/remove-check', pane=pane)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertEqual(self.topic_sessions(topic_id, pane), ['cli-rm-home/remove-check'])
        self.assertIn(session_id, self.s.tmux('list-sessions', '-F', '#{session_id}').split(), 'the removed Session stopped')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', session_id + ':', '@muxify_topic'), '', 'the Session is still in a Topic')

        window = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', '=cli-rm-home/remove-check:')
        into_topic = self.muxify('window', 'remove-from-topic', '--window', window, '--session', 'cli-rm-home/remove-check', pane=pane)
        self.assertEqual(into_topic.returncode, 1, 'a Session in a Topic is no destination')
        self.assertIn('is in the Topic', into_topic.stderr)
        moved = self.muxify('window', 'remove-from-topic', '--window', window, '--new-session', pane=pane)
        self.assertEqual(moved.returncode, 0, moved.stderr)
        session = self.s.tmux('display-message', '-p', '-t', window, '#{session_name}')
        self.assertNotEqual(session, 'cli-rm-home/remove-check', 'the Window did not leave the Session')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', window, '@muxify_topic'), '', 'the Window is still in a Topic')

    def test_the_incident_a_branch_moves_to_a_new_topic_on_a_worktree_that_settle_removes_and_the_branch_stays(self):
        repository = self.projects/'cli-incident'
        self.git('init', '-q', '-b', 'main', str(repository), cwd=self.s.root)
        self.git('commit', '-q', '--allow-empty', '-m', 'first', cwd=repository)
        self.git('branch', 'hover-titles', cwd=repository)
        commit = self.git('rev-parse', 'hover-titles', cwd=repository)
        pane = self.s.tmux('display-message', '-p', '-t', '=base:', '#{pane_id}')

        made = self.muxify('topic', 'new', 'Hover titles', '--json', pane='')
        self.assertEqual(made.returncode, 0, made.stderr)
        topic_id = json.loads(made.stdout)['changed']['topic_id']
        taken = self.muxify('topic', 'add-session', str(repository), '--worktree', '--branch', 'main', '--topic', topic_id, pane=pane)
        self.assertEqual(taken.returncode, 1, 'main is checked out in the repository')
        self.assertIn('checked out in the Worktree', taken.stderr)
        added = self.muxify('topic', 'add-session', str(repository), '--worktree', '--branch', 'hover-titles', '--topic', topic_id, pane=pane)
        self.assertEqual(added.returncode, 0, added.stderr)
        worktree = self.s.root/'state/muxify/worktrees/cli-incident/hover-titles'
        self.assertEqual(self.git('symbolic-ref', '--short', 'HEAD', cwd=worktree), 'hover-titles')
        record = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertEqual([(s.get('branch'), s.get('worktree_created'), s.get('base')) for s in record['sessions']],
                         [('hover-titles', True, commit)], record)

        settled = self.muxify('topic', 'settle', '--kill-sessions', '--remove-worktrees', '--topic', topic_id, pane=pane)
        self.assertEqual(settled.returncode, 0, settled.stderr)
        self.assertFalse(worktree.exists(), 'Settle kept the Worktree that Muxify made')
        self.assertEqual(self.git('rev-parse', 'hover-titles', cwd=repository), commit, 'Settle changed or deleted the branch')

    def test_add_session_json_gives_the_ids_of_the_session_window_and_pane_that_it_made(self):
        (self.projects/'cli-ids').mkdir(parents=True)
        made = self.muxify('topic', 'new', 'Ids check', '--json', pane='')
        topic_id = json.loads(made.stdout)['changed']['topic_id']
        added = self.muxify('topic', 'add-session', str(self.projects/'cli-ids'), '--topic', topic_id, '--json', pane='')
        self.assertEqual(added.returncode, 0, added.stderr)
        changed = json.loads(added.stdout)['changed']
        self.assertEqual(changed['session_name'], 'cli-ids/ids-check', changed)
        found = self.s.tmux('display-message', '-p', '-t', changed['pane'], '#{session_id} #{window_id} #{pane_id} #{@muxify_topic}')
        self.assertEqual(found, ' '.join([changed['session'], changed['window'], changed['pane'], topic_id]))

    def test_window_new_in_a_topic_goes_to_its_only_session_and_fails_with_none_or_several(self):
        for name in ('cli-wn-home', 'cli-wn-tools'):
            (self.projects/name).mkdir(parents=True)
        empty = json.loads(self.muxify('topic', 'new', 'Window empty', '--json', pane='').stdout)['changed']['topic_id']
        none = self.muxify('window', 'new', '--topic', empty, pane='')
        self.assertEqual(none.returncode, 1)
        self.assertIn('muxify topic add-session <dir> --topic ' + empty, none.stderr)

        topic_id = self.new_topic('Window one', self.projects/'cli-wn-home', pane='')
        marker = self.s.root/'window-new-ran'
        made = self.muxify('window', 'new', '--topic', topic_id, '--json', '--', 'sh', '-c', 'pwd > ' + str(marker) + '; sleep 600', pane='')
        self.assertEqual(made.returncode, 0, made.stderr)
        changed = json.loads(made.stdout)['changed']
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', changed['window'], '#{session_name}'), 'cli-wn-home/window-one')
        wait(lambda: marker.exists() and marker.read_text().strip(), 'the command did not run in the new Window', seconds=10)
        self.assertEqual(os.path.realpath(marker.read_text().strip()), os.path.realpath(self.projects/'cli-wn-home'))

        added = self.muxify('topic', 'add-session', str(self.projects/'cli-wn-tools'), '--topic', topic_id, pane='')
        self.assertEqual(added.returncode, 0, added.stderr)
        windows = self.s.tmux('list-windows', '-a', '-F', '#{window_id}')
        several = self.muxify('window', 'new', '--topic', topic_id, pane='')
        self.assertEqual(several.returncode, 1)
        self.assertIn('Choose one with --session', several.stderr)
        self.assertIn('cli-wn-tools/window-one ($', several.stderr)
        self.assertEqual(self.s.tmux('list-windows', '-a', '-F', '#{window_id}'), windows, 'a failed window new made a Window')

    def test_session_new_starts_a_no_topic_session_and_a_taken_name_gets_plus_two(self):
        (self.projects/'cli-sn').mkdir(parents=True)
        names = []
        for _ in range(2):
            made = self.muxify('session', 'new', str(self.projects/'cli-sn'), '--json', pane='')
            self.assertEqual(made.returncode, 0, made.stderr)
            changed = json.loads(made.stdout)['changed']
            names.append(changed['session_name'])
            self.assertEqual(self.s.tmux('show-options', '-qv', '-t', changed['session'] + ':', '@muxify_topic'), '', 'the Session is in a Topic')
        self.assertEqual(names, ['cli-sn', 'cli-sn+2'])
        named = self.muxify('session', 'new', str(self.projects/'cli-sn'), '--name', 'cli-sn-debug', pane='')
        self.assertEqual(named.returncode, 0, named.stderr)
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', named.stdout.strip(), '#{session_name}'), 'cli-sn-debug')

    def test_session_and_window_rename_keep_the_topic_slug(self):
        (self.projects/'cli-rn').mkdir(parents=True)
        topic_id = self.new_topic('Rename tmux', self.projects/'cli-rn', pane='')
        pane = self.s.tmux('display-message', '-p', '-t', '=cli-rn/rename-tmux:', '#{pane_id}')
        renamed = self.muxify('session', 'rename', 'cli-renamed', pane=pane)
        self.assertEqual((renamed.returncode, renamed.stdout.strip()), (0, 'cli-renamed/rename-tmux'), renamed.stderr)
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', pane, '#{session_name} #{@muxify_topic}'),
                         'cli-renamed/rename-tmux ' + topic_id)
        window = self.muxify('window', 'rename', 'cli-logs', '--pane', pane, pane='')
        self.assertEqual(window.returncode, 0, window.stderr)
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', pane, '#{window_id} #{window_name}'), window.stdout.strip() + ' cli-logs')

    def test_window_kill_and_session_kill_from_their_own_pane_and_the_last_session_leaves_the_topic_empty(self):
        (self.projects/'cli-kill').mkdir(parents=True)
        topic_id = self.new_topic('Kill check', self.projects/'cli-kill', pane='')
        window = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', '=cli-kill/kill-check:')
        pane = self.s.tmux('display-message', '-p', '-t', window, '#{pane_id}')
        self.s.tmux('respawn-pane', '-k', '-t', pane, str(CLI) + ' window kill')
        wait(lambda: window not in self.s.tmux('list-windows', '-a', '-F', '#{window_id}').split(), 'window kill from its own Pane left the Window')

        # The kill closes the Pane that runs the CLI, so the record must be written before the kill.
        pane = self.s.tmux('display-message', '-p', '-t', '=cli-kill/kill-check:', '#{pane_id}')
        self.s.tmux('respawn-pane', '-k', '-t', pane, str(CLI) + ' session kill')
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=cli-kill/kill-check').returncode != 0, 'session kill from its own Pane left the Session')
        record = json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text())
        self.assertEqual((record.get('settled_at'), record.get('sessions', [])), (None, []), 'the Topic is not open and Empty')

        (self.projects/'cli-kill-json').mkdir(parents=True)
        other = self.new_topic('Kill json', self.projects/'cli-kill-json', pane='')
        killed = self.muxify('session', 'kill', '--session', 'cli-kill-json/kill-json', '--json', pane='')
        self.assertEqual(killed.returncode, 0, killed.stderr)
        self.assertEqual(json.loads(killed.stdout)['changed']['topic_id'], other)

    def topic_list(self):
        listed = self.muxify('topic', 'list', '--json', pane='')
        self.assertEqual(listed.returncode, 0, listed.stderr)
        return json.loads(listed.stdout)['topics']

    def test_topic_pin_puts_the_topic_first_in_topic_list_and_unpin_puts_it_first_among_the_others(self):
        first, second = (json.loads(self.muxify('topic', 'new', title, '--json', pane='').stdout)['changed']['topic_id']
                         for title in ('Pin first', 'Pin second'))
        pinned = self.muxify('topic', 'pin', '--topic', second, pane='')
        self.assertEqual(pinned.returncode, 0, pinned.stderr)
        topics = self.topic_list()
        self.assertEqual((topics[0]['id'], topics[0]['pinned']), (second, True), topics)

        unpinned = self.muxify('topic', 'unpin', '--topic', second, pane='')
        self.assertEqual(unpinned.returncode, 0, unpinned.stderr)
        ids = [topic['id'] for topic in self.topic_list()]
        self.assertFalse(any(topic['pinned'] for topic in self.topic_list()), 'a Pin stays')
        self.assertLess(ids.index(second), ids.index(first), ids)

    def test_zen_start_snoozes_the_other_topics_zen_end_restores_them_and_settle_of_the_kept_topic_ends_zen(self):
        kept, quiet = (json.loads(self.muxify('topic', 'new', title, '--json', pane='').stdout)['changed']['topic_id']
                       for title in ('Zen kept', 'Zen quiet'))
        zen_file = self.s.root/'state/muxify/zen.json'
        snoozed = lambda id: json.loads((self.s.root/'state/muxify/topics'/(id + '.json')).read_text()).get('snoozed_until')

        started = self.muxify('zen', 'start', '2h', '--topic', kept, '--json', pane='')
        self.assertEqual(started.returncode, 0, started.stderr)
        self.assertIn(quiet, json.loads(started.stdout)['snooze_changed']['topic_ids'])
        self.assertNotIn(kept, json.loads(started.stdout)['snooze_changed']['topic_ids'])
        self.assertIsNotNone(snoozed(quiet), 'Zen did not Snooze the other Topic')
        self.assertIsNone(snoozed(kept), 'Zen Snoozed the kept Topic')
        again = self.muxify('zen', 'start', 'forever', '--topic', quiet, pane='')
        self.assertEqual(again.returncode, 1)
        self.assertIn('Zen is on', again.stderr)

        ended = self.muxify('zen', 'end', pane='')
        self.assertEqual(ended.returncode, 0, ended.stderr)
        self.assertIsNone(snoozed(quiet), 'zen end did not give back the earlier Snooze')
        self.assertFalse(zen_file.exists(), 'zen end left the Zen record')
        self.assertEqual(self.muxify('zen', 'end', pane='').returncode, 0, 'zen end without Zen failed')

        self.assertEqual(self.muxify('zen', 'start', '2h', '--topic', kept, pane='').returncode, 0)
        settled = self.muxify('topic', 'settle', '--topic', kept, pane='')
        self.assertEqual(settled.returncode, 0, settled.stderr)
        self.assertFalse(zen_file.exists(), 'Settle of the kept Topic left Zen on')
        self.assertIsNone(snoozed(quiet))

    def test_topic_move_steps_over_a_snoozed_topic_and_fails_at_the_end_or_for_the_snoozed_topic(self):
        top, snoozed, moved = (json.loads(self.muxify('topic', 'new', title, '--json', pane='').stdout)['changed']['topic_id']
                               for title in ('Move top', 'Move snoozed', 'Move moved'))
        self.assertEqual(self.muxify('topic', 'snooze', '1d', '--topic', snoozed, pane='').returncode, 0)

        up = self.muxify('topic', 'move', 'up', '--topic', moved, pane='')
        self.assertEqual(up.returncode, 0, up.stderr)
        ids = [topic['id'] for topic in self.topic_list()]
        self.assertEqual(ids[-3:], [moved, top, snoozed], 'the card did not step over the Snoozed Topic: %s' % ids)

        before = self.topic_list()
        at_end = self.muxify('topic', 'move', 'down', '--topic', top, '--json', pane='')
        self.assertEqual(at_end.returncode, 1, at_end.stderr)
        self.assertEqual(json.loads(at_end.stdout)['failed']['kind'], 'card_at_end', at_end.stdout)
        hidden = self.muxify('topic', 'move', 'up', '--topic', snoozed, '--json', pane='')
        self.assertEqual((hidden.returncode, json.loads(hidden.stdout)['failed']['kind']), (1, 'card_hidden'), hidden.stdout)
        self.assertEqual(self.topic_list(), before, 'a failed move changed the order')

    def test_session_move_steps_a_session_among_its_topics_sessions_and_topic_sort_sessions_gives_back_the_creation_order(self):
        for name in ('cli-order-a', 'cli-order-b'):
            (self.projects/name).mkdir(parents=True)
        topic_id = self.new_topic('Session order', self.projects/'cli-order-a', pane='')
        added = self.muxify('topic', 'add-session', str(self.projects/'cli-order-b'), '--topic', topic_id, pane='')
        self.assertEqual(added.returncode, 0, added.stderr)
        cards = [topic['id'] for topic in self.topic_list()]
        def order():
            shown = self.muxify('topic', 'show', '--topic', topic_id, '--json', pane='')
            self.assertEqual(shown.returncode, 0, shown.stderr)
            return [session['name'] for session in json.loads(shown.stdout)['topic']['sessions']]
        created = ['cli-order-a/session-order', 'cli-order-b/session-order']
        self.assertEqual(order(), created)

        up = self.muxify('session', 'move', 'up', '--session', created[1], pane='')
        self.assertEqual(up.returncode, 0, up.stderr)
        self.assertEqual(order(), created[::-1], 'session move up did not step the Session')
        self.assertEqual([topic['id'] for topic in self.topic_list()], cards, 'session move moved a Topic card')
        at_end = self.muxify('session', 'move', 'up', '--session', created[1], '--json', pane='')
        self.assertEqual((at_end.returncode, json.loads(at_end.stdout)['failed']['kind']), (1, 'session_at_end'), at_end.stdout)
        self.assertEqual(order(), created[::-1], 'a failed move changed the order')

        pane = self.s.tmux('display-message', '-p', '-t', '=' + created[0] + ':', '#{pane_id}')
        sorted_ = self.muxify('topic', 'sort-sessions', pane=pane)
        self.assertEqual((sorted_.returncode, sorted_.stdout.strip()), (0, topic_id), sorted_.stderr)
        self.assertEqual(order(), created, 'topic sort-sessions did not give back the creation order')

    def test_mark_read_verbs_change_the_topic_and_each_agent_in_their_scope_and_mark_all_read_clears_both(self):
        (self.projects/'cli-read').mkdir(parents=True)
        topic_id = self.new_topic('Read check', self.projects/'cli-read', pane='')
        done = self.fake_agent('cli-read/read-check', 'done')
        working = self.fake_agent('cli-read/read-check', 'working')
        other = self.fake_agent('base', 'done')
        record_unread = lambda: json.loads((self.s.root/'state/muxify/topics'/(topic_id + '.json')).read_text()).get('unread', False)
        agent_unread = lambda pane: self.s.tmux('display-message', '-p', '-t', pane, '#{@muxify_agent_unread}') == '1'
        state = lambda: (record_unread(), agent_unread(done), agent_unread(working), agent_unread(other))

        marked = self.muxify('topic', 'mark-unread', '--topic', topic_id, '--json', pane='')
        self.assertEqual(marked.returncode, 0, marked.stderr)
        self.assertEqual(json.loads(marked.stdout)['read_changed'], {'topic_ids': [topic_id], 'pane_ids': [done]}, marked.stdout)
        self.assertEqual(state(), (True, True, False, False), 'Mark Unread changes the Topic and each Agent in it that is not working')

        read = self.muxify('agent', 'mark-read', pane=done)
        self.assertEqual(read.returncode, 0, read.stderr)
        self.assertEqual(state(), (True, False, False, False), 'agent mark-read changes only the Agent of its Pane')

        window = self.muxify('window', 'mark-unread', '--pane', done, pane='')
        self.assertEqual(window.returncode, 0, window.stderr)
        self.assertEqual(state(), (True, True, False, False), 'window mark-unread changes only the Agents of that Window')

        self.assertEqual(self.muxify('agent', 'mark-unread', pane=other).returncode, 0)
        cleared = self.muxify('mark-all-read', '--json', pane='')
        self.assertEqual(cleared.returncode, 0, cleared.stderr)
        self.assertEqual(state(), (False, False, False, False), 'mark-all-read left an Unread')

    def test_topic_open_and_window_open_hand_the_app_the_url_of_their_target_and_fail_without_one(self):
        fake = self.s.root/'fake-open'
        fake.mkdir()
        opened = fake/'opened'
        (fake/'open').write_text('#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' % opened)
        (fake/'open').chmod(0o755)
        env = {'PATH': '%s:%s' % (fake, self.s.env.get('PATH', os.environ['PATH']))}
        encoded = lambda value: ''.join('%%%02x' % byte for byte in value.encode())
        (self.projects/'cli-open').mkdir(parents=True)
        topic_id = self.new_topic('Open view', self.projects/'cli-open', pane='')
        pane, window = self.s.tmux('display-message', '-p', '-t', '=cli-open/open-view:', '#{pane_id} #{window_id}').split()

        for args, caller in [(('topic', 'open'), pane), (('topic', 'open', '--topic', 'Open view'), ''),
                             (('window', 'open'), pane), (('window', 'open', '--window', window), '')]:
            result = self.muxify(*args, pane=caller, env=env)
            self.assertEqual((result.returncode, result.stdout), (0, ''), '%s: %s' % (args, result.stderr))
        self.assertEqual(opened.read_text().splitlines(), ['muxify://select?topic=' + encoded(topic_id)] * 2
                         + ['muxify://select?window=' + encoded(window)] * 2)

        for args in [('topic', 'open', '--topic', 'No such topic'), ('window', 'open', '--window', '@9999'), ('window', 'open')]:
            result = self.muxify(*args, pane='', env=env)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertTrue(result.stderr.strip(), args)
        self.assertEqual(len(opened.read_text().splitlines()), 4, 'a failed view verb opened a URL')

    def test_window_move_before_and_after_reorders_the_windows_of_a_session_and_fails_for_another_sessions_window(self):
        self.s.tmux('new-session', '-d', '-s', 'cli-wmv', '-c', str(self.s.root))
        for _ in range(2):
            self.s.tmux('new-window', '-d', '-t', '=cli-wmv:')
        order = lambda: self.s.tmux('list-windows', '-t', '=cli-wmv', '-F', '#{window_id}').split()
        current = lambda: self.s.tmux('display-message', '-p', '-t', '=cli-wmv:', '#{window_id}')
        a, b, c = order()
        shown = current()

        pane = self.s.tmux('display-message', '-p', '-t', c, '#{pane_id}')
        before = self.muxify('window', 'move', '--before', a, pane=pane)
        self.assertEqual((before.returncode, before.stdout.strip()), (0, c), before.stderr)
        self.assertEqual(order(), [c, a, b], 'window move --before from the Window\'s own Pane')

        after = self.muxify('window', 'move', '--after', b, '--window', c, '--json', pane='')
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertEqual(json.loads(after.stdout)['changed']['window'], c, after.stdout)
        self.assertEqual(order(), [a, b, c], 'window move --after --window')
        self.assertEqual(current(), shown, 'the Session changed its current Window')

        other = self.s.tmux('display-message', '-p', '-t', '=base:', '#{window_id}')
        elsewhere = self.muxify('window', 'move', '--before', other, '--window', a, '--json', pane='')
        self.assertEqual((elsewhere.returncode, json.loads(elsewhere.stdout)['failed']['kind']), (1, 'window_not_in_session'), elsewhere.stdout)
        self.assertEqual(order(), [a, b, c], 'a failed move changed the order')


if __name__ == '__main__':
    unittest.main()
