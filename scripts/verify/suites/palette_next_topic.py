"""Settle shows and opens the next Topic in Sidebar order."""

import json
import unittest

from scripts.verify.sandbox import Sandbox, frame, remove_topic, wait

SHELL = '/bin/zsh -f'


class PaletteNextTopic(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.project = s.root/'projects/next'
        cls.project.mkdir(parents=True)
        cls.topics = s.root/'state/muxify/topics'
        cls.topics.mkdir(parents=True, exist_ok=True)
        (s.root/'config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n')
        cls.base = s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'base', '-c', str(cls.project), SHELL)
        s.tmux('set-option', '-g', 'detach-on-destroy', 'off')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES'])

    def select_window(self, window):
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').splitlines():
            if tty.endswith(' 0'):
                self.s.tmux('switch-client', '-c', tty.split()[0], '-t', window)
        self.s.wait_shown(window)

    def check_next(self, placement):
        s = self.s
        prefix = 'settle-' + placement
        names = [prefix + '-' + str(i) for i in range(1 if placement == 'none' else 3)]
        windows = {}
        for index, name in enumerate(names):
            (self.topics/(name + '.json')).write_text(json.dumps(dict(
                id=name, title=name, slug=name, home_project=str(self.project),
                created_at='2026-01-0%dT00:00:00Z' % (index + 1))))
            self.addCleanup(remove_topic, self.topics/(name + '.json'))
            sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name,
                          '-c', str(self.project), SHELL)
            s.tmux('set-option', '-t', sid, '@muxify_topic', name)
            windows[name] = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
            self.addCleanup(s.tmux_ok, 'kill-session', '-t', sid)
        self.addCleanup(self.select_window, self.base)
        s.wait_rows(lambda rs: s.has('sidebar-view-topics', rs), 'The Sidebar did not show')
        if s.row('sidebar-view-topics').get('accessibilityValue') != 'selected':
            s.act('press', 'sidebar-view-topics')
        rs = s.wait_rows(lambda rs: all(s.has('topic-' + name, rs) for name in names), 'The Topic cards did not show')
        order = sorted(names, key=lambda name: -frame(s.row('topic-' + name, rs))[1])
        current = order[-1] if placement == 'above' else order[0]
        expected = order[-2] if placement == 'above' else order[1] if placement == 'below' else None
        self.select_window(windows[current])
        wait(lambda: s.driver('press', 'Settle Topic…')['pressed'], 'Settle stayed disabled')
        s.wait_rows(lambda rs: any(key.startswith('palette-row-session-') for key in s.ids(rs)),
                    'Settle choices did not load')
        rs = s.wait_rows(lambda rs: s.has('palette-note', rs), 'The next Topic preview did not show')
        note = s.row('palette-note', rs)
        self.assertIn('Then opens: ' + (expected or 'No Topic'),
                      note.get('accessibilityLabel', '') + note.get('accessibilityValue', ''))
        s.act('press', 'palette-accept')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Settle did not close the palette')
        if expected:
            s.wait_shown(windows[expected])
            rs = s.wait_rows(lambda rs: s.row('topic-window-' + windows[expected], rs).get('accessibilityValue') == 'selected',
                             'Settle did not select the next Topic Window')
            self.assertEqual(s.row('topic-window-' + windows[expected], rs).get('accessibilityValue'), 'selected')
        else:
            # Settle kills the Topic's Session by default (ADR 0047), so the client goes to the No Topic Session.
            s.wait_shown(self.base)
            sid = s.tmux('display-message', '-p', '-t', self.base, '#{session_id}')
            rs = s.wait_rows(lambda rs: s.has('no-topic-session-' + sid, rs), 'Settle did not show the No Topic card')
            self.assertTrue(s.has('no-topic-session-' + sid, rs))
            wait(lambda: s.tmux_ok('has-session', '-t', '=' + current).returncode != 0,
                 'Settle did not kill the Session of the Topic')
        record = json.loads((self.topics/(current + '.json')).read_text())
        self.assertTrue(record.get('settled_at'), record)

    def test_settle_opens_the_topic_below(self):
        self.check_next('below')

    def test_settle_opens_the_topic_above_at_the_end(self):
        self.check_next('above')

    def test_settle_opens_no_topic_when_no_other_topic_remains(self):
        self.check_next('none')


if __name__ == '__main__':
    unittest.main()
