import unittest

from scripts.verify.sandbox import Sandbox, wait


class EnvironmentRules(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        (s.root/'config/muxify/config.yaml').write_text('notifications:\n  manual_read: true\n')
        s.tmux('new-session', '-d', '-s', 'main', 'sleep 600')
        s.tmux('set-option', '-p', '-t', '%0', '@muxify_agent', 'claude',
               ';', 'set-option', '-p', '-t', '%0', '@muxify_agent_status', 'working')
        s.launch()

    def test_owner_exit_releases_lock_and_next_owner_finds_unread_update(self):
        s = self.s
        wait(lambda: s.tmux('show-option', '-pqv', '-t', '%0', '@muxify_agent_seen_status') == 'working',
             'The first owner did not save working Status')
        s._terminate([s.pid])
        s.tmux('set-option', '-p', '-t', '%0', '@muxify_agent_status', 'done')
        s.launch()
        wait(lambda: s.tmux('show-option', '-pqv', '-t', '%0', '@muxify_agent_seen_status') == 'done',
             'The next app process did not take the rules lock')
        self.assertEqual(s.tmux('show-option', '-pqv', '-t', '%0', '@muxify_agent_unread'), '1')
