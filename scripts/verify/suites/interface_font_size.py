"""The Interface font size, `ui.font_size`: Muxify's own text keeps its ratio to 12, and the fixed sizes that hold it
grow with it (ADR 0067). Each check rewrites the sandbox Config, at 12 and then at 18, and measures elements in the
dump. Paddings and spacing do not scale, so a check compares the part of an element that holds its text: the element's
height less its padding.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.interface_font_size
"""

import re
import unittest

from scripts.verify.sandbox import Sandbox, frame
from scripts.verify.topic_records import TopicRecords

SHELL = '/bin/zsh -f'
# The padding of an open card's header, which does not scale: `CardHeader` in Sources/Muxify/UI/SidebarCard.swift has
# 7 points above, 3 below, and 2 of spacing between its title line and its details line.
CARD_HEADER_PADDING = 7 + 3 + 2
# `WindowRow` in Sources/Muxify/UI/SidebarView.swift has 4 points above and below its text.
WINDOW_ROW_PADDING = 4 + 4
# A frame is rounded to the display's pixels, so each height can be off by up to a point.
ROUNDING = 1
# The Sidebar's default width at 12, when the user never dragged it: `SidebarWidth.designDefault`.
SIDEBAR_WIDTH = 260
WINDOW_NAME = 'font-size-window'


def height(row):
    bottom, top = frame(row)
    return top - bottom


def width(row):
    return float(re.findall(r'-?[\d.]+', row['accessibilityFrame'])[2])


