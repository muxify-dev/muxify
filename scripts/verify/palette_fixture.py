"""The fixture and helpers of the palette suites that start Commands: one Session Path, Topic records and live Sessions.

PaletteFixture has no checks. Each suite subclasses it, so each suite makes its own Sandbox and app.

The driver cannot type keys. run_command opens Commands from its View menu item, and a check calls the search
field's accessibility actions for the keys (UI/CommandPaletteView.swift).
"""

import json
import unittest

from scripts.verify.sandbox import Sandbox, remove_topic, wait

SHELL = '/bin/zsh -f'


class PaletteFixture(unittest.TestCase):
    # The YAML of `topics.tags`: Tag name to its value, in Config order. Empty leaves Tags off.
    TAGS = {}

    @classmethod
    def config_text(cls, tags=None):
        tags = cls.TAGS if tags is None else tags
        text = 'sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n'
        if tags:
            text += 'topics:\n  tags:\n' + ''.join('    %s: %s\n' % (name, value) for name, value in tags.items())
        return text

    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(cls.__module__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.project = s.root/'projects/palette'
        cls.project.mkdir(parents=True)
        cls.topics = s.root/'state/muxify/topics'
        cls.topics.mkdir(parents=True, exist_ok=True)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text(cls.config_text())
        cls.base = s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', 'base', '-c', str(cls.project), SHELL)
        s.tmux('set-option', '-g', 'detach-on-destroy', 'off')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES'])

    def setUp(self):
        if self.s.has('palette-search'):
            self.s.act('action', 'palette-search', 'Close')
        if self.s.row('sidebar-view-topics').get('accessibilityValue') != 'selected':
            self.s.act('press', 'sidebar-view-topics')
        self.select(self.base)

    def select(self, window):
        for client in self.s.tmux('list-clients', '-F', '#{client_tty} #{client_control_mode}').splitlines():
            if client.endswith(' 0'):
                self.s.tmux('switch-client', '-c', client.split()[0], '-t', window)
        self.s.wait_shown(window)

    def topic(self, name, order=None, session=False, **fields):
        """A Topic record, and with `session` a live Session in it; returns that Session's Window."""
        path = self.topics/(name + '.json')
        record = dict(id=name, title=name, slug=name)
        if order is not None:
            record['order'] = order
        path.write_text(json.dumps(dict(record, **fields)))
        self.addCleanup(remove_topic, path)
        if not session:
            return None
        window = self.s.tmux('new-session', '-d', '-P', '-F', '#{window_id}', '-s', name, '-c', str(self.project), SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', name)
        self.s.tmux('set-option', '-t', name, '@muxify_topic', name)
        self.addCleanup(self.select, self.base)
        return window

    def records(self):
        return [json.loads(path.read_text()) for path in self.topics.glob('*.json')]

    def record(self, name):
        return json.loads((self.topics/(name + '.json')).read_text())

    def text(self, key, rs):
        row = self.s.row(key, rs)
        return row.get('accessibilityLabel', '') + row.get('accessibilityValue', '')

    def search(self, title):
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'the Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', title)
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == title,
                         'Commands did not keep the query')

    def run_command(self, title):
        self.search(title)
        key = 'palette-row-command-' + title
        self.s.wait_rows(lambda rs: self.s.has(key, rs), title + ' was missing from Commands')
        self.s.act('press', key)
