"""The Sidebar's two Topics lists: the SwiftUI list, and the AppKit list that replaces it
(docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).

The user default `topicsListAppKit` chooses the list: missing or false is the SwiftUI list, and true is the AppKit
list. A check stores it as a user does, with `defaults write` on the bundle id of this run's app copy. A launch
argument hides the stored value from the app, so a check that stores the default first starts the app without that
argument, also in a run with `TOPICS_LIST`.

The AppKit list draws bare cards for now: a border and the title. So the checks compare what a bare card has with the
SwiftUI card: the rows of the card and its header, their order and their titles, and where the cards start and how
far apart they stand. A bare card is lower than a SwiftUI card.

The pager hides the page that its mode does not show from accessibility, so no dump has the Topics list while
Sessions shows; the driver's `topics-list` still finds the AppKit list then, as the page that does not show. The check
of a held swipe holds the Sidebar at 0.400 from Topics, where the Topics page has moved and shrunk, and keeps a
`snapshot` of each version in the run directory, `mid-swipe-swiftui.png` and `mid-swipe-appkit.png`, for a person to
compare the fade. While the pager slides or Sessions shows, it takes the Topics page's clicks too (`allowsHitTesting`
in SidebarPager.swift), and a bare card does nothing on a click, so no check clicks it.

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
        for order, (topic, title) in enumerate(TOPICS):
            cls.topic(topic, title, order)
        locked = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'list-locked', SHELL)
        s.tmux('set-option', '-t', locked, '@muxify_lock', str(len(TOPICS)))
        # The headers of the cards, in the Topic order: the Topics, then the Locked Session after them.
        cls.keys = ['topic-' + topic for topic, _ in TOPICS] + ['locked-' + locked]
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
        self.assertEqual(self.s.topics_list(), APP_DEFAULT, 'a launch with no user default shows another Topics list')
        self.show_mode('topics')
        self.wait_cards()

    def test_with_the_default_true_the_appkit_list_has_a_bare_card_for_each_topic_in_order(self):
        self.show_list('swiftui')
        before = self.wait_cards()
        swiftui_list = self.settled('topics-list')
        swiftui = [rect(self.s.row('card-' + key, before)) for key in self.keys]

        self.show_list('appkit')
        rs = self.wait_cards()
        self.assertEqual(self.s.row('topics-list', rs).get('accessibilityRole'), 'AXScrollArea')
        self.assert_close(self.settled('topics-list'), swiftui_list, 'the two lists do not take the same place')
        self.assertEqual([(row['accessibilityIdentifier'], row.get('accessibilityLabel')) for row in self.headers(rs)],
                         [(row['accessibilityIdentifier'], row.get('accessibilityLabel')) for row in self.headers(before)],
                         'the AppKit cards are not the SwiftUI cards, in their order and with their titles')
        self.assertEqual([row.get('accessibilityLabel') for row in self.headers(rs)][:len(TOPICS)],
                         [title for _, title in TOPICS], 'the cards do not have the titles of the Topics')
        cards = []
        for header in self.headers(rs):
            card = self.s.row('card-' + header['accessibilityIdentifier'], rs)
            self.assertEqual(card.get('accessibilityRole'), 'AXGroup', 'the card of %s is no group' % header['accessibilityIdentifier'])
            self.assertEqual(header.get('accessibilityRole'), 'AXButton')
            cards.append(rect(card))
        # The same insets from the list's edges, and the same gaps between the cards. A bare card is lower than a
        # SwiftUI card, so the cards under the first one start higher.
        top = lambda card: card[1] + card[3]
        self.assert_close([cards[0][0], cards[0][2], top(cards[0])], [swiftui[0][0], swiftui[0][2], top(swiftui[0])],
                          'the first card does not start where the SwiftUI card starts')
        for side, name in ((cards, 'AppKit'), (swiftui, 'SwiftUI')):
            gaps = [above[1] - top(below) for above, below in zip(side, side[1:])]
            self.assert_close(gaps, [6] * (len(side) - 1), 'the gaps between the %s cards' % name)
            self.assert_close([card[0] for card in side] + [card[2] for card in side],
                              [side[0][0]] * len(side) + [side[0][2]] * len(side), 'the sides of the %s cards' % name)

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
