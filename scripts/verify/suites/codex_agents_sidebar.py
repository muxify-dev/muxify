import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import unittest
import uuid

from scripts.verify.sandbox import REPO, Sandbox, wait


class CodexAgentsSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        codex = shutil.which('codex')
        if not codex:
            raise unittest.SkipTest('Codex CLI is not installed')
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.home = s.root/'home'
        cls.codex_home = cls.home/'.codex'
        cls.codex_home.mkdir(parents=True)
        # Cleanups run last in, first out: Codex's daemon stops before the Sandbox's sweep.
        cls.addClassCleanup(cls.stop_daemon, codex)
        s.env['HOME'] = s.app_env['HOME'] = str(cls.home)
        cls.codex_env = dict(
            HOME=str(cls.home), CODEX_HOME=str(cls.codex_home),
            PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin', TERM='xterm-256color',
            XDG_STATE_HOME=s.env['XDG_STATE_HOME'], TMUX_TMPDIR=s.env['TMUX_TMPDIR'],
            OPENAI_API_KEY='verify-not-a-real-key',
            HTTP_PROXY='http://127.0.0.1:1', HTTPS_PROXY='http://127.0.0.1:1',
            ALL_PROXY='http://127.0.0.1:1', NO_PROXY='127.0.0.1,localhost')
        package = pathlib.Path(codex).resolve().parent.parent
        cached = pathlib.Path(os.environ.get('CODEX_HOME', str(pathlib.Path.home()/'.codex')))/'packages/app-server-daemon/current'
        source = package if (package/'codex-package.json').is_file() else cached.resolve()
        if (source/'bin/codex').is_file():
            daemon = cls.codex_home/'packages/app-server-daemon'
            daemon.mkdir(parents=True)
            (daemon/'current').symlink_to(source, target_is_directory=True)
        (cls.codex_home/'config.toml').write_text('''model = "verify"
model_provider = "verify"
check_for_update_on_startup = false
[tui]
terminal_title = ["thread-id", "app-name"]
[model_providers.verify]
name = "Verification only"
base_url = "http://127.0.0.1:1/v1"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
[projects.%s]
trust_level = "trusted"
''' % json.dumps(str(s.root)))
        cls.extension = s.root/'muxify-status.sh'
        shutil.copyfile(REPO/'extensions/codex/muxify-status.sh', cls.extension)
        (cls.codex_home/'hooks.json').write_text(json.dumps(dict(hooks={
            event: [dict(hooks=[dict(type='command', command='/bin/sh '+shlex.quote(str(cls.extension)))])]
            for event in ['SessionStart', 'UserPromptSubmit']
        })))
        (s.root/'config/muxify/config.yaml').write_text('sidebar:\n  agents_scope: all\n')
        s.tmux('new-session', '-d', '-s', 'codex-agents', '-n', 'away', '/bin/sh')
        cls.panes = []
        cls.titles = []
        cls.conversations = []
        for name in ['one', 'two']:
            pane = s.tmux('new-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'codex-agents',
                          '-n', name, '-c', str(s.root), '/bin/sh')
            cls.panes.append(pane)
            s.tmux('pipe-pane', '-O', '-t', pane, 'cat > '+shlex.quote(str(s.root/'logs'/('codex-'+name+'.bin'))))
            command = ['env', '-i', *[key+'='+value for key, value in cls.codex_env.items()],
                       codex, '--no-alt-screen', '-C', str(s.root)]
            s.tmux('send-keys', '-t', pane, shlex.join(command), 'Enter')
            if name == 'one':
                wait(lambda: 'Hooks need review' in s.tmux('capture-pane', '-p', '-t', pane),
                     'Codex did not ask to trust the isolated Extension')
                s.tmux('send-keys', '-t', pane, 'Down', 'Enter')
                wait(lambda: (cls.codex_home/'config.toml').read_text().count('trusted_hash') == 2,
                     'Codex did not save trust for the two isolated Extension hooks')
            def ready():
                title = s.tmux('display-message', '-p', '-t', pane, '#{pane_title}')
                return title if re.match(r'^[0-9a-f-]{29}\.\.\. \| codex$', title) else None
            title = wait(ready, 'Codex did not publish its conversation in its title; see logs/codex-'+name+'.bin', 30)
            cls.titles.append(title)
            s.tmux('send-keys', '-t', pane, '-l', '/status')
            wait(lambda: '/status' in s.tmux('capture-pane', '-p', '-t', pane), 'Codex did not read /status')
            s.tmux('send-keys', '-t', pane, 'Enter')
            def conversation():
                screen = s.tmux('capture-pane', '-p', '-t', pane, '-S', '-200')
                (s.root/'logs'/('codex-'+name+'-status.txt')).write_text(screen)
                matches = re.findall(r'\b'+re.escape(title[:29])+r'[0-9a-f]{7}\b', screen)
                return matches[0] if matches else None
            cls.conversations.append(wait(conversation, 'Codex /status did not show its full conversation ID'))
        daemon_pid = json.loads((cls.codex_home/'app-server-daemon/daemon.pid').read_text())['pid']
        command = subprocess.check_output(['ps', '-p', str(daemon_pid), '-o', 'command='], text=True)
        assert '--managed-daemon' in command, command
        (s.root/'logs/runtime.json').write_text(json.dumps(dict(
            daemon_pid=daemon_pid, panes=cls.panes, titles=cls.titles, conversations=cls.conversations)))
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES',
                  '-sidebarWorkView', 'Sessions'])

    @classmethod
    def stop_daemon(cls, codex):
        """Stops the app-server daemon that Codex starts for this CODEX_HOME, through Codex's own command, then by
        the PID it recorded. The daemon ignores SIGTERM for longer than the Sandbox waits."""
        try:
            pid = json.loads((cls.codex_home/'app-server-daemon/daemon.pid').read_text())['pid']
        except (FileNotFoundError, ValueError, KeyError):
            return
        environment = dict(cls.s.env, HOME=str(cls.home), CODEX_HOME=str(cls.codex_home))
        try:
            subprocess.run([codex, 'app-server', 'daemon', 'stop'], env=environment, capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            pass
        if subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout.count('--managed-daemon'):
            cls.s._terminate([pid])

    def setUp(self):
        for pane, title, conversation in zip(self.panes, self.titles, self.conversations):
            self.s.tmux('select-pane', '-t', pane, '-T', title)
            self.report(conversation, 'SessionStart')
        self.wait_statuses([None, None])

    def report(self, conversation, event, **fields):
        payload = dict(session_id=conversation, hook_event_name=event, cwd=str(self.s.root), **fields)
        result = subprocess.run(['/bin/sh', str(self.extension)], input=json.dumps(payload),
                                env=self.codex_env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '', 'The Extension must not add text to the Agent context')

    def wait_statuses(self, statuses):
        expected = ['Codex — '+(status or 'no status yet') for status in statuses]
        rows = self.s.wait_rows(
            lambda rs: all(self.s.row('agent-'+pane, rs).get('accessibilityHelp', '').split(',')[0] == help_text
                           for pane, help_text in zip(self.panes, expected)),
            'Codex Agent Status does not match '+repr(statuses))
        for pane, help_text in zip(self.panes, expected):
            self.assertEqual(self.s.row('agent-'+pane, rows)['accessibilityHelp'].split(',')[0], help_text)
        cli = self.s.app/'Contents/Resources/bin/muxify'
        result = subprocess.run([str(cli), 'agent', 'list', '--json'], env=self.s.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        agents = {row['pane_id']: row['agent'] for row in json.loads(result.stdout)['agents']}
        for pane, status in zip(self.panes, statuses):
            self.assertEqual(agents[pane].get('status'), status)
        return rows

    def test_two_default_daemon_clients_have_separate_status(self):
        self.assertNotEqual(self.conversations[0], self.conversations[1])
        self.report(self.conversations[0], 'UserPromptSubmit')
        self.report(self.conversations[1], 'PermissionRequest')
        self.wait_statuses(['working', 'blocked'])
        self.report(self.conversations[0], 'Stop')
        self.wait_statuses(['done', 'blocked'])
        self.report(self.conversations[1], 'UserPromptSubmit')
        self.wait_statuses(['done', 'working'])

    def test_running_codex_is_an_agent_before_its_first_report(self):
        for conversation in self.conversations:
            (self.home/'.local/state/muxify/codex'/(conversation+'.json')).unlink(missing_ok=True)
        self.wait_statuses([None, None])

    def test_real_daemon_prompt_hook_reports_only_its_conversation(self):
        report = self.home/'.local/state/muxify/codex'/(self.conversations[0]+'.json')
        report.unlink(missing_ok=True)
        prompt = 'Verify the local provider connection only.'
        self.s.tmux('send-keys', '-t', self.panes[0], '-l', prompt)
        wait(lambda: prompt in self.s.tmux('capture-pane', '-p', '-t', self.panes[0]),
             'Codex did not read the verification prompt')
        self.s.tmux('send-keys', '-t', self.panes[0], 'Enter')
        def working_report():
            record = json.loads(report.read_text())
            return record if record.get('status') == 'working' else None
        record = wait(working_report, 'The real Codex daemon did not run the Extension for its prompt')
        self.assertEqual(record, dict(version=1, conversation=self.conversations[0], status='working'))
        (self.s.root/'logs/real-hook-report.json').write_text(json.dumps(record))
        self.wait_statuses(['working', None])

    def test_shell_with_stale_codex_title_is_not_an_agent(self):
        pane = self.s.tmux('new-window', '-d', '-P', '-F', '#{pane_id}', '-t', 'codex-agents',
                           '-n', 'stale-title', '/bin/sh')
        self.s.tmux('select-pane', '-t', pane, '-T', self.titles[0])
        self.s.tmux('set-option', '-p', '-t', pane, '@muxify_agent', 'codex',
                    ';', 'set-option', '-p', '-t', pane, '@muxify_agent_status', 'blocked')
        self.report(self.conversations[0], 'UserPromptSubmit')
        rows = self.wait_statuses(['working', None])
        self.assertFalse(self.s.has('agent-'+pane, rows), 'A shell inherited the previous Codex Agent')
        self.s.tmux('send-keys', '-t', pane, 'exec sleep 600', 'Enter')
        wait(lambda: self.s.tmux('display-message', '-p', '-t', pane, '#{pane_current_command}') == 'sleep',
             'The stale Pane did not start sleep')
        self.report(self.conversations[0], 'Stop')
        rows = self.wait_statuses(['done', None])
        self.assertFalse(self.s.has('agent-'+pane, rows), 'sleep inherited the previous Codex Agent')

    def test_synthetic_conversation_switch_uses_report_that_arrived_before_title(self):
        conversation = str(uuid.uuid4())
        self.report(self.conversations[0], 'Stop')
        self.report(conversation, 'PermissionRequest')
        self.wait_statuses(['done', None])
        self.s.tmux('select-pane', '-t', self.panes[0], '-T', conversation[:29]+'... | codex')
        self.wait_statuses(['blocked', None])
        self.report(conversation, 'UserPromptSubmit')
        self.wait_statuses(['working', None])
