"""Snooze and Settle show and open the next Topic in Sidebar order."""

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
        if self.s.has('empty-no-topic'):
            wait(lambda: self.s.driver('press', 'Go to…')['pressed'], 'Go to did not open')
            self.s.act('focus', 'palette-search')
            self.s.act('set', 'palette-search', 'Hidden base')
            key = 'palette-row-topic-hidden-base'
            self.s.wait_rows(lambda rs: self.s.has(key, rs), 'The base Topic did not show in Go to')
            self.s.act('press', key)
        for tty in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').splitlines():
            if tty.endswith(' 0'):
                self.s.tmux('switch-client', '-c', tty.split()[0], '-t', window)
        self.s.wait_shown(window)

    def check_next(self, action, placement, empty=False):
        s = self.s
        prefix = action.lower() + '-' + placement
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
        if action == 'Snooze':
            wait(lambda: s.driver('press', 'Go to…')['pressed'], 'Go to did not open')
            key = 'palette-row-topic-' + current
            s.wait_rows(lambda rs: s.has(key, rs), 'The active Topic did not show in Go to')
            s.act('action', key, 'Snooze Topic')
            s.wait_rows(lambda rs: s.has('palette-row-never', rs), 'Snooze choices did not show')
        else:
            wait(lambda: s.driver('press', 'Settle Topic…')['pressed'], 'Settle stayed disabled')
            s.wait_rows(lambda rs: any(key.startswith('palette-row-session-') for key in s.ids(rs)),
                        'Settle choices did not load')
        rs = s.wait_rows(lambda rs: s.has('palette-note', rs), 'The next Topic preview did not show')
        note = s.row('palette-note', rs)
        self.assertIn('Then opens: ' + (expected or 'No Topic'),
                      note.get('accessibilityLabel', '') + note.get('accessibilityValue', ''))
        if action == 'Snooze':
            s.act('press', 'palette-row-never')
        else:
            s.act('press', 'palette-accept')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), action + ' did not close the palette')
        if expected:
            s.wait_shown(windows[expected])
            rs = s.wait_rows(lambda rs: s.row('topic-window-' + windows[expected], rs).get('accessibilityValue') == 'selected',
                             action + ' did not select the next Topic Window')
            self.assertEqual(s.row('topic-window-' + windows[expected], rs).get('accessibilityValue'), 'selected')
        elif empty:
            rs = s.wait_rows(lambda rs: s.has('empty-no-topic', rs), action + ' did not show empty No Topic')
            self.assertTrue(s.has('empty-no-topic', rs))
        else:
            # Settle keeps the Session with no Topic (ADR 0036), so No Topic shows it. Snooze leaves it in its Topic.
            shown = windows[current] if action == 'Settle' else self.base
            s.wait_shown(shown)
            sid = s.tmux('display-message', '-p', '-t', shown, '#{session_id}')
            rs = s.wait_rows(lambda rs: s.has('no-topic-session-' + sid, rs), action + ' did not show the No Topic card')
            self.assertTrue(s.has('no-topic-session-' + sid, rs))
            if action == 'Settle':
                self.assertEqual(s.tmux('show-option', '-qv', '-t', sid, '@muxify_topic'), '',
                                 'Settle with Keep left the Session in the Topic')
        record = json.loads((self.topics/(current + '.json')).read_text())
        self.assertTrue(record.get('snoozed_until' if action == 'Snooze' else 'settled_at'), record)

    def test_snooze_shows_empty_no_topic_when_every_session_has_a_topic(self):
        hidden = self.topics/'hidden-base.json'
        hidden.write_text(json.dumps(dict(id='hidden-base', title='Hidden base', slug='hidden-base',
                                          home_project=str(self.project), snoozed_until='never')))
        self.addCleanup(remove_topic, hidden)
        sid = self.s.tmux('display-message', '-p', '-t', self.base, '#{session_id}')
        self.s.tmux('set-option', '-t', sid, '@muxify_topic', 'hidden-base')
        self.addCleanup(self.s.tmux, 'set-option', '-u', '-t', sid, '@muxify_topic')
        self.check_next('Snooze', 'none', empty=True)

    def test_snooze_opens_the_topic_below(self):
        self.check_next('Snooze', 'below')

    def test_snooze_opens_the_topic_above_at_the_end(self):
        self.check_next('Snooze', 'above')

    def test_snooze_opens_no_topic_when_no_other_topic_remains(self):
        self.check_next('Snooze', 'none')

    def test_settle_opens_the_topic_below(self):
        self.check_next('Settle', 'below')

    def test_settle_opens_the_topic_above_at_the_end(self):
        self.check_next('Settle', 'above')

    def test_settle_opens_no_topic_when_no_other_topic_remains(self):
        self.check_next('Settle', 'none')


if __name__ == '__main__':
    unittest.main()
