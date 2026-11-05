"""A list on the Sidebar page that does not show scrolls and then comes to rest.

While Topics shows, the Sessions list still scrolls to the card of the selected Window's Session. SidebarPager shrank
the page that does not show to 0.975 of its size. A scroll view under that scale puts its scroll on a grid of
1.95 pixels a point, where SwiftUI's animated scrollTo never reached its target. So SwiftUI started the scroll again
every frame, for as long as the app ran, and AppKit left a display link behind with many of these starts. On a Space
switch AppKit updates every link, and tens of thousands of them froze the app for minutes.

The check counts the scroll animations in the Diagnostics log: the `animation #` lines of DisplayLinkProbe
(Diagnostics/DisplayLinkProbe.swift). It fails when it reads no such line, so a change that removes the probe must
give the check another way to count them.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.sidebar_pager_scroll
"""

import time
import unittest

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/zsh -f'
# More Sessions than the Sidebar shows, so the last one's card is far down the Sessions list.
SESSIONS = 30


class SidebarPagerScroll(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        (s.root/'config/muxify/config.yaml').write_text('diagnostics:\n  enabled: true\n')
        cls.log = s.root/'logs/muxify.log'
        cls.windows = []
        for number in range(SESSIONS):
            session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'pager-scroll-%02d' % number, SHELL)
            cls.windows.append(s.tmux('display-message', '-p', '-t', session + ':', '#{window_id}'))
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])
        wait(lambda: 'launch: pid %d' % s.pid in cls.log_text(), 'no launch line in %s' % cls.log, 10)

    @classmethod
    def log_text(cls):
        return cls.log.read_text(errors='replace') if cls.log.exists() else ''

    def scroll_animations(self):
        return [line for line in self.log_text().splitlines() if ' animation #' in line]

    def require_motion(self):
        """The pager shrinks a page only while it animates. Reduce Motion in System Settings stops that for every app."""
        if self.s.row('sidebar-swipe-input').get('accessibilityLabel', '').startswith('Sidebar swipe input instant'):
            self.skipTest('Reduce Motion is on, so the Sidebar pager does not animate')

    def test_the_hidden_sessions_list_comes_to_rest_after_it_scrolls(self):
        rs = self.s.wait_rows(lambda rs: self.s.row('sidebar-view-topics', rs).get('accessibilityValue') == 'selected',
                              'the Sidebar does not show Topics')
        self.assertFalse(self.s.has('sessions-list', rs), 'the Sessions list shows, so its page is not the hidden one')
        self.require_motion()
        before = len(self.scroll_animations())

        self.s.show(self.windows[-1])
        wait(lambda: len(self.scroll_animations()) > before,
             'no scroll animation in the Diagnostics log after the Sessions list had to scroll to the last Session', 10)
        # A scroll glides for 0.2 s. Sleep past it, then count what starts after it.
        time.sleep(2)
        settled = len(self.scroll_animations())
        time.sleep(2)
        later = self.scroll_animations()[settled:]
        self.assertEqual(0, len(later), 'the hidden Sessions list still starts scroll animations 2 s after it scrolled, '
                         '%d in 2 s; the last: %s' % (len(later), later[-1:]))


if __name__ == '__main__':
    unittest.main()
