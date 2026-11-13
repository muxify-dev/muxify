"""A list on the Sidebar page that does not show scrolls and then comes to rest.

While Topics shows, the Sessions list still scrolls to the card of the selected Window's Session. SidebarPager once
shrank the page that does not show to 0.975 of its size with SwiftUI. A scroll view under that scale puts its scroll on
a grid of 1.95 pixels a point, where SwiftUI's animated scrollTo never reached its target. So SwiftUI started the
scroll again every frame, for as long as the app ran, and AppKit left a display link behind with many of these starts.
On a Space switch AppKit updates every link, and tens of thousands of them froze the app for minutes.

Now each page is its own hosting view that the pager slides as a Core Animation layer, which the scroll view never
sees, and the page that does not show rests whole, one width to the side. In that hidden host AppKit runs no animated
scroll: the list lands on its card at once. So the check proves the end result and the rest, not how the list moves:

- While Topics shows, the app shows the last Session's Window, so the hidden Sessions list must scroll far down.
- The hidden list rests. The check counts the scroll animations in the Diagnostics log, the `animation #` lines of
  DisplayLinkProbe (Diagnostics/DisplayLinkProbe.swift), which the suite's Config turns on with
  `diagnostics.display_links`. This count caught the freeze: a list that never reaches its
  target starts one every frame. After the scroll, no new one may start over 2 s. A scroll that does animate may start
  some, so the check needs none to start and needs no Reduce Motion skip. A change that removes the probe must give the
  check another way to count them, or this half proves nothing.
- The list reached its Session. After a switch to Sessions, the last Session's card lies inside the Sessions list's
  frame.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.sidebar_pager_scroll
"""

import time
import unittest

from scripts.verify.sandbox import Sandbox, frame, wait

SHELL = '/bin/zsh -f'
# More Sessions than the Sidebar shows, so the last one's card is far down the Sessions list.
SESSIONS = 30


class SidebarPagerScroll(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        # Diagnostics and the display-link probe that writes the `animation #` lines are both off by default.
        (s.root/'config/muxify/config.yaml').write_text('diagnostics:\n  enabled: true\n  display_links: true\n')
        cls.logs = s.root/'logs'
        cls.sessions, cls.windows = [], []
        for number in range(SESSIONS):
            session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'pager-scroll-%02d' % number, SHELL)
            cls.sessions.append(session)
            cls.windows.append(s.tmux('display-message', '-p', '-t', session + ':', '#{window_id}'))
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])
        wait(lambda: 'launch: pid %d' % s.pid in cls.log_text(), 'no launch line in %s' % cls.logs, 10)

    @classmethod
    def log_text(cls):
        """The day files in order, so a run across local midnight reads on into the next day's file."""
        return ''.join(path.read_text(errors='replace') for path in sorted(cls.logs.glob('muxify-*.log')))

    def scroll_animations(self):
        return [line for line in self.log_text().splitlines() if ' animation #' in line]

    def test_the_hidden_sessions_list_scrolls_to_its_session_and_comes_to_rest(self):
        rs = self.s.wait_rows(lambda rs: self.s.row('sidebar-view-topics', rs).get('accessibilityValue') == 'selected',
                              'the Sidebar does not show Topics')
        self.assertFalse(self.s.has('sessions-list', rs), 'the Sessions list shows, so its page is not the hidden one')

        self.s.show(self.windows[-1])
        # An animated scroll glides for 0.15 s. Wait past it, then count what starts after it.
        time.sleep(2)
        settled = len(self.scroll_animations())
        time.sleep(2)
        later = self.scroll_animations()[settled:]
        self.assertEqual(0, len(later), 'the hidden Sessions list still starts scroll animations 2 s after it scrolled, '
                         '%d in 2 s; the last: %s' % (len(later), later[-1:]))

        card = 'session-' + self.sessions[-1]
        def inside(rs):
            if not (self.s.has('sessions-list', rs) and self.s.has(card, rs)):
                return False
            (list_bottom, list_top), (card_bottom, card_top) = frame(self.s.row('sessions-list', rs)), frame(self.s.row(card, rs))
            return list_bottom <= card_bottom and card_top <= list_top
        self.s.act('press', 'sidebar-view-sessions')
        try:
            self.s.wait_rows(inside, 'the last Session card is not inside the Sessions list', 10)
        except AssertionError:
            rs = self.s.rows()
            self.fail('after a switch to Sessions, the last Session card %s is not inside the Sessions list, so the '
                      'hidden list did not scroll to it: card %s, list %s' % (
                          card, self.s.row(card, rs).get('accessibilityFrame', 'not in the dump'),
                          self.s.row('sessions-list', rs).get('accessibilityFrame', 'not in the dump')))

if __name__ == '__main__':
    unittest.main()
