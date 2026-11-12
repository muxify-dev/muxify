"""The Sidebar's two Topics lists: the SwiftUI list, and the AppKit list that replaces it
(docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).

The user default `topicsListAppKit` chooses the list: missing or false is the SwiftUI list, and true is the AppKit
list. A check stores it as a user does, with `defaults write` on the bundle id of this run's app copy. A launch
argument hides the stored value from the app, so a check that stores the default first starts the app without that
argument, also in a run with `TOPICS_LIST`.

The check of the cards closes the Location's card first, and compares the rows of the cards and their headers in the
two versions: their order, labels, values and help, and their frames. The compare run (`make compare AREA=topics`)
compares open cards, the No Topic card and a header that sticks.

The checks of an open Topic card in the AppKit list make their own Topic with live Sessions named as Muxify names
them, `<base>/<Topic ID>`, and remove it at their end: a click on a Window row, a press on a Pane row, on a Session line
and on "N more…", and a header that sticks to the top of the list and never passes the card's last row. The AppKit
list glides a card that opens with Core Animation, whose frames a dump does not read, so the checks prove where the
cards below come to rest; the glide is for the eye.

The checks of a press on a card's header press it in two ways. `press` performs the header's default accessibility
action. `click` sends a mouse down and a mouse up to the App Window, which is not the key window, because the run
keeps the app behind the user's windows: it is a first click while Muxify is not the front app. The header follows
both. The check of a press on a Locked card runs the same presses in both versions and compares what they did.

The pager hides the page that its mode does not show from accessibility, so no dump has the Topics list while
Sessions shows; the driver's `topics-list` still finds the AppKit list then, as the page that does not show. The check
of a held swipe holds the Sidebar at 0.400 from Topics, where the Topics page has moved and shrunk, and keeps a
`snapshot` of each version in the run directory, `mid-swipe-swiftui.png` and `mid-swipe-appkit.png`, for a person to
compare the fade. While the pager slides or Sessions shows, it takes the Topics page's clicks too (`allowsHitTesting`
in SidebarPager.swift), so the checks click a card only while Topics shows.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_list_sidebar
"""

import os
import re
import subprocess
import unittest
from unittest.mock import patch

from scripts.verify.sandbox import TOPICS_LIST, TOPICS_LIST_DEFAULT, Sandbox, alive, topics_list_option, wait
from scripts.verify.topic_records import TopicRecords

SHELL = '/bin/zsh -f'
CONFIG = 'sidebar:\n  agents: false\n'
ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics']
# What the app shows when nothing sets the user default.
APP_DEFAULT = 'swiftui'
# The Topics of the fixture: (id, title), in the Topic order.
TOPICS = [('list-first', 'List first'), ('list-second', 'List second'), ('list-third', 'List third')]
# How a card's header is pressed: by its accessibility action, and by a first click.
PRESSES = ('press', 'click')


def rect(row):
    """[x, y, width, height] of a dump row's accessibilityFrame, in screen points."""
    return [float(number) for number in re.findall(r'-?[\d.]+', row['accessibilityFrame'])]


