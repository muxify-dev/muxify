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
        for title, step in [('Add a Session', 'Add a Session'), ('Settle Topic', 'Settle'), ('Forget Topic', 'Forget'),
                            ('Rename Topic', 'Rename')]:
            self.run_command(title)
            self.s.wait_rows(lambda rs: step in self.text('palette-breadcrumb', rs), title + ' did not open its step')
            if title == 'Rename Topic':
                # Rename starts with the title in the field, and Back works only in an empty field.
                self.s.act('set', 'palette-search', '')
            self.back(title)
        after = json.loads(path.read_text())
        original = json.loads(before)
        for key in ['title', 'settled_at']:
            self.assertEqual(after.get(key), original.get(key), key + ' changed on Cancel')

    def test_rename_window_prefills_name_keeps_back_and_saves_current_window(self):
        window = self.topic('rename-window-command', session=True)
        self.select(window)
        self.s.tmux('rename-window', '-t', window, 'Before rename')
        self.s.wait_rows(lambda rs: any(row.get('accessibilityIdentifier') == 'topic-window-' + window
                                       and 'Before rename' in row.get('accessibilityLabel', '') for row in rs),
                         'the Sidebar did not receive the Window name')
        title = 'Rename a Window'
        self.run_command(title)
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == 'Before rename',
                         'Rename did not prefill the current Window name')
        self.s.act('set', 'palette-search', '')
        self.back(title)
        self.assertEqual(self.s.tmux('display-message', '-p', '-t', window, '#{window_name}'), 'Before rename')
        self.run_command(title)
        self.s.act('set', 'palette-search', 'After rename')
        self.s.act('action', 'palette-search', 'Accept')
        wait(lambda: self.s.tmux('display-message', '-p', '-t', window, '#{window_name}') == 'After rename',
             'Rename did not save the current Window name')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Rename did not close the palette')
        self.topic('rename-empty')
        self.s.wait_rows(lambda rs: self.s.has('topic-rename-empty', rs), 'the Empty Topic did not appear')
        self.s.act('action', 'topic-rename-empty', 'Go to Topic')
        self.s.wait_rows(lambda rs: self.s.has('empty-topic-title', rs), 'the Empty Topic did not open')
        self.assertTrue(self.absent(title), 'Rename a Window shows without a Window')

    def test_set_topic_note_starts_with_the_note_keeps_back_and_an_empty_field_clears_it(self):
        note = "Waiting on Ana's review"
        self.current_topic('note-set')
        self.run_command('Set Topic Note')
        self.s.wait_rows(lambda rs: 'Topic Note' in self.text('palette-breadcrumb', rs)
                         and self.s.row('palette-search', rs).get('accessibilityValue', '') == '',
                         'Set Topic Note did not open an empty field for a Topic with no Note')
        self.s.act('set', 'palette-search', note)
        self.s.act('action', 'palette-search', 'Accept')
        wait(lambda: self.record('note-set').get('note') == note, 'Set Topic Note did not save the Note')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Set Topic Note did not close the palette')

        self.run_command('Set Topic Note')
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == note,
                         'Set Topic Note did not start with the current Note')
        self.s.act('set', 'palette-search', '')
        self.back('Set Topic Note')
        self.assertEqual(self.record('note-set').get('note'), note, 'Back changed the Note')

        self.run_command('Set Topic Note')
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue') == note,
                         'Set Topic Note did not start with the current Note')
        self.s.act('set', 'palette-search', '')
        self.s.act('action', 'palette-search', 'Accept')
        wait(lambda: 'note' not in self.record('note-set'), 'Return on an empty field did not clear the Note')

    def test_clear_topic_note_shows_only_while_the_active_topic_has_a_note_and_clears_it_at_once(self):
        window = self.topic('note-clear', session=True, note='Bisect from v2')
        self.select(window)
        self.run_command('Clear Topic Note')
        wait(lambda: 'note' not in self.record('note-clear'), 'Clear Topic Note did not clear the Note')
        self.assertEqual(self.record('note-clear').get('title'), 'note-clear', 'Clear Topic Note changed the title')
        self.assertTrue(self.absent('Clear Topic Note'), 'Clear Topic Note shows for a Topic with no Note')

    def go_to(self, query):
        def opened():
            if not self.s.has('palette-search'):
                self.s.driver('press', 'Go to…')
            return self.s.has('palette-search')
        wait(opened, 'Go to… did not open', seconds=20)
        self.s.act('focus', 'palette-search')
        self.s.act('set', 'palette-search', query)
        return self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue', '') == query,
                                'Go to… did not take the query %r' % query)

    def test_a_topic_row_shows_its_note_and_its_actions_set_and_clear_it(self):
        s = self.s
        self.topic('note-row', note='Repro with seed 4411')
        self.topic('note-row-settled', note='Wait for the release', settled_at='2026-01-01T00:00:00Z')
        self.go_to('note-row')
        key, settled = 'palette-row-topic-note-row', 'palette-row-topic-note-row-settled'
        rs = s.wait_rows(lambda rs: s.has(key, rs) and s.has(settled, rs), 'Go to… did not list the Topics')
        self.assertIn('Repro with seed 4411', self.text(key, rs), 'a Topic row does not show its Note')
        self.assertIn('Wait for the release · ', self.text(settled, rs), 'a Settled row does not show its Note before its Settle date')
        s.act('action', 'palette-search', 'Close')
        self.go_to('seed 4411')
        rs = s.wait_rows(lambda rs: s.has('palette-search', rs), 'Go to… closed')
        self.assertFalse(s.has(key, rs), 'a search matches the text of a Note')
        s.act('action', 'palette-search', 'Close')

        self.go_to('note-row')
        s.wait_rows(lambda rs: s.has(key, rs), 'Go to… did not list the Topic')
        s.act('action', key, 'Clear Topic Note')
        wait(lambda: 'note' not in self.record('note-row'), 'the Clear Topic Note action did not clear the Note')
        self.go_to('note-row')
        s.wait_rows(lambda rs: s.has(key, rs), 'Go to… did not list the Topic')
        s.act('action', key, 'Set Topic Note')
        s.wait_rows(lambda rs: 'Topic Note' in self.text('palette-breadcrumb', rs), 'the Set Topic Note action did not open its step')
        s.act('set', 'palette-search', 'Ship it\nafter review')
        s.act('action', 'palette-search', 'Accept')
        wait(lambda: self.record('note-row').get('note') == 'Ship it after review', 'the Set Topic Note action did not save one line')

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
        for title in ['Add a Session', 'Settle Topic', 'Move Pane with Active Tab',
                      'Remove Session from Topic', 'Forget Topic', 'Rename Topic', 'Move Topic Up', 'Move Topic Down',
                      'Pin Topic', 'Set Topic Note', 'Clear Topic Note']:
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

    def test_pin_topic_flips_to_unpin_topic(self):
        self.current_topic('pin-current')
        self.run_command('Pin Topic')
        wait(lambda: self.record('pin-current').get('pinned') is True, 'Pin Topic did not Pin the Active Topic')
        self.assertTrue(self.absent('Pin Topic'), 'Pin Topic shows for a Pinned Topic')
        self.run_command('Unpin Topic')
        wait(lambda: not self.record('pin-current').get('pinned'), 'Unpin Topic did not Unpin the Active Topic')

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
