"""Every Snooze goes through one palette flow: a check step of Topics, then one time for the whole set.

The driver cannot type keys. A check opens Commands from its View menu item, and starts Snooze again
through the Snoozed card's accessibility action (TopicCard in UI/SidebarView.swift). In the check step,
Accept, Back, Space and Check All Shown are what Return, Backspace in the empty field, Space and Cmd-A call, and a
press on a row is a click, which checks it as Space does (UI/CommandPaletteView.swift, UI/PaletteCheck.swift).

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.palette_snooze_topics
"""

import datetime
import subprocess
import unittest

from scripts.verify.palette_fixture import PaletteFixture
from scripts.verify.sandbox import DEBUG_APP, frame, wait

CLI = DEBUG_APP/'Contents/Resources/bin/muxify'

LATER = '2099-01-01T00:00:00Z'


class PaletteSnoozeTopics(PaletteFixture):
    TAGS = {name: '{}' for name in ['pkfirst', 'cttag', 'rttag', 'tgsnooze', 'other', 'bktag', 'assnooze']}

    def filter(self, query):
        self.s.act('set', 'palette-search', query)
        self.s.wait_rows(lambda rs: self.s.row('palette-search', rs).get('accessibilityValue', '') == query,
                         'the check step did not take the query %r' % query)

    def box(self, key, rs):
        """'checked', 'partly checked' or '' for the row with this identifier."""
        value = self.s.row(key, rs).get('accessibilityValue', '')
        return 'partly checked' if 'partly checked' in value else 'checked' if 'checked' in value else ''

    def checked(self, rs):
        """The Topics whose rows are checked."""
        return sorted(key[len('palette-row-topic-'):] for key in self.s.ids(rs)
                      if key.startswith('palette-row-topic-') and self.box(key, rs) == 'checked')

    def wait_checked(self, names, message):
        return self.s.wait_rows(lambda rs: self.checked(rs) == sorted(names), '%s: want %s checked' % (message, sorted(names)))

    def wait_step(self, crumb):
        return self.s.wait_rows(lambda rs: crumb in self.text('palette-breadcrumb', rs) and self.s.has('palette-note', rs),
                                'the step %r did not show' % crumb)

    def open_check(self):
        self.run_command('Snooze Topics…')
        return self.s.wait_rows(lambda rs: 'Snooze Topics › check' in self.text('palette-breadcrumb', rs),
                                'the check step did not show')

    def check_rows(self, *names):
        """Presses the row of each Topic, as a click does, and waits until they are all checked."""
        for name in names:
            self.s.act('press', 'palette-row-topic-' + name)
        return self.s.wait_rows(lambda rs: set(names) <= set(self.checked(rs)), 'pressing the rows did not check %s' % (names,))

    def test_snooze_again_with_an_earlier_time_writes_it_and_names_the_shorter_snooze(self):
        s = self.s
        self.topic('snz-again', 1, snoozed_until=LATER)
        rs = s.wait_rows(lambda rs: s.has('snoozed-topics', rs), 'the Snoozed group did not show')
        if s.row('snoozed-topics', rs).get('accessibilityValue') != 'expanded':
            s.act('press', 'snoozed-topics')
        s.wait_rows(lambda rs: s.has('topic-snz-again', rs), 'the Snoozed Topic did not show')
        s.act('action', 'topic-snz-again', 'Snooze again…')
        rs = s.wait_rows(lambda rs: s.has('palette-row-0', rs) and s.has('palette-note', rs), 'the "until" step did not show its note')
        self.assertIn('snz-again › Snooze › until', self.text('palette-breadcrumb', rs))
        self.assertIn('Gets shorter: snz-again', self.text('palette-note', rs), 'the note does not name the shorter Snooze')
        s.act('press', 'palette-row-0')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Snooze did not close the palette')
        stored = wait(lambda: (lambda value: value if value != LATER else None)(self.record('snz-again').get('snoozed_until')),
                      'the earlier time was not written', seconds=10)
        until = datetime.datetime.strptime(stored, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        self.assertLess(until, datetime.datetime(2099, 1, 1, tzinfo=datetime.timezone.utc), stored)

    def test_the_check_step_starts_with_nothing_checked_and_lists_tags_then_topics_then_already_snoozed(self):
        s = self.s
        self.topic('pk-alpha', 11, tags=['pkfirst'])
        self.topic('pk-snoozed', 12, snoozed_until=LATER)
        self.topic('pk-settled', 13, settled_at='2026-01-01T00:00:00Z')
        self.select(self.topic('pk-active', 14, session=True))
        rs = self.open_check()
        self.assertEqual(self.checked(rs), [], 'the check step started with a Topic checked')
        self.assertFalse(any(key.startswith('palette-tag-') or key.startswith('palette-topic-') for key in s.ids(rs)),
                         'the search field shows chips')
        ids = s.ids(rs)
        self.assertLess(ids.index('palette-section-tags'), ids.index('palette-section-topics'), ids)
        self.assertLess(ids.index('palette-section-topics'), ids.index('palette-section-snoozed'), ids)
        self.assertTrue(s.has('palette-row-topic-pk-snoozed', rs), 'a Snoozed Topic is not listed')
        self.assertFalse(s.has('palette-row-topic-pk-settled', rs), 'a Settled Topic is listed')

    def test_the_check_step_lists_only_the_tags_the_config_defines(self):
        s = self.s
        self.topic('po-one', 15, tags=['pkfirst', 'pkorphan'])
        self.open_check()
        self.filter('#pk')
        rs = s.wait_rows(lambda rs: s.has('palette-row-tag-pkfirst', rs), 'the Tag of the Config is not listed')
        self.assertFalse(s.has('palette-row-tag-pkorphan', rs), 'a Tag the Config does not define is listed')
        s.act('action', 'palette-search', 'Close')

    def test_checking_a_tag_checks_its_topics_and_the_note_names_them(self):
        s = self.s
        self.topic('ct-one', 21, tags=['cttag'])
        self.topic('ct-two', 22, tags=['cttag'])
        self.topic('ct-none', 23)
        self.open_check()
        s.act('press', 'palette-row-tag-cttag')
        rs = self.wait_checked(['ct-one', 'ct-two'], 'checking the Tag did not check only its Topics')
        self.assertEqual(self.box('palette-row-tag-cttag', rs), 'checked', 'the Tag box is not checked when all its Topics are')
        self.assertIn('2 Topics', self.text('palette-row-tag-cttag', rs))
        note = self.text('palette-note', rs)
        self.assertIn('Snoozes: ct-one, ct-two', note, 'the note does not name the checked Topics')
        self.assertIn('↩ Snoozes 2 Topics…', note, 'the note does not say what Return does')
        s.act('press', 'palette-row-topic-ct-one')
        rs = self.wait_checked(['ct-two'], 'pressing a Topic of a checked Tag did not uncheck only it')
        self.assertEqual(self.box('palette-row-tag-cttag', rs), 'partly checked')
        self.assertIn('1/2', self.text('palette-row-tag-cttag', rs), 'the Tag row does not count its checked Topics')
        s.act('press', 'palette-row-tag-cttag')
        self.wait_checked(['ct-one', 'ct-two'], 'Space on a partly checked Tag did not check all its Topics')
        s.act('press', 'palette-row-tag-cttag')
        self.wait_checked([], 'Space on a checked Tag did not uncheck its Topics')
        self.assertIsNone(self.record('ct-one').get('snoozed_until'), 'checking Snoozed')

    def test_return_with_nothing_checked_on_a_topic_goes_on_with_only_that_topic(self):
        s = self.s
        self.topic('rn-one', 31)
        self.topic('rn-two', 32)
        self.open_check()
        self.filter('rn-one')
        s.wait_rows(lambda rs: '↩ Snoozes rn-one…' in self.text('palette-note', rs), 'the note does not say that Return Snoozes the Topic')
        s.act('action', 'palette-search', 'Accept')
        self.wait_step('rn-one › Snooze › until')
        s.act('action', 'palette-search', 'Back')
        rs = s.wait_rows(lambda rs: 'Snooze Topics › check' in self.text('palette-breadcrumb', rs), 'Back did not open the check step')
        self.assertEqual(self.checked(rs), ['rn-one'], 'Back did not keep only the Topic checked')

    def test_return_with_nothing_checked_on_a_tag_checks_its_topics_and_stays(self):
        s = self.s
        self.topic('rt-one', 33, tags=['rttag'])
        self.topic('rt-two', 34, tags=['rttag'])
        self.open_check()
        self.filter('#rttag')
        s.wait_rows(lambda rs: '↩ checks #rttag' in self.text('palette-note', rs), 'the note does not say that Return checks the Tag')
        s.act('action', 'palette-search', 'Accept')
        rs = self.wait_checked(['rt-one', 'rt-two'], 'Return on the Tag did not check its Topics')
        self.assertIn('Snooze Topics › check', self.text('palette-breadcrumb', rs), 'Return on a Tag went on')
        self.assertTrue(all(self.record(name).get('snoozed_until') is None for name in ('rt-one', 'rt-two')),
                        'Return on a Tag row Snoozed its Topics')

    def test_space_checks_the_highlighted_row_and_check_all_shown_checks_the_filtered_topics(self):
        s = self.s
        self.topic('sp-one', 35, title='sp-one sppair')
        self.topic('sp-two', 36, title='sp-two sppair')
        self.topic('sp-other', 37)
        self.open_check()
        self.filter('sp-other')
        s.act('action', 'palette-search', 'Space')
        self.wait_checked(['sp-other'], 'Space did not check the highlighted row')
        self.filter('sppair')
        s.act('action', 'palette-search', 'Check All Shown')
        rs = self.wait_checked(['sp-one', 'sp-two'], 'Cmd-A did not check every Topic the filter shows')
        self.assertIn('1 checked is not shown', self.text('palette-note', rs), 'the note does not count the hidden checked Topic')
        s.act('action', 'palette-search', 'Check All Shown')
        self.wait_checked([], 'Cmd-A on all checked rows did not uncheck them')
        self.filter('')
        self.wait_checked(['sp-other'], 'a checked Topic that the filter hid lost its check')

    def test_a_snooze_by_tag_writes_one_time_on_its_open_topics_and_keeps_its_already_snoozed_topic(self):
        tagged = ['tgsnooze-one', 'tgsnooze-two']
        self.topic(tagged[0], 61, tags=['tgsnooze'])
        self.topic(tagged[1], 62, tags=['tgsnooze', 'other'])
        self.topic('tgsnooze-three', 63, tags=['tgsnooze'], snoozed_until=LATER)
        self.topic('tgsnooze-none', 64)
        self.select(self.topic('tgsnooze-active', 65, session=True))
        self.open_check()
        self.s.act('press', 'palette-row-tag-tgsnooze')
        rs = self.wait_checked(tagged, 'checking the Tag did not check only its Topics that are not Snoozed')
        self.assertEqual(self.box('palette-row-tag-tgsnooze', rs), 'checked', 'the Tag box counts its Already Snoozed Topic')
        self.assertIn('2 Topics · 1 Snoozed', self.text('palette-row-tag-tgsnooze', rs), 'the Tag row does not count its Already Snoozed Topic apart')
        self.s.act('action', 'palette-search', 'Accept')
        self.wait_step('2 Topics › Snooze › until')
        self.s.act('press', 'palette-row-0')
        self.s.wait_rows(lambda rs: not self.s.has('palette-search', rs), 'Snooze did not close the palette')
        names = tagged + ['tgsnooze-three', 'tgsnooze-none', 'tgsnooze-active']
        times = {name: self.record(name).get('snoozed_until') for name in names}
        self.assertEqual(len({times[name] for name in tagged}), 1, times)
        self.assertNotIn(times['tgsnooze-one'], (None, LATER), times)
        self.assertEqual(times['tgsnooze-three'], LATER, 'a Snooze by Tag changed the time of an Already Snoozed Topic: %s' % times)
        self.assertIsNone(times['tgsnooze-none'], times)
        self.assertIsNone(times['tgsnooze-active'], 'a Topic that was not checked was Snoozed: %s' % times)
        self.assertEqual(sorted(self.record('tgsnooze-one')), ['id', 'order', 'sessions', 'slug', 'snoozed_until', 'tags', 'title'],
                         'a Snooze by Tag writes a usual Snooze and no other field')

    def test_a_tag_with_only_snoozed_topics_has_no_row_and_its_topic_is_checked_by_its_own_row(self):
        s = self.s
        self.topic('as-one', 66, tags=['assnooze'], snoozed_until=LATER)
        self.topic('as-two', 67, tags=['assnooze'], snoozed_until=LATER)
        self.open_check()
        self.filter('#assnooze')
        rs = s.wait_rows(lambda rs: s.has('palette-row-topic-as-one', rs) and s.has('palette-row-topic-as-two', rs),
                         'the Already Snoozed Topics of the Tag are not listed')
        self.assertFalse(s.has('palette-row-tag-assnooze', rs), 'a Tag whose Topics are all Snoozed has a row')
        rs = self.check_rows('as-one')
        self.assertEqual(self.checked(rs), ['as-one'], 'pressing the Already Snoozed Topic did not check only it')
        s.act('action', 'palette-search', 'Close')

    def test_snooze_topics_writes_one_time_on_the_set_names_the_shorter_snooze_and_opens_the_next_topic_outside_it(self):
        s = self.s
        self.topic('nx-a', 71, session=True)
        active = self.topic('nx-b', 72, session=True)
        self.topic('nx-c', 73)
        after = self.topic('nx-d', 74, session=True)
        self.topic('nx-f', 76, snoozed_until=LATER)
        self.select(active)
        self.open_check()
        rs = self.check_rows('nx-f', 'nx-b', 'nx-c')
        self.assertIn('Snoozes: nx-b, nx-c, nx-f', self.text('palette-note', rs), 'the note does not name the set in list order')
        self.assertIn('Then opens: nx-d', self.text('palette-note', rs), 'the check step does not name the Next Topic')
        s.act('action', 'palette-search', 'Accept')
        rs = self.wait_step('3 Topics › Snooze › until')
        note = self.text('palette-note', rs)
        self.assertIn('Snoozes: nx-b, nx-c, nx-f', note)
        self.assertIn('Gets shorter: nx-f', note)
        self.assertIn('Then opens: nx-d', note, 'the Next Topic skips the rows that leave the list with the set')
        s.act('press', 'palette-row-0')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Snooze did not close the palette')
        s.wait_shown(after)
        times = {name: self.record(name).get('snoozed_until') for name in ['nx-a', 'nx-b', 'nx-c', 'nx-d', 'nx-f']}
        self.assertEqual(len({times['nx-b'], times['nx-c'], times['nx-f']}), 1, times)
        self.assertNotIn(times['nx-f'], (None, LATER), 'the shorter Snooze was not written: %s' % times)
        self.assertIsNone(times['nx-a'], times)
        self.assertIsNone(times['nx-d'], times)

    def test_back_in_the_until_step_goes_back_to_check_with_the_checks_kept(self):
        self.topic('bk-one', 81, tags=['bktag'])
        self.topic('bk-two', 82)
        self.topic('bk-three', 83)
        self.open_check()
        self.s.act('press', 'palette-row-tag-bktag')
        self.check_rows('bk-two')
        self.s.act('action', 'palette-search', 'Accept')
        self.wait_step('2 Topics › Snooze › until')
        self.s.act('action', 'palette-search', 'Back')
        self.wait_checked(['bk-one', 'bk-two'], 'Back did not keep the checks')

    def test_snooze_topic_starts_at_until_and_back_opens_check_with_its_topic_checked(self):
        s = self.s
        self.select(self.topic('st-one', 91, session=True))
        self.run_command('Snooze Topic')
        rs = self.wait_step('st-one › Snooze › until')
        self.assertTrue(s.has('palette-row-never', rs), 'the "until" step has no times')
        self.assertIn('⌫ goes back to check', self.text('palette-note', rs))
        s.act('action', 'palette-search', 'Back')
        self.wait_checked(['st-one'], 'Back did not open the check step with the Topic checked')
        s.act('action', 'palette-search', 'Accept')
        self.wait_step('st-one › Snooze › until')
        s.act('action', 'palette-search', 'Close')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Close did not close the palette')
        self.assertIsNone(self.record('st-one').get('snoozed_until'), 'Close after the steps Snoozed the Topic')

    def test_topic_snooze_from_the_cli_moves_the_topic_to_snoozed_and_keeps_its_session(self):
        s = self.s
        window = self.topic('cli-snz', 41, session=True)
        rs = s.wait_rows(lambda rs: s.has('topic-cli-snz', rs), 'the open Topic did not show')
        self.assertFalse(s.has('unsnooze-topic-cli-snz', rs), 'the Topic was Snoozed before the command')
        pane = s.tmux('display-message', '-p', '-t', window, '#{pane_id}')
        result = subprocess.run([str(CLI), 'topic', 'snooze', 'tomorrow', '--pane', pane], env=s.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, 'cli-snz\n', ''))
        rs = s.wait_rows(lambda rs: s.has('snoozed-topics', rs), 'the Snoozed group did not show')
        if s.row('snoozed-topics', rs).get('accessibilityValue') != 'expanded':
            s.act('press', 'snoozed-topics')
        s.wait_rows(lambda rs: s.has('unsnooze-topic-cli-snz', rs), 'the Topic did not move to Snoozed')
        self.assertEqual(s.tmux('show-options', '-qv', '-t', '=cli-snz:', '@muxify_topic'), 'cli-snz', 'the Session left the Topic')

    def test_topic_snooze_and_unsnooze_from_the_cli_move_several_topics_and_back(self):
        s = self.s
        self.topic('cli-a', 42)
        self.topic('cli-b', 43)
        s.wait_rows(lambda rs: s.has('topic-cli-a', rs) and s.has('topic-cli-b', rs), 'the open Topics did not show')
        def cli(*args):
            result = subprocess.run([str(CLI), 'topic', *args], env=s.env, capture_output=True, text=True, timeout=30)
            return (result.returncode, result.stdout, result.stderr)
        self.assertEqual(cli('snooze', 'tomorrow', '--topic', 'cli-a', '--topic', 'cli-b'), (0, 'cli-a\ncli-b\n', ''))
        rs = s.wait_rows(lambda rs: s.has('snoozed-topics', rs), 'the Snoozed group did not show')
        if s.row('snoozed-topics', rs).get('accessibilityValue') != 'expanded':
            s.act('press', 'snoozed-topics')
        s.wait_rows(lambda rs: s.has('unsnooze-topic-cli-a', rs) and s.has('unsnooze-topic-cli-b', rs),
                    'the Topics did not move to Snoozed')
        self.assertEqual(cli('unsnooze', '--topic', 'cli-a', '--topic', 'cli-b'), (0, 'cli-a\ncli-b\n', ''))
        s.wait_rows(lambda rs: s.has('topic-cli-a', rs) and s.has('topic-cli-b', rs) and not s.has('unsnooze-topic-cli-a', rs)
                    and not s.has('unsnooze-topic-cli-b', rs), 'the Topics did not move back to the open Topics')
        self.assertIsNone(self.record('cli-a').get('snoozed_until'), 'Unsnooze left the Snooze in the record')

    def test_topics_whose_snooze_ends_at_its_time_come_back_at_the_bottom_in_their_earlier_order(self):
        s = self.s
        past = '2000-01-01T00:00:00Z'
        self.topic('wake-b', 50, snoozed_until=past)
        self.topic('wake-a', 51, snoozed_until=past)
        self.topic('wake-c', 52)
        wait(lambda: all(self.record(name).get('snoozed_until') is None for name in ('wake-a', 'wake-b')),
             'the app did not wake the due Topics')
        orders = {name: self.record(name).get('order') for name in ('wake-a', 'wake-b', 'wake-c')}
        self.assertLess(orders['wake-c'], orders['wake-b'], orders)
        self.assertLess(orders['wake-b'], orders['wake-a'], orders)
        names = ['wake-a', 'wake-b', 'wake-c']
        def shown(rs):
            return all(s.has('topic-' + name, rs) for name in names) and \
                sorted(names, key=lambda name: -frame(s.row('topic-' + name, rs))[1]) == ['wake-c', 'wake-b', 'wake-a']
        s.wait_rows(shown, 'the Topics list did not show the woken Topics below wake-c in their earlier order')

if __name__ == '__main__':
    unittest.main()
