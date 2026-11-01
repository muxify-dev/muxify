import datetime
import json
import os
import shlex
import signal
import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, alive, ax_wake, wait
from scripts.verify.topic_records import TopicRecords


class EnvironmentWatch(unittest.TestCase):
    def setUp(self):
        self.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        self.addCleanup(s.teardown)
        (s.root/'config/muxify/config.yaml').write_text('notifications:\n  manual_read: true\n')
        s.tmux('new-session', '-d', '-s', 'main', 'sleep 600')
        s.tmux('set-option', '-p', '-t', '%0', '@muxify_agent', 'claude',
               ';', 'set-option', '-p', '-t', '%0', '@muxify_agent_status', 'working')
        s.tmux('new-session', '-d', '-s', 'other', 'sleep 600')
        s.tmux('set-option', '-p', '-t', '%1', '@muxify_agent', 'claude',
               ';', 'set-option', '-p', '-t', '%1', '@muxify_agent_status', 'working')
        s.launch()
        wait(lambda: self.seen() == 'working', 'The Local child did not observe working Status')

    def seen(self, pane='%0'):
        return self.s.tmux('show-option', '-pqv', '-t', pane, '@muxify_agent_seen_status')

    def children(self):
        listing = subprocess.run(['ps', '-ax', '-ww', '-o', 'pid=,ppid=,command='],
                                 check=True, capture_output=True, text=True).stdout
        result = []
        for line in listing.splitlines():
            fields = line.split(None, 2)
            if len(fields) != 3:
                continue
            pid, parent, command = fields
            if int(parent) == self.s.pid and 'environment watch' in command:
                self.assertIn(str(self.s.app), command)
                result.append(int(pid))
        return result

    def child(self):
        children = wait(self.children, 'The app did not start its Local watch child')
        self.assertEqual(len(children), 1, children)
        return children[0]

    def test_two_app_windows_share_one_child_and_one_unread_write(self):
        s = self.s
        child = self.child()
        s.act('press', 'New Muxify Window')
        ax_wake(s.pid)
        s.wait_rows(lambda rows: sum(row.get('accessibilityIdentifier') == 'client-input' for row in rows) == 2,
                    'The second Local App Window did not appear')
        self.assertEqual(self.children(), [child])
        wait(lambda: self.seen('%1') == 'working', 'The child did not observe Status in the other Session')
        self.assertEqual(s.tmux('display-message', '-p', '-t', 'other', '#{session_attached}'), '0')
        log = s.root/'logs/options.log'
        command = "printf '%s\\n' '#{hook_arguments}' >> " + shlex.quote(str(log))
        s.tmux('set-hook', '-g', 'after-set-option', 'run-shell ' + shlex.quote(command))
        s.tmux('set-option', '-p', '-t', '%1', '@muxify_agent_status', 'done')
        wait(lambda: self.seen('%1') == 'done', 'The shared child did not observe done Status in the other Session')
        self.assertEqual(s.tmux('show-option', '-pqv', '-t', '%1', '@muxify_agent_unread'), '1')
        time.sleep(2)
        writes = [line for line in log.read_text().splitlines() if '@muxify_agent_unread' in line]
        self.assertEqual(len(writes), 1, writes)
        self.assertEqual(self.children(), [child])

    def test_the_control_client_is_alone_in_the_watch_session(self):
        # tmux answers a Pane's background color query from the first client on its Session, and a control client
        # answers black, so the watch's client must never share a Session with the user's Panes.
        self.child()
        def control_sessions():
            rows = self.s.tmux('list-clients', '-F', '#{client_control_mode} #{session_name}').splitlines()
            return [name for mode, name in (row.split(' ', 1) for row in rows) if mode == '1']
        self.assertEqual(wait(control_sessions, 'The watch did not start its control client'), ['muxify-watch'])

    def test_child_crash_restores_inventory_and_rules(self):
        s = self.s
        child = self.child()
        os.kill(child, signal.SIGKILL)
        wait(lambda: self.children() and child not in self.children(), 'The app did not replace its failed child')
        self.child()
        s.tmux('set-option', '-p', '-t', '%0', '@muxify_agent_status', 'done')
        wait(lambda: self.seen() == 'done', 'The replacement child did not resume rules')
        s.tmux('rename-window', '-t', '@0', 'after-child-restart')
        s.wait_rows(lambda rows: any('after-child-restart' in str(row) for row in rows),
                    'The App Window did not recover its Inventory')
        self.assertTrue(alive(s.pid))

    def test_rules_continue_without_app_windows_and_child_exits_with_app(self):
        s = self.s
        child = self.child()
        # ClientVerification exposes native close without opening a context menu or taking focus.
        s.act('action', 'client-input', 'Close App Window')
        wait(lambda: not s.has('client-input'), 'The App Window did not close')
        self.assertTrue(alive(s.pid))
        self.assertEqual(self.children(), [child])
        records = TopicRecords(s.root/'state/muxify')
        deadline = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=2)
        records.put(dict(id='no-window-clock', title='No App Window', sessions=[],
                         snoozed_until=deadline.isoformat().replace('+00:00', 'Z')))
        wait(lambda: records.get('no-window-clock').get('snoozed_until') is None,
             'Local Snooze did not wake without an App Window', seconds=10)
        s._terminate([s.pid])
        wait(lambda: not alive(child), 'The Local child survived the app process')
