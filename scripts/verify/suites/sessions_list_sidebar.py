"""The Sidebar's Sessions list: the AppKit list that replaced the SwiftUI one
(docs/adr/0074-an-area-leaves-swiftui-for-appkit-only-where-swiftui-caused-bugs.md). The user signed it off, and the
SwiftUI list and the user default that chose between the two are gone
(docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).

The pager hides the page that its mode does not show from accessibility, so no dump has the Sessions list while a
swipe from Topics holds the Sidebar between its pages. The check of a held swipe therefore reads the list's frame
while Sessions shows, where the swipe pulls the page past its end. The check of the swipe from Topics keeps a
`snapshot` in the run directory, `mid-swipe.png`, for a person to look at.

The checks of a press on a card's header press it in two ways. `press` performs the header's default accessibility
action. `click` sends a mouse down and a mouse up to the App Window, which is not the key window, because the run
keeps the app behind the user's windows: it is a first click while Muxify is not the front app. The header follows
both.

A check never opens a context menu ("Do not take focus" in scripts/verify/README.md). A card gives its menu's items as
its named actions, from one list (`SidebarMenu` in UI/SidebarMenu.swift), so the check of Go to Session and Lock
Session runs them by `action` on the card, and reads the names with `actions`.

A click on a Window row aims at the middle of the row's first part, its app icon.

The checks of a press on a Pane row and on "N more…" press them as the header is pressed: by the accessibility action
and by a first click. A card shows all its rows from a press on its "N more…" until the app quits, so each press gets
a Session of its own.

The check of the glide to the card of the Location's Session presses a card's header, which moves the Location to its
Session, and `watch` reads the card's frames in each frame the app draws. The list reports each glide to Diagnostics,
which logs it as an animation with its duration (`DisplayLinkProbe.didStart(glide:in:duration:from:to:)`), so the
check turns Diagnostics on and reads the log. That the glide eases out shows in the frames: its first step is longer
than its last.

The check of a change of `ui.font_size` rewrites the Config while the app runs, waits for a closed card to grow, and
reads that the open cards, the selected Window row and the Location stay as they were.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.sessions_list_sidebar
"""

import re
import unittest

from scripts.verify.sandbox import Sandbox, wait

