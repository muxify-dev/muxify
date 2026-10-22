"""Tags in Go to…: each Topic row shows its Tags, a Tags section after Topics for a query, a Tag filter chip, and Snooze its Topics.

The driver cannot type keys. A check opens Go to… from its View menu item and sets the query. A press on a row is
what Return on it does, Back is what Backspace in the empty field calls, and a row's accessibility actions are its
Cmd-K actions (UI/CommandPaletteView.swift).

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.palette_goto_tags
"""

import unittest

from scripts.verify.palette_fixture import PaletteFixture
from scripts.verify.sandbox import wait

LATER = '2099-01-01T00:00:00Z'


class PaletteGoToTags(PaletteFixture):
    TAGS = {'gssect': '{}', 'gfilter': '{}', 'gzsnooze': '{}', 'gplain': '{color: green}', 'gempty': '{}'}

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

    def chips(self, rs):
        return [key[len('palette-tag-'):] for key in self.s.ids(rs) if key.startswith('palette-tag-')]

    def test_the_tags_section_comes_after_topics_and_only_for_a_query(self):
        s = self.s
        self.topic('gs-one', 1, tags=['gssect'])
        self.topic('gs-untagged', 2)
        rs = self.go_to('')
        self.assertFalse(s.has('palette-section-tags', rs), 'the empty Go to… lists Tags')
        rs = s.wait_rows(lambda rs: s.has('palette-row-topic-gs-one', rs) and s.has('palette-row-topic-gs-untagged', rs),
                         'the empty Go to… did not list the Topics')
        self.assertIn('#gssect', s.row('palette-row-topic-gs-one', rs).get('accessibilityLabel', ''),
                      'a Topic row in the empty Go to… does not show its Tags')
        self.assertNotIn('#', s.row('palette-row-topic-gs-untagged', rs).get('accessibilityLabel', ''),
                         'a Topic with no Tags shows a Tag')
        self.go_to('gs')
        rs = s.wait_rows(lambda rs: s.has('palette-row-tag-gssect', rs) and s.has('palette-row-topic-gs-one', rs),
                         'the query "gs" did not show the Tag and the Topic')
        ids = s.ids(rs)
        self.assertLess(ids.index('palette-section-topics'), ids.index('palette-section-tags'), 'the Tags section is not after Topics')
        self.assertIn('1 Topic', s.row('palette-row-tag-gssect', rs).get('accessibilityLabel', ''))

    def test_tags_show_their_name_and_a_tag_with_no_topic_or_no_definition_is_not_listed(self):
        s = self.s
        self.topic('gd-one', 31, tags=['gplain', 'gorphan'])
        rs = self.go_to('#')
        rs = s.wait_rows(lambda rs: s.has('palette-row-tag-gplain', rs), 'the Tag is not listed')
        self.assertIn('#gplain', self.text('palette-row-tag-gplain', rs), 'the Tag row does not show the Tag name')
        self.assertFalse(s.has('palette-row-tag-gorphan', rs), 'a Tag the Config does not define is listed')
        self.assertFalse(s.has('palette-row-tag-gempty', rs), 'a Tag that no Topic has is listed as a filter')
        self.go_to('#gpla')
        rs = s.wait_rows(lambda rs: s.has('palette-row-tag-gplain', rs), 'the name of a Tag does not find it')
        self.assertIn('#gplain', s.row('palette-row-topic-gd-one', rs).get('accessibilityLabel', ''),
                      'the Topic row does not show the name of its Tag')
        self.assertNotIn('#gorphan', s.row('palette-row-topic-gd-one', rs).get('accessibilityLabel', ''),
                         'the Topic row shows a Tag the Config does not define')
        s.act('action', 'palette-search', 'Close')

    def test_return_on_a_tag_row_filters_by_the_tag_and_back_removes_the_filter(self):
        s = self.s
        self.topic('gf-open', 11, tags=['gfilter'])
        self.topic('gf-snoozed', 12, tags=['gfilter'], snoozed_until=LATER)
        self.topic('gf-settled', 13, tags=['gfilter'], settled_at='2026-01-01T00:00:00Z')
        self.topic('gf-other', 14)
        self.go_to('#gfilter')
        s.wait_rows(lambda rs: s.has('palette-row-tag-gfilter', rs), 'the Tag row did not show')
        s.act('press', 'palette-row-tag-gfilter')
        rs = s.wait_rows(lambda rs: self.chips(rs) == ['gfilter'] and s.has('palette-row-topic-gf-open', rs),
                         'Return on the Tag row did not make it a filter chip')
        self.assertIn('Go to… › #gfilter', self.text('palette-breadcrumb', rs))
        self.assertEqual(s.row('palette-search', rs).get('accessibilityValue', ''), '', 'the filter did not clear the query')
        shown = [key for key in s.ids(rs) if key.startswith('palette-row-')]
        self.assertEqual(sorted(shown), ['palette-row-topic-gf-open', 'palette-row-topic-gf-settled', 'palette-row-topic-gf-snoozed'],
                         'the filter does not show exactly the Topics with the Tag, Snoozed and Settled too')
        s.act('action', 'palette-search', 'Back')
        rs = s.wait_rows(lambda rs: not self.chips(rs) and s.has('palette-search', rs), 'Back did not remove the filter chip')
        self.assertFalse(s.has('palette-breadcrumb', rs), 'the breadcrumb stayed after the filter went')

    def test_snooze_its_topics_on_a_tag_row_opens_check_with_the_topics_of_the_tag_that_are_not_snoozed_checked(self):
        s = self.s
        self.topic('gz-one', 21, tags=['gzsnooze'])
        self.topic('gz-two', 22, tags=['gzsnooze'])
        self.topic('gz-none', 23)
        self.topic('gz-snoozed', 24, tags=['gzsnooze'], snoozed_until=LATER)
        self.go_to('#gzsnooze')
        s.wait_rows(lambda rs: s.has('palette-row-tag-gzsnooze', rs), 'the Tag row did not show')
        s.act('action', 'palette-row-tag-gzsnooze', 'Snooze its Topics…')
        checked = lambda rs, name: 'checked' in s.row('palette-row-topic-' + name, rs).get('accessibilityValue', '')
        rs = s.wait_rows(lambda rs: 'Snooze Topics › check' in self.text('palette-breadcrumb', rs) and checked(rs, 'gz-one') and checked(rs, 'gz-two'),
                         'Snooze its Topics… did not open the check step with the Topics of the Tag checked')
        self.assertFalse(checked(rs, 'gz-none'), 'a Topic without the Tag is checked')
        self.assertTrue(s.has('palette-row-topic-gz-snoozed', rs), 'the Already Snoozed Topic of the Tag is not listed')
        self.assertFalse(checked(rs, 'gz-snoozed'), 'an Already Snoozed Topic of the Tag is checked')
        self.assertEqual(self.chips(rs), [], 'the check step shows a chip')
        self.assertIn('↩ Snoozes 2 Topics…', self.text('palette-note', rs))
        s.act('action', 'palette-search', 'Close')

if __name__ == '__main__':
    unittest.main()