class InterfaceFontSize(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.s = s = Sandbox(__name__.rsplit('.', 1)[-1])
        cls.addClassCleanup(s.teardown)
        cls.project = s.root/'projects/alpha'
        cls.project.mkdir(parents=True)
        cls.config = s.root/'config/muxify/config.yaml'
        cls.write_config('')
        store = TopicRecords(s.root/'state/muxify')
        cls.windows = {}
        for topic_id, names in [('fs-size', [WINDOW_NAME]), ('fs-keep', ['keep-one', 'keep-two']), ('fs-other', ['other'])]:
            store.put(dict(id=topic_id, title=topic_id, slug=topic_id, home_project=str(cls.project)))
            sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', topic_id, '-n', names[0],
                         '-c', str(cls.project), SHELL)
            s.tmux('set-option', '-t', sid, '@muxify_topic', topic_id)
            for name in names[1:]:
                s.tmux('new-window', '-d', '-t', sid + ':', '-n', name, '-c', str(cls.project), SHELL)
            cls.windows[topic_id] = s.tmux('list-windows', '-t', sid + ':', '-F', '#{window_id}').split()
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES', '-sidebarWorkView', 'Topics'])
        s.wait_rows(lambda rs: all(s.has('topic-' + topic_id, rs) for topic_id in cls.windows), 'the Topic cards do not show')

    @classmethod
    def write_config(cls, extra):
        cls.config.write_text('sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n' + extra)

    def set_size(self, size):
        """Writes `ui.font_size` and waits until the Sidebar has the width of an undragged Sidebar at that size."""
        self.write_config('ui:\n  font_size: %s\n' % size)
        expected = SIDEBAR_WIDTH * size / 12
        return self.s.wait_rows(lambda rs: abs(width(self.s.row('sidebar-panel', rs)) - expected) < 1,
                                'the Sidebar is not %.0f points wide at ui.font_size: %s' % (expected, size))

    def settled(self, keys, message):
        """The rows once the heights of `keys` are the same in two dumps in a row, after a change has laid them out."""
        heights = []
        def same(rs):
            if not all(self.s.has(key, rs) for key in keys):
                return False
            heights.append([height(self.s.row(key, rs)) for key in keys])
            return heights[-2:] == [heights[-1]] * 2
        return self.s.wait_rows(same, message)

    def assert_text_grows_by_half(self, key, padding, small, large):
        """The part of the element that holds its text is about 1.5 times as tall at 18 as at 12."""
        expected = 1.5 * (small - padding)
        self.assertLessEqual(abs(large - padding - expected), ROUNDING * 2.5,
                             '%s holds its text in %.1f points at 12 and %.1f at 18, not about %.1f: it is %.0f and then '
                             '%.0f points tall, with %d of padding' % (key, small - padding, large - padding, expected,
                                                                       small, large, padding))

    def hover_label(self, rs):
        """The texts of the open hover label, None when none is open."""
        ids = self.s.ids(rs)
        if 'hover-label' not in ids:
            return None
        texts = []
        for row in rs[ids.index('hover-label') + 1:]:
            if row.get('accessibilityRole') == 'AXWindow':
                break
            text = row.get('accessibilityValue') or row.get('accessibilityLabel')
            if row.get('accessibilityRole') == 'AXStaticText' and text:
                texts.append(text)
        return texts

    def test_at_18_a_topic_cards_title_row_and_a_window_row_grow_by_half_and_show_their_whole_text(self):
        self.addCleanup(self.write_config, '')
        window = self.windows['fs-size'][0]
        card, row = 'topic-fs-size', 'topic-window-' + window
        self.s.show(window)
        self.set_size(12)
        rs = self.settled([card, row], 'the open card does not show its Window row at 12')
        self.assertIn('expanded', self.s.row(card, rs).get('accessibilityValue', ''), 'the card of the shown Window is closed')
        small = {key: height(self.s.row(key, rs)) for key in [card, row]}
        self.set_size(18)
        rs = self.settled([card, row], 'the open card does not show its Window row at 18')
        large = {key: height(self.s.row(key, rs)) for key in [card, row]}
        # An open card's title wraps when it does not fit, so a title on one line at 12 that needs two at 18 would make
        # the title row twice as tall.
        self.assert_text_grows_by_half(card, CARD_HEADER_PADDING, small[card], large[card])
        self.assert_text_grows_by_half(row, WINDOW_ROW_PADDING, small[row], large[row])
        self.assertEqual(self.s.row(card, rs).get('accessibilityLabel'), 'fs-size')
        # A Window row cuts a title that does not fit, and its hover label then shows the whole title before the place.
        self.addCleanup(self.s.act, 'hover', 'agents-header')
        self.s.act('hover', row)
        texts = self.hover_label(self.s.wait_rows(lambda rs: self.hover_label(rs), 'no hover label on ' + row, seconds=5))
        self.assertEqual(len(texts), 1, 'the Window row cuts its title off at 18: its hover label shows %s' % texts)

    def test_ui_sidebar_font_size_is_gone_with_a_problem_and_changes_no_size(self):
        self.addCleanup(self.write_config, '')
        self.set_size(12)
        self.write_config('ui:\n  sidebar:\n    font_size: 14\n')
        problem = 'ui.sidebar.font_size is gone: use ui.font_size'
        rs = self.s.wait_rows(lambda rs: any(problem in row.get('accessibilityLabel', '') + row.get('accessibilityValue', '')
                                             for row in rs),
                              'the Config problems banner does not show "%s"' % problem)
        line = next(row.get('accessibilityValue') or row.get('accessibilityLabel') for row in rs
                    if problem in row.get('accessibilityLabel', '') + row.get('accessibilityValue', ''))
        self.assertIn('config.yaml:6: ', line, 'the problem does not name the line of ui.sidebar.font_size')
        self.assertEqual(width(self.s.row('sidebar-panel', rs)), SIDEBAR_WIDTH,
                         'ui.sidebar.font_size: 14 changed the size of the Sidebar')

    def test_a_size_change_keeps_the_selected_window_and_the_expanded_cards(self):
        self.addCleanup(self.write_config, '')
        keep_one, keep_two = self.windows['fs-keep']
        cards = ['topic-' + topic_id for topic_id in self.windows]
        self.set_size(12)
        self.s.show(keep_two)
        rs = self.s.wait_rows(lambda rs: self.s.has('topic-window-' + keep_two, rs), 'the shown Window has no row')

        def state(rs):
            """The App Window's title, which names the Session it shows, each card's open state, and the selected rows."""
            title = next((r.get('accessibilityTitle') for r in rs if r.get('accessibilityRole') == 'AXWindow'), None)
            rows = {key: self.s.row(key, rs).get('accessibilityValue', '').split(',')[0] for key in cards}
            selected = [r['accessibilityIdentifier'] for r in rs if r.get('accessibilityValue') == 'selected'
                        and r.get('accessibilityIdentifier', '').startswith(('topic-window-', 'header-window-'))]
            return title, rows, sorted(selected)

        shown = state(rs)
        self.assertEqual(shown[1]['topic-fs-keep'], 'expanded', 'the card of the shown Window is closed')
        self.assertEqual(shown[2], sorted(['topic-window-' + keep_two, 'header-window-' + keep_two]))
        for size in [18, 12]:
            rs = self.set_size(size)
            self.assertEqual(state(rs), shown, 'ui.font_size: %s changed the Location, the selection or the cards' % size)
        # A card the user closed stays closed.
        self.s.act('press', 'topic-fs-keep')
        rs = self.s.wait_rows(lambda rs: self.s.row('topic-fs-keep', rs).get('accessibilityValue', '').startswith('collapsed'),
                              'the card of the shown Window did not close')
        self.addCleanup(lambda: self.s.row('topic-fs-keep').get('accessibilityValue', '').startswith('collapsed')
                        and self.s.act('press', 'topic-fs-keep'))
        closed = state(rs)
        rs = self.set_size(18)
        self.assertEqual(state(rs), closed, 'ui.font_size: 18 opened a closed card or changed the Location')
