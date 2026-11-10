"""The Sidebar's two Sessions lists: the SwiftUI list, and the AppKit list that replaces it
(docs/adr/0074-an-area-leaves-swiftui-for-appkit-only-where-swiftui-caused-bugs.md).

The user default `sessionsListAppKit` chooses the list. A check stores it as a user does, with `defaults write` on the
bundle id of this run's app copy. A launch argument hides the stored value from the app, so a check that stores the
default first starts the app without that argument, also in a run with `SESSIONS_LIST`.

The pager hides the page that its mode does not show from accessibility, so no dump has the Sessions list while a
swipe from Topics holds the Sidebar between its pages. The check of a held swipe therefore reads the list's frame
while Sessions shows, where the swipe pulls the page past its end. The check of the swipe from Topics keeps a
`snapshot` of each version in the run directory, `mid-swipe-swiftui.png` and `mid-swipe-appkit.png`, for a person
to compare.

The checks of a press on a card's header run against both lists. `press` performs the header's default accessibility
action. `click` sends a mouse down and a mouse up to the App Window, which is not the key window, because the run
keeps the app behind the user's windows: it is a first click while Muxify is not the front app. The header of the
AppKit card follows it. The header of the SwiftUI card does not follow the driver's `click`, also before the AppKit
list existed: a one-off probe on the commit before the AppKit cards showed that. So only the AppKit list gets `click`.

The check of a click on a Window row runs against both lists, because the SwiftUI row takes the first click
(`takesFirstClick` on its drag handle). A click aims at the middle of the row's first part, its app icon.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.sessions_list_sidebar
"""

import os
import re
import subprocess
import unittest
from unittest.mock import patch

from scripts.verify.sandbox import SESSIONS_LIST, SESSIONS_LIST_DEFAULT, Sandbox, alive, sessions_list_option, wait

SHELL = '/bin/zsh -f'
# How each list's card header is pressed: by its accessibility action, and for the AppKit list by a first click too.
PRESSES = dict(swiftui=('press',), appkit=('press', 'click'))
CONFIG = 'sidebar:\n  agents: false\n'
ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Sessions']
# What the app shows when nothing sets the user default.
APP_DEFAULT = 'swiftui'


def rect(row):
    """[x, y, width, height] of a dump row's accessibilityFrame, in screen points."""
    return [float(number) for number in re.findall(r'-?[\d.]+', row['accessibilityFrame'])]


class SessionsListSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text(CONFIG)
        cls.sessions = [s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, SHELL)
                        for name in ('list-first', 'list-second', 'list-third')]
        # The one Window of each Session.
        cls.windows = {session: s.tmux('list-windows', '-t', session, '-F', '#{window_id}') for session in cls.sessions}
        # As every suite launches: with the list that SESSIONS_LIST names, or the app's default.
        s.launch(ARGS)
        cls.argument = sessions_list_option() is not None
        cls.first = s.sessions_list()

    def setUp(self):
        self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')

    @classmethod
    def start(cls, option=None):
        """Starts the app again, as `make verify SESSIONS_LIST=<option>` starts it. Without an option the app gets no
        launch argument for the user default, so it follows the stored value."""
        with patch.dict(os.environ):
            os.environ.pop(SESSIONS_LIST, None)
            if option:
                os.environ[SESSIONS_LIST] = option
            cls.s.restart_app(ARGS)
        cls.argument = option is not None

    def store_default(self, value):
        """Stores the user default, or deletes it for None. The app follows the stored value, so it must run without
        the launch argument."""
        if self.argument:
            self.start()
        self.write_default(value)

    def write_default(self, value):
        if value is None:
            subprocess.run(['defaults', 'delete', self.s.bundle_id, SESSIONS_LIST_DEFAULT], capture_output=True)
        else:
            subprocess.run(['defaults', 'write', self.s.bundle_id, SESSIONS_LIST_DEFAULT, '-bool', 'YES' if value else 'NO'],
                           check=True, capture_output=True)

    def wait_list(self, version):
        wait(lambda: self.s.sessions_list() == version,
             lambda: 'the App Window shows the %s Sessions list, not the %s list' % (self.s.sessions_list(), version))

    def show_list(self, version):
        self.store_default(version == 'appkit')
        self.wait_list(version)

    def headers(self, rs):
        """The header rows of the Sessions list's cards, from its top."""
        return [row for row in rs if re.fullmatch(r'session-\$\d+', row.get('accessibilityIdentifier', ''))]

    def wait_cards(self, sessions=None):
        """The rows once the Sessions list shows a card for each of the Sessions, and for no other."""
        wanted = sorted('session-' + session for session in (sessions if sessions is not None else self.sessions))
        last = []
        def shown(rs):
            last[:] = self.s.ids(self.headers(rs))
            return self.s.has('sessions-list', rs) and sorted(last) == wanted
        return self.s.wait_rows(shown, lambda: 'the Sessions list shows the cards %s, not %s' % (last, wanted))

    def card_value(self, session, rs=None):
        return self.s.row('session-' + session, rs).get('accessibilityValue') or ''

    def wait_card(self, session, state, message):
        """Waits until the header of the Session's card has the state, `expanded` or `collapsed`, as its value."""
        self.s.wait_rows(lambda rs: self.card_value(session, rs).startswith(state),
                         lambda: '%s: the value of its header is %r' % (message, self.card_value(session)))

    def location(self, what='session_id'):
        """The Session of the Location, or with `what='window_id'` its Window: the one of the app's tmux client that is
        no control client."""
        clients = self.s.tmux('list-clients', '-F', '#{client_control_mode} #{%s}' % what).splitlines()
        return [line.split()[1] for line in clients if line.startswith('0 ')]

    def stand_on(self, session, opened):
        """Moves the Location to the Session, and opens or closes its card. Only a press on the card of the
        Location closes a card."""
        self.s.show(self.windows[session])
        self.s.wait_rows(lambda rs: self.card_value(session, rs), 'the card of %s has no state' % session)
        if self.card_value(session).startswith('expanded') != opened:
            self.s.act('press', 'session-' + session)
        self.wait_card(session, 'expanded' if opened else 'collapsed', 'the card of the Location did not get ready')

    def wait_mode(self, mode):
        position = '0.000' if mode == 'topics' else '1.000'
        return self.s.wait_rows(lambda rs: self.s.row('sidebar-view-' + mode, rs).get('accessibilityValue') == 'selected'
                                and self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' ' + position),
                                'the Sidebar did not settle on ' + mode)

    def show_mode(self, mode):
        self.s.act('press', 'sidebar-view-' + mode)
        self.wait_mode(mode)

    def wait_position(self, position):
        self.s.wait_rows(lambda rs: self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' ' + position),
                         'the Sidebar did not follow the swipe to ' + position)

    def settled(self, key):
        """The frame of the row once two dumps in a row have it in one place: a page slides for a moment after a
        switch."""
        frames = []
        def at_rest(rs):
            frames.append(self.s.row(key, rs).get('accessibilityFrame'))
            return len(frames) >= 2 and frames[-1] is not None and frames[-2] == frames[-1]
        return rect(self.s.row(key, self.s.wait_rows(at_rest, lambda: '%s did not come to rest: %s' % (key, frames[-3:]))))

    def require_motion(self):
        """The Sidebar follows a swipe only while it animates. Reduce Motion in System Settings stops that for every app."""
        if self.s.row('sidebar-swipe-input').get('accessibilityLabel', '').startswith('Sidebar swipe input instant'):
            self.skipTest('Reduce Motion is on, so the Sidebar does not follow a swipe')

    def sample(self, name):
        self.s.act('action', 'sidebar-swipe-input', name)

    def assert_close(self, first, second, message):
        self.assertTrue(len(first) == len(second) and all(abs(a - b) <= .5 for a, b in zip(first, second)),
                        '%s: %s and %s' % (message, first, second))

    def test_without_the_default_the_sidebar_shows_the_swiftui_list(self):
        self.write_default(None)
        self.start()
        self.assertEqual(self.s.sessions_list(), APP_DEFAULT, 'a launch with no user default shows another Sessions list')
        self.wait_cards()

    def test_with_the_default_true_the_appkit_list_has_a_card_for_each_session(self):
        self.show_list('swiftui')
        self.show_mode('sessions')
        before = self.wait_cards()
        swiftui_list = self.settled('sessions-list')
        swiftui = [rect(self.s.row('card-' + key, before)) for key in self.s.ids(self.headers(before))]

        self.show_list('appkit')
        rs = self.wait_cards()
        self.assertEqual(self.s.row('sessions-list', rs).get('accessibilityRole'), 'AXScrollArea')
        self.assert_close(self.settled('sessions-list'), swiftui_list, 'the two lists do not take the same place')
        self.assertEqual([(row['accessibilityIdentifier'], row.get('accessibilityLabel')) for row in self.headers(rs)],
                         [(row['accessibilityIdentifier'], row.get('accessibilityLabel')) for row in self.headers(before)],
                         'the AppKit cards are not the SwiftUI cards, in their order and with their titles')
        cards = []
        for header in self.headers(rs):
            card = self.s.row('card-' + header['accessibilityIdentifier'], rs)
            self.assertEqual(card.get('accessibilityRole'), 'AXGroup', 'the card of %s is no group' % header['accessibilityIdentifier'])
            self.assertEqual(header.get('accessibilityRole'), 'AXButton')
            cards.append(rect(card))
        # The same insets from the list's edges, and the same gaps between the cards. An open card of the AppKit list
        # can have another height, so only the first card's top is compared.
        top = lambda card: card[1] + card[3]
        self.assert_close([cards[0][0], cards[0][2], top(cards[0])], [swiftui[0][0], swiftui[0][2], top(swiftui[0])],
                          'the first card does not start where the SwiftUI card starts')
        for side, name in ((cards, 'AppKit'), (swiftui, 'SwiftUI')):
            gaps = [above[1] - top(below) for above, below in zip(side, side[1:])]
            self.assert_close(gaps, [6] * (len(side) - 1), 'the gaps between the %s cards' % name)
            self.assert_close([card[0] for card in side] + [card[2] for card in side],
                              [side[0][0]] * len(side) + [side[0][2]] * len(side), 'the sides of the %s cards' % name)

    def test_a_press_on_the_card_of_the_location_closes_and_opens_it(self):
        home, below = self.sessions[0], self.sessions[1]
        def top(rs=None):
            return sum(rect(self.s.row('card-session-' + below, rs))[1::2])
        for version in ('swiftui', 'appkit'):
            self.show_list(version)
            self.show_mode('sessions')
            self.stand_on(home, opened=True)
            for command in PRESSES[version]:
                with self.subTest(version=version, command=command):
                    opened = top(self.wait_cards())
                    self.s.act(command, 'session-' + home)
                    self.wait_card(home, 'collapsed', 'a %s on the open card of the Location did not close it' % command)
                    # A closed card shows its Summary under its title, and the card below stands under it.
                    self.assertEqual(self.s.row('session-' + home).get('accessibilityHelp'), '1 Window')
                    closed = self.settled('card-session-' + below)
                    self.assertNotEqual(closed[1] + closed[3], opened, 'the card below did not move when the card closed')
                    self.s.act(command, 'session-' + home)
                    self.wait_card(home, 'expanded', 'a %s on the closed card of the Location did not open it' % command)
                    self.assertEqual(self.s.row('session-' + home).get('accessibilityHelp'), '', 'an open card has a Summary')
                    again = self.settled('card-session-' + below)
                    self.assertEqual(again[1] + again[3], opened, 'the card below did not go back when the card opened')
                    self.assertEqual(self.location(), [home], 'a press on the card of the Location moved the Location')

    def test_a_press_on_another_card_opens_it_and_goes_to_its_session(self):
        home, other = self.sessions[0], self.sessions[2]
        for version in ('swiftui', 'appkit'):
            self.show_list(version)
            self.show_mode('sessions')
            for command in PRESSES[version]:
                with self.subTest(version=version, command=command):
                    # The other card is closed, and the Location is not on it.
                    self.stand_on(other, opened=False)
                    self.stand_on(home, opened=True)
                    self.assertTrue(self.card_value(other).startswith('collapsed'), 'the other card did not stay closed')
                    self.s.act(command, 'session-' + other)
                    self.wait_card(other, 'expanded', 'a %s on the card of another Session did not open it' % command)
                    self.s.wait_shown(self.windows[other])
                    self.assertEqual(self.location(), [other], 'a press on the card of another Session did not go to it')
                    self.assertTrue(self.card_value(home).startswith('expanded'), 'the card that the Location left closed')

    def test_a_click_on_a_window_row_goes_to_its_window(self):
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'list-rows', SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        first = self.s.tmux('list-windows', '-t', session, '-F', '#{window_id}')
        second = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', session + ':', SHELL)
        for version in ('swiftui', 'appkit'):
            self.show_list(version)
            self.show_mode('sessions')
            for start, target in ((first, second), (second, first)):
                with self.subTest(version=version, target=target):
                    self.s.show(start)
                    self.s.wait_shown(start)
                    if not self.card_value(session).startswith('expanded'):
                        self.s.act('press', 'session-' + session)
                    self.s.wait_rows(lambda rs: self.s.has('session-window-' + target, rs),
                                     'the open card of %s has no row for %s' % (session, target))
                    self.s.act('click', 'session-window-' + target)
                    self.s.wait_shown(target)
                    self.assertEqual(self.location('window_id'), [target], 'a click on its row did not go to the Window')

    def test_a_session_that_starts_or_ends_changes_the_cards_of_the_appkit_list(self):
        self.show_list('appkit')
        self.show_mode('sessions')
        self.wait_cards()
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', 'list-started')
        started = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'list-started', SHELL)
        rs = self.wait_cards(self.sessions + [started])
        self.assertEqual(self.s.row('session-' + started, rs).get('accessibilityLabel'), 'list-started')
        self.assertTrue(self.s.has('card-session-' + started, rs), 'the new Session has no card row')
        self.s.tmux('kill-session', '-t', started)
        rs = self.wait_cards()
        self.assertFalse(self.s.has('card-session-' + started, rs), 'the Session ended, and its card stays')

    def test_a_change_of_the_default_while_the_app_runs_changes_the_list(self):
        self.store_default(None)
        self.wait_list(APP_DEFAULT)
        self.show_mode('sessions')
        app = self.s.pid
        for value, version in ((True, 'appkit'), (False, 'swiftui'), (True, 'appkit'), (None, APP_DEFAULT)):
            with self.subTest(default=value):
                self.store_default(value)
                self.wait_list(version)
                self.wait_cards()
        self.assertTrue(self.s.pid == app and alive(app), 'the app started again')

    def test_sessions_list_chooses_the_list_of_every_launch(self):
        self.assertEqual(self.first, sessions_list_option() or APP_DEFAULT,
                         'the first launch of this suite did not show the list that the run names')
        # The stored value does not win over the option.
        self.store_default(True)
        for option in ('swiftui', 'appkit'):
            with self.subTest(SESSIONS_LIST=option):
                self.start(option)
                self.assertEqual(self.s.sessions_list(), option)
                self.wait_cards()

    def test_the_appkit_list_slides_with_its_page(self):
        self.require_motion()
        self.show_list('appkit')
        self.show_mode('sessions')
        rest = self.settled('sessions-list')
        self.show_mode('topics')
        self.settled('topics-list')
        rs = self.s.rows()
        self.assertFalse(self.s.has('sessions-list', rs) or self.headers(rs), 'Topics shows, and the Sessions page is accessible')
        frames = self.s.act('press', 'sidebar-view-sessions', watch=['sessions-list'], watch_seconds=1.5)['frames'].get('sessions-list', [])
        self.wait_mode('sessions')
        # The frames that the app drew while the page slid in. A busy Mac draws few of them.
        places = [frame[0] for frame in frames]
        self.assertGreater(len(set(places)), 3, 'the list did not move with its page: it stood at %s' % places)
        self.assertGreater(max(places), rest[0] + rest[2] / 4, 'the list did not come in from the side: %s' % places)
        self.assert_close(frames[-1], rest, 'the list did not come to rest in its place')

    def test_a_held_swipe_moves_and_shrinks_both_lists_alike(self):
        self.require_motion()
        self.addCleanup(lambda: self.sample('Cancel current swipe'))
        rest, held = {}, {}
        for version in ('swiftui', 'appkit'):
            self.show_list(version)
            self.show_mode('sessions')
            rest[version] = self.settled('sessions-list')
            # The swipe pulls the Sessions page past its end, where it resists: the pager stands at 1.038.
            self.sample('Begin swipe left')
            self.wait_position('1.038')
            held[version] = self.settled('sessions-list')
            self.sample('Cancel current swipe')
            self.wait_mode('sessions')
        self.assert_close(rest['appkit'], rest['swiftui'], 'the two lists do not rest in the same place')
        self.assert_close(held['appkit'], held['swiftui'], 'the swipe does not hold the two lists in the same place')
        for version in ('swiftui', 'appkit'):
            self.assertLess(held[version][0], rest[version][0] - 5, 'the swipe did not move the %s list' % version)
            self.assertLess(held[version][2], rest[version][2], 'the swipe did not shrink the %s list' % version)

    def test_a_swipe_held_from_topics_hides_the_sessions_page_and_leaves_a_picture_of_each_version(self):
        self.require_motion()
        self.addCleanup(lambda: self.sample('Cancel current swipe'))
        for version in ('swiftui', 'appkit'):
            with self.subTest(version=version):
                self.show_list(version)
                self.show_mode('topics')
                self.sample('Begin swipe left')
                self.wait_position('0.400')
                self.settled('topics-list')
                rs = self.s.rows()
                self.assertFalse(self.s.has('sessions-list', rs) or self.headers(rs),
                                 'Topics is the mode, and the Sessions page is accessible')
                picture = self.s.root/('mid-swipe-%s.png' % version)
                self.s.act('snapshot', '', str(picture))
                self.assertGreater(picture.stat().st_size, 0)
                self.sample('Cancel current swipe')
                self.wait_mode('topics')

    def test_the_appkit_list_draws_again_when_the_interface_font_size_changes(self):
        """The Interface font size is one of the values that the SwiftUI Sidebar hands to the AppKit list."""
        def height(rs):
            card = self.s.row('card-session-' + self.sessions[0], rs)
            return rect(card)[3] if card else None
        self.show_list('appkit')
        self.show_mode('sessions')
        before = height(self.wait_cards())
        def restore():
            self.config.write_text(CONFIG)
            self.s.wait_rows(lambda rs: height(rs) == before, 'the cards did not go back to their height at 12')
        self.addCleanup(restore)
        self.config.write_text(CONFIG + 'ui:\n  font_size: 18\n')
        self.s.wait_rows(lambda rs: (height(rs) or 0) > before + 5,
                         lambda: 'a card is %s points high at ui.font_size: 18, and %s at 12' % (height(self.s.rows()), before))

    def test_the_appkit_list_stands_alone_when_topics_are_off(self):
        def restore():
            self.config.write_text(CONFIG)
            self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')
        self.show_list('appkit')
        self.addCleanup(restore)
        self.config.write_text(CONFIG + '  topics: false\n')
        self.s.wait_rows(lambda rs: not self.s.has('sidebar-view-topics', rs), 'the Sidebar kept its two views')
        self.wait_cards()
        self.assertEqual(self.s.sessions_list(), 'appkit')


if __name__ == '__main__':
    unittest.main()
