"""An unsupported Remote keeps Sessions and Browser writes, without Topics."""

import shlex

from scripts.verify.suites.environment_browser import RemoteEnvironmentFixture
from scripts.verify.sandbox import wait


class EnvironmentFallback(RemoteEnvironmentFixture):
    @classmethod
    def prepare_remote(cls, local, remote, home, fake):
        commands = remote.root/'commands'
        commands.mkdir()
        uname = commands/'uname'
        uname.write_text('#!/bin/sh\nif [ "$1" = -s ]; then echo Linux; else exec /usr/bin/uname "$@"; fi\n')
        uname.chmod(0o755)
        fake.write_text(fake.read_text().replace('for arg do', 'export PATH=%s:"$PATH"\nfor arg do' % shlex.quote(str(commands))))
        cls.home = home

    def test_fallback_keeps_remote_browser_and_has_no_topics(self):
        s = self.local
        self.assertFalse((self.home/'.local/share/muxify/bin').exists())
        s.act('press', 'browser-new-tab')
        wait(lambda: self.tabs(self.remote) == ['https://remote.invalid/', 'about:blank'],
             'Fallback Browser write did not reach Remote')
        self.assertEqual(self.tabs(s), ['https://local.invalid/'])
        self.assertFalse(s.has('sidebar-view-topics'), 'Fallback offered Topics')
        s.act('action', 'client-input', 'New Tab and Close App Window')
        wait(lambda: len(self.tabs(self.remote)) == 3, 'Fallback close lost its final Browser save')
        wait(lambda: not self.remote.tmux('list-clients', '-F', '#{client_tty}').strip(),
             'Fallback retained the Terminal Client')
