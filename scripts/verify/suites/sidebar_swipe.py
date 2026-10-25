"""Topics/Sessions switching in the Sidebar, driven without taking focus.

SidebarPager exposes Debug-only accessibility samples while the sandbox's TestDriver runs. They feed
the real gesture recognizer and release path; no check needs to move the pointer or use the user's tmux server.
"""

import json
import time
import unittest

from scripts.verify.sandbox import Sandbox


class SidebarSwipe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        project = s.root/'project'
        project.mkdir()
        cls.config = s.root/'config/muxify/config.yaml'
        cls.config.write_text('sidebar:\n  agents: false\n')
        topics = s.root/'state/muxify/topics'
        topics.mkdir()
        (topics/'swipe.json').write_text(json.dumps(dict(id='swipe', title='Sidebar swipe', slug='swipe')))
        cls.session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'sidebar-swipe',
                             '-c', str(project), '/bin/zsh -f')
        s.tmux('set-option', '-t', cls.session, '@muxify_topic', 'swipe')
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])
        s.wait_shown(cls.session + ':')

    def setUp(self):
        self.s.wait_rows(lambda rs: self.s.has('sidebar-view-topics', rs), 'the two Sidebar views did not return')
        self.s.act('press', 'sidebar-view-topics')
        self.wait_mode('topics')

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
        frames = []
        def settled(rs):
            frames.append(self.s.row('topics-list', rs).get('accessibilityFrame'))
            return len(frames) >= 2 and frames[-1] is not None and frames[-2] == frames[-1]
        rs = self.s.wait_rows(settled, 'the Topics list did not finish its previous animation')
        before = self.s.row('topics-list', rs)['accessibilityFrame']
        self.sample('Begin swipe left')
        self.s.wait_rows(lambda rs: self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').endswith(' 0.400'),
                         'the enabled animation did not preview the swipe')
        self.config.write_text('sidebar:\n  agents: false\n  animate_switching: false\n')
        self.s.wait_rows(lambda rs: self.s.row('sidebar-swipe-input', rs).get('accessibilityLabel', '').startswith('Sidebar swipe input instant '),
                         'the animation setting did not reload')
        rs = self.wait_mode('topics')
        self.assertEqual(self.s.row('topics-list', rs)['accessibilityFrame'], before,
                         'disabling animation left the Topics list shifted or scaled')
        self.sample('Cancel current swipe')
        self.sample('Begin swipe left')
        rs = self.wait_mode('topics')
        self.assertEqual(self.s.row('topics-list', rs)['accessibilityFrame'], before,
                         'a swipe moved the Topics list with animation disabled')
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