SHELL = '/bin/zsh -f'
# How a card's header is pressed: by its accessibility action, and by a first click.
PRESSES = ('press', 'click')
CONFIG = 'sidebar:\n  agents: false\n'
ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Sessions']
# The Sessions of the suite, in the order of their cards.
NAMES = ('list-first', 'list-second', 'list-third')
# SessionsListMetrics: the gap between two cards, the room beside the cards and the room above the first card.
CARD_SPACING = 6
HORIZONTAL_INSET = 6
VERTICAL_INSET = 4


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
        cls.sessions = [s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, SHELL) for name in NAMES]
        # The one Window of each Session.
        cls.windows = {session: s.tmux('list-windows', '-t', session, '-F', '#{window_id}') for session in cls.sessions}
        s.launch(ARGS)

    def setUp(self):
        self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')

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

    def test_the_list_has_a_card_for_each_session_with_its_gaps_and_insets(self):
        self.show_mode('sessions')
        # The page slides in for a moment after the switch, so the cards are read once the list is at rest.
        listed = self.settled('sessions-list')
        rs = self.wait_cards()
        self.assertEqual(self.s.row('sessions-list', rs).get('accessibilityRole'), 'AXScrollArea')
        self.assertEqual([(row['accessibilityIdentifier'], row.get('accessibilityLabel')) for row in self.headers(rs)],
                         [('session-' + session, name) for session, name in zip(self.sessions, NAMES)],
                         'the cards are not the Sessions, in their order and with their names')
        cards = []
        for header in self.headers(rs):
            card = self.s.row('card-' + header['accessibilityIdentifier'], rs)
            self.assertEqual(card.get('accessibilityRole'), 'AXGroup', 'the card of %s is no group' % header['accessibilityIdentifier'])
            self.assertEqual(header.get('accessibilityRole'), 'AXButton')
            cards.append(rect(card))
        # The insets from the list's edges, and the gaps between the cards. A frame counts up from the bottom of the
        # screen, so a top edge is its y and its height.
        top = lambda frame: frame[1] + frame[3]
        self.assert_close([cards[0][0], cards[0][0] + cards[0][2], top(cards[0])],
                          [listed[0] + HORIZONTAL_INSET, listed[0] + listed[2] - HORIZONTAL_INSET, top(listed) - VERTICAL_INSET],
                          'the first card does not stand at the insets of the list')
        gaps = [above[1] - top(below) for above, below in zip(cards, cards[1:])]
        self.assert_close(gaps, [CARD_SPACING] * (len(cards) - 1), 'the gaps between the cards')
        self.assert_close([card[0] for card in cards] + [card[2] for card in cards],
                          [cards[0][0]] * len(cards) + [cards[0][2]] * len(cards), 'the sides of the cards')

    def test_a_press_on_the_card_of_the_location_closes_and_opens_it(self):
        home, below = self.sessions[0], self.sessions[1]
        def top(rs=None):
            return sum(rect(self.s.row('card-session-' + below, rs))[1::2])
        self.show_mode('sessions')
        self.stand_on(home, opened=True)
        for command in PRESSES:
            with self.subTest(command=command):
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
        self.show_mode('sessions')
        for command in PRESSES:
            with self.subTest(command=command):
                # The other card is closed, and the Location is not on it.
                self.stand_on(other, opened=False)
                self.stand_on(home, opened=True)
                self.assertTrue(self.card_value(other).startswith('collapsed'), 'the other card did not stay closed')
                self.s.act(command, 'session-' + other)
                self.wait_card(other, 'expanded', 'a %s on the card of another Session did not open it' % command)
                self.s.wait_shown(self.windows[other])
                self.assertEqual(self.location(), [other], 'a press on the card of another Session did not go to it')
                self.assertTrue(self.card_value(home).startswith('expanded'), 'the card that the Location left closed')

    def test_the_named_actions_of_a_card_go_to_its_session_and_lock_it(self):
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'list-actions', SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        window = self.s.tmux('list-windows', '-t', session, '-F', '#{window_id}')
        lock = lambda: self.s.tmux('show-options', '-qv', '-t', session, '@muxify_lock')
        self.show_mode('sessions')
        self.stand_on(self.sessions[0], opened=True)
        self.wait_cards(self.sessions + [session])
        card = 'card-session-' + session
        # The names are the titles of the card's menu, in the order SwiftUI gives them: from the last item to the first.
        self.assertEqual(self.s.actions(card), [['Lock Session', 'New Topic from this Session', 'Move to Topic…', 'Go to Session']])
        self.assertEqual(self.s.actions('session-' + session), [['Lock Session', 'Go to Session']])

        self.s.act('action', card, 'Go to Session')
        self.s.wait_shown(window)
        self.assertEqual(self.location(), [session], 'Go to Session did not go to the Session of the card')

        self.s.act('action', card, 'Lock Session')
        wait(lambda: lock() != '', 'Lock Session did not set @muxify_lock', seconds=10)
        self.s.wait_rows(lambda rs: 'Locked' in self.card_value(session, rs).split(', '),
                         lambda: 'the header of the Locked Session has the value %r' % self.card_value(session))
        self.assertEqual(self.s.actions(card)[0][0], 'Unlock Session', 'the card of a Locked Session offers no Unlock Session')
        self.s.act('action', card, 'Unlock Session')
        wait(lambda: lock() == '', 'Unlock Session kept @muxify_lock', seconds=10)

    def test_a_click_on_a_window_row_goes_to_its_window(self):
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'list-rows', SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        first = self.s.tmux('list-windows', '-t', session, '-F', '#{window_id}')
        second = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', session + ':', SHELL)
        self.show_mode('sessions')
        for start, target in ((first, second), (second, first)):
            with self.subTest(target=target):
                self.s.show(start)
                self.s.wait_shown(start)
                if not self.card_value(session).startswith('expanded'):
                    self.s.act('press', 'session-' + session)
                self.s.wait_rows(lambda rs: self.s.has('session-window-' + target, rs),
                                 'the open card of %s has no row for %s' % (session, target))
                self.s.act('click', 'session-window-' + target)
                self.s.wait_shown(target)
                self.assertEqual(self.location('window_id'), [target], 'a click on its row did not go to the Window')

    def open_card(self, session, window):
        """Moves the Location to the Window and opens the card of its Session."""
        self.s.show(window)
        self.s.wait_shown(window)
        self.s.wait_rows(lambda rs: self.card_value(session, rs), 'the card of %s has no state' % session)
        if not self.card_value(session).startswith('expanded'):
            self.s.act('press', 'session-' + session)
        self.wait_card(session, 'expanded', 'the card of %s did not open' % session)

    def show_panes(self):
        def restore():
            self.config.write_text(CONFIG)
            self.s.wait_rows(lambda rs: not any(key.startswith('pane-') for key in self.s.ids(rs)), 'the Pane rows stay')
        self.addCleanup(restore)
        self.config.write_text(CONFIG + '  panes: true\n')

    def test_a_press_on_a_pane_row_goes_to_its_pane(self):
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'list-panes', SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        split = self.s.tmux('list-windows', '-t', session, '-F', '#{window_id}')
        first = self.s.tmux('display-message', '-p', '-t', split, '#{pane_id}')
        second = self.s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', split, SHELL)
        other = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', session + ':', SHELL)
        self.show_panes()
        self.show_mode('sessions')
        for command in PRESSES:
            with self.subTest(command=command):
                # The Location is on the other Window, and the first Pane is the active one of the split Window.
                self.s.tmux('select-pane', '-t', first)
                self.open_card(session, other)
                self.s.wait_rows(lambda rs: self.s.row('pane-' + second, rs).get('accessibilityValue') == '',
                                 'the card of %s has no row for the Pane %s that is not active' % (session, second))
                self.s.act(command, 'pane-' + second)
                self.s.wait_shown(split)
                wait(lambda: self.s.tmux('display-message', '-p', '-t', split, '#{pane_id}') == second,
                     'a %s on its row did not make the Pane %s active' % (command, second))
                self.assertEqual(self.location('window_id'), [split], 'a %s on its row did not go to the Window of the Pane' % command)
                self.s.wait_rows(lambda rs: self.s.row('pane-' + second, rs).get('accessibilityValue') == 'active',
                                 'the row of the Pane %s does not show it active' % second)

    def test_a_press_on_n_more_shows_all_rows_of_the_card(self):
        self.show_mode('sessions')
        for command in PRESSES:
            with self.subTest(command=command):
                name = 'list-more-%s' % command
                session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, SHELL)
                self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
                windows = [self.s.tmux('list-windows', '-t', session, '-F', '#{window_id}')]
                windows += [self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', session + ':', SHELL)
                            for _ in range(6)]
                more = 'session-%s-more' % session
                shown = lambda rs: [window for window in windows if self.s.has('session-window-' + window, rs)]
                # The Location is on the first Window, so the card lists the first five rows and holds two back.
                self.open_card(session, windows[0])
                rs = self.s.wait_rows(lambda rs: self.s.row(more, rs).get('accessibilityLabel') == '2 more…',
                                      lambda: 'the card of %s does not end with "2 more…": it has %r'
                                      % (session, self.s.row(more).get('accessibilityLabel')))
                self.assertEqual(shown(rs), windows[:5], 'the card does not list its first five rows')
                self.s.act(command, more)
                rs = self.s.wait_rows(lambda rs: shown(rs) == windows and not self.s.has(more, rs),
                                      lambda: 'a %s on "2 more…" did not show all rows: the card lists %s'
                                      % (command, shown(self.s.rows())))

    def glides(self):
        """The glides of the list in the Diagnostics log."""
        log = self.s.root/'logs/muxify.log'
        return [line for line in (log.read_text(errors='replace') if log.exists() else '').splitlines()
                if ' SessionsListGlide ' in line]

    def test_the_list_glides_to_the_card_of_the_location_and_stays_for_a_card_that_shows_whole(self):
        # More Sessions than the Sidebar shows, so the last card is far down the list.
        sessions = []
        for number in range(30):
            name = 'list-glide-%02d' % number
            sessions.append(self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, SHELL))
            self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', name)
        windows = {session: self.s.tmux('list-windows', '-t', session, '-F', '#{window_id}') for session in sessions}
        def restore():
            self.config.write_text(CONFIG)
        self.addCleanup(restore)
        self.config.write_text(CONFIG + 'diagnostics:\n  enabled: true\n')
        log = self.s.root/'logs/muxify.log'
        # A frame counts up from the bottom of the screen: its top edge is its y and its height.
        def top(frame):
            return frame[1] + frame[3]
        def bottom(frame):
            return frame[1]
        def card(session, rs=None):
            return rect(self.s.row('card-session-' + session, rs))
        self.show_mode('sessions')
        wait(lambda: re.search(r'(launch|on): pid %d\b' % self.s.pid, log.read_text(errors='replace') if log.exists() else ''),
             'Diagnostics did not turn on')
        # The Location on the first of these Sessions, and the list at its top.
        self.s.show(windows[sessions[0]])
        self.s.act('scroll', 'sessions-list', from_end=100000)
        shown = self.settled('sessions-list')
        rs = self.wait_cards(self.sessions + sessions)
        # The card lowest in the list, which is out of view.
        target = min(sessions, key=lambda session: bottom(card(session, rs)))
        self.assertLess(top(card(target, rs)), bottom(shown), 'the card of %s shows before the glide' % target)
        before = len(self.glides())

        frames = self.s.act('press', 'session-' + target, watch=['card-session-' + target],
                            watch_seconds=1.5)['frames'].get('card-session-' + target, [])
        self.s.wait_shown(windows[target])
        # The card's top edge, which only the glide moves: the press also opens the card, which grows down.
        places = [top(frame) for frame in frames]
        self.assertGreater(len(set(places)), 3, 'the list did not glide to the card of %s: it stood at %s' % (target, places))
        self.assertTrue(bottom(frames[-1]) >= bottom(shown) - .5 and top(frames[-1]) <= top(shown) + .5,
                        'the card of the Location %s does not show whole in the list %s after the glide' % (frames[-1], shown))
        glides = self.glides()[before:]
        self.assertEqual(len(glides), 1, 'the list did not glide once: %s' % glides)
        self.assertIn('duration 0.150s', glides[0])
        # Ease-out: the glide slows down to its end.
        steps = [abs(b - a) for a, b in zip(places, places[1:]) if b != a]
        self.assertGreater(steps[0], steps[-1], 'the glide did not slow down to its end: it stood at %s' % places)

        # A card that shows whole, the highest one in view: the Location goes to it, and the list does not move.
        rs = self.s.rows()
        whole = [session for session in sessions
                 if session != target and top(card(session, rs)) <= top(shown) + .5]
        still = max(whole, key=lambda session: top(card(session, rs)))
        before = len(self.glides())
        frames = self.s.act('press', 'session-' + still, watch=['card-session-' + still],
                            watch_seconds=1)['frames'].get('card-session-' + still, [])
        self.s.wait_shown(windows[still])
        self.wait_card(still, 'expanded', 'the card of the Location did not open')
        self.assertEqual(len(set(top(frame) for frame in frames)), 1,
                         'the list moved for the card of %s, which showed whole: %s' % (still, frames))
        self.assertEqual(top(self.settled('card-session-' + still)), top(frames[0]), 'the list moved after the move')
        self.assertEqual(self.glides()[before:], [], 'the list glided for a card that showed whole')

    def test_a_session_that_starts_or_ends_changes_the_cards_of_the_list(self):
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

    def test_the_list_slides_with_its_page(self):
        self.require_motion()
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

    def test_a_held_swipe_moves_and_shrinks_the_list(self):
        self.require_motion()
        self.addCleanup(lambda: self.sample('Cancel current swipe'))
        self.show_mode('sessions')
        rest = self.settled('sessions-list')
        # The swipe pulls the Sessions page past its end, where it resists: the pager stands at 1.038.
        self.sample('Begin swipe left')
        self.wait_position('1.038')
        held = self.settled('sessions-list')
        self.sample('Cancel current swipe')
        self.wait_mode('sessions')
        self.assertLess(held[0], rest[0] - 5, 'the swipe did not move the list')
        self.assertLess(held[2], rest[2], 'the swipe did not shrink the list')
        self.assert_close(self.settled('sessions-list'), rest, 'the list did not come back to rest in its place')

    def test_a_swipe_held_from_topics_hides_the_sessions_page_and_leaves_a_picture(self):
        self.require_motion()
        self.addCleanup(lambda: self.sample('Cancel current swipe'))
        self.show_mode('topics')
        self.sample('Begin swipe left')
        self.wait_position('0.400')
        self.settled('topics-list')
        rs = self.s.rows()
        self.assertFalse(self.s.has('sessions-list', rs) or self.headers(rs),
                         'Topics is the mode, and the Sessions page is accessible')
        picture = self.s.root/'mid-swipe.png'
        self.s.act('snapshot', '', str(picture))
        self.assertGreater(picture.stat().st_size, 0)
        self.sample('Cancel current swipe')
        self.wait_mode('topics')

    def test_a_change_of_the_interface_font_size_draws_the_list_again_and_keeps_its_open_cards_and_selected_row(self):
        """The Interface font size is one of the values that the SwiftUI Sidebar hands to the AppKit list. A change of
        `ui.font_size` in the Config applies at once, and changes nothing that is open or selected (ADR 0068)."""
        home, other, closed = self.sessions
        def height(rs):
            card = self.s.row('card-session-' + closed, rs)
            return rect(card)[3] if card else None
        def state(rs):
            """The open state of each card, and the selected Window rows."""
            cards = {session: self.card_value(session, rs).split(',')[0] for session in self.sessions}
            selected = sorted({row['accessibilityIdentifier'] for row in rs if row.get('accessibilityValue') == 'selected'
                               and row.get('accessibilityIdentifier', '').startswith('session-window-')})
            return cards, selected
        designed = []
        def restore():
            self.config.write_text(CONFIG)
            if designed:
                self.s.wait_rows(lambda rs: height(rs) == designed[0], 'the cards did not go back to their height at 12')
        self.addCleanup(restore)
        self.show_mode('sessions')
        # Two cards open, one of them the Location's, and one closed.
        self.stand_on(closed, opened=False)
        self.stand_on(other, opened=True)
        self.stand_on(home, opened=True)
        rs = self.wait_cards()
        shown = state(rs)
        self.assertEqual(shown, ({home: 'expanded', other: 'expanded', closed: 'collapsed'},
                                 ['session-window-' + self.windows[home]]), 'the list did not get ready')
        designed[:] = [height(rs)]
        self.config.write_text(CONFIG + 'ui:\n  font_size: 18\n')
        rs = self.s.wait_rows(lambda rs: (height(rs) or 0) > designed[0] + 5,
                              lambda: 'a card is %s points high at ui.font_size: 18, and %s at 12'
                              % (height(self.s.rows()), designed[0]))
        self.assertEqual(state(rs), shown, 'ui.font_size: 18 changed the open cards or the selected row')
        self.config.write_text(CONFIG)
        rs = self.s.wait_rows(lambda rs: height(rs) == designed[0], 'the cards did not go back to their height at 12')
        self.assertEqual(state(rs), shown, 'ui.font_size: 12 changed the open cards or the selected row')
        self.assertEqual(self.location(), [home], 'a change of ui.font_size moved the Location')

    def test_the_list_stands_alone_when_topics_are_off(self):
        def restore():
            self.config.write_text(CONFIG)
            self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')
        self.addCleanup(restore)
        self.config.write_text(CONFIG + '  topics: false\n')
        self.s.wait_rows(lambda rs: not self.s.has('sidebar-view-topics', rs), 'the Sidebar kept its two views')
        self.wait_cards()


if __name__ == '__main__':
    unittest.main()
