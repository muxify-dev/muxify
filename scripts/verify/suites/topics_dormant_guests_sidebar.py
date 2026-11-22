"""A Guest Session after a tmux restart: its Lock in the state database keeps its card at its place among the Guests,
Dormant, and a press on the card creates its Session again with its Windows. Its page offers Start Fresh, which
creates the Session with one shell Window.

A restart ends every Session of the fixture, so these checks have a suite of their own. GuestSessionLockTests and
EnvironmentPublisherTests prove the rules: a restart keeps the Lock, and an end on the same server ends it.

The card of a Guest Session gives "Make a Guest" on the Session card and its default action on its own header
(UI/SidebarView.swift), so the checks reach them without a context menu. The page shows when the Dormant Guest
Session is the Next Topic after a Settle, as a Dormant Topic's page does.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.topics_dormant_guests_sidebar
"""

import time
import unittest
from pathlib import Path

from scripts.verify.sandbox import frame, wait
from scripts.verify.topics_sidebar import REFRESH_LIMIT, SHELL, TopicsSidebar


class TopicsDormantGuestsSidebar(TopicsSidebar):
    def above(self, upper, lower, rs):
        return self.s.has(upper, rs) and self.s.has(lower, rs) and frame(self.s.row(upper, rs))[1] > frame(self.s.row(lower, rs))[1]

    def make_guest(self, name, windows):
        """A No Topic Session with `windows` Windows, made a Guest from its Session card; returns its Lock id."""
        s = self.s
        sid = self.new_session(name, self.beta)
        for index in range(1, windows):
            s.tmux('new-window', '-d', '-t', sid + ':', '-n', 'w%d' % index, '-c', str(self.beta), SHELL)
        self.select_window(sid + ':')
        card = 'no-topic-session-' + sid
        self.find(card, 'the selected No Topic Session %s has no card' % name)
        s.act('action', card, 'Make a Guest')
        lock_id = wait(lambda: s.tmux('show-options', '-qv', '-t', sid, '@muxify_session_id'), 'Make a Guest gave %s no Lock' % name)
        self.addCleanup(self.store.remove_board_session, lock_id)
        self.find('locked-' + lock_id, 'Make a Guest gave %s no card' % name)
        return lock_id

    def restart_tmux(self):
        """Kills the sandbox's tmux server and starts it again, as a computer restart does, with the fixture's base
        Session. The App Window offers Reconnect once it sees the server stop, and each try presses it and asks the
        app to show base."""
        s = self.s
        socket = s.tmux('display-message', '-p', '#{socket_path}')
        self.assertTrue(Path(socket).resolve().is_relative_to(s.root.resolve()), 'the server %s is not the sandbox\'s' % socket)
        s.tmux('kill-server')
        s.wait_rows(lambda rs: any(r.get('accessibilityValue') == 'tmux server is not running' for r in rs),
                    'the app did not see the tmux server stop')
        s.tmux('new-session', '-d', '-s', 'base', '-c', str(self.beta), SHELL)
        s.tmux('set-option', '-g', 'detach-on-destroy', 'off')
        base = s.tmux('display-message', '-p', '-t', 'base:', '#{window_id}')
        def reconnected():
            for button in ['Reattach', 'Reconnect']:
                s.driver('press', button)
            s.select(base)
            try:
                s.wait_shown(base, seconds=3)
                return True
            except AssertionError:
                return False
        wait(reconnected, 'the App Window did not reconnect to the new tmux server', seconds=30)

    def test_a_guest_session_comes_back_dormant_at_its_place_and_a_press_reopens_it_with_its_windows(self):
        s = self.s
        self.write_topic('dormant-upper', 'Dormant upper', order=0)
        notes = self.make_guest('dormant-notes', windows=2)
        later = self.make_guest('dormant-later', windows=1)
        key, later_key = 'locked-' + notes, 'locked-' + later
        s.wait_rows(lambda rs: self.above('topics-guests-line', key, rs) and self.above(key, later_key, rs),
                    'the two Guest Sessions are not in the Guests in the order they were made')

        self.restart_tmux()
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', '=dormant-notes')
        rs = s.wait_rows(lambda rs: s.has(key, rs) and 'Dormant' in s.row(key, rs).get('accessibilityValue', ''),
                         'the Guest Session has no Dormant card after the tmux restart', seconds=15)
        self.assertIn('Guest', s.row(key, rs).get('accessibilityValue', ''), self.describe(key, rs))
        self.assertIn('dormant-notes', s.row(key, rs).get('accessibilityLabel', ''), self.describe(key, rs))
        self.assertEqual(s.row(key, rs).get('accessibilityHelp'), '2 Windows',
                         'the closed Dormant card does not show the Windows that it remembers: ' + self.describe(key, rs))
        self.assertTrue(self.above('topics-guests-line', key, rs) and self.above(key, later_key, rs),
                        'the Dormant card left its place: %s' % [self.describe(k, rs) for k in (key, later_key)])

        s.act('press', key)
        def reopened():
            found = s.tmux_ok('list-windows', '-t', '=dormant-notes:', '-F', '#{window_id}')
            return found.returncode == 0 and len(found.stdout.split()) == 2
        wait(reopened, 'a press on the Dormant card did not create its Session with its 2 Windows', seconds=15)
        self.assertEqual(s.tmux('show-options', '-qv', '-t', '=dormant-notes:', '@muxify_session_id'), notes,
                         'the new Session does not point at the same Lock')
        s.wait_rows(lambda rs: s.has(key, rs) and 'Dormant' not in s.row(key, rs).get('accessibilityValue', '')
                    and self.above(key, later_key, rs), 'the card is not live again at its place', seconds=15)

    def test_the_page_of_a_dormant_guest_session_offers_start_fresh_which_makes_one_window_at_its_place(self):
        s = self.s
        self.write_topic('fresh-upper', 'Fresh upper', order=0)
        notes = self.make_guest('fresh-notes', windows=2)
        later = self.make_guest('fresh-later', windows=1)
        key, later_key = 'locked-' + notes, 'locked-' + later

        self.restart_tmux()
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', '=fresh-notes')
        s.wait_rows(lambda rs: s.has(key, rs) and 'Dormant' in s.row(key, rs).get('accessibilityValue', ''),
                    'the Guest Session has no Dormant card after the tmux restart', seconds=15)

        sid = self.new_session('beta/fresh-upper', self.beta, topic='fresh-upper')
        upper = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        s.show(upper)
        s.wait_shown(upper)

        def settle_names_the_dormant_card():
            # The menu item follows the Location about a second after the Sidebar.
            if s.has('palette-search'):
                s.act('action', 'palette-search', 'Close')
            s.driver('press', 'Settle Topic…')
            found, _ = self.rows_until(lambda rs: s.has('palette-note', rs) and 'Then opens: fresh-notes' in self.describe('palette-note', rs),
                                       seconds=3)
            return found is not None
        wait(settle_names_the_dormant_card, 'Settle of the Topic above does not name the Dormant Guest Session as the Next Topic',
             seconds=20)
        s.act('press', 'palette-accept')
        rs = s.wait_rows(lambda rs: s.has('reopen-choice-start-fresh', rs),
                         "Next Topic did not show the Dormant Guest Session's Reopen choice", seconds=15)
        self.assertIn('w1', self.describe('reopen-session-fresh-notes', rs), 'the Reopen column does not list the remembered Windows')
        fresh = self.describe('start-fresh-session-fresh-notes', rs)
        self.assertIn('shell', fresh, 'the Start Fresh column does not list its shell Window')
        self.assertNotIn('w1', fresh, 'the Start Fresh column lists a remembered Window')
        self.assertNotEqual(s.tmux_ok('has-session', '-t', '=fresh-notes').returncode, 0, 'showing the choice created the Session')

        s.act('press', 'reopen-choice-start-fresh')
        def made_with_one_window():
            found = s.tmux_ok('list-windows', '-t', '=fresh-notes:', '-F', '#{window_id}')
            return found.returncode == 0 and len(found.stdout.split()) == 1
        wait(made_with_one_window, 'Start Fresh did not create the Session with one Window', seconds=15)
        self.assertEqual(s.tmux('show-options', '-qv', '-t', '=fresh-notes:', '@muxify_session_id'), notes,
                         'the new Session does not point at the same Lock')
        s.wait_rows(lambda rs: not s.has('reopen-choice-start-fresh', rs) and s.has(key, rs)
                    and 'Dormant' not in s.row(key, rs).get('accessibilityValue', '') and self.above(key, later_key, rs),
                    'the page stays, or the card is not live again at its place', seconds=15)
        time.sleep(REFRESH_LIMIT)
        self.assertEqual(len(s.tmux('list-windows', '-t', '=fresh-notes:', '-F', '#{window_id}').split()), 1,
                         'a remembered Window came back after Start Fresh')


if __name__ == '__main__':
    unittest.main()
