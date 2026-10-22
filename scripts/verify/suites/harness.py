"""The sandbox itself: a run that dies leaves nothing behind once the next run starts.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.harness
"""

import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

from scripts.verify.sandbox import BASE, OWNER, OWNERLESS_GRACE, REPO, Sandbox, alive, new_run_id, wait

NAME = __name__.rsplit('.', 1)[-1]

# Owns one run with an app and a tmux server, reports them, then waits to be killed.
OWNER_PROCESS = '''
import json, time
from scripts.verify.sandbox import Sandbox
s = Sandbox(%r)
s.launch()
s.tmux('new-session', '-d', '-s', 'orphan')
print(json.dumps(dict(root=str(s.root), app=s.pid, server=int(s.tmux('display-message', '-p', '#{pid}')))), flush=True)
time.sleep(600)
''' % NAME


class Harness(unittest.TestCase):
    def test_fixture_commits_do_not_use_the_users_signer(self):
        from scripts.verify.suites.command_palette import CommandPalette
        from scripts.verify.topics_sidebar import TopicsSidebar

        run = Sandbox(NAME)
        self.addCleanup(run.teardown)
        config = run.root/'signing.gitconfig'
        config.write_text('[commit]\n\tgpgSign = true\n[gpg]\n\tprogram = /usr/bin/false\n\tformat = openpgp\n')
        # Exercise the real repository setup, but do not launch a UI or invoke
        # the user's signer. A commit without its override would fail here.
        with patch.dict(os.environ, GIT_CONFIG_GLOBAL=str(config)), patch.object(Sandbox, 'launch'):
            for fixture in [TopicsSidebar, CommandPalette]:
                with self.subTest(fixture=fixture.__name__):
                    class Fixture(fixture):
                        pass

                    try:
                        Fixture.setUpClass()
                        commit = subprocess.check_output(
                            ['/usr/bin/git', '-C', str(Fixture.alpha), 'cat-file', 'commit', 'HEAD'], text=True)
                        self.assertNotIn('\ngpgsig ', commit, 'a fixture commit was signed')
                    finally:
                        Fixture.doClassCleanups()

    def live_run(self):
        run = Sandbox(NAME)
        self.addCleanup(run.teardown)
        run.tmux('new-session', '-d', '-s', 'live')
        return run, int(run.tmux('display-message', '-p', '#{pid}'))

    def test_run_whose_owner_was_killed_is_swept_and_live_run_is_kept(self):
        live, live_server = self.live_run()
        environment = {key: value for key, value in os.environ.items() if key not in ('TMUX', 'TMUX_PANE')}
        owner = subprocess.Popen([sys.executable, '-c', OWNER_PROCESS], cwd=REPO, env=environment,
                                 stdout=subprocess.PIPE, text=True)
        self.addCleanup(owner.kill)
        self.addCleanup(owner.stdout.close)
        dead = json.loads(owner.stdout.readline())
        dead_root = pathlib.Path(dead['root'])

        os.kill(owner.pid, signal.SIGKILL)
        owner.wait(timeout=5)
        self.assertTrue(dead_root.is_dir() and alive(dead['app']) and alive(dead['server']),
                        'killed run should leave its root, app and tmux server: %s' % dead)

        self.addCleanup(Sandbox(NAME).teardown)
        wait(lambda: not alive(dead['app']) and not alive(dead['server']),
             'sweep left the dead run running: %s' % dead, seconds=10)
        self.assertFalse(dead_root.exists(), 'sweep left the dead root %s' % dead_root)
        self.assertTrue(live.root.is_dir() and alive(live_server),
                        'sweep touched the live run %s (server %d)' % (live.root, live_server))
        self.assertEqual(live.tmux('display-message', '-p', '-t', 'live', '#{session_name}'), 'live')

    def test_run_whose_owner_pid_was_reused_is_swept(self):
        reused, server = self.live_run()
        # The owner PID still runs, but it is a later process than the one that made the run.
        (reused.root/OWNER).write_text(json.dumps(dict(pid=os.getpid(), started='Thu Jan  1 00:00:00 1970')))

        self.addCleanup(Sandbox(NAME).teardown)
        wait(lambda: not alive(server), 'sweep left the tmux server %d of a reused-PID run' % server, seconds=10)
        self.assertFalse(reused.root.exists(), 'sweep left the reused-PID root %s' % reused.root)

    def test_root_without_owner_is_swept_only_after_grace(self):
        old, young = BASE/NAME/new_run_id(), BASE/NAME/new_run_id()
        for root in (old, young):
            (root/'logs').mkdir(parents=True)
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        then = time.time() - OWNERLESS_GRACE - 60
        os.utime(old, (then, then))

        self.addCleanup(Sandbox(NAME).teardown)
        self.assertFalse(old.exists(), 'sweep left the ownerless root %s older than the grace' % old)
        self.assertTrue(young.is_dir(), 'sweep removed the ownerless root %s inside the grace' % young)


if __name__ == '__main__':
    unittest.main()
