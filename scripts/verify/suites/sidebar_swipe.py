"""Topics/Sessions switching in the Sidebar, driven without taking focus.

SidebarPager exposes a Debug-only `sidebar-swipe-input` element while the sandbox's TestDriver runs. Its actions feed
the real gesture recognizer and release path; no check needs to move the pointer or use the user's tmux server. The
pages slide as Core Animation layers, which leave every row's accessibility frame at rest, so a check reads where the
pages show from the element's label, "Sidebar swipe input animated|instant <position>", never from a row's frame.
The driver cannot type keys, so the `toggle_sidebar_mode` checks press its View menu item ("Switch to Sessions" /
"Switch to Topics") without opening the menu, or run its Command from the palette's search field.
"""

import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, wait
from scripts.verify.topic_records import TopicRecords


class SwipeSteps:
    """The steps every Sidebar swipe check takes through the Debug `sidebar-swipe-input` element of `self.s`."""

    def wait_mode(self, mode):
        position = '0.000' if mode == 'topics' else '1.000'
        return self.s.wait_rows(lambda rs: self.s.row('sidebar-view-' + mode, rs).get('accessibilityValue') == 'selected'
                                and self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' ' + position),
                                'the Sidebar did not settle on ' + mode)

    def require_motion(self):
        """The Sidebar follows a swipe only while it animates. Reduce Motion in System Settings stops that for every app."""
        if self.s.row('sidebar-swipe-input').get('accessibilityLabel', '').startswith('Sidebar swipe input instant'):
            self.skipTest('Reduce Motion is on, so the Sidebar does not follow a swipe')

    def sample(self, name):
        self.s.act('action', 'sidebar-swipe-input', name)

    def position(self, rs=None):
        """Where the pages show: the end of the Debug element's label, which AppKit answers from the layers."""
        return self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').rsplit(' ', 1)[-1]

    def positions(self, seconds):
        """The position, read again and again for `seconds`."""
        found = []
        end = time.time() + seconds
        while time.time() < end:
            found.append(self.position())
            time.sleep(0.05)
        return found


# A Sidebar full enough that a SwiftUI update of the pages container on every frame would cost the app a lot.
BURST_SESSIONS = 15
BURST_SWIPES = 10
# SwiftUI updates of the pages container a swipe may cause: the committed mode, and one spare for a tmux read that
# lands mid-swipe. A swipe that drove SwiftUI each frame updated it about once a frame, tens of times a swipe.
UPDATES_PER_SWIPE = 2
# CPU seconds a swipe may cost the app, gesture, settle and the driver's reads of the accessibility tree included.
# Old build (0be752b, SwiftUI moved the pages every frame): `sample` of a swiping app read about 42% of a core against
# about 2% idle, so a swipe of about a second of gesture and settle cost about 0.4 s, before the driver's reads.
# New build: not measured yet. The shell that wrote this check has no Accessibility permission, so the driver sees no
# elements; the sign-off run from a trusted terminal measures it and writes it here. The limit is generous on purpose:
# it fails a return to per-frame SwiftUI, not a slow machine. The update count above is the sharp guard.
CPU_PER_SWIPE = 0.3


def cpu_seconds(pid):
    """The user and system CPU time of `pid` so far, read as scripts/verify/suites/working_marks.py reads it."""
    out = subprocess.run(['/bin/ps', '-o', 'time=', '-p', str(pid)], capture_output=True, text=True,
                         check=True).stdout.strip()
    minutes, seconds = out.split(':')
    return int(minutes) * 60 + float(seconds)


