"""Image paste over the production SSH command lane, on the Sandbox server.

ClientVerification's fixed actions use private pasteboards, leaving the user's
clipboard and keyboard alone. The SSH fixture executes remote commands locally;
all tmux processes and uploaded files stay in this Sandbox.
"""

import base64
import pathlib
import shlex
import sys
import unittest

from scripts.verify.sandbox import Sandbox, wait


PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=')


class AttachmentsTerminal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = sandbox = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(sandbox.teardown)
        cls.remote_tmp = sandbox.root/'remote-tmp'
        cls.remote_tmp.mkdir()
        home = sandbox.root/'remote-home'
        home.mkdir()
        (sandbox.root/'config/muxify/config.yaml').write_text(
            'remote_environments:\n  - name: Fixture\n    host: unused\n    username: unused\n')
        fake = sandbox.root/'ssh'
        fake.write_text('''#!/bin/bash
unset TMUX TMUX_PANE XDG_CONFIG_HOME XDG_STATE_HOME
export TMUX_TMPDIR=%s TMPDIR=%s HOME=%s
for arg do
    if [ "$arg" = -O ]; then exit 0; fi
    command=$arg
done
if [[ "$command" == *'folder=$(mktemp'* ]]; then
    touch %s
    while [ -f %s ]; do sleep 0.05; done
    if [ -f %s ]; then echo 'fixture upload failed' >&2; exit 1; fi
fi
exec /bin/sh -c "$command"
''' % tuple(shlex.quote(str(p)) for p in [sandbox.root/'tmux', cls.remote_tmp, home,
                                         sandbox.root/'upload-started', sandbox.root/'upload-hold', sandbox.root/'upload-fail']))
        fake.chmod(0o755)
        sandbox.app_env['MUXIFY_TEST_SSH'] = str(fake)
        sandbox.tmux('new-session', '-d', '-s', 'attachments', '/bin/sh')
        sandbox.launch(args=('-selectedEnvironment', 'Fixture'))
        cls.tty = wait(lambda: next((line.split('|')[1] for line in sandbox.tmux(
            'list-clients', '-F', '#{client_control_mode}|#{client_tty}').splitlines()
            if line.startswith('0|')), None), 'remote Client did not attach')
        sandbox.wait_rows(lambda rows: any(r.get('accessibilityIdentifier') == 'client-input' for r in rows),
                          'Client actions missing')
        cls.recorder = sandbox.root/'record.py'
        cls.recorder.write_text('''import os, pathlib, sys, termios, tty
output, ready = map(pathlib.Path, sys.argv[1:])
old = termios.tcgetattr(0)
tty.setraw(0)
os.write(1, b'\\x1b[?2004h')
ready.touch()
data = b''
try:
    while not data.endswith(b'\\x1b[201~'):
        data += os.read(0, 1)
    output.write_bytes(data)
finally:
    termios.tcsetattr(0, termios.TCSANOW, old)
''')

    def setUp(self):
        for name in ['upload-started', 'upload-hold', 'upload-fail']:
            (self.sandbox.root/name).unlink(missing_ok=True)
        (self.sandbox.root/'paste.png').write_bytes(PNG)

    def recorder_pane(self, name):
        sandbox = self.sandbox
        output, ready = sandbox.root/(name + '.input'), sandbox.root/(name + '.ready')
        command = shlex.join([sys.executable, str(self.recorder), str(output), str(ready)])
        pane = sandbox.tmux('new-window', '-d', '-P', '-F', '#{pane_id}', '-n', name, command)
        wait(ready.exists, 'Pane recorder did not start')
        # The store must finish reading its initial remote attachment first.
        sandbox.wait_rows(lambda rows: any('Connected to Fixture' in str(r.get('accessibilityValue', ''))
                                           for r in rows), 'Remote Environment not shown')
        window = sandbox.tmux('display-message', '-p', '-t', pane, '#{window_id}')
        key = 'header-window-' + window
        sandbox.wait_rows(lambda rows: sandbox.has(key, rows), 'Recorder Window did not appear')
        sandbox.act('press', key)
        sandbox.wait_rows(lambda rows: sandbox.row(key, rows).get('accessibilityValue') == 'selected'
                          and sandbox.tmux('display-message', '-p', '-c', self.tty, '#{window_id}') == window,
                          'Recorder Window was not selected by the app and Client')
        return pane, output

    def pasted_path(self, output):
        data = wait(lambda: output.read_bytes(), 'Pane did not receive attachment')
        self.assertTrue(data.startswith(b'\x1b[200~'), data)
        self.assertTrue(data.endswith(b'\x1b[201~'), data)
        words = shlex.split(data[6:-6].decode())
        self.assertEqual(len(words), 1)
        file = pathlib.Path(words[0])
        self.assertTrue(file.is_relative_to(self.remote_tmp), file)
        return file

    def test_clipboard_image_uploads_before_bracketed_path_paste(self):
        _, output = self.recorder_pane('clipboard-image')
        self.sandbox.act('action', 'client-input', 'Paste Fixture Image')
        file = self.pasted_path(output)
        self.assertEqual(file.read_bytes(), PNG)
        self.assertEqual(file.name, 'Screenshot.png')
        self.assertEqual(file.parent.stat().st_mode & 0o777, 0o700)

    def test_drop_snapshots_file_and_pastes_into_original_pane_after_switch(self):
        sandbox = self.sandbox
        _, output = self.recorder_pane('original-pane')
        source = sandbox.root/"Screenshot ' ; $(oops).png"
        source.write_bytes(PNG)
        (sandbox.root/'paste-file').write_text(str(source))
        hold = sandbox.root/'upload-hold'
        hold.touch()
        self.addCleanup(hold.unlink, missing_ok=True)
        sandbox.act('action', 'client-input', 'Drop Fixture File')
        wait((sandbox.root/'upload-started').exists, 'upload did not start')
        source.unlink()
        _, other = self.recorder_pane('other-pane')
        hold.unlink()
        file = self.pasted_path(output)
        self.assertEqual(file.name, source.name)
        self.assertEqual(file.read_bytes(), PNG)
        self.assertFalse(other.exists(), 'upload pasted into the newly selected Pane')

    def test_failed_upload_shows_error_and_pastes_nothing(self):
        sandbox = self.sandbox
        _, output = self.recorder_pane('failed-upload')
        (sandbox.root/'upload-fail').touch()
        sandbox.act('action', 'client-input', 'Paste Fixture Image')
        rows = sandbox.wait_rows(lambda rows: any('fixture upload failed' in str(r) for r in rows),
                                 'upload failure was not shown')
        self.assertTrue(sandbox.has('attachment-status', rows))
        self.assertFalse(output.exists(), 'a failed upload pasted into the Pane')
