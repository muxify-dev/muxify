import unittest

from scripts.verify.sandbox import Sandbox
from scripts.verify.topic_records import TopicRecords


class AgentFormatsSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.config = s.root / 'config/muxify/config.yaml'
        cls.config.write_text('sidebar:\n  agents_scope: all\n')
        store = TopicRecords(s.root/'state/muxify')
        store.put(dict(id='formats', title='Format Topic', slug='formats'))
        cls.session, cls.window, cls.pane = s.tmux(
            'new-session', '-d', '-P', '-F', '#{session_id} #{window_id} #{pane_id}',
            '-s', 'format-session', '-n', 'stable-window', 'sleep 600').split()
        s.tmux('set-option', '-t', cls.session, '@muxify_topic', 'formats')
        s.tmux('set-window-option', '-t', cls.window, 'automatic-rename', 'off')
        s.tmux('set-option', '-p', '-t', cls.pane, '@muxify_agent', 'claude')
        s.tmux('set-option', '-p', '-t', cls.pane, '@muxify_agent_status', 'working')
        s.tmux('select-pane', '-t', cls.pane, '-T', 'Agent task')
        cls.other = s.tmux('split-window', '-d', '-t', cls.window, '-P', '-F', '#{pane_id}', 'sleep 600')
        s.tmux('select-pane', '-t', cls.other, '-T', 'Other task')
        cls.key = 'agent-' + cls.pane
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES',
                  '-sidebarWorkView', 'Topics'])

    def setUp(self):
        self.config.write_text('sidebar:\n  agents_scope: all\n')
        self.s.tmux('set-option', '-t', self.session, '@muxify_topic', 'formats')
        self.s.tmux('select-pane', '-t', self.pane, '-T', 'Agent task')
        self.s.tmux('select-pane', '-t', self.pane)
        self.show_mode('topics')
        self.wait_text('Agent task, Format Topic')

    def show_mode(self, mode):
        key = 'sidebar-view-' + mode
        self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Sidebar mode control is missing')
        if self.s.row(key).get('accessibilityValue') != 'selected':
            self.s.act('press', key)
        self.s.wait_rows(lambda rs: self.s.row(key, rs).get('accessibilityValue') == 'selected',
                         'Sidebar mode did not change to ' + mode)

    def text(self, rows):
        return self.s.row(self.key, rows).get('accessibilityValue', '')

    def wait_text(self, expected):
        rows = self.s.wait_rows(lambda rs: self.text(rs) == expected, 'Agent text differs from ' + expected)
        self.assertEqual(self.text(rows), expected)
        return rows

    def test_defaults_keep_topic_session_and_scope_text(self):
        for mode, group in [('topics', 'Format Topic'), ('sessions', 'format-session')]:
            self.show_mode(mode)
            self.config.write_text('sidebar:\n  agents_scope: all\n')
            self.wait_text('Agent task, ' + group)
            for scope in ['active', 'window']:
                self.config.write_text('sidebar:\n  agents_scope: ' + scope + '\n')
                self.wait_text('Agent task')
                if scope == 'window':
                    rows = self.s.wait_rows(
                        lambda rs: self.s.row('agents-header', rs).get('accessibilityValue') == 'Agents · Agent task',
                        'Default Agents header did not use the Window title')
                    self.assertEqual(self.s.row('agents-header', rows).get('accessibilityValue'), 'Agents · Agent task')
        self.show_mode('topics')
        self.config.write_text('sidebar:\n  agents_scope: all\n')
        self.s.tmux('set-option', '-u', '-t', self.session, '@muxify_topic')
        self.wait_text('Agent task, No Topic')

    def test_custom_formats_keep_summary_in_scoped_sections(self):
        self.config.write_text("""sidebar:
  agents_scope: window
  formats:
    agent:
      title:
        topics: '#{topic_title}'
        sessions: '#{window_name}'
      summary: '#{session_name} / #{agent_status}'
""")
        for mode, title in [('topics', 'Format Topic'), ('sessions', 'stable-window')]:
            self.show_mode(mode)
            self.wait_text(title + ', format-session / working')
        self.config.write_text("""sidebar:
  agents_scope: window
  formats:
    agent:
      title: '#{window_name}'
      summary: ''
""")
        self.wait_text('stable-window')

    def test_agent_context_stays_with_its_pane_when_selection_and_title_change(self):
        self.config.write_text("""sidebar:
  agents_scope: all
  formats:
    agent:
      title: '#{window_name} / #{topic_title}'
      summary: '#{pane_label} / #{pane_active_flag}'
""")
        for mode in ['topics', 'sessions']:
            self.show_mode(mode)
            for selected, active in [(self.pane, '1'), (self.other, '0')]:
                self.s.tmux('select-pane', '-t', selected)
                self.s.tmux('select-pane', '-t', self.pane, '-T', 'Changed Agent task')
                self.wait_text('stable-window / Format Topic, Changed Agent task / ' + active)

    def test_window_scoped_header_keeps_formatted_window_name_when_pane_changes(self):
        self.config.write_text("""sidebar:
  agents_scope: window
  formats:
    window:
      title: '#{window_index}:#{window_name}'
    agent:
      title: '#{?topic_title,#{topic_title},#{window_name}}'
      summary: '#{pane_label} / #{pane_active_flag}'
""")
        index = self.s.tmux('display-message', '-p', '-t', self.window, '#{window_index}')
        expected = 'Agents · ' + index + ':stable-window'
        for mode in ['topics', 'sessions']:
            self.show_mode(mode)
            for selected, active in [(self.pane, '1'), (self.other, '0')]:
                title = 'Changed task ' + mode + ' ' + active
                self.s.tmux('select-pane', '-t', self.pane, '-T', title)
                self.s.tmux('select-pane', '-t', selected)
                rows = self.wait_text('Format Topic, ' + title + ' / ' + active)
                self.assertEqual(self.s.row('agents-header', rows).get('accessibilityValue'), expected)
