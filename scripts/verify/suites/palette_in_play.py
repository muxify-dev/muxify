"""Choose In Play and Replace from Bench set which cards are In Play, with topics.in_play: 2.

The driver cannot type keys. A check opens Commands from its View menu item and calls the search field's
accessibility actions for the keys. A press on a row of a check step is a click, which checks it as Space does, and a
press on a row of a choose-a-row step is what Return on it does (UI/CommandPaletteView.swift).

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.palette_in_play
"""

import unittest

from scripts.verify.palette_fixture import PaletteFixture
from scripts.verify.sandbox import wait


class PaletteInPlay(PaletteFixture):
    TAGS = {'work': '{}'}

    @classmethod
    def config_text(cls, tags=None):
        return super().config_text(tags) + '  in_play: 2\n'

    def order(self, prefix):
        """The ids of the check's Topics in the order of the Topics list."""
        records = [r for r in self.records() if r['id'].startswith(prefix) and not r.get('settled_at')]
        return [r['id'] for r in sorted(records, key=lambda r: r.get('order', 0))]

    def absent(self, title):
        self.search(title)
        present = self.s.has('palette-row-command-' + title)
        self.s.act('action', 'palette-search', 'Close')
        return not present

    def test_choose_in_play_checks_the_cards_then_takes_one_for_each_place(self):
        s = self.s
        self.topic('cip-p', order=-1, pinned=True)
        for order, (name, tags) in enumerate([('cip-a', []), ('cip-b', []), ('cip-c', ['work']), ('cip-d', ['work'])]):
            self.topic(name, order=order, tags=tags)
        key = lambda name: 'palette-row-topic-cip-' + name
        rows = lambda rs: [k for k in s.ids(rs) if k.startswith('palette-row-topic-cip-')]
        checked = lambda rs: [k for k in rows(rs) if 'checked' in s.row(k, rs).get('accessibilityValue', '')]
        s.wait_rows(lambda rs: s.has('topic-cip-b', rs), 'the Topics did not appear')
        self.run_command('Choose In Play…')
        rs = s.wait_rows(lambda rs: 'Choose In Play › Check' in self.text('palette-breadcrumb', rs) and len(rows(rs)) == 4,
                         'Choose In Play did not list the cards: %s' % rows(s.rows()))
        self.assertEqual(rows(rs), [key('a'), key('b'), key('c'), key('d')], 'the step lists a Pinned Topic, or not in list order')
        self.assertEqual(checked(rs), [key('a'), key('b')], 'the In Play cards do not start checked')

        s.act('set', 'palette-search', '#work')
        s.wait_rows(lambda rs: rows(rs) == [key('c'), key('d')], '#work did not narrow the rows: %s' % rows(s.rows()))
        s.act('action', 'palette-search', 'Space')
        self.assertEqual(checked(s.rows()), [], 'Space with a query checked a row')
        s.act('press', key('c'))
        s.act('press', key('d'))
        s.act('set', 'palette-search', '')
        s.wait_rows(lambda rs: len(rows(rs)) == 4, 'the empty query did not list every card')
        s.act('action', 'palette-search', 'Space')
        rs = s.wait_rows(lambda rs: checked(rs) == [key('b'), key('c'), key('d')],
                         'Space in the empty field did not uncheck the first row: %s' % checked(s.rows()))
        self.assertIn('3 checked for 2 In Play places. The last 1 go to the top of the Bench.', self.text('palette-note', rs))
        s.act('press', key('a'))
        rs = s.wait_rows(lambda rs: len(checked(rs)) == 4, 'a click did not check the row: %s' % checked(s.rows()))
        self.assertIn('4 checked for 2 In Play places. The last 2 go to the top of the Bench.', self.text('palette-note', rs))

        s.act('action', 'palette-search', 'Accept')
        place = lambda name: 'palette-row-place-topic-cip-' + name
        places = lambda rs: [k for k in s.ids(rs) if k.startswith('palette-row-place-topic-cip-')]
        rs = s.wait_rows(lambda rs: 'Place 1' in self.text('palette-breadcrumb', rs)
                         and places(rs) == [place('a'), place('b'), place('c'), place('d')],
                         'the first place does not list the checked cards in list order: %s' % places(s.rows()))
        self.assertNotIn('on the Bench', self.text('palette-note', rs))
        s.act('press', place('d'))
        s.wait_rows(lambda rs: 'Place 2' in self.text('palette-breadcrumb', rs) and places(rs) == [place('a'), place('b'), place('c')],
                    'the second place does not list the cards that are left: %s' % places(s.rows()))
        s.act('action', 'palette-search', 'Back')
        s.wait_rows(lambda rs: 'Place 1' in self.text('palette-breadcrumb', rs) and len(places(rs)) == 4, 'Back did not go back one place')
        s.act('press', place('c'))
        s.wait_rows(lambda rs: 'Place 2' in self.text('palette-breadcrumb', rs), 'the second place did not open')
        s.act('press', place('b'))
        rs = s.wait_rows(lambda rs: 'Place 3' in self.text('palette-breadcrumb', rs) and places(rs) == [place('a'), place('d')],
                         'the checked cards after the last In Play place have no place step: %s' % places(s.rows()))
        self.assertIn('Place 3 is on the Bench.', self.text('palette-note', rs))
        s.act('press', place('d'))
        wait(lambda: self.order('cip-') == ['cip-p', 'cip-c', 'cip-b', 'cip-d', 'cip-a'],
             'the chosen cards are not In Play and at the top of the Bench in their order')
        self.assertEqual(self.record('cip-p').get('order'), -1, 'Choose In Play moved a Pinned Topic')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Choose In Play did not close the palette')

    def test_replace_from_bench_puts_the_chosen_card_in_the_place_and_goes_to_it(self):
        s = self.s
        window = self.topic('rfb-a', order=0, session=True)
        self.topic('rfb-b', order=1)
        incoming = self.topic('rfb-c', order=2, session=True)
        self.topic('rfb-d', order=3)
        s.wait_rows(lambda rs: s.has('topic-rfb-a', rs), 'the Topic did not appear')
        self.assertTrue(self.absent('Replace from Bench…'), 'Replace from Bench… shows on No Topic')
        self.select(window)
        self.run_command('Replace from Bench…')
        rs = s.wait_rows(lambda rs: 'rfb-a › Replace from Bench' in self.text('palette-breadcrumb', rs)
                         and s.has('palette-row-topic-rfb-d', rs), 'Replace from Bench did not list the Bench')
        rows = [key for key in s.ids(rs) if key.startswith('palette-row-topic-rfb-')]
        self.assertEqual(rows, ['palette-row-topic-rfb-c', 'palette-row-topic-rfb-d'], 'the step lists more than the Bench')
        self.assertIn('rfb-a goes to the end of the Bench', self.text('palette-note', rs))
        s.act('press', 'palette-row-topic-rfb-c')
        wait(lambda: self.order('rfb-') == ['rfb-c', 'rfb-b', 'rfb-d', 'rfb-a'],
             'the chosen card did not take the place')
        s.wait_rows(lambda rs: not s.has('palette-search', rs), 'Replace from Bench did not close the palette')
        s.wait_shown(incoming)
        self.select(window)
        self.assertTrue(self.absent('Replace from Bench…'), 'Replace from Bench… shows on a Benched card')


if __name__ == '__main__':
    unittest.main()
