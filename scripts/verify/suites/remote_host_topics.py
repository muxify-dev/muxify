"""A Remote App Window shows its Host's Topics through the Host Server, `muxify server` on a channel of the
attachment's SSH connection.

The SSH fixture runs remote commands locally, as remote_session_end's does: the Host's tmux server is the Sandbox
server, the Host's home is `remote-home`, and the Host's Topics are in `remote-home/.local/state/muxify/muxify.db`,
apart from the Mac's own `state/muxify`. The Host's `muxify` is the first one on the fixture's PATH: the Debug app's
own CLI, which serves, or a stand-in with no server mode, which the app must answer with Sessions only and a reason.
"""

import json
import shlex
import subprocess
import unittest

from scripts.verify.sandbox import DEBUG_APP, Sandbox, wait
from scripts.verify.topic_records import TopicRecords

CLI = DEBUG_APP/'Contents/Resources/bin/muxify'
OLD_BUILD = 'muxify 0123abc 1600000000'


class RemoteHostTopics(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.home = home = s.root/'remote-home'
        (home/'.config/muxify').mkdir(parents=True)
        remote_tmp = s.root/'remote-tmp'
        remote_tmp.mkdir()
        cls.projects = s.root/'host-projects'
        cls.projects.mkdir()
        # The Host's own Config: its Session Paths, where `muxify topic add-session` starts a Session.
        (home/'.config/muxify/config.yaml').write_text('sessions:\n  paths:\n    - path: ' + str(cls.projects) + '/*\n')
        cls.host_store = TopicRecords(home/'.local/state/muxify')
        (s.root/'config/muxify/config.yaml').write_text(
            'remote_environments:\n  - name: Fixture\n    host: unused\n    username: unused\n')

        # The Host's muxify: `serving` links the Debug app's CLI, `old` holds a CLI from before `muxify server`.
        cls.bins = {'serving': s.root/'bin-serving', 'old': s.root/'bin-old'}
        for directory in cls.bins.values():
            directory.mkdir()
        (cls.bins['serving']/'muxify').symlink_to(CLI)
        old = cls.bins['old']/'muxify'
        old.write_text('#!/bin/sh\ncase "$1" in\n    --version) echo %s ;;\n    *) echo "muxify: unknown command $1" >&2; exit 2 ;;\nesac\n'
                       % shlex.quote(OLD_BUILD))
        old.chmod(0o755)
        cls.host_bin = s.root/'host-bin'

        fake = s.root/'ssh'
        fake.write_text('''#!/bin/bash
unset TMUX TMUX_PANE XDG_CONFIG_HOME XDG_STATE_HOME
export TMUX_TMPDIR=%s TMPDIR=%s HOME=%s PATH=%s:"$PATH"
for arg do
    if [ "$arg" = -O ]; then exit 0; fi
    if [ "$arg" = -tt ]; then exec 2>&1; fi
    command=$arg
done
exec /bin/sh -c "$command"
''' % tuple(shlex.quote(str(p)) for p in [s.root/'tmux', remote_tmp, home, cls.host_bin]))
        fake.chmod(0o755)
        s.app_env['MUXIFY_TEST_SSH'] = str(fake)
        # The install chain finds a CLI on the PATH; an old one would be updated from here, which serves nothing.
        s.app_env['MUXIFY_CLI_BASE_URL'] = 'http://127.0.0.1:9/'
        cls.mode = None
        s.tmux('new-session', '-d', '-s', 'start', '-c', str(cls.projects), '/bin/sh')
        # A Topic that the Host CLI wrote before the app started.
        cls.before_launch = cls.new_topic('Before Launch', 'before-launch')

    @classmethod
    def host_muxify(cls, *args):
        """Runs the Debug app's CLI as an Agent on the Host would: the Host's home, its tmux server, no Mac state."""
        environment = {k: v for k, v in cls.s.env.items() if k not in ('TMUX', 'TMUX_PANE', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME')}
        environment.update(HOME=str(cls.home), TMUX_TMPDIR=str(cls.s.root/'tmux'))
        result = subprocess.run([str(CLI), *args], env=environment, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, 'muxify %s failed: %s' % (' '.join(args), result.stderr)
        return result.stdout

    @classmethod
    def new_topic(cls, title, folder):
        """A Topic with one Session, made on the Host by its CLI; returns the Topic's id."""
        (cls.projects/folder).mkdir()
        topic = json.loads(cls.host_muxify('topic', 'new', title, '--json'))['changed']['topic_id']
        cls.host_muxify('topic', 'add-session', str(cls.projects/folder), '--topic', topic)
        return topic

    def use(self, mode):
        """Runs the app on a Host whose muxify is `mode`'s, starting it again when the Host changed."""
        if self.mode == mode and self.s.pid is not None:
            return
        if self.host_bin.is_symlink():
            self.host_bin.unlink()
        self.host_bin.symlink_to(self.bins[mode])
        args = ('-selectedEnvironment', 'Fixture', '-sidebarVisible', 'YES', '-sessionsVisible', 'YES')
        if self.s.pid is None:
            self.s.launch(args=args)
        else:
            self.s.restart_app(args=args)
        type(self).mode = mode

    def topic_row(self, topic, message):
        return self.s.wait_rows(lambda rs: self.s.has('topic-' + topic, rs), message, seconds=30)

    def test_a_remote_app_window_shows_the_topics_that_muxify_topic_wrote_on_the_host(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Remote App Window does not show the Host\'s Topic')
        self.assertIsNone(TopicRecords(self.s.root/'state/muxify').get(self.before_launch),
                          'the Mac keeps a copy of the Host\'s Topic')

    def test_a_topic_written_on_the_host_appears_without_a_palette_action(self):
        self.use('serving')
        self.topic_row(self.before_launch, 'the Remote App Window does not show the Host\'s Topics')
        live = self.new_topic('Written Live', 'written-live')
        self.topic_row(live, 'a Topic that the Host CLI wrote does not appear in the Sidebar')

    def test_a_topic_action_from_the_palette_changes_the_hosts_database(self):
        self.use('serving')
        topic = self.new_topic('Pin From Mac', 'pin-from-mac')
        self.topic_row(topic, 'the Host\'s Topic does not appear')
        window = next(line.split()[0] for line in self.s.tmux('list-windows', '-a', '-F', '#{window_id} #{@muxify_topic}').splitlines()
                      if line.split()[1:] == [topic])
        # The Terminal's Client moves to the Topic's Window, as tmux navigation on the Host does.
        tty = next(line.split()[1] for line in self.s.tmux('list-clients', '-F', '#{client_control_mode} #{client_tty}').splitlines()
                   if line.startswith('0 '))
        self.s.tmux('switch-client', '-c', tty, '-t', window)
        # A Remote App Window's title names its Environment too, so the selected row says that it shows the Window.
        self.s.wait_rows(lambda rs: self.s.row('topic-window-' + window, rs).get('accessibilityValue') == 'selected',
                         'the app does not show the Topic\'s Window', seconds=20)
        wait(lambda: self.s.driver('press', 'Commands')['pressed'], 'Commands did not open')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'the Commands field did not show')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Pin Topic')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-command-Pin Topic', rs), 'Pin Topic is missing from Commands')
        self.s.act('press', 'palette-row-command-Pin Topic')
        wait(lambda: self.host_store.get(topic).get('pinned') is True, 'Pin Topic did not Pin the Topic in the Host\'s database')

    def test_a_host_whose_muxify_has_no_server_mode_shows_sessions_only_and_why(self):
        self.use('old')
        expected = 'Topics are unavailable on Fixture: the Host\'s muxify is too old (%s).' % OLD_BUILD
        def note(rs):
            row = self.s.row('topics-unavailable', rs)
            return (row.get('accessibilityLabel', '') + row.get('accessibilityValue', '')) == expected
        rs = self.s.wait_rows(note, 'the Sidebar does not say why Topics are unavailable', seconds=30)
        self.assertFalse(self.s.has('topic-' + self.before_launch, rs), 'a Sessions-only window shows a Topic')
        self.assertTrue(any(r.get('accessibilityIdentifier', '').startswith('session-window-') for r in rs),
                        'a Sessions-only window shows no Session')


if __name__ == '__main__':
    unittest.main()