class SidebarSwipeBurst(SwipeSteps, unittest.TestCase):
    """A burst of swipes over a full Sidebar moves the pages as Core Animation layers, not through SwiftUI each frame
    (docs/adr/0074-motion-that-runs-every-frame-goes-through-core-animation.md)."""

    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        project = s.root/'project'
        project.mkdir()
        (s.root/'config/muxify/config.yaml').write_text('sidebar:\n  agents: false\n  animate_switching: true\n')
        store = TopicRecords(s.root/'state/muxify')
        cls.topics = ['burst-%02d' % number for number in range(BURST_SESSIONS)]
        for topic in cls.topics:
            store.put(dict(id=topic, title='Burst ' + topic[-2:], slug=topic))
            session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', topic,
                             '-c', str(project), '/bin/zsh -f')
            s.tmux('set-option', '-t', session, '@muxify_topic', topic)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])

    def updates(self):
        """How many times SwiftUI has updated the pages container: the Debug element's value, "<n> updates"."""
        return int(self.s.row('sidebar-swipe-input').get('accessibilityValue', '').split(' ', 1)[0])

    def test_a_burst_of_swipes_updates_swiftui_at_most_twice_a_swipe(self):
        self.s.wait_rows(lambda rs: any(self.s.has('topic-' + topic, rs) for topic in self.topics),
                         'the Sidebar shows none of the %d Topics' % BURST_SESSIONS)
        self.wait_mode('topics')
        self.require_motion()
        updates, cpu = self.updates(), cpu_seconds(self.s.pid)
        for number in range(BURST_SWIPES):
            if number % 2:
                self.sample('Swipe right')
                self.wait_mode('topics')
            else:
                self.sample('Swipe left')
                self.wait_mode('sessions')
        cpu = cpu_seconds(self.s.pid) - cpu
        updates = self.updates() - updates
        self.assertLessEqual(updates, UPDATES_PER_SWIPE * BURST_SWIPES,
                             '%d swipes updated the pages container through SwiftUI %d times' % (BURST_SWIPES, updates))
        self.assertLess(cpu / BURST_SWIPES, CPU_PER_SWIPE,
                        'a swipe cost the app %.3f CPU seconds; %d updates in the burst' % (cpu / BURST_SWIPES, updates))