class TopicsListSidebar(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text(CONFIG)
        cls.store = TopicRecords(s.root/'state/muxify')
        # The Session of each card's header.
        cls.sessions = {'topic-' + topic: cls.topic(topic, title, order) for order, (topic, title) in enumerate(TOPICS)}
        locked = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'list-locked', SHELL)
        s.tmux('set-option', '-t', locked, '@muxify_lock', str(len(TOPICS)))
        cls.sessions['locked-' + locked] = locked
        # The headers of the cards, in the Topic order: the Topics, then the Locked Session after them.
        cls.keys = ['topic-' + topic for topic, _ in TOPICS] + ['locked-' + locked]
        # The Window of each card's header.
        cls.windows = {key: s.tmux('list-windows', '-t', session, '-F', '#{window_id}') for key, session in cls.sessions.items()}
        # As every suite launches: with the list that TOPICS_LIST names, or the app's default.
        s.launch(ARGS)
        cls.argument = topics_list_option() is not None
        cls.first = s.topics_list()

    @classmethod
    def topic(cls, topic, title, order):
        """A Topic with a live Session that names it. Returns the Session's id."""
        cls.store.put(dict(id=topic, title=title, slug=topic, order=order))
        session = cls.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', topic, SHELL)
        cls.s.tmux('set-option', '-t', session, '@muxify_topic', topic)
        return session

    def setUp(self):
        self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')
        self.show_mode('topics')

    @classmethod
    def start(cls, option=None):
        """Starts the app again, as `make verify TOPICS_LIST=<option>` starts it. Without an option the app gets no
        launch argument for the user default, so it follows the stored value."""
        with patch.dict(os.environ):
            os.environ.pop(TOPICS_LIST, None)
            if option:
                os.environ[TOPICS_LIST] = option
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
            subprocess.run(['defaults', 'delete', self.s.bundle_id, TOPICS_LIST_DEFAULT], capture_output=True)
        else:
            subprocess.run(['defaults', 'write', self.s.bundle_id, TOPICS_LIST_DEFAULT, '-bool', 'YES' if value else 'NO'],
                           check=True, capture_output=True)

    def wait_list(self, version):
        wait(lambda: self.s.topics_list() == version,
             lambda: 'the App Window shows the %s Topics list, not the %s list' % (self.s.topics_list(), version))

    def show_list(self, version):
        self.store_default(version == 'appkit')
        self.wait_list(version)

    def headers(self, rs, keys=None):
        """The header rows of the cards of the Topics list, from its top."""
        keys = keys or self.keys
        return [row for row in rs if row.get('accessibilityIdentifier') in keys]

    def wait_cards(self, keys=None):
        """The rows once the Topics list shows a card for each of the headers, in their order, and for no other."""
        wanted = keys or self.keys
        last = []
        def shown(rs):
            last[:] = self.s.ids(self.headers(rs, wanted))
            others = [key for key in self.s.ids(rs) if re.fullmatch(r'topic-list-[a-z]+|locked-\$\d+', key)
                      and key not in wanted]
            return self.s.has('topics-list', rs) and last == wanted and not others
        return self.s.wait_rows(shown, lambda: 'the Topics list shows the cards %s, not %s' % (last, wanted))

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

    def card_value(self, key, rs=None):
        return self.s.row(key, rs).get('accessibilityValue') or ''

    def wait_card(self, key, state, message):
        """Waits until the header has the state, `expanded` or `collapsed`, at the start of its value."""
        self.s.wait_rows(lambda rs: self.card_value(key, rs).startswith(state),
                         lambda: '%s: the value of its header is %r' % (message, self.card_value(key)))

    def location(self):
        """The Session of the Location: the one of the app's tmux client that is no control client."""
        clients = self.s.tmux('list-clients', '-F', '#{client_control_mode} #{session_id}').splitlines()
        return [line.split()[1] for line in clients if line.startswith('0 ')]

    def stand_on(self, key, opened):
        """Moves the Location to the Session of the card's header, and opens or closes the card. Only a press on the
        card of the Location closes it."""
        self.s.show(self.windows[key])
        self.s.wait_rows(lambda rs: self.card_value(key, rs), 'the card %s has no state' % key)
        if self.card_value(key).startswith('expanded') != opened:
            self.s.act('press', key)
        self.wait_card(key, 'expanded' if opened else 'collapsed', 'the card of the Location did not get ready')

    def require_motion(self):
        """The Sidebar follows a swipe only while it animates. Reduce Motion in System Settings stops that for every app."""
        if self.s.row('sidebar-swipe-input').get('accessibilityLabel', '').startswith('Sidebar swipe input instant'):
            self.skipTest('Reduce Motion is on, so the Sidebar does not follow a swipe')

    def sample(self, name):
        self.s.act('action', 'sidebar-swipe-input', name)

    def assert_close(self, first, second, message):
        self.assertTrue(len(first) == len(second) and all(abs(a - b) <= .5 for a, b in zip(first, second)),
                        '%s: %s and %s' % (message, first, second))

    def topic_with(self, topic, sessions):
        """A Topic, last in the Topic order, with a live Session `<base>/<topic>` for each (base, Window names) of
        `sessions`. Returns {base: (Session id, Window ids)}. The check's cleanup removes them."""
        self.store.put(dict(id=topic, title=topic.replace('-', ' ').capitalize(), slug=topic, order=100))
        self.addCleanup(self.store.remove, topic)
        found = {}
        for base, windows in sessions:
            session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', base + '/' + topic, '-n', windows[0], SHELL)
            self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
            ids = [self.s.tmux('display-message', '-p', '-t', session + ':', '#{window_id}')]
            ids += [self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', session + ':', '-n', window, SHELL)
                    for window in windows[1:]]
            self.s.tmux('set-option', '-t', session, '@muxify_topic', topic)
            found[base] = (session, ids)
        return found

    def open_topic(self, topic, window):
        """Moves the Location to the Window of the Topic, whose card then opens, and returns the rows."""
        self.s.show(window)
        self.wait_card('topic-' + topic, 'expanded', 'the card of the Topic %s did not open' % topic)
        return self.s.rows()

    def show_panes(self):
        def restore():
            self.config.write_text(CONFIG)
            self.s.wait_rows(lambda rs: not any(key.startswith('pane-') for key in self.s.ids(rs)), 'the Pane rows stay')
        self.addCleanup(restore)
        self.config.write_text(CONFIG + '  panes: true\n')

    def test_without_the_default_the_sidebar_shows_the_swiftui_list(self):
        self.write_default(None)
        self.start()
        self.assertEqual(self.s.topics_list(), APP_DEFAULT, 'a launch with no user default shows another Topics list')
        self.show_mode('topics')
        self.wait_cards()

    def test_with_the_default_true_the_appkit_list_has_a_card_for_each_topic_in_order(self):
        def header_rows(rs):
            return [(row['accessibilityIdentifier'], row.get('accessibilityRole'), row.get('accessibilityLabel'),
                     row.get('accessibilityValue'), row.get('accessibilityHelp')) for row in self.headers(rs)]
        self.show_list('swiftui')
        self.stand_on(self.keys[0], opened=False)
        before = self.wait_cards()
        swiftui_list = self.settled('topics-list')
        swiftui = [self.settled('card-' + key) for key in self.keys]

        self.show_list('appkit')
        rs = self.wait_cards()
        self.assertEqual(self.s.row('topics-list', rs).get('accessibilityRole'), 'AXScrollArea')
        self.assert_close(self.settled('topics-list'), swiftui_list, 'the two lists do not take the same place')
        self.assertEqual(header_rows(rs), header_rows(before),
                         'the AppKit headers are not the SwiftUI headers, in their order, labels, values and help')
        self.assertEqual([row.get('accessibilityLabel') for row in self.headers(rs)][:len(TOPICS)],
                         [title for _, title in TOPICS], 'the cards do not have the titles of the Topics')
        for key, frame in zip(self.keys, swiftui):
            card = self.s.row('card-' + key, rs)
            self.assertEqual(card.get('accessibilityRole'), 'AXGroup', 'the card of %s is no group' % key)
            self.assert_close(rect(card), frame, 'the card of %s does not stand where the SwiftUI card stands' % key)
        top = lambda card: card[1] + card[3]
        gaps = [above[1] - top(below) for above, below in zip(swiftui, swiftui[1:])]
        self.assert_close(gaps, [6] * (len(swiftui) - 1), 'the gaps between the cards')

    def test_a_press_on_the_header_of_the_active_topics_card_closes_and_opens_it(self):
        home, below = self.keys[0], self.keys[1]
        def bottom(rs=None):
            return top_of(self.s.row('card-' + below, rs))
        top_of = lambda row: sum(rect(row)[1::2])
        self.show_list('appkit')
        self.stand_on(home, opened=True)
        for command in PRESSES:
            with self.subTest(command=command):
                opened = bottom(self.wait_cards())
                self.s.act(command, home)
                self.wait_card(home, 'collapsed', 'a %s on the open card of the Active Topic did not close it' % command)
                # A closed card shows its Summary under its title, and the card below stands under it.
                self.assertTrue(self.s.row(home).get('accessibilityHelp'), 'the closed card has no Summary')
                closed = self.settled('card-' + below)
                self.assertNotEqual(closed[1] + closed[3], opened, 'the card below did not move when the card closed')
                self.s.act(command, home)
                self.wait_card(home, 'expanded', 'a %s on the closed card of the Active Topic did not open it' % command)
                self.assertEqual(self.s.row(home).get('accessibilityHelp'), '', 'an open card has a Summary')
                again = self.settled('card-' + below)
                self.assertEqual(again[1] + again[3], opened, 'the card below did not go back when the card opened')
                self.assertEqual(self.location(), [self.sessions[home]], 'a press on the Active Topic\'s card moved the Location')

    def test_a_press_on_another_card_opens_it_and_goes_to_its_topic(self):
        home, other = self.keys[0], self.keys[2]
        self.show_list('appkit')
        for command in PRESSES:
            with self.subTest(command=command):
                # The other card is closed, and the Location is not on it.
                self.stand_on(other, opened=False)
                self.stand_on(home, opened=True)
                self.wait_card(other, 'collapsed', 'the other card did not stay closed')
                self.s.act(command, other)
                self.wait_card(other, 'expanded', 'a %s on the card of another Topic did not open it' % command)
                self.s.wait_shown(self.windows[other])
                self.assertEqual(self.location(), [self.sessions[other]], 'a press on the card of another Topic did not go to it')

    def test_a_press_on_a_locked_card_does_what_it_does_in_the_swiftui_list(self):
        """From the open card of a Topic, a press on the Locked card goes to its Session and opens the card, a second
        press closes it, and a third opens it again."""
        home, locked = self.keys[0], self.keys[-1]
        did = {}
        for version in ('swiftui', 'appkit'):
            self.show_list(version)
            for command in PRESSES:
                with self.subTest(version=version, command=command):
                    self.stand_on(home, opened=True)
                    self.wait_card(locked, 'collapsed', 'the Locked card is open before the press')
                    steps = []
                    for state in ('expanded', 'collapsed', 'expanded'):
                        self.s.act(command, locked)
                        self.wait_card(locked, state, 'a %s on the Locked card did not leave it %s' % (command, state))
                        self.s.wait_shown(self.windows[locked])
                        steps.append((self.card_value(locked), self.location()))
                    did[version, command] = steps
                    self.assertEqual([location for _, location in steps], [[self.sessions[locked]]] * 3,
                                     'a press on the Locked card did not go to its Session')
        for command in PRESSES:
            self.assertEqual(did['appkit', command], did['swiftui', command],
                             'a %s on the Locked card does not do in the AppKit list what it does in the SwiftUI list' % command)

    def test_a_click_on_a_window_row_of_an_open_topic_card_goes_to_its_window(self):
        self.show_list('appkit')
        (_, (home, other)), = self.topic_with('open-rows', [('one', ['main', 'logs'])]).values()
        self.open_topic('open-rows', home)
        row = 'topic-window-' + other
        rs = self.s.wait_rows(lambda rs: self.s.row(row, rs).get('accessibilityValue') == '',
                              'the open card has no Window row %s that is not the Location\'s' % row)
        self.assertEqual(self.s.row(row, rs).get('accessibilityRole'), 'AXButton', 'the Window row is not one button')
        self.assertEqual(self.s.row(row, rs).get('accessibilityLabel'), 'logs, 1', 'the Window row does not name its title and Pane count')
        self.s.act('click', row)
        self.s.wait_shown(other)
        self.s.wait_rows(lambda rs: self.s.row(row, rs).get('accessibilityValue') == 'selected'
                         and self.s.row('topic-window-' + home, rs).get('accessibilityValue') == '',
                         'the tint did not go to the Window row that the click went to')

    def test_a_press_on_a_pane_row_of_an_open_topic_card_goes_to_that_pane(self):
        self.show_list('appkit')
        (_, (home, split)), = self.topic_with('open-panes', [('one', ['main', 'split'])]).values()
        second = self.s.tmux('split-window', '-d', '-P', '-F', '#{pane_id}', '-t', split, SHELL)
        self.show_panes()
        self.open_topic('open-panes', home)
        self.s.wait_rows(lambda rs: self.s.row('pane-' + second, rs).get('accessibilityValue') == '',
                         'the open card has no row for the Pane %s that is not active' % second)
        self.s.act('press', 'pane-' + second)
        self.s.wait_shown(split)
        wait(lambda: self.s.tmux('display-message', '-p', '-t', split, '#{pane_id}') == second,
             'a press on its row did not make the Pane %s active' % second)
        self.s.wait_rows(lambda rs: self.s.row('pane-' + second, rs).get('accessibilityValue') == 'active',
                         'the row of the Pane %s does not show it active' % second)

    def test_a_press_on_a_session_line_of_an_open_topic_card_goes_to_its_session(self):
        self.show_list('appkit')
        found = self.topic_with('open-lines', [('one', ['main']), ('two', ['main', 'logs'])])
        (_, (home,)), (two, (_, logs)) = found['one'], found['two']
        self.s.tmux('select-window', '-t', logs)
        line = 'topic-open-lines-session-' + two
        for command in PRESSES:
            with self.subTest(command=command):
                self.open_topic('open-lines', home)
                rs = self.s.wait_rows(lambda rs: self.s.has(line, rs), 'the open card has no Session line %s' % line)
                self.assertEqual((self.s.row(line, rs).get('accessibilityRole'), self.s.row(line, rs).get('accessibilityLabel')),
                                 ('AXButton', 'two'), 'the Session line is not a button with the Session\'s name')
                self.s.act(command, line)
                self.s.wait_shown(logs)
                self.assertEqual(self.location(), [two], 'a %s on the Session line did not go to its Session' % command)

    def test_a_press_on_n_more_of_an_open_topic_card_shows_all_its_rows(self):
        self.show_list('appkit')
        (_, windows), = self.topic_with('open-more', [('one', ['w%d' % number for number in range(1, 8)])]).values()
        self.open_topic('open-more', windows[0])
        more = 'topic-open-more-more'
        rs = self.s.wait_rows(lambda rs: self.s.row(more, rs).get('accessibilityLabel') == '2 more…',
                              'the open card does not end with "2 more…"')
        self.assertEqual([window for window in windows if self.s.has('topic-window-' + window, rs)], windows[:5],
                         'the card lists other rows than the first five')
        self.s.act('press', more)
        rs = self.s.wait_rows(lambda rs: all(self.s.has('topic-window-' + window, rs) for window in windows),
                              '"N more…" did not list the rows it held back')
        self.assertFalse(self.s.has(more, rs), '"N more…" stays after every row shows')

    def test_the_header_of_an_open_topic_card_sticks_to_the_top_and_never_passes_its_last_row(self):
        # The top and bottom edges of a row, in points down from the top of the screen.
        def edges(key, rs):
            x, y, width, height = rect(self.s.row(key, rs))
            return -(y + height), -y
        def scroll(by):
            self.s.act('scroll', 'topics-list', by=by, steps=1)
        self.show_list('appkit')
        (_, windows), = self.topic_with('open-sticky', [('one', ['w%02d' % number for number in range(1, 41)])]).values()
        # Empty Topics after the card, so the list can scroll the card's end up to its top. They need only a record.
        for number in range(16):
            filler = 'open-filler-%02d' % number
            self.store.put(dict(id=filler, title='Filler %02d' % number, slug=filler, order=200 + number))
            self.addCleanup(self.store.remove, filler)
        card, header = 'card-topic-open-sticky', 'topic-open-sticky'
        # The Location on the card's last Window, so the card lists every row.
        self.open_topic('open-sticky', windows[-1])
        self.s.wait_rows(lambda rs: self.s.has('topic-window-' + windows[-1], rs) and self.s.has('topic-open-filler-15', rs),
                         'the open card does not list all its rows above the Empty Topics')
        rs = self.s.rows()
        list_top = edges('topics-list', rs)[0]

        scroll(edges(card, rs)[0] - list_top + 100)
        rs = self.s.wait_rows(lambda rs: edges(card, rs)[0] < list_top - 50, 'the list did not scroll the card\'s top away')
        self.assertLess(abs(edges(header, rs)[0] - list_top), .5, 'the header %s does not stick to the top of the list at %s'
                        % (edges(header, rs), list_top))

        scroll(edges(card, rs)[1] - list_top - 20)
        rs = self.s.wait_rows(lambda rs: edges(card, rs)[1] < list_top + 40, 'the list did not scroll the card\'s end to its top')
        card_bottom, (header_top, header_bottom) = edges(card, rs)[1], edges(header, rs)
        self.assertLess(header_top, list_top - 1, 'the header did not leave the top with the card\'s end')
        self.assertLessEqual(header_bottom, card_bottom - 8 + .5,
                             'the header %s passed the card\'s last row, whose card ends at %s' % ((header_top, header_bottom), card_bottom))

    def test_the_no_topic_card_lists_the_window_rows_of_its_session(self):
        self.show_list('appkit')
        session = self.s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'open-scratch', SHELL)
        self.addCleanup(self.s.tmux_ok, 'kill-session', '-t', session)
        home = self.s.tmux('display-message', '-p', '-t', session + ':', '#{window_id}')
        other = self.s.tmux('new-window', '-d', '-P', '-F', '#{window_id}', '-t', session + ':', SHELL)
        self.s.show(home)
        header = 'no-topic-session-' + session
        self.wait_card(header, 'expanded', 'the No Topic card of the Location did not open')
        rs = self.s.wait_rows(lambda rs: self.s.has('topic-window-' + other, rs), 'the No Topic card does not list its Window rows')
        self.assertTrue(self.s.has('card-' + header, rs), 'the No Topic card has no card row')
        self.s.act('click', 'topic-window-' + other)
        self.s.wait_shown(other)

    def test_a_topic_that_comes_or_goes_changes_the_cards_of_the_appkit_list(self):
        self.show_list('appkit')
        self.wait_cards()
        def remove():
            self.s.tmux_ok('kill-session', '-t', 'list-fourth')
            self.store.remove('list-fourth')
        self.addCleanup(remove)
        self.topic('list-fourth', 'List fourth', len(TOPICS) + 1)
        rs = self.wait_cards(self.keys + ['topic-list-fourth'])
        self.assertEqual(self.s.row('topic-list-fourth', rs).get('accessibilityLabel'), 'List fourth')
        self.assertTrue(self.s.has('card-topic-list-fourth', rs), 'the new Topic has no card row')
        remove()
        rs = self.wait_cards()
        self.assertFalse(self.s.has('card-topic-list-fourth', rs), 'the Topic went, and its card stays')

    def test_a_change_of_the_default_while_the_app_runs_changes_the_list(self):
        self.store_default(None)
        self.wait_list(APP_DEFAULT)
        self.show_mode('topics')
        app = self.s.pid
        for value, version in ((True, 'appkit'), (False, 'swiftui'), (True, 'appkit'), (None, APP_DEFAULT)):
            with self.subTest(default=value):
                self.store_default(value)
                self.wait_list(version)
                self.wait_cards()
        self.assertTrue(self.s.pid == app and alive(app), 'the app started again')

    def test_topics_list_chooses_the_list_of_every_launch(self):
        self.assertEqual(self.first, topics_list_option() or APP_DEFAULT,
                         'the first launch of this suite did not show the list that the run names')
        # The stored value does not win over the option.
        self.store_default(True)
        for option in ('swiftui', 'appkit'):
            with self.subTest(TOPICS_LIST=option):
                self.start(option)
                self.assertEqual(self.s.topics_list(), option)
                self.show_mode('topics')
                self.wait_cards()

    def test_the_appkit_list_slides_with_its_page_and_hides_while_sessions_shows(self):
        self.require_motion()
        self.show_list('appkit')
        rest = self.settled('topics-list')
        self.show_mode('sessions')
        self.settled('sessions-list')
        rs = self.s.rows()
        self.assertFalse(self.s.has('topics-list', rs) or self.headers(rs), 'Sessions shows, and the Topics page is accessible')
        self.assertEqual(self.s.topics_list(), 'appkit', 'the AppKit list left the Sidebar while Sessions shows')
        frames = self.s.act('press', 'sidebar-view-topics', watch=['topics-list'], watch_seconds=1.5)['frames'].get('topics-list', [])
        self.wait_mode('topics')
        # The frames that the app drew while the page slid in. A busy Mac draws few of them.
        places = [frame[0] for frame in frames]
        self.assertGreater(len(set(places)), 3, 'the list did not move with its page: it stood at %s' % places)
        self.assertLess(min(places), rest[0] - rest[2] / 4, 'the list did not come in from the side: %s' % places)
        self.assert_close(frames[-1], rest, 'the list did not come to rest in its place')
        self.wait_cards()

    def test_a_held_swipe_moves_and_shrinks_both_lists_alike_and_leaves_a_picture_of_each(self):
        self.require_motion()
        self.addCleanup(lambda: self.sample('Cancel current swipe'))
        rest, held = {}, {}
        for version in ('swiftui', 'appkit'):
            self.show_list(version)
            self.show_mode('topics')
            rest[version] = self.settled('topics-list')
            self.sample('Begin swipe left')
            self.wait_position('0.400')
            held[version] = self.settled('topics-list')
            picture = self.s.root/('mid-swipe-%s.png' % version)
            self.s.act('snapshot', '', str(picture))
            self.assertGreater(picture.stat().st_size, 0)
            self.sample('Cancel current swipe')
            self.wait_mode('topics')
        self.assert_close(rest['appkit'], rest['swiftui'], 'the two lists do not rest in the same place')
        self.assert_close(held['appkit'], held['swiftui'], 'the swipe does not hold the two lists in the same place')
        for version in ('swiftui', 'appkit'):
            self.assertLess(held[version][0], rest[version][0] - 5, 'the swipe did not move the %s list' % version)
            self.assertLess(held[version][2], rest[version][2], 'the swipe did not shrink the %s list' % version)

    def test_the_appkit_list_draws_again_when_the_interface_font_size_changes(self):
        """The Interface font size is one of the values that the SwiftUI Sidebar hands to the AppKit list."""
        def height(rs):
            card = self.s.row('card-' + self.keys[1], rs)
            return rect(card)[3] if card else None
        self.show_list('appkit')
        before = height(self.wait_cards())
        def restore():
            self.config.write_text(CONFIG)
            self.s.wait_rows(lambda rs: height(rs) == before, 'the cards did not go back to their height at 12')
        self.addCleanup(restore)
        self.config.write_text(CONFIG + 'ui:\n  font_size: 18\n')
        self.s.wait_rows(lambda rs: (height(rs) or 0) > before + 5,
                         lambda: 'a card is %s points high at ui.font_size: 18, and %s at 12' % (height(self.s.rows()), before))

    def test_the_appkit_list_stands_alone_when_sessions_are_off(self):
        def restore():
            self.config.write_text(CONFIG)
            self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')
        self.show_list('appkit')
        self.addCleanup(restore)
        self.config.write_text(CONFIG + '  sessions: false\n')
        self.s.wait_rows(lambda rs: not self.s.has('sidebar-view-topics', rs), 'the Sidebar kept its two views')
        self.wait_cards()
        self.assertEqual(self.s.topics_list(), 'appkit')


if __name__ == '__main__':
    unittest.main()
