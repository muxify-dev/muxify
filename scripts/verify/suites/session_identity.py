"""Session identity, exact-name launches and explicit move destinations in the running app.

All UI interaction uses existing palette/Sidebar accessibility actions; no menu, keys or focus theft.
"""
import unittest

from scripts.verify.sandbox import Sandbox, wait
from scripts.verify.topic_records import TopicRecords


class SessionIdentity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.store = TopicRecords(s.root/'state/muxify')
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
        self.store.put(dict(id=name, title=name, slug=name))
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
        saved = wait(lambda: (data if len((data := self.store.get(topic)).get('sessions', [])) == 2 else None), 'two Sessions not remembered', seconds=10)
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
        wait(lambda: bool(self.store.get(topic).get('sessions')), 'live Session not remembered', seconds=10)
        self.select(self.base_id)
        self.s.tmux('kill-session', '-t', sid)
        wait(lambda: self.store.get(topic).get('sessions') == [], 'confirmed closure left a resurrectable Session', seconds=10)