class SidebarSwipe(SwipeSteps, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        project = s.root/'project'
        project.mkdir()
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text('sidebar:\n  agents: false\n')
        store = TopicRecords(s.root/'state/muxify')
        store.put(dict(id='swipe', title='Sidebar swipe', slug='swipe'))
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'sidebar-swipe',
                             '-c', str(project), '/bin/zsh -f')
        s.tmux('set-option', '-t', cls.session, '@muxify_topic', 'swipe')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])
        s.wait_shown(cls.session + ':')

    def setUp(self):
        self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')
        self.s.act('press', 'sidebar-view-topics')
        self.wait_mode('topics')

    def test_swipe_switches_views_without_changing_the_window_or_focus(self):
        before = self.s.tmux('list-clients', '-F', '#{client_tty}|#{window_id}')
        responder = self.s.driver('responder')['responders']
        self.sample('Swipe left')
        rs = self.wait_mode('sessions')
        self.assertTrue(self.s.has('session-' + self.session, rs), 'Sessions has no Session card')
        self.assertFalse(self.s.has('topic-swipe', rs), 'the offscreen Topics page is accessible')
        self.sample('Swipe right')
        rs = self.wait_mode('topics')
        self.assertTrue(self.s.has('topic-swipe', rs), 'Topics has no Topic card')
        self.assertFalse(self.s.has('session-' + self.session, rs), 'the offscreen Sessions page is accessible')
        self.assertEqual(self.s.tmux('list-clients', '-F', '#{client_tty}|#{window_id}'), before)
        self.assertEqual(self.s.driver('responder')['responders'], responder)

    def test_swipe_works_again_after_the_git_view_closes(self):
        self.s.wait_rows(lambda rs: self.s.has('toggle-git-view', rs), 'the header has no Git View button')
        self.s.act('press', 'toggle-git-view')
        self.s.wait_rows(lambda rs: self.s.row('toggle-git-view', rs).get('accessibilityValue') == 'on', 'the Git View did not open')
        self.s.act('press', 'toggle-git-view')
        self.s.wait_rows(lambda rs: self.s.row('toggle-git-view', rs).get('accessibilityValue') == 'off', 'the Git View did not close')
        self.sample('Swipe left')
        self.wait_mode('sessions')
        self.sample('Swipe right')
        self.wait_mode('topics')

    def test_a_swipe_beside_the_sidebar_does_not_switch_views(self):
        self.sample('Swipe left beside the Sidebar')
        time.sleep(1)
        rs = self.wait_mode('topics')
        self.assertTrue(self.s.has('topic-swipe', rs), 'a swipe over the terminal switched the Sidebar to Sessions')

    def test_a_swipe_over_the_agents_section_switches_views(self):
        def hide_agents():
            self.config.write_text('sidebar:\n  agents: false\n')
            self.s.wait_rows(lambda rs: not self.s.has('agents-header', rs), 'the Sidebar kept Agents')
        self.addCleanup(hide_agents)
        self.config.write_text('sidebar:\n  agents: true\n')
        self.s.wait_rows(lambda rs: self.s.has('agents-header', rs), 'the Sidebar did not show Agents')
        self.sample('Swipe left below the Sidebar views')
        rs = self.wait_mode('sessions')
        self.assertTrue(self.s.has('agents-header', rs), 'Sessions did not keep the Agents section')

    def test_partial_swipe_previews_the_next_page_before_committing(self):
        self.require_motion()
        self.sample('Begin swipe left')
        self.addCleanup(lambda: self.sample('Cancel current swipe'))
        rs = self.s.wait_rows(lambda rs: self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' 0.400'),
                              'the Sidebar did not follow the partial swipe')
        self.assertEqual(self.s.row('sidebar-view-topics', rs).get('accessibilityValue'), 'selected')
        self.sample('Cancel current swipe')
        self.wait_mode('topics')

    def test_animation_can_be_disabled_and_reenabled_live_without_disabling_switching(self):
        self.require_motion()
        self.addCleanup(self.config.write_text, 'sidebar:\n  agents: false\n')
        self.addCleanup(lambda: self.sample('Cancel current swipe'))
        # The pages move as layers, which leave every row's accessibility frame where it rests. The Debug position is
        # where the pages show, mid-settle included, so it ends in 0.000 only once the Topics page is back at rest.
        self.wait_mode('topics')
        self.sample('Begin swipe left')
        self.s.wait_rows(lambda rs: self.position(rs) == '0.400', 'the enabled animation did not preview the swipe')
        self.config.write_text('sidebar:\n  agents: false\n  animate_switching: false\n')
        self.s.wait_rows(lambda rs: self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').startswith('Sidebar swipe input instant '),
                         'the animation setting did not reload')
        self.wait_mode('topics')
        self.sample('Cancel current swipe')
        self.sample('Begin swipe left')
        positions = self.positions(seconds=0.5)
        self.assertEqual(set(positions), {'0.000'}, 'a swipe moved the pages with animation disabled: %s' % positions)
        self.sample('Cancel current swipe')
        self.sample('Short swipe left')
        self.wait_mode('topics')
        self.sample('Swipe left')
        rs = self.wait_mode('sessions')
        self.assertTrue(self.s.has('session-' + self.session, rs), 'the instant swipe did not show Sessions')
        self.s.act('press', 'sidebar-view-topics')
        self.wait_mode('topics')
        self.config.write_text('sidebar:\n  agents: false\n  animate_switching: true\n')
        self.s.wait_rows(lambda rs: self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').startswith('Sidebar swipe input animated '),
                         'the animation did not turn back on')
        self.sample('Begin swipe left')
        self.s.wait_rows(lambda rs: self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' 0.400'),
                         'reenabling animation did not restore the swipe preview')
        self.sample('Cancel current swipe')
        self.wait_mode('topics')

    def test_short_and_cancelled_swipes_spring_back(self):
        for name in ['Short swipe left', 'Cancel swipe left']:
            with self.subTest(sample=name):
                self.sample(name)
                self.wait_mode('topics')
        self.sample('Swipe left')
        self.wait_mode('sessions')
        for name in ['Short swipe right', 'Cancel swipe right']:
            with self.subTest(sample=name):
                self.sample(name)
                self.wait_mode('sessions')

    def test_a_short_quick_flick_switches_views(self):
        self.sample('Flick left')
        self.wait_mode('sessions')
        self.sample('Flick right')
        self.wait_mode('topics')

    def test_vertical_scrolling_stays_in_its_list_even_if_it_turns_horizontal(self):
        for name in ['Vertical scroll', 'Vertical then horizontal']:
            with self.subTest(sample=name):
                self.sample(name)
                self.wait_mode('topics')

    def test_swiping_past_either_end_stays_on_that_view(self):
        self.sample('Swipe right')
        self.wait_mode('topics')
        self.sample('Swipe left')
        self.wait_mode('sessions')
        self.sample('Swipe left')
        self.wait_mode('sessions')

    def test_disabling_a_view_removes_the_pager(self):
        self.addCleanup(self.config.write_text, 'sidebar:\n  agents: false\n')
        self.config.write_text('sidebar:\n  agents: false\n  sessions: false\n')
        rs = self.s.wait_rows(lambda rs: self.s.has('topic-swipe', rs) and not self.s.has('sidebar-view-sessions', rs),
                              'the single Topics view kept its mode selector')
        self.assertFalse(self.s.has('sidebar-swipe-input', rs), 'a disabled Sessions view can still be swiped to')

    def press_menu_item(self, title):
        """The app updates its menu items a moment after a change, so a press can find the item still disabled."""
        wait(lambda: self.s.driver('press', title)['pressed'], 'the menu item %s stays disabled' % title, seconds=10)

    def test_the_view_menu_item_switches_modes_without_changing_the_window_or_focus(self):
        before = self.s.tmux('list-clients', '-F', '#{client_tty}|#{window_id}')
        responder = self.s.driver('responder')['responders']
        self.press_menu_item('Switch to Sessions')
        rs = self.wait_mode('sessions')
        self.assertTrue(self.s.has('session-' + self.session, rs), 'Sessions has no Session card')
        self.press_menu_item('Switch to Topics')
        rs = self.wait_mode('topics')
        self.assertTrue(self.s.has('topic-swipe', rs), 'Topics has no Topic card')
        self.assertEqual(self.s.tmux('list-clients', '-F', '#{client_tty}|#{window_id}'), before)
        self.assertEqual(self.s.driver('responder')['responders'], responder)

    def test_the_switch_shows_a_hidden_sidebar_in_the_other_mode(self):
        def show_sidebar():
            if not self.s.has('sidebar-view-topics'):
                self.press_menu_item('Show Sidebar')
        self.addCleanup(show_sidebar)
        self.press_menu_item('Hide Sidebar')
        self.s.wait_rows(lambda rs: not self.s.has('sidebar-view-topics', rs), 'the Sidebar did not hide')
        self.press_menu_item('Switch to Sessions')
        rs = self.wait_mode('sessions')
        self.assertTrue(self.s.has('session-' + self.session, rs), 'the shown Sidebar has no Session card')

    def test_the_switch_command_runs_at_once_from_commands(self):
        def close_palette():
            if self.s.has('palette-search'):
                self.s.act('action', 'palette-search', 'Close')
        self.addCleanup(close_palette)
        self.press_menu_item('Commands')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Commands did not open')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Switch to')
        key = 'palette-row-command-Switch to Sessions'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Switch to Sessions was missing from Commands')
        self.assertFalse(self.s.has('palette-row-command-Switch to Topics', rs), 'Topics shows, yet Commands offers Switch to Topics')
        self.s.act('press', key)
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'the Command did not close the palette')
        self.wait_mode('sessions')

    def test_with_one_mode_off_the_switch_is_not_offered(self):
        def restore():
            self.config.write_text('sidebar:\n  agents: false\n')
            self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')
            if self.s.has('palette-search'):
                self.s.act('action', 'palette-search', 'Close')
        self.addCleanup(restore)
        self.config.write_text('sidebar:\n  agents: false\n  sessions: false\n')
        self.s.wait_rows(lambda rs: self.s.has('topic-swipe', rs) and not self.s.has('sidebar-view-sessions', rs),
                         'the single Topics view kept its mode selector')
        time.sleep(1)
        self.assertFalse(self.s.driver('press', 'Switch to Sessions')['pressed'], 'the View menu item is enabled with Sessions off')
        self.press_menu_item('Commands')
        self.s.wait_rows(lambda rs: self.s.has('palette-search', rs), 'Commands did not open')
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', 'Switch to')
        time.sleep(1)
        rs = self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == 'Switch to',
                              'Commands did not keep the query')
        self.assertFalse(self.s.has('palette-row-command-Switch to Sessions', rs), 'Commands offers a switch with Sessions off')
        self.assertFalse(self.s.has('palette-row-command-Switch to Topics', rs), 'Commands offers a switch with Sessions off')

    def test_swiping_between_modes_with_different_agents_visibility(self):
        self.addCleanup(self.config.write_text, 'sidebar:\n  agents: false\n')
        self.config.write_text('sidebar:\n  agents:\n    topics: true\n    sessions: false\n')
        self.s.wait_rows(lambda rs: self.s.has('agents-header', rs), 'Topics did not show Agents')
        self.sample('Swipe left')
        rs = self.wait_mode('sessions')
        self.assertFalse(self.s.has('agents-header', rs), 'Sessions kept the Topics Show Agents choice')
        self.sample('Swipe right')
        rs = self.wait_mode('topics')
        self.assertTrue(self.s.has('agents-header', rs), 'Topics did not restore its Show Agents choice')
