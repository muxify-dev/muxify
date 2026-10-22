"""Session identity, exact-name launches and explicit move destinations in the running app.

All UI interaction uses existing palette/Sidebar accessibility actions; no menu, keys or focus theft.
The migration check applies only to fixture copies under this Sandbox and reads its throwaway server.
"""
import json
import subprocess
import unittest

from scripts.verify.sandbox import REPO, Sandbox, wait


class SessionIdentity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.paths = s.root/'folders'
        cls.paths.mkdir()
        cls.base = cls.paths/'base'
        cls.base.mkdir()
        (s.root/'config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(cls.paths) + '/*\n')
        cls.base_id = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'base', '-c', str(cls.base), '/bin/zsh -f')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES'])
        s.wait_shown('=base:')

    def tearDown(self):
        if self.s.has('palette-search'):
            self.s.act('action', 'palette-search', 'Close')

    def folder(self, name):
        path = self.paths/name
        path.mkdir(exist_ok=True)
        return path

    def session(self, name, directory, topic=None):
        sid = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, '-c', str(directory), '/bin/zsh -f')
        if topic:
            self.s.tmux('set-option', '-t', sid, '@muxify_topic', topic)
        return sid

    def topic(self, name):
        (self.s.root/'state/muxify/topics').mkdir(exist_ok=True)
        (self.s.root/('state/muxify/topics/' + name + '.json')).write_text(json.dumps(dict(id=name, title=name, slug=name)))
        return name

    def select(self, sid):
        tty = wait(lambda: next((line for line in self.s.tmux('list-clients', '-F', '#{client_tty}|#{client_control_mode}').splitlines()
                                 if line.endswith('|0')), None), 'no terminal client', seconds=10).split('|')[0]
        self.s.tmux('switch-client', '-c', tty, '-t', sid + ':')
        self.s.wait_shown(sid + ':')

    def search(self, query, key):
        if not self.s.has('palette-search'):
            self.s.act('press', 'Go to…')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'palette did not open')
        self.s.act('set', 'palette-search', query)
        return self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no palette row ' + key)

    def name(self, sid):
        return self.s.tmux('display-message', '-p', '-t', sid + ':', '#{session_name}')

    def test_exact_name_launch_is_not_occupied_by_a_topic_session_in_same_folder(self):
        path = self.folder('exact-launch')
        topic = self.topic('exact-topic')
        sid = self.session('debug/exact-topic', path, topic)
        key = 'palette-row-session-path:' + str(path)
        for mode in ['topics', 'sessions']:
            self.s.act('press', 'sidebar-view-' + mode)
            rows = self.search('exact', key)
            self.assertTrue(self.s.has('palette-row-session:' + sid, rows), self.s.ids(rows))
            self.s.act('action', 'palette-search', 'Close')
        self.search('exact-launch', key)
        self.s.act('press', key)
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=exact-launch').returncode == 0, 'exact launch name not created', seconds=10)
        self.assertEqual(self.name(sid), 'debug/exact-topic')
        self.s.wait_shown('=exact-launch:')

    def test_exact_name_elsewhere_reuses_the_running_row_and_new_session_stays_no_topic(self):
        path = self.folder('named-elsewhere')
        sid = self.session('named-elsewhere', self.base)
        key = 'palette-row-session:' + sid
        rows = self.search('named-elsewhere', key)
        self.assertFalse(self.s.has('palette-row-session-path:' + str(path), rows))
        self.s.act('press', key)
        self.s.wait_shown(sid + ':')
        self.search('named-elsewhere', key)
        self.s.act('action', key, 'New Session')
        self.s.wait_shown('=named-elsewhere+2:')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=named-elsewhere+2:', '@muxify_topic'), '')

    def test_new_session_on_topic_member_keeps_scope_and_base_with_same_folder(self):
        topic = self.topic('repeat-topic')
        path = self.folder('repeat-folder')
        sid = self.session('debug/repeat-topic', path, topic)
        key = 'palette-row-session:' + sid
        self.search('debug/repeat-topic', key)
        self.s.act('action', key, 'New Session')
        self.s.wait_shown('=debug+2/repeat-topic:')
        self.assertEqual(self.s.tmux('show-options', '-qv', '-t', '=debug+2/repeat-topic:', '@muxify_topic'), topic)
        file = self.s.root/('state/muxify/topics/' + topic + '.json')
        saved = wait(lambda: (data if len((data := json.loads(file.read_text())).get('sessions', [])) == 2 else None), 'two Sessions not remembered', seconds=10)
        self.assertEqual(len({row['id'] for row in saved['sessions']}), 2)
        self.assertEqual({row['base_name'] for row in saved['sessions']}, {'debug', 'debug+2'})

    def test_window_move_chooses_a_session_when_topic_has_two_in_the_same_folder(self):
        topic = self.topic('destination-topic')
        path = self.folder('destination-folder')
        one = self.session('one/destination-topic', path, topic)
        two = self.session('two/destination-topic', path, topic)
        source = self.session('move-source', path)
        self.select(source)
        self.s.act('press', 'sidebar-view-topics')
        window = self.s.tmux('display-message', '-p', '-t', source + ':', '#{window_id}')
        row = 'topic-window-' + window
        self.s.reveal(row)
        self.s.act('action', row, 'Move Window to Topic…')
        key = 'palette-row-topic-' + topic
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'no Topic destination')
        self.s.act('press', key)
        chosen = 'palette-row-destination-' + two
        rows = self.s.wait_rows(lambda rs: self.s.has(chosen, rs), 'no destination Session step')
        self.assertTrue(self.s.has('palette-row-destination-' + one, rows))
        self.assertTrue(self.s.has('palette-row-new-session', rows))
        self.s.act('press', chosen)
        wait(lambda: self.s.tmux('display-message', '-p', '-t', window, '#{session_id}') == two, 'Window did not move to chosen Session', seconds=10)

    def test_confirmed_last_closure_empties_record_while_server_remains(self):
        topic = self.topic('closed-topic')
        sid = self.session('debug/closed-topic', self.base, topic)
        self.select(sid)
        file = self.s.root/('state/muxify/topics/' + topic + '.json')
        wait(lambda: bool(json.loads(file.read_text()).get('sessions')), 'live Session not remembered', seconds=10)
        self.select(self.base_id)
        self.s.tmux('kill-session', '-t', sid)
        wait(lambda: json.loads(file.read_text()).get('sessions') == [], 'confirmed closure left a resurrectable Session', seconds=10)

class TopicMigration(unittest.TestCase):
    def setUp(self):
        self.s = Sandbox('session_identity_migration')
        self.addCleanup(self.s.teardown)
        self.base = self.s.root/'folder'
        self.base.mkdir()

    def session(self, name, directory, topic):
        sid = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, '-c', str(directory), '/bin/zsh -f')
        self.s.tmux('set-option', '-t', sid, '@muxify_topic', topic)

    def test_migration_dry_run_backup_live_names_and_idempotent_apply(self):
        state = self.s.root/'migration'
        (state/'topics').mkdir(parents=True)
        topic = 'migration-topic'
        self.session('actual-debug/migration-topic', self.base, topic)
        record = dict(id=topic, slug=topic, home_project=str(self.base), future=True,
                      sessions=[dict(project_path=str(self.base), windows=[])])
        file = state/('topics/' + topic + '.json')
        file.write_text(json.dumps(record))
        script = REPO/'scripts/migrate-topic-sessions.sh'
        command = ['bash', str(script), '--state-dir', str(state), '--socket', str(self.s.socket)]
        before = file.read_bytes()
        dry = subprocess.run(command + ['--dry-run'], env=self.s.env, capture_output=True, text=True, check=True)
        self.assertIn('actual-debug/migration-topic', dry.stdout)
        self.assertEqual(file.read_bytes(), before)
        self.assertEqual(list(state.glob('*before*')), [])
        subprocess.run(command + ['--apply'], env=self.s.env, capture_output=True, text=True, check=True)
        saved = json.loads(file.read_text())
        self.assertNotIn('home_project', saved)
        self.assertEqual(saved['sessions'][0]['name'], 'actual-debug/migration-topic')
        self.assertEqual(saved['sessions'][0]['base_name'], 'actual-debug')
        self.assertEqual(next(state.glob('*before*')).joinpath(file.name).read_bytes(), before)
        after = file.read_bytes()
        result = subprocess.run(command + ['--apply'], env=self.s.env, capture_output=True, text=True, check=True)
        self.assertIn('0 Topic file(s)', result.stdout)
        self.assertEqual(file.read_bytes(), after)

    def test_inactive_fallbacks_allocate_before_suffix_keep_layout_and_unowned_worktrees(self):
        state = self.s.root/'migration-fallbacks'
        (state/'topics').mkdir(parents=True)
        file = state/'topics/fallback.json'
        layout = [dict(name='editor', directory='/missing/repo/tree/src', future_window=7)]
        file.write_text(json.dumps(dict(id='fallback', slug='fix', home_project='/missing/repo', future_topic=True,
            sessions=[dict(project_path='/missing/repo', worktree_path='/missing/repo/tree', branch='fix', windows=layout),
                      dict(project_path='/missing/repo', worktree_path='/missing/repo/tree', branch='fix', windows=layout)])))
        command = ['bash', str(REPO/'scripts/migrate-topic-sessions.sh'), '--state-dir', str(state), '--no-tmux']
        result = subprocess.run(command + ['--dry-run'], env=self.s.env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.count('FALLBACK (inactive'), 2)
        subprocess.run(command + ['--apply'], env=self.s.env, capture_output=True, text=True, check=True)
        record = json.loads(file.read_text())
        self.assertTrue(record['future_topic'])
        self.assertEqual([s['name'] for s in record['sessions']], ['repo/tree/fix', 'repo/tree+2/fix'])
        self.assertEqual(len({s['id'] for s in record['sessions']}), 2)
        for row in record['sessions']:
            self.assertNotIn('project_path', row)
            self.assertEqual(row['repository_path'], '/missing/repo')
            self.assertFalse(row['worktree_created'])
            self.assertEqual(row['windows'], layout)
        again = subprocess.run(command + ['--apply'], env=self.s.env, capture_output=True, text=True, check=True)
        self.assertIn('0 Topic file(s)', again.stdout)

    def test_invalid_record_prevents_every_replacement(self):
        state = self.s.root/'migration-invalid'
        (state/'topics').mkdir(parents=True)
        good = state/'topics/a.json'
        good.write_text(json.dumps(dict(id='a', home_project='/missing/repo', sessions=[])))
        (state/'topics/z.json').write_text(json.dumps(dict(id='z', sessions=[{}])))
        before = good.read_bytes()
        result = subprocess.run(['bash', str(REPO/'scripts/migrate-topic-sessions.sh'), '--state-dir', str(state),
                                 '--no-tmux', '--apply'], env=self.s.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no launch directory', result.stderr)
        self.assertEqual(good.read_bytes(), before)
        self.assertEqual(list(state.glob('*before*')), [])

    def test_inventory_failure_requires_explicit_no_tmux(self):
        state = self.s.root/'migration-offline'
        (state/'topics').mkdir(parents=True)
        file = state/'topics/offline.json'
        file.write_text(json.dumps(dict(id='offline', home_project='/missing/repo', sessions=[])))
        before = file.read_bytes()
        result = subprocess.run(['bash', str(REPO/'scripts/migrate-topic-sessions.sh'), '--state-dir', str(state),
                                 '--socket', str(self.s.socket), '--apply'], env=self.s.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--no-tmux', result.stderr)
        self.assertEqual(file.read_bytes(), before)
