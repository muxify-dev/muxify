"""Commands start Actions on the current item and retain Back to search.

The driver cannot type keys. A check opens Commands from its View menu item and calls the search field's
accessibility actions for the keys. A press on a row of a check step is a click, which checks it as Space does
(UI/CommandPaletteView.swift, UI/PaletteCheck.swift).
"""

import json
import unittest

from scripts.verify.palette_fixture import PaletteFixture
from scripts.verify.sandbox import wait


class PaletteCurrentCommands(PaletteFixture):
    def back(self, title):
        self.s.act('action', 'palette-search', 'Back')
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == title
                         and not self.s.has('palette-breadcrumb', rs), 'Back did not restore ' + title)
        self.s.act('action', 'palette-search', 'Close')

    def current_topic(self, name):
        """A Topic with a live Session that the client shows; returns its record file."""
        window = self.topic(name, session=True)
        self.s.wait_rows(lambda rs: self.s.has('topic-' + name, rs), 'Topic did not appear')
        self.select(window)
        return self.topics/(name + '.json')

    def test_move_scopes_keep_back_and_cancel_without_tmux_changes(self):
        before = self.s.tmux('list-panes', '-a', '-F', '#{session_id} #{window_id} #{pane_id}')
        for scope in ['Pane', 'Window', 'Session']:
            title = 'Move ' + scope
            self.run_command(title)
            self.s.wait_rows(lambda rs: self.text('palette-breadcrumb', rs).startswith(scope + ' '), 'Wrong scope for ' + title)
            self.back(title)
        self.assertEqual(self.s.tmux('list-panes', '-a', '-F', '#{session_id} #{window_id} #{pane_id}'), before)
        self.assertEqual(list(self.topics.glob('*.json')), [])

    def test_topic_steps_keep_back_and_cancel_without_writes(self):
        path = self.current_topic('current-commands')
        before = path.read_text()
        for title, step in [('Add a Session', 'Add a Session'), ('Snooze Topic', 'Snooze'),
                            ('Settle Topic', 'Settle'), ('Zen', 'Zen'), ('Forget Topic', 'Forget'), ('Rename Topic', 'Rename')]:
            self.run_command(title)
            self.s.wait_rows(lambda rs: step in self.text('palette-breadcrumb', rs), title + ' did not open its step')
            if title == 'Rename Topic':
                # Rename starts with the title in the field, and Back works only in an empty field.
                self.s.act('set', 'palette-search', '')
            if title == 'Snooze Topic':
                self.s.act('action', 'palette-search', 'Back')
                self.s.wait_rows(lambda rs: 'Snooze Topics › check' in self.text('palette-breadcrumb', rs)
                                 and 'checked' in self.s.row('palette-row-topic-current-commands', rs).get('accessibilityValue', ''),
                                 'Back did not go to the check step with the Topic checked')
            self.back(title)
        after = json.loads(path.read_text())
        original = json.loads(before)
        for key in ['title', 'snoozed_until', 'settled_at']:
            self.assertEqual(after.get(key), original.get(key), key + ' changed on Cancel')
        self.assertFalse((self.s.root/'state/muxify/zen.json').exists())

    def test_the_topics_commands_come_before_the_topic_commands(self):
        self.current_topic('snooze-order')
        self.topic('snooze-order-snoozed', snoozed_until='never')
        for verb in ['Snooze', 'Unsnooze']:
            self.search(verb.lower() + ' topic')
            many, one = 'palette-row-command-%s Topics…' % verb, 'palette-row-command-%s Topic' % verb
            rs = self.s.wait_rows(lambda rs: self.s.has(many, rs) and self.s.has(one, rs), 'both %s Commands did not show' % verb)
            ids = self.s.ids(rs)
            self.assertLess(ids.index(many), ids.index(one), '%s Topic came before %s Topics…' % (verb, verb))
            self.s.act('action', 'palette-search', 'Close')

    def remembered(self, path):
        """Waits until the app records the Topic's live Session, so that a removal has something to forget."""
        wait(lambda: json.loads(path.read_text()).get('sessions'), 'the Topic did not remember its Session')

    def assert_empty_topic(self, name, path, sessions):
        self.assertEqual(json.loads(path.read_text()).get('sessions'), [], 'the Topic still remembers the Session')
        card = self.s.wait_rows(lambda rs: 'Empty' in self.s.row('topic-' + name, rs).get('accessibilityValue', ''),
                                'the Topic card does not show Empty')
        self.assertNotIn('Dormant', self.s.row('topic-' + name, card).get('accessibilityValue', ''))
        self.s.act('press', 'topic-' + name)
        self.s.wait_rows(lambda rs: self.s.has('empty-topic-add-session', rs), 'going to the Topic did not offer Add a Session Path')
        self.assertEqual(self.s.tmux('list-sessions', '-F', '#{session_name}').split(), sessions, 'going to the Topic made a Session')

    def test_remove_session_from_topic_leaves_the_topic_empty_and_the_session_live(self):
        path = self.current_topic('remove-empty')
        self.remembered(path)
        self.run_command('Remove Session from Topic')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Remove Session from Topic did not close Commands')
        wait(lambda: self.s.tmux('show-options', '-qv', '-t', 'remove-empty', '@muxify_topic') == '',
             'the Session is still in the Topic')
        self.assert_empty_topic('remove-empty', path, self.s.tmux('list-sessions', '-F', '#{session_name}').split())

    def test_command_return_on_remove_session_from_topic_kills_the_session_after_a_confirm_step(self):
        path = self.current_topic('remove-kill')
        self.remembered(path)
        self.search('Remove Session from Topic')
        self.s.wait_rows(lambda rs: 'Remove and Kill' in self.text('palette-note', rs),
                         'the note does not show the ⌘↩ variant')
        self.s.act('action', 'palette-search', 'Confirm')
        self.s.wait_rows(lambda rs: 'Remove from Topic and Kill' in self.text('palette-breadcrumb', rs) and self.s.has('palette-row-kill-session', rs),
                         '⌘↩ did not open the Kill confirm step')
        self.assertEqual(self.s.tmux_ok('has-session', '-t', '=remove-kill').returncode, 0, 'the confirm step killed the Session')
        self.s.act('action', 'palette-search', 'Confirm')
        wait(lambda: self.s.tmux_ok('has-session', '-t', '=remove-kill').returncode != 0, 'Remove and Kill did not kill the Session')
        self.assert_empty_topic('remove-kill', path, self.s.tmux('list-sessions', '-F', '#{session_name}').split())

    def test_commands_omit_unavailable_topic_and_tab_actions(self):
        for title in ['Add a Session', 'Snooze Topic', 'Settle Topic', 'Zen', 'Move Pane with Active Tab',
                      'Remove Session from Topic', 'Forget Topic', 'Rename Topic', 'Move Topic Up', 'Move Topic Down',
                      'Pin Topic', 'Unsnooze Topic', 'Unsnooze Topics…']:
            self.search(title)
            self.assertFalse(self.s.has('palette-row-command-' + title), title + ' had no target')
            self.s.act('action', 'palette-search', 'Close')

    def absent(self, title):
        self.search(title)
        present = self.s.has('palette-row-command-' + title)
        self.s.act('action', 'palette-search', 'Close')
        return not present

    def test_move_topic_up_and_down_move_the_active_topic_among_the_cards_with_its_pin(self):
        self.topic('move-pinned', order=-300, pinned=True)
        self.topic('move-upper', order=-200)
        self.current_topic('move-current')
        order = lambda name: self.record(name).get('order', 0)
        wait(lambda: order('move-current') > order('move-upper'), 'the Active Topic did not start below the other Topic')
        self.assertTrue(self.absent('Move Topic Down'), 'Move Topic Down shows for the last card')
        self.search('Move Topic Up')
        key = 'palette-row-command-Move Topic Up'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Move Topic Up was missing from Commands')
        self.assertIn('⌥⌘↑', self.text(key, rs), 'Move Topic Up does not show its shortcut')
        self.s.act('press', key)
        wait(lambda: order('move-current') < order('move-upper'), 'Move Topic Up did not move the Active Topic above the other Topic')
        self.assertTrue(self.absent('Move Topic Up'), 'Move Topic Up moves a card that is not Pinned above a Pinned card')
        self.run_command('Move Topic Down')
        wait(lambda: order('move-current') > order('move-upper'), 'Move Topic Down did not move the Active Topic back')

    def test_pin_topic_flips_to_unpin_topic_and_unsnooze_topic_unsnoozes_a_snoozed_active_topic_at_once(self):
        self.current_topic('pin-current')
        self.assertTrue(self.absent('Unsnooze Topic'), 'Unsnooze Topic shows with no Snoozed Topic')
        self.run_command('Pin Topic')
        wait(lambda: self.record('pin-current').get('pinned') is True, 'Pin Topic did not Pin the Active Topic')
        self.assertTrue(self.absent('Pin Topic'), 'Pin Topic shows for a Pinned Topic')
        self.run_command('Unpin Topic')
        wait(lambda: not self.record('pin-current').get('pinned'), 'Unpin Topic did not Unpin the Active Topic')

        window = self.topic('unsnooze-current', session=True, snoozed_until='never')
        self.select(window)
        self.run_command('Unsnooze Topic')
        wait(lambda: 'snoozed_until' not in self.record('unsnooze-current'), 'Unsnooze Topic did not Unsnooze the Active Topic')

    def test_unsnooze_topics_lists_only_snoozed_topics_and_unsnoozes_the_checked_set_at_once(self):
        s = self.s
        self.current_topic('us-current')
        for name in ['us-a', 'us-b', 'us-c']:
            self.topic(name, snoozed_until='2099-01-01T00:00:00Z')
        self.run_command('Unsnooze Topics…')
        rs = s.wait_rows(lambda rs: 'Unsnooze Topics › check' in self.text('palette-breadcrumb', rs) and s.has('palette-row-topic-us-c', rs),
                         'Unsnooze Topics… did not open the check step of the Snoozed Topics')
        self.assertFalse(s.has('palette-row-topic-us-current', rs), 'the check step lists a Topic that is not Snoozed')
        self.assertIn('until', self.text('palette-row-topic-us-a', rs), 'a Snoozed row does not show its wake time')
        for name in ['us-a', 'us-b']:
            s.act('press', 'palette-row-topic-' + name)
        rs = s.wait_rows(lambda rs: '↩ Unsnoozes 2 Topics' in self.text('palette-note', rs), 'the note does not say what Return does')
        self.assertIn('Unsnoozes: us-a, us-b', self.text('palette-note', rs), 'the note does not name the checked Topics')
        s.act('action', 'palette-search', 'Accept')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Unsnooze Topics… did not close the palette')
        wait(lambda: all('snoozed_until' not in self.record(name) for name in ['us-a', 'us-b']), 'the checked Topics are still Snoozed')
        self.assertEqual(self.record('us-c').get('snoozed_until'), '2099-01-01T00:00:00Z', 'a Topic that was not checked was Unsnoozed')

    def test_unsnooze_topic_with_an_active_topic_that_is_not_snoozed_opens_the_choose_step(self):
        s = self.s
        self.current_topic('uc-current')
        self.topic('uc-one', snoozed_until='2099-01-01T00:00:00Z')
        self.topic('uc-two', snoozed_until='2099-01-01T00:00:00Z')
        self.run_command('Unsnooze Topic')
        rs = s.wait_rows(lambda rs: self.text('palette-breadcrumb', rs).startswith('Unsnooze Topic') and s.has('palette-row-topic-uc-one', rs),
                         'Unsnooze Topic did not open the choice of the Snoozed Topics')
        self.assertFalse(s.has('palette-row-topic-uc-current', rs), 'the choice lists a Topic that is not Snoozed')
        self.assertIn('snoozed_until', self.record('uc-one'), 'opening the choice Unsnoozed a Topic')
        s.act('press', 'palette-row-topic-uc-one')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'choosing a row did not close the palette')
        wait(lambda: 'snoozed_until' not in self.record('uc-one'), 'Unsnooze Topic did not Unsnooze the chosen Topic')
        self.assertIn('snoozed_until', self.record('uc-two'), 'Unsnooze Topic Unsnoozed a Topic that was not chosen')

    def test_end_zen_is_available_in_no_topic_and_closes_commands(self):
        self.current_topic('zen-current-command')
        self.run_command('Zen')
        self.s.wait_rows(lambda rs: self.s.has('palette-row-never', rs), 'Zen presets did not show')
        self.s.act('press', 'palette-row-never')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Zen did not close')
        self.select(self.base)
        self.run_command('End Zen')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'End Zen did not close Commands')
        self.search('End Zen')
        self.assertFalse(self.s.has('palette-row-command-End Zen'), 'Zen remained active')
        self.s.act('action', 'palette-search', 'Close')

    def test_layout_commands_show_their_shortcut_and_change_the_window(self):
        self.search('Maximize Terminal')
        key = 'palette-row-command-Maximize Terminal'
        rs = self.s.wait_rows(lambda rs: self.s.has(key, rs), 'Maximize Terminal was missing from Commands')
        row = self.s.row(key, rs)
        self.assertIn('⌥⌘J', row.get('accessibilityLabel', '') + row.get('accessibilityValue', ''),
                      'Maximize Terminal does not show its shortcut: %s' % row)
        self.s.act('action', 'palette-search', 'Close')
        self.run_command('Show Browser')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Show Browser did not close Commands')
        wait(lambda: self.s.tmux('show-options', '-wqv', '-t', self.base, '@muxify_browser') == 'on',
             'Show Browser did not turn the Browser toggle on')
        self.run_command('Hide Browser')
        wait(lambda: self.s.tmux('show-options', '-wqv', '-t', self.base, '@muxify_browser') == '',
             'Hide Browser did not turn the Browser toggle off')
