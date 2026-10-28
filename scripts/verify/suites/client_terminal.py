"""ClientVerification exposes fixed terminal actions without taking keyboard focus."""

import os
import pathlib
import pty
import shlex
import subprocess
import unittest

from scripts.verify.sandbox import REPO, Sandbox, wait


class ClientTerminal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(cls.sandbox.teardown)
        cls.sandbox.app_env['SHELL'] = '/bin/sh'
        cls.sandbox.app_env['MUXIFY_TERMINAL'] = 'not-muxify'
        cls.sandbox.tmux('new-session', '-d', '-s', 'client', '-c', str(cls.sandbox.root), '/bin/sh',
                         ';', 'set-option', '-g', 'default-shell', '/bin/sh',
                         ';', 'set-option', '-g', 'update-environment',
                         'PATH GHOSTTY_BIN_DIR GHOSTTY_RESOURCES_DIR TERMINFO MUXIFY_TERMINAL')
        cls.sandbox.launch()
        wait(lambda: cls.sandbox.tmux_ok('list-clients').returncode == 0, 'app did not start tmux')
        wait(lambda: '@muxify_client_' in cls.sandbox.tmux('show-options', '-s'),
             'Muxify did not register its first Client')
        docs = (REPO/'docs/configuration.md').read_text()
        snippet = docs.split('```sh\nmuxify_environment()', 1)[1].split('```', 1)[0]
        cls.check = cls.sandbox.root/'check.sh'
        cls.check.write_text('muxify_environment()' + snippet)

    def clients(self):
        output = self.sandbox.tmux('list-clients', '-F', '#{client_pid}|#{client_tty}|#{client_activity}|#{client_control_mode}')
        return {int(pid): dict(tty=tty, activity=int(activity), control=control)
                for pid, tty, activity, control in (line.split('|') for line in output.splitlines())}

    def markers(self):
        options = self.sandbox.tmux('show-options', '-s')
        return {line.split()[0]: self.sandbox.tmux('show-options', '-sqv', line.split()[0]).split('␟')
                for line in options.splitlines() if line.startswith('@muxify_client_')}

    def pane_command(self, pane, command):
        self.sandbox.tmux('send-keys', '-c', '', '-t', pane, 'C-u')
        self.sandbox.tmux('send-keys', '-c', '', '-l', '-t', pane, command)
        self.sandbox.tmux('send-keys', '-c', '', '-t', pane, 'Enter')

    def answer(self, pane):
        result = self.sandbox.root/'answer'
        result.unlink(missing_ok=True)
        self.pane_command(pane, '/bin/sh %s > %s' % (shlex.quote(str(self.check)), shlex.quote(str(result))))
        word = wait(lambda: result.read_text().strip(), 'Pane did not run the check')
        cli = self.sandbox.app/'Contents/Resources/bin/muxify'
        answer = subprocess.run([str(cli), 'browser', 'available'],
                                env=dict(self.sandbox.env, TMUX_PANE=pane), capture_output=True, text=True)
        self.assertEqual(answer.stdout.strip(), word)
        self.assertEqual(answer.returncode, 1 if word == 'no' else 0)
        self.assertEqual(answer.stderr, '')
        return word

    def setUp(self):
        previous = set(self.markers())
        self.sandbox.act('action', 'client-input', 'Reattach Client')
        self.option, self.fields = wait(lambda: next(((key, value) for key, value in self.markers().items()
                                                    if key not in previous), None),
                                       'Muxify did not register its Client')
        self.assertEqual(len(self.fields), 5)
        self.assertEqual(self.fields[4], 'local')
        self.muxify_pid = int(self.fields[0])
        wait(lambda: self.muxify_pid in self.clients(), 'marked Client did not attach')
        self.assertEqual(self.clients()[self.muxify_pid]['tty'], self.fields[1])

    def test_terminal_identifies_itself_when_attaching_to_an_existing_server(self):
        session = self.sandbox.tmux('display-message', '-p', '-c', self.fields[1], '#{session_id}')
        self.assertEqual(self.sandbox.tmux('show-environment', '-t', session, 'MUXIFY_TERMINAL'),
                         'MUXIFY_TERMINAL=1')

    def test_new_pane_uses_bundled_cli_and_resources(self):
        sandbox, fields = self.sandbox, self.fields
        previous_pane = sandbox.tmux('display-message', '-p', '-c', fields[1], '#{pane_id}')
        sandbox.act('action', 'client-input', 'New Window')
        def new_pane():
            pane = sandbox.tmux('display-message', '-p', '-c', fields[1], '#{pane_id}')
            return pane if pane != previous_pane else None
        pane = wait(new_pane, 'Muxify did not create a Window')

        marker = sandbox.root/'terminal-marker'
        self.pane_command(pane, 'printf \'%s\' "$MUXIFY_TERMINAL" > ' + shlex.quote(str(marker)))
        self.assertEqual(wait(lambda: marker.read_text().strip(), 'Pane did not report its terminal marker'), '1')
        result = sandbox.root/'cli-path'
        self.pane_command(pane, 'command -v muxify > ' + shlex.quote(str(result)))
        cli = wait(lambda: result.read_text().strip(), 'Pane did not resolve muxify')
        self.assertEqual(pathlib.Path(cli).resolve(), (sandbox.app/'Contents/Resources/bin/muxify').resolve())
        variables = sandbox.root/'bin-variables'
        self.pane_command(pane, 'printf \'%s\\n%s\\n\' "$GHOSTTY_BIN_DIR" "$PATH" > ' + shlex.quote(str(variables)))
        bin_dir, path = wait(lambda: variables.read_text().splitlines(), 'Pane did not report its PATH')
        self.assertEqual(pathlib.Path(bin_dir).resolve(), (sandbox.app/'Contents/Resources/bin').resolve())
        app_executables = (sandbox.app/'Contents/MacOS').resolve()
        self.assertNotIn(app_executables, [pathlib.Path(entry).resolve() for entry in path.split(':') if entry], path)
        self.pane_command(pane, 'muxify --help > ' + shlex.quote(str(sandbox.root/'cli-help')))
        help_text = wait(lambda: (sandbox.root/'cli-help').read_text().strip(), 'bundled CLI did not return help')
        self.assertIn('usage: muxify browser open', help_text)
        resources = sandbox.root/'resources'
        self.pane_command(pane, 'printf \'%s\\n%s\\n\' "$GHOSTTY_RESOURCES_DIR" "$TERMINFO" > ' + shlex.quote(str(resources)))
        paths = wait(lambda: resources.read_text().splitlines(), 'Pane did not report Ghostty resources')
        self.assertEqual(pathlib.Path(paths[0]).resolve(), (sandbox.app/'Contents/Resources/ghostty').resolve())
        self.assertEqual(pathlib.Path(paths[1]).resolve(), (sandbox.app/'Contents/Resources/terminfo').resolve())
        self.assertTrue((pathlib.Path(paths[1])/'78/xterm-ghostty').is_file())

    def test_muxify_in_a_pane_never_runs_the_app_on_a_server_that_an_older_build_started(self):
        sandbox = self.sandbox
        # Before the bundled CLI, libghostty gave the tmux client Contents/MacOS in PATH. A client that is
        # not attached gives its PATH to the Pane that new-session makes, and APFS ignores case.
        app_executables = str(sandbox.app/'Contents/MacOS')
        sandbox.tmux('new-session', '-d', '-s', 'older-build', '-c', str(sandbox.root),
                     env=dict(PATH='/usr/bin:/bin:' + app_executables))
        self.addCleanup(sandbox.tmux, 'kill-session', '-t', 'older-build')
        pane = sandbox.tmux('display-message', '-p', '-t', 'older-build:', '#{pane_id}')

        result = sandbox.root/'older-build-muxify'
        self.pane_command(pane, 'printf \'%s\\n%s\\n\' "$PATH" "$(command -v muxify)" > ' + shlex.quote(str(result)))
        path, cli = wait(lambda: (lambda lines: lines if len(lines) == 2 else None)(result.read_text().split('\n')[:2]),
                         'Pane did not resolve muxify')
        self.assertIn(app_executables, path.split(':'), 'the Pane did not get the older build\'s PATH')
        self.assertEqual(cli, '', 'muxify resolved to the app in Contents/MacOS: %s' % os.listdir(app_executables))

    def type_in_plain_client(self, session):
        """Attaches a plain tmux Client, as Ghostty.app would, and types into it until it is the newest Client."""
        master, slave = pty.openpty()
        os.set_blocking(master, False)
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        plain = self.sandbox.tmux_client(session, slave)
        def stop_plain():
            self.sandbox._terminate([plain.pid])
            plain.wait(timeout=5)
        self.addCleanup(stop_plain)
        wait(lambda: plain.pid in self.clients(), 'plain Client did not attach')
        previous = self.clients()[self.muxify_pid]['activity']
        def plain_active():
            try:
                while os.read(master, 65536):
                    pass
            except BlockingIOError:
                pass
            os.write(master, b' ')
            return self.clients()[plain.pid]['activity'] > previous
        wait(plain_active, 'plain Client did not receive input')
        return plain

    def test_newer_input_in_a_plain_client_on_the_same_session_keeps_the_answer_local(self):
        sandbox, fields = self.sandbox, self.fields
        pane = sandbox.tmux('display-message', '-p', '-c', fields[1], '#{pane_id}')
        session = sandbox.tmux('display-message', '-p', '-t', pane, '#{session_id}')
        self.assertEqual(self.answer(pane), 'local')
        self.type_in_plain_client(session)
        self.assertEqual(self.answer(pane), 'local')

    def test_pane_in_a_session_that_no_client_shows_answers_local_while_muxify_shows_the_server(self):
        sandbox, fields = self.sandbox, self.fields
        shown = sandbox.tmux('display-message', '-p', '-c', fields[1], '#{session_id}')
        sandbox.tmux('new-session', '-d', '-s', 'unshown', '-c', str(sandbox.root), '/bin/sh')
        self.addCleanup(sandbox.tmux, 'kill-session', '-t', '=unshown')
        pane = sandbox.tmux('display-message', '-p', '-t', '=unshown:', '#{pane_id}')
        self.assertEqual(sandbox.tmux('display-message', '-p', '-t', pane, '#{session_attached}'), '0')
        self.type_in_plain_client(shown)
        self.assertEqual(self.answer(pane), 'local')

    def test_marker_whose_client_is_not_attached_answers_no(self):
        pane = self.sandbox.tmux('display-message', '-p', '-c', self.fields[1], '#{pane_id}')
        gone = max(self.clients()) + 100000
        self.sandbox.tmux('set-option', '-s', self.option, '␟'.join([str(gone)] + self.fields[1:]))
        self.assertEqual(self.answer(pane), 'no')

    def test_unreadable_tmux_fails_with_status_two_and_a_reason(self):
        pane = self.sandbox.tmux('display-message', '-p', '-c', self.fields[1], '#{pane_id}')
        missing = str(self.sandbox.root/'no-such-socket')
        env = dict(self.sandbox.env, TMUX_PANE=pane, TMUX=missing + ',1,0')
        cli = self.sandbox.app/'Contents/Resources/bin/muxify'
        answer = subprocess.run([str(cli), 'browser', 'available'], env=env, capture_output=True, text=True)
        self.assertEqual((answer.returncode, answer.stdout), (2, ''), answer.stderr)
        self.assertIn('cannot read tmux', answer.stderr)
        self.assertIn('no-such-socket', answer.stderr, 'tmux\'s own reason reaches stderr')
        script = subprocess.run(['/bin/sh', str(self.check)], env=env, capture_output=True, text=True)
        self.assertEqual((script.returncode, script.stdout), (2, ''), script.stderr)

    def test_remote_marker_matches_script_and_command(self):
        pane = self.sandbox.tmux('display-message', '-p', '-c', self.fields[1], '#{pane_id}')
        self.sandbox.tmux('set-option', '-s', self.option, '␟'.join(self.fields[:-1] + ['remote']))
        self.assertEqual(self.answer(pane), 'remote')

    def test_marker_is_removed_on_reattach_and_detach(self):
        sandbox, option = self.sandbox, self.option
        sandbox.act('action', 'client-input', 'Reattach Client')
        replacement = wait(lambda: next(((key, value) for key, value in self.markers().items()
                                        if key != option and int(value[0]) in self.clients()), None),
                           'replacement Client did not register')
        wait(lambda: option not in self.markers(), 'old marker survived reattach')
        socket = sandbox.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(pathlib.Path(socket).resolve().is_relative_to(sandbox.root.resolve()))
        sandbox.tmux('detach-client', '-t', replacement[1][1])
        wait(lambda: replacement[0] not in self.markers(), 'marker survived detach')
