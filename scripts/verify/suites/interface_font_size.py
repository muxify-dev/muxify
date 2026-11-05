"""The Interface font size, `ui.font_size`: Muxify's own text keeps its ratio to 12, and the fixed sizes that hold it
grow with it (ADR 0068). Each check rewrites the sandbox Config, at 12 and then at 18, and measures elements in the
dump. Paddings and spacing do not scale, so a check compares the part of an element that holds its text: the element's
height less its padding.

The Bench's geometry follows the edge pill, whose band grows with the size, so the Bench's rules also hold at 18: a
Benched card stands directly below the Bench line or the "more above" pill, and neither covers it (ADR 0063).

The App Window header's height, `ui.header_height`, is a length at 12 that grows by the same factor, so its buttons,
which grow too, still fit in it. A maximum width that grows, such as the Git button's, gives way in a header without
room for it, so no button leaves the App Window.

The Git View's list rows, list headers, tabs and bars hold their text in fixed heights that grow by the factor, and the
List pane's width bounds grow too, so a file name keeps its room. Its keys, its scrolling to the selection and a click
select the row that is drawn there at every size.

The Git View's popups, the commit box and a Git View menu, hold their text in fixed heights and widths that grow by the
factor too, but never past the Git View, so a popup stays in the App Window. A Git View menu leaves the keys with the
Git View, and a Git View prompt gives them to its field, at every size.

The Git View's code text does not follow `ui.font_size`: it is the Terminal's `font-size` less one point, and its
line-number gutter grows with it, wide enough for the diff's widest line number, so a 5-digit number shows whole.

A Command Palette's rows, section headers and search field hold their text in fixed heights that grow by the factor, and
its width grows too, but never past the App Window less its margins. The list still shows six and a half rows. Its
keys, its scrolling to the highlighted row and a click choose the row that is drawn there at every size. The driver
cannot type keys, so a check opens a palette from its View menu item and calls the search field's accessibility actions
for them (Sources/Muxify/UI/CommandPaletteView.swift).

The overlays over an App Window hold their text in fixed heights and widths that grow by the factor too: a Pill, the
Config problems banner, Find in Pane's bar, a Hint, an Empty Topic page's title and a hover label, whose panel is
outside the App Window's view tree and takes the size from the row it labels. A width that grows is a maximum, so an
overlay never leaves the App Window or what it overlays.

The Browser's chrome, its tab strip, Tabs, toolbar and address field, holds its text in fixed heights that grow by the
factor, and a Tab's width bounds grow too, so its title keeps its room. The page inside it keeps its own zoom: its
viewport is as many CSS pixels wide at every size. The Sidebar's width grows with the size and the Browser takes a share
of the room beside it, so that check hides the Sidebar, and the Browser is as wide at both sizes.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.interface_font_size
"""

import math
import re
import subprocess
import time
import unittest

from scripts.verify.sandbox import Sandbox, frame, wait
from scripts.verify.topic_records import TopicRecords

SHELL = '/bin/zsh -f'
# The padding of an open card's header, which does not scale: `CardHeader` in Sources/Muxify/UI/SidebarCard.swift has
# 7 points above, 3 below, and 2 of spacing between its title line and its details line.
CARD_HEADER_PADDING = 7 + 3 + 2
# `WindowRow` in Sources/Muxify/UI/SidebarView.swift has 4 points above and below its text.
WINDOW_ROW_PADDING = 4 + 4
# `PaneRow` in Sources/Muxify/UI/SidebarView.swift has 3 points above and below its text, and 1 between its title and
# its Summary.
PANE_ROW_PADDING = 3 + 3 + 1
# A closed card's header has 4 points more padding at its bottom than an open card's (`CardHeader` in
# Sources/Muxify/UI/SidebarCard.swift), and 2 of spacing and 1 of padding above its Summary line. So the closed header
# of a card whose title is on one line is the open header of such a card, these 7 points, and the Summary line.
SUMMARY_PADDING = 4 + 2 + 1
# `TagChip` in Sources/Muxify/UI/CardTags.swift has 1 point above and below its text, and 5 on each side.
CHIP_PADDING = 1 + 1
CHIP_SIDES = 5 + 5
# The room between the items of the Topics list (`TopicsSection.contentSpacing` in Sources/Muxify/UI/SidebarView.swift).
SPACING = 6
# The band of the "more above" pill at 12 (`EdgePill.designHeight` in Sources/Muxify/UI/TopicsListEdge.swift).
PILL = 30
LINE = 'topics-bench-line'
# A frame is rounded to the display's pixels, so each height can be off by up to a point.
ROUNDING = 1
# The Sidebar's default width at 12, when the user never dragged it: `SidebarWidth.designDefault`.
SIDEBAR_WIDTH = 260
WINDOW_NAME = 'font-size-window'
HEADER = 'header-bar'
# The header's buttons, which all hold their text or symbol in a fixed height: 24 points at 12 for the Git button, the
# Window list's buttons and the titlebar buttons (`HeaderTextButton` in Sources/Muxify/UI/HeaderGitButton.swift and
# `TitlebarButton` in Sources/Muxify/UI/ContentView.swift), and 22 for the Environment badge.
HEADER_BUTTONS = ['toggle-git-view', 'header-environment-selector', 'toggle-maximize', 'toggle-sidebar',
                  'toggle-terminal', 'toggle-browser']
# `HeaderTextButton` has 8 points on each side of its text.
HEADER_BUTTON_SIDES = 8 + 8
# Pane rows with a Summary, and Tag chips on their own line. After the part a check writes, so that part keeps its
# line numbers.
FIXTURE = ("sidebar:\n  panes: true\n  tag_placement: line\n  formats:\n    pane:\n      summary: 'Pane Summary'\n"
           'topics:\n  tags:\n    work: {color: blue}\n')
IN_PLAY = '  in_play: 1\n'
LAUNCH_ARGS = ['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-agentsVisible', 'YES', '-sidebarWorkView', 'Topics']
# The Git button's maximum width at 12, with its 16 points of padding (`HeaderGitButton`).
GIT_BUTTON_MAX = 180 + HEADER_BUTTON_SIDES
# The Git View's width in the Git View checks. Its List pane takes 30% of it, but at least 240 points at 12 and 360 at 18
# (`GitListMetrics` in Sources/Muxify/UI/GitListMetrics.swift), and at 760 both are less than half of it. So the List
# pane is at its least width at both sizes, and that grows by the factor.
GIT_VIEW_WIDTH = 760
# `GitTabBar` in Sources/Muxify/UI/GitViewPanel.swift has 8 points around its bar and 2 inside it, above and below the tabs.
TAB_BAR_PADDING = 8 + 8 + 2 + 2
# A file name that fits in its row in the List pane at 12.
LONG_NAME = 'a-long-file-name.txt'
GIT_ROW = 'git-row-change:'
# The Git View's width in the popup checks. A popup leaves 48 points beside it in the Git View (`GitPopupMetrics` in
# Sources/Muxify/UI/GitPopupMetrics.swift), so at 1000 the commit box, 620 points wide at 12 and 930 at 18, and a Git
# View menu, 460 and 690, grow by the factor.
POPUP_GIT_VIEW_WIDTH = 1000
STAGED_NAME = 'a-staged-file.txt'
# The parts of the commit box that grow with their text (`GitCommitBox` in Sources/Muxify/UI/GitViewPanel.swift), each
# with its padding that does not grow: the summary field, one line of its text; the description editor, in 124 points
# at 12 with 10 above and 10 below it, so it is 20 points shorter than what grows (a padding of -20); the texts of a
# staged file's row; the Commit button, 30 points high at 12; and the footer around it, 58.
COMMIT_PARTS = {'git-commit-summary': 0, 'git-commit-description': -(10 + 10), 'git-commit-file:' + STAGED_NAME: 0,
                'git-commit-submit': 0, 'git-commit-footer': 0}
# The Discard menu's first choice, on the root row of Changes: 48 points high at 12, with its note.
MENU_CHOICE = 'git-menu-choice-x'
# The view of the Git View that has the keys: it takes them while a Git View menu shows (`GitKeyCatcher` in
# Sources/Muxify/UI/GitViewPanel.swift).
KEY_VIEW = 'KeyView'
# A file long enough for 5-digit line numbers, changed near its end: its hunk shows the lines 9999 to 10005, with 3
# lines of context on each side of the change.
LONG_FILE = 'a-long-file.txt'
LONG_FILE_LINES = 10010
CHANGED_LINE = 10002
# The Terminal's `font-size` at its default and larger. The Git View's code is a point smaller.
TERMINAL_SIZES = [13, 18]
# The Command Palette and its search field. A row of a palette holds its text in 52 points at 12, with nothing above or
# below it, and the list shows 6.5 rows before it scrolls. The palette is 700 points wide at 12, and never wider than the
# App Window less 48 (`PaletteMetrics` in Sources/Muxify/UI/PaletteMetrics.swift).
PALETTE = 'command-palette'
PALETTE_SEARCH = 'palette-search'
PALETTE_LIST = 'palette-list'
PALETTE_ROW = 52
PALETTE_VISIBLE_ROWS = 6.5
PALETTE_WIDTH = 700
PALETTE_MARGIN = 48
# Dormant Topics, so that Choose In Play, which lists every Topic that is not Pinned, lists more rows than it shows.
PICK_TOPICS = ['fs-pick-%02d' % n for n in range(10)]
# A Pill holds its title and value in 38 points at 12, with nothing above or below them (`PillView` in
# Sources/Muxify/UI/Pill.swift). Across it, beside its mark and texts, which grow, it has 8 points before the mark, 8
# after it, 8 between the title and the value, 2 before the value and 16 after it.
PILL_HEIGHT = 38
PILL_SIDES = 8 + 8 + 8 + 2 + 16
# Mark Read on a Window with nothing Unread explains itself in a Pill (`Pill(readRefusal:in:)` in
# Sources/Muxify/UI/ReadPills.swift).
PILL_TITLE = 'Not marked Read'
PILL_VALUE = 'explanation: Nothing is Unread in this Window'
# The Config problems banner is at most 560 points wide at 12, and its close button is 18 points square
# (`ConfigProblemsBanner` in Sources/Muxify/UI/ContentView.swift). It stands 10 points inside the App Window.
BANNER_WIDTH = 560
BANNER_MARGIN = 10 + 10
BANNER_CLOSE = 18
REMOVED_KEY = 'ui.sidebar.font_size is gone: use ui.font_size'
# Find in Pane's bar is 34 points high at 12 and at most 420 wide, 10 points inside the Terminal's corner (`findBar` in
# Sources/Muxify/UI/ContentView.swift).
FIND_BAR_HEIGHT = 34
FIND_BAR_WIDTH = 420
FIND_BAR_MARGIN = 10 + 10
# A Hint: a card's key at rest is at least 16 points square at 12 (`CardRestKey` in Sources/Muxify/UI/HintView.swift),
# and the badge that a held modifier shows has 2 points above and below its keys and 5 on each side (`HintBadge`).
REST_KEY = 16
BADGE_PADDING = 2 + 2
BADGE_SIDES = 5 + 5
# A Topic with no Session and no Home Session Path: going to it shows its Empty Topic page.
EMPTY_TOPIC = 'fs-empty'
# A hover label has 4 points above its text and 5 below it, and 7 before and 8 after it (`HoverLabelView` in
# Sources/Muxify/UI/HoverLabel.swift).
HOVER_LABEL_PADDING = 4 + 5
HOVER_LABEL_SIDES = 7 + 8
# The Browser's chrome at 12, with nothing above or below its text: the tab strip is 36 points high, a Tab 26, the
# toolbar 40, its buttons 26 square and the address field 30, and a Tab's close button is 16 square (`TabStrip`, `TabItem`
# and `TabContent` in Sources/Muxify/Browser/BrowserPanel.swift). A Tab is between 110 and 220 points wide at 12
# (`BrowserTabWidth` in Sources/Muxify/Browser/BrowserTabWidth.swift), and the strip has 16 points of padding, 4 after
# each Tab and the New Tab button, 26 at 12, beside them.
BROWSER_CHROME = {'browser-tab-strip': 36, 'browser-tab': 26, 'browser-toolbar': 40, 'browser-back': 26,
                  'browser-address-field': 30, 'browser-tab-close': 16}
TAB_WIDTH = 220
TAB_STRIP_SIDES = 16 + 4 + 4 + 26
# A Tab's title stands between its icon and its close button, 6 points from each, with a Spacer that takes what the
# title leaves (`TabItem`), so there is 6 more points of spacing before the close button.
TAB_TITLE_SPACING = 6 + 6
BROWSER_TOPIC = 'fs-browser'
# The page reports its viewport's width in CSS pixels in its title, which the Tab shows. The title is longer than a Tab
# shows at either size.
BROWSER_PAGE = """<!doctype html><meta charset="utf-8"><body style="margin: 0">
<script>
  const show = () => { document.title = 'fs-page vw=' + innerWidth + ' and a title longer than any Tab shows whole'; };
  show();
  setInterval(show, 200);
</script>"""


def code_line_height(terminal_size):
    """A line of the Git View's code at the Terminal's `font-size`: 1.6 times the code's size, which is a point smaller
    (`GitView.TextMetrics.lineHeight` in Sources/Muxify/UI/GitDiffMetrics.swift)."""
    return round(1.6 * (terminal_size - 1))


def height(row):
    bottom, top = frame(row)
    return top - bottom


def width(row):
    return float(re.findall(r'-?[\d.]+', row['accessibilityFrame'])[2])


def bounds(row):
    """(x, y, width, height) of a dump row's accessibilityFrame, in screen points."""
    return tuple(map(float, re.findall(r'-?[\d.]+', row['accessibilityFrame'])))


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
        cls.store = store
        cls.windows = {}
        for topic_id, names in [('fs-size', [WINDOW_NAME]), ('fs-keep', ['keep-one', 'keep-two']), ('fs-other', ['other']),
                                ('fs-panes', ['split']), ('fs-tags', ['tagged'])]:
            store.put(dict(id=topic_id, title=topic_id, slug=topic_id, home_project=str(cls.project),
                           tags=['work'] if topic_id == 'fs-tags' else []))
            sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', topic_id, '-n', names[0],
                         '-c', str(cls.project), SHELL)
            s.tmux('set-option', '-t', sid, '@muxify_topic', topic_id)
            for name in names[1:]:
                s.tmux('new-window', '-d', '-t', sid + ':', '-n', name, '-c', str(cls.project), SHELL)
            cls.windows[topic_id] = s.tmux('list-windows', '-t', sid + ':', '-F', '#{window_id}').split()
        cls.panes = s.tmux('list-panes', '-t', cls.windows['fs-panes'][0], '-F', '#{pane_id}').split()
        cls.panes.append(s.tmux('split-window', '-d', '-t', cls.windows['fs-panes'][0], '-P', '-F', '#{pane_id}',
                                '-c', str(cls.project), SHELL))
        s.launch(LAUNCH_ARGS)
        s.wait_rows(lambda rs: all(s.has('topic-' + topic_id, rs) for topic_id in cls.windows), 'the Topic cards do not show')

    def restart_app(self, args):
        """Starts the app again, and waits until its Terminal's tmux client is attached and its Topic cards show. Before
        that, the app drops a request to show a Window."""
        s = self.s
        s.restart_app(args)
        wait(lambda: '0' in s.tmux('list-clients', '-F', '#{client_control_mode}').split(), 'the app attached no client')
        s.wait_rows(lambda rs: all(s.has('topic-' + topic_id, rs) for topic_id in self.windows), 'the Topic cards do not show')

    @classmethod
    def write_config(cls, extra, topics=''):
        """The Config with `extra` after the Session Paths, then the FIXTURE, whose `topics` section ends with `topics`."""
        cls.config.write_text('sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n' + extra + FIXTURE + topics)

    def set_size(self, size, topics='', extra=''):
        """Writes `ui.font_size`, then `extra`, and waits until the Sidebar has the width of an undragged Sidebar at that
        size."""
        self.write_config('ui:\n  font_size: %s\n' % size + extra, topics)
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

    def assert_text_grows_by_half(self, key, padding, small, large, side='tall'):
        """The part of the element that holds its text is about 1.5 times as tall (or `side`) at 18 as at 12."""
        expected = 1.5 * (small - padding)
        self.assertLessEqual(abs(large - padding - expected), ROUNDING * 2.5,
                             '%s holds its text in %.1f points at 12 and %.1f at 18, not about %.1f: it is %.0f and then '
                             '%.0f points %s, with %d of padding' % (key, small - padding, large - padding, expected,
                                                                     small, large, side, padding))

    def heights(self, keys, size, message, topics=''):
        """The heights of `keys` once they are laid out at `size`, and the rows."""
        self.set_size(size, topics)
        rs = self.settled(keys, message % size)
        return {key: height(self.s.row(key, rs)) for key in keys}, rs

    def assert_hover_label_shows_only_the_place(self, key):
        """A row cuts a title that does not fit, and its hover label then shows the whole title before the place."""
        self.addCleanup(self.s.act, 'hover', 'agents-header')
        self.s.act('hover', key)
        texts = self.hover_label(self.s.wait_rows(lambda rs: self.hover_label(rs), 'no hover label on ' + key, seconds=5))
        self.assertEqual(len(texts), 1, '%s cuts its title off at 18: its hover label shows %s' % (key, texts))

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
        self.assert_hover_label_shows_only_the_place(row)

    def test_at_18_a_pane_row_with_its_summary_grows_by_half_and_shows_its_whole_title(self):
        self.addCleanup(self.write_config, '')
        row = 'pane-' + self.panes[1]
        self.s.show(self.windows['fs-panes'][0])
        small, _ = self.heights([row], 12, 'the open card does not show its Pane row at %s')
        large, rs = self.heights([row], 18, 'the open card does not show its Pane row at %s')
        # The row's title and its Summary are both in it: at 12 it is two lines of text tall.
        self.assert_text_grows_by_half(row, PANE_ROW_PADDING, small[row], large[row])
        self.assert_hover_label_shows_only_the_place(row)

    def test_at_18_a_closed_cards_summary_grows_by_half_and_shows_its_whole_text(self):
        self.addCleanup(self.write_config, '')
        opened, closed = 'topic-fs-size', 'topic-fs-other'
        self.s.show(self.windows['fs-size'][0])
        lines, widths = {}, {}
        for size in [12, 18]:
            measured, rs = self.heights([opened, closed], size, 'the cards do not show at %s')
            self.assertIn('expanded', self.s.row(opened, rs).get('accessibilityValue', ''), 'the card of the shown Window is closed')
            self.assertIn('collapsed', self.s.row(closed, rs).get('accessibilityValue', ''), 'the other card is open')
            # Both titles are on one line, so the closed header is the open one with the Summary line and its room.
            lines[size] = measured[closed] - measured[opened]
            widths[size] = width(self.s.row(closed, rs))
            # The card's hint is the Summary that the Format gives, whole.
            self.assertEqual(self.s.row(closed, rs).get('accessibilityHelp'), 'fs-other · 1 Window')
        self.assert_text_grows_by_half('the Summary line of ' + closed, SUMMARY_PADDING, lines[12], lines[18])
        # The Summary is one line, cut with "…" only when it is wider than its room: the card's width less padding that
        # does not grow and the corner, which grows by the factor. A card at least 1.5 times as wide gives the Summary,
        # 1.5 times as wide, at least the room it had at 12, where it shows whole.
        self.assertGreaterEqual(widths[18], 1.5 * widths[12] - ROUNDING,
                                'the closed card is %.0f points wide at 12 and %.0f at 18, too narrow for its Summary'
                                % (widths[12], widths[18]))

    def test_at_18_a_tag_chip_grows_by_half_and_shows_its_whole_tag(self):
        self.addCleanup(self.write_config, '')
        chip = 'tags-topic-fs-tags'
        frames = {}
        for size in [12, 18]:
            _, rs = self.heights([chip], size, 'the card does not show its Tag chip at %s')
            self.assertEqual(self.s.row(chip, rs).get('accessibilityValue'), 'work')
            frames[size] = (height(self.s.row(chip, rs)), width(self.s.row(chip, rs)))
        self.assert_text_grows_by_half(chip, CHIP_PADDING, frames[12][0], frames[18][0])
        # The chip does not cut its text, so the text in it is about 1.5 times as wide too.
        self.assert_text_grows_by_half(chip, CHIP_SIDES, frames[12][1], frames[18][1], side='wide')

    def test_at_18_the_bench_line_grows_by_half_and_shows_its_whole_title(self):
        self.addCleanup(self.write_config, '')
        small, rs = self.heights([LINE], 12, 'the Topics list has no Bench line at %s', IN_PLAY)
        title = self.s.row(LINE, rs).get('accessibilityLabel')
        large, rs = self.heights([LINE], 18, 'the Topics list has no Bench line at %s', IN_PLAY)
        # The line is as tall as its text needs, with no padding above or below it.
        self.assert_text_grows_by_half(LINE, 0, small[LINE], large[LINE])
        self.assertIn(title, ['Bench', 'Hide Bench'])
        self.assertEqual(self.s.row(LINE, rs).get('accessibilityLabel'), title, 'the Bench line changed its title at 18')

    def test_at_18_the_benched_cards_fit_the_bench_under_the_line_and_under_the_more_above_pill(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        # An Open Place that the check leaves would take an In Play place.
        self.addCleanup(self.store.set_open_places, [])
        self.set_size(18, IN_PLAY)
        # Dormant Topics make the Bench much longer than the Sidebar, and the last Benched card is a live Topic.
        for order in range(100, 118):
            topic = 'fs-bench-%d' % order
            self.addCleanup(self.store.remove, topic)
            self.store.put(dict(id=topic, title=topic, slug=topic, home_project=str(self.project), order=order))
        last, key = 'fs-bench-last', 'topic-fs-bench-last'
        self.addCleanup(self.store.remove, last)
        self.store.put(dict(id=last, title=last, slug=last, home_project=str(self.project), order=200))
        sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', last, '-c', str(self.project), SHELL)
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', sid)
        self.addCleanup(s.show, self.windows['fs-size'][0])
        s.tmux('set-option', '-t', sid, '@muxify_topic', last)
        window = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        s.wait_rows(lambda rs: s.has(LINE, rs), 'the Topics list has no Bench line')
        if s.row(LINE).get('accessibilityLabel') == 'Hide Bench':
            s.act('press', LINE)
        s.show(window)
        rs = s.wait_rows(lambda rs: self.after_line(rs) == [key] and s.row(LINE, rs).get('accessibilityLabel') == 'Bench',
                         lambda: 'the Benched card of the Location does not show alone under the hidden line: %s'
                         % self.after_line(s.rows()))
        before = self.top(key, rs)
        s.act('press', LINE)
        rs = s.wait_rows(lambda rs: s.row(LINE, rs).get('accessibilityLabel') == 'Hide Bench'
                         and abs(self.under_pill(key, rs)) <= ROUNDING,
                         lambda: 'the card of the Location is not directly under the "more above" pill: %s'
                         % self.under_pill(key, s.rows()))
        bench = self.after_line(rs)
        pill = height(s.row('topics-more-above', rs))
        self.assertAlmostEqual(pill, 1.5 * PILL, delta=ROUNDING, msg='the "more above" pill did not grow by half')
        # The card stays where it stood, moved down only by the pill's band, out from under the pill (ADR 0063).
        self.assertAlmostEqual(self.top(key, rs), before - pill, delta=ROUNDING,
                               msg='the card of the Location did not move down by the pill when the Bench showed')
        bottom, top = frame(s.row('topics-more-above', rs))
        self.assertEqual([card for card in bench if bottom < self.top(card, rs) < top], [],
                         'the pill covers the top of a Benched card')
        # At the top of the Bench, the highest Benched card stands directly under the line, and no card covers it.
        s.act('scroll', 'topics-list', from_end=100000)

        def highest_under_line(rs):
            """How far the top of the highest Benched card is from where a card directly under the line has its top. The
            dump has only the cards in view, so they are the cards under the line in this dump."""
            return max(self.top(card, rs) for card in self.after_line(rs)) - (frame(s.row(LINE, rs))[0] - SPACING)
        s.wait_rows(lambda rs: abs(highest_under_line(rs)) <= ROUNDING,
                    lambda: 'the highest Benched card is not directly under the Bench line at the top of the Bench: %s'
                    % highest_under_line(s.rows()))

    def top(self, key, rs):
        return frame(self.s.row(key, rs))[1]

    def after_line(self, rs):
        """The cards under the Bench line, in Sidebar order."""
        ids = self.s.ids(rs)
        if LINE not in ids:
            return None
        return [key for key in ids[ids.index(LINE) + 1:] if key.startswith('topic-') and not key.startswith('topic-window-')
                and '-session-' not in key and not key.endswith('-more') and not key.startswith('topic-agent-mark-')]

    def under_pill(self, key, rs):
        """How far the card's top is from where a card directly under the "more above" pill has its top, or infinity
        while no pill shows."""
        if not self.s.has('topics-more-above', rs) or not self.s.has(key, rs):
            return math.inf
        return self.top(key, rs) - (frame(self.s.row('topics-more-above', rs))[0] - SPACING)

    def test_at_18_the_header_and_its_session_name_grow_by_half_and_its_buttons_fit_in_it(self):
        self.addCleanup(self.write_config, '')
        window = self.windows['fs-size'][0]
        selector = 'header-window-' + window
        buttons = [selector] + HEADER_BUTTONS
        keys = [HEADER, 'header-session-name'] + buttons
        self.s.show(window)
        frames = {}
        for size in [12, 18]:
            _, rs = self.heights(keys, size, 'the header does not show the Session name, its Window and its buttons at %s')
            frames[size] = {key: bounds(self.s.row(key, rs)) for key in keys}
            self.assertEqual(self.s.row('header-session-name', rs).get('accessibilityValue'), 'fs-size')
            self.assertFalse(self.s.has('header-window-menu', rs),
                             'the Window list became a dropdown at %s, though its one Window fits inline' % size)
            self.assertEqual(self.s.row(selector, rs).get('accessibilityValue'), 'selected')
            app_window = self.app_window(rs)
            header_x, header_y, header_width, header_height = frames[size][HEADER]
            for key in ['header-session-name'] + buttons:
                x, y, w, h = frames[size][key]
                self.assertTrue(header_y - ROUNDING <= y and y + h <= header_y + header_height + ROUNDING,
                                '%s, %.0f points tall, does not fit in the %.0f-point header at %s'
                                % (key, h, header_height, size))
                self.assertTrue(app_window[0] - ROUNDING <= x and x + w <= app_window[0] + app_window[2] + ROUNDING,
                                '%s is pushed off the App Window at %s: it is at %.0f to %.0f, the App Window at %.0f '
                                'to %.0f' % (key, size, x, x + w, app_window[0], app_window[0] + app_window[2]))
        small, large = frames[12], frames[18]
        # ui.header_height is a length at 12: its default, 30, is 45 at 18.
        self.assertAlmostEqual(large[HEADER][3], 1.5 * small[HEADER][3], delta=ROUNDING,
                               msg='the header is %.0f points tall at 12 and %.0f at 18' % (small[HEADER][3], large[HEADER][3]))
        self.assert_text_grows_by_half('header-session-name', 0, small['header-session-name'][3],
                                       large['header-session-name'][3])
        for key in buttons:
            self.assert_text_grows_by_half(key, 0, small[key][3], large[key][3])
        # The Window's title is monospaced and never cut inline, so the whole title is 1.5 times as wide at 18.
        self.assert_text_grows_by_half(selector, HEADER_BUTTON_SIDES, small[selector][2], large[selector][2], side='wide')

    def test_at_24_beside_the_widest_sidebar_a_long_branch_gives_way_and_no_header_button_leaves_the_app_window(self):
        s = self.s
        repo = s.root/'projects/fs-branch'
        repo.mkdir(parents=True, exist_ok=True)
        branch = 'fs-branch/' + 'long-' * 30 + 'end'
        for args in [['init', '-q', '-b', branch], ['-c', 'user.name=Verify', '-c', 'user.email=verify@example.test',
                                                    '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'x']]:
            subprocess.run(['git', '-C', str(repo), *args], env=s.env, check=True, capture_output=True)
        sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', 'fs-branch', '-c', str(repo), SHELL)
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', sid)
        window = s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')
        self.addCleanup(self.write_config, '')
        # The Sidebar as wide as a drag can make it, through the width a drag stores. At 24 the header beside it has
        # less room than its controls take with the Git button at its maximum, so that maximum must give way.
        self.addCleanup(self.restart_app, LAUNCH_ARGS)
        self.restart_app(LAUNCH_ARGS + ['-sidebarWidth', '10000'])
        self.write_config('ui:\n  font_size: 24\n')
        s.show(window)
        # The Sidebar's widest bound, 420 at 12 (`SidebarWidth.designBounds`), at 24.
        widest = 420 * 2
        rs = s.wait_rows(lambda rs: s.row('toggle-git-view', rs).get('accessibilityLabel') == branch
                         and abs(width(s.row('sidebar-panel', rs)) - widest) < 1
                         and abs(height(s.row(HEADER, rs)) - 60) < 1,
                         'the header does not show the branch beside a %d-point Sidebar at ui.font_size: 24' % widest)
        rs = self.settled([HEADER, 'toggle-git-view'] + HEADER_BUTTONS, 'the header does not settle at 24')
        app_window = self.app_window(rs)
        for key in ['header-session-name'] + HEADER_BUTTONS:
            x, _, w, _ = bounds(s.row(key, rs))
            self.assertTrue(app_window[0] - ROUNDING <= x and x + w <= app_window[0] + app_window[2] + ROUNDING,
                            '%s is pushed off the App Window: it is at %.0f to %.0f, the App Window at %.0f to %.0f'
                            % (key, x, x + w, app_window[0], app_window[0] + app_window[2]))
        git = width(s.row('toggle-git-view', rs))
        self.assertLess(git, 2 * GIT_BUTTON_MAX - ROUNDING,
                        'the Git button keeps its whole maximum of %d points in a header without room for it, so the '
                        'check tests nothing: it is %.0f points wide' % (2 * GIT_BUTTON_MAX, git))

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

    def git_window(self, name, files):
        """The Window of a new Session in a new repository with one commit and the untracked `files`."""
        s = self.s
        repo = s.root/'projects'/name
        repo.mkdir(parents=True)
        for args in [['init', '-q', '-b', 'main'], ['-c', 'user.name=Verify', '-c', 'user.email=verify@example.test',
                                                    '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'x']]:
            subprocess.run(['git', '-C', str(repo), *args], env=s.env, check=True, capture_output=True)
        for file in files:
            (repo/file).write_text('one\n')
        sid = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', name, '-c', str(repo), SHELL)
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', sid)
        return s.tmux('display-message', '-p', '-t', sid + ':', '#{window_id}')

    def open_git_view(self, window):
        """Shows the Window and opens its Git View on Changes, through the View menu item. SwiftUI rebuilds the menu a
        moment after the state it reads changes, and a press in that moment can miss."""
        s = self.s
        s.show(window)
        self.addCleanup(s.show, self.windows['fs-size'][0])

        def opened():
            s.driver('press', 'Show Git View')
            return s.has('git-view')
        wait(opened, 'the Git View did not open', seconds=10, step=.3)
        self.addCleanup(self.close_git_view)
        rs = s.wait_rows(lambda rs: s.has('git-toolbar', rs), 'the Git View did not read the repository')
        if s.row('git-tab-changes', rs).get('accessibilityValue') != 'selected':
            s.act('action', 'git-view', '1')

    def close_git_view(self):
        # A popup takes the Git View's keys, q among them, so ⎋ closes it first.
        if any(self.s.has(popup) for popup in ['git-commit-box', 'git-menu', 'git-prompt']):
            self.s.act('action', 'git-view', 'escape')
        if self.s.has('git-view'):
            self.s.act('action', 'git-view', 'q')
            wait(lambda: not self.s.has('git-view'), 'the Git View did not close', seconds=10)

    def set_git_view_size(self, size, git_view_width=GIT_VIEW_WIDTH):
        """`ui.font_size`, with the Git View `git_view_width` points wide. The toolbar spans the Git View, whose own frame
        in the dump also takes in what its bars cut off."""
        app_window = self.app_window()
        self.assertGreaterEqual(app_window[2], git_view_width, 'the App Window is too narrow for the Git View checks')
        self.set_size(size, extra='git_view:\n  width: %.4f%%\n' % (100 * git_view_width / app_window[2]))
        self.s.wait_rows(lambda rs: abs(width(self.s.row('git-toolbar', rs)) - git_view_width) < 1,
                         lambda: 'the Git View is %.0f points wide, not %d, at ui.font_size: %s'
                         % (width(self.s.row('git-toolbar')), git_view_width, size))

    def app_window(self, rs=None):
        """(x, y, width, height) of the App Window."""
        return bounds(next(row for row in rs or self.s.rows() if row.get('accessibilityRole') == 'AXWindow'))

    def selected(self, key, rs=None):
        return 'selected=1' in self.s.row(key, rs).get('accessibilityValue', '')

    def test_at_18_a_git_view_list_row_and_the_tab_bar_grow_by_half_and_a_long_file_name_keeps_its_room(self):
        self.addCleanup(self.write_config, '')
        row = GIT_ROW + LONG_NAME
        keys = [row, 'git-tab-changes', 'git-list-pane', 'git-list-changes', 'git-toolbar']
        self.open_git_view(self.git_window('fs-git-row', [LONG_NAME]))
        frames, tab_bars = {}, {}
        for size in [12, 18]:
            self.set_git_view_size(size)
            rs = self.settled(keys, 'the Git View does not show its Changes and its tabs at %s' % size)
            frames[size] = {key: bounds(self.s.row(key, rs)) for key in keys}
            # The tab bar is the List pane's bottom, from the bottom of the list's scroll view to the Git View's bottom.
            tab_bars[size] = frame(self.s.row('git-list-changes', rs))[0] - frame(self.s.row('git-view', rs))[0]
            self.assertEqual(self.s.row(row, rs).get('accessibilityLabel'), LONG_NAME)
            self.assertEqual(self.s.row('git-tab-changes', rs).get('accessibilityValue'), 'selected')
            # The List pane is in the left half of the Git View, which nothing in it pushes wider than it is.
            git_x, _, git_width, _ = frames[size]['git-toolbar']
            pane_x, _, pane_width, _ = frames[size]['git-list-pane']
            self.assertAlmostEqual(git_width, GIT_VIEW_WIDTH, delta=ROUNDING, msg='the Git View is not as wide as set')
            self.assertTrue(git_x - ROUNDING <= pane_x and pane_x + pane_width <= git_x + git_width / 2 + ROUNDING,
                            'the List pane, at %.0f to %.0f, is not in the left half of the Git View, at %.0f to %.0f, at %s'
                            % (pane_x, pane_x + pane_width, git_x, git_x + git_width, size))
        small, large = frames[12], frames[18]
        # A row holds its text in 24 points at 12, with nothing above or below it, and a tab in its 24 points.
        self.assert_text_grows_by_half(row, 0, small[row][3], large[row][3])
        self.assert_text_grows_by_half('git-tab-changes', 0, small['git-tab-changes'][3], large['git-tab-changes'][3])
        self.assert_text_grows_by_half('the tab bar', TAB_BAR_PADDING, tab_bars[12], tab_bars[18])
        # The List pane grows from its least width at 12 to its least width at 18. A row's padding and spacing do not
        # grow, so a row 1.5 times as wide gives the name, 1.5 times as wide, at least the room it fits in at 12.
        self.assertAlmostEqual(large['git-list-pane'][2], 1.5 * small['git-list-pane'][2], delta=ROUNDING,
                               msg='the List pane is %.0f points wide at 12 and %.0f at 18'
                               % (small['git-list-pane'][2], large['git-list-pane'][2]))
        self.assertGreaterEqual(large[row][2], 1.5 * small[row][2] - ROUNDING,
                                'the row of %s is %.0f points wide at 12 and %.0f at 18, too narrow for its name'
                                % (LONG_NAME, small[row][2], large[row][2]))

    def test_at_12_and_18_the_git_view_keys_scrolling_and_a_click_select_the_row_drawn_there(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        names = ['fs-nav-%02d.txt' % n for n in range(40)]
        rows = [GIT_ROW + name for name in names]
        self.open_git_view(self.git_window('fs-git-nav', names))
        for size in [12, 18]:
            self.set_git_view_size(size)
            row_height = 24 * size / 12
            self.settled([rows[0], 'git-list-changes'], 'the Git View does not show its Changes at %s' % size)

            def in_view(key, rs):
                """The row is drawn whole in the list's scroll view, and as tall as a row at this size."""
                if not s.has(key, rs):
                    return False
                bottom, top = frame(s.row(key, rs))
                list_bottom, list_top = frame(s.row('git-list-changes', rs))
                return (list_bottom - ROUNDING <= bottom and top <= list_top + ROUNDING
                        and abs(top - bottom - row_height) <= ROUNDING)

            # j from the top moves down, to the row drawn directly under the one before.
            s.act('action', 'git-view', 'shift+comma')
            s.act('action', 'git-view', 'j')
            s.act('action', 'git-view', 'j')
            rs = s.wait_rows(lambda rs: self.selected(rows[1], rs) and in_view(rows[1], rs),
                             lambda: 'j from the top does not select %s in view at %s' % (rows[1], size))
            self.assertAlmostEqual(frame(s.row(rows[0], rs))[0], frame(s.row(rows[1], rs))[1], delta=ROUNDING,
                                   msg='the rows are not drawn one under the other at %s' % size)
            # > selects the last row, far below the list's bottom, and scrolls it into view.
            s.act('action', 'git-view', 'shift+period')
            rs = s.wait_rows(lambda rs: self.selected(rows[-1], rs) and in_view(rows[-1], rs),
                             lambda: '> does not scroll the last row into view at %s' % size)
            # A click in the middle of a row drawn there selects that row, once the list has stopped scrolling. A row takes
            # the first click (`takesFirstClick` on the rows of `GitListView`), so the click reaches it in the background.
            target = rows[-4]
            frames = []

            def still(rs):
                frames.append(s.row(target, rs).get('accessibilityFrame'))
                return frames[-2:] == [frames[-1]] * 2 and in_view(target, rs)
            s.wait_rows(still, '%s is not in view, standing still, above the last row at %s' % (target, size))
            s.act('click', target)
            s.wait_rows(lambda rs: self.selected(target, rs) and not self.selected(rows[-1], rs),
                        lambda: 'a click on %s does not select it at %s' % (target, size))

    def staged_git_window(self, name):
        """The Window of a new Session in a new repository, with STAGED_NAME staged, and the repository."""
        window = self.git_window(name, [STAGED_NAME])
        repo = self.s.root/'projects'/name
        for args in [['config', 'user.name', 'Verify'], ['config', 'user.email', 'verify@example.test'],
                     ['config', 'commit.gpgsign', 'false'], ['add', STAGED_NAME]]:
            self.run_git(repo, *args)
        return window, repo

    def run_git(self, repo, *args):
        return subprocess.run(['git', '-C', str(repo), *args], env=self.s.env, check=True, capture_output=True,
                              text=True).stdout

    def assert_in_app_window(self, key, rs, size):
        """The element is drawn whole inside the App Window and inside the Git View, whose toolbar spans it."""
        x, y, w, h = bounds(self.s.row(key, rs))
        app_x, app_y, app_w, app_h = self.app_window(rs)
        git_x, _, git_w, _ = bounds(self.s.row('git-toolbar', rs))
        self.assertTrue(app_x - ROUNDING <= x and x + w <= app_x + app_w + ROUNDING
                        and app_y - ROUNDING <= y and y + h <= app_y + app_h + ROUNDING,
                        '%s, at %s, leaves the App Window, at %s, at %s' % (key, (x, y, w, h), (app_x, app_y, app_w, app_h), size))
        self.assertTrue(git_x - ROUNDING <= x and x + w <= git_x + git_w + ROUNDING,
                        '%s, %.0f to %.0f, leaves the Git View, %.0f to %.0f, at %s' % (key, x, x + w, git_x, git_x + git_w, size))

    def responder(self):
        return self.s.driver('responder')

    def assert_field_has_the_keys(self, name, size):
        """A field has the keys: its field editor is the first responder. And the field shows all of the editor, which
        it would cut its text off from."""
        editors = wait(lambda: self.responder()['editors'],
                       lambda: '%s does not have the keys at %s: %s' % (name, size, self.responder()))
        self.assertEqual(len(editors), 1, editors)
        editor, visible = (re.findall(r'-?[\d.]+', editors[0][key]) for key in ('frame', 'visible'))
        self.assertGreaterEqual(float(visible[3]), float(editor[3]) - ROUNDING,
                                'the field of %s cuts its text off at %s: %s' % (name, size, editors))

    def open_stash_prompt(self, size):
        """s in Changes asks for the stash's message, in a prompt whose field has the keys."""
        s = self.s
        s.act('action', 'git-view', 's')
        s.wait_rows(lambda rs: s.has('git-prompt', rs) and s.row('git-prompt', rs).get('accessibilityLabel') == 'Stash changes',
                    's did not open the Stash changes prompt at %s' % size)
        self.assert_field_has_the_keys('the prompt field', size)

    def test_at_18_the_commit_box_and_a_git_view_menus_choice_row_grow_by_half_show_their_text_whole_and_fit_the_app_window(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        window, _ = self.staged_git_window('fs-git-popups')
        self.open_git_view(window)
        boxes, menus = {}, {}
        for size in [12, 18]:
            self.set_git_view_size(size, POPUP_GIT_VIEW_WIDTH)
            s.wait_rows(lambda rs: s.has(GIT_ROW + STAGED_NAME, rs), 'Changes do not list %s at %s' % (STAGED_NAME, size))
            s.act('action', 'git-view', 'c')
            rs = self.settled(['git-commit-box', *COMMIT_PARTS], 'the commit box does not show its parts at %s' % size)
            boxes[size] = {key: bounds(s.row(key, rs)) for key in ['git-commit-box', *COMMIT_PARTS]}
            self.assert_in_app_window('git-commit-box', rs, size)
            # The summary has the keys, and shows its text whole.
            self.assert_field_has_the_keys('the summary', size)
            s.act('action', 'git-view', 'escape')
            s.wait_rows(lambda rs: not s.has('git-commit-box', rs), 'escape did not close the commit box at %s' % size)
            # d on the root row, where < puts the selection, asks in the Discard menu.
            s.act('action', 'git-view', 'shift+comma')
            s.act('action', 'git-view', 'd')
            rs = self.settled(['git-menu', MENU_CHOICE], 'the Discard menu does not show its choices at %s' % size)
            menus[size] = {key: bounds(s.row(key, rs)) for key in ['git-menu', MENU_CHOICE]}
            self.assert_in_app_window('git-menu', rs, size)
            s.act('action', 'git-menu', 'escape')
            s.wait_rows(lambda rs: not s.has('git-menu', rs), 'escape did not close the Discard menu at %s' % size)
        for key, padding in COMMIT_PARTS.items():
            self.assert_text_grows_by_half(key, padding, boxes[12][key][3], boxes[18][key][3])
        self.assert_text_grows_by_half(MENU_CHOICE, 0, menus[12][MENU_CHOICE][3], menus[18][MENU_CHOICE][3])
        # Each popup is 1.5 times as wide, in a Git View with room for it. Its text is 1.5 times as wide, and its padding
        # does not grow, so a row 1.5 times as wide as at 12 gives its text at least the room it shows whole in at 12:
        # the menu's choice, and the commit box's rows, which span it less its padding.
        for frames, popup in [(boxes, 'git-commit-box'), (menus, 'git-menu')]:
            self.assert_text_grows_by_half(popup, 0, frames[12][popup][2], frames[18][popup][2], side='wide')
        self.assertGreaterEqual(menus[18][MENU_CHOICE][2], 1.5 * menus[12][MENU_CHOICE][2] - ROUNDING,
                                '%s is %.0f points wide at 12 and %.0f at 18, too narrow for its text'
                                % (MENU_CHOICE, menus[12][MENU_CHOICE][2], menus[18][MENU_CHOICE][2]))

    def test_at_12_and_18_a_git_view_menu_and_prompt_keep_the_keys_in_the_git_view_and_enter_and_escape_work(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        window, repo = self.staged_git_window('fs-git-keys')
        self.open_git_view(window)
        row = GIT_ROW + STAGED_NAME

        def git_view_has_the_keys(after):
            wait(lambda: KEY_VIEW in self.responder()['responders'],
                 lambda: 'the Git View does not have the keys %s at %s: %s' % (after, size, self.responder()['responders']))

        for size in [12, 18]:
            self.set_git_view_size(size, POPUP_GIT_VIEW_WIDTH)
            s.wait_rows(lambda rs: s.has(row, rs), 'Changes do not list %s at %s' % (STAGED_NAME, size))
            git_view_has_the_keys('once it shows')
            # A Git View menu leaves the keys with the Git View, which gives them to the menu. ⎋ closes it.
            s.act('action', 'git-view', 'd')
            s.wait_rows(lambda rs: s.has('git-menu', rs), 'd did not open the Discard menu at %s' % size)
            self.assertIn(KEY_VIEW, self.responder()['responders'], 'the Discard menu took the keys from the Git View at %s' % size)
            s.act('action', 'git-menu', 'escape')
            s.wait_rows(lambda rs: not s.has('git-menu', rs), 'escape did not close the Discard menu at %s' % size)
            self.assertIn('A  ' + STAGED_NAME, self.run_git(repo, 'status', '--porcelain'), 'escape discarded at %s' % size)
            # A Git View prompt's field has the keys, and shows its text whole. ↩ submits what it holds, and gives the
            # keys back to the Git View. ↩ comes before ⎋: a prompt opened again while the last one still fades out, in
            # its first 0.15 seconds, leaves the keys with the Git View, at every size.
            message = 'fs-stash-%s' % size
            self.open_stash_prompt(size)
            s.act('set', 'git-prompt-field', message)
            s.wait_rows(lambda rs: s.row('git-prompt-field', rs).get('accessibilityValue') == message,
                        lambda: 'the prompt field does not hold %r at %s: %r'
                        % (message, size, s.row('git-prompt-field').get('accessibilityValue')))
            s.act('action', 'git-prompt', 'enter')
            s.wait_rows(lambda rs: not s.has('git-prompt', rs), 'enter did not close the prompt at %s' % size)
            git_view_has_the_keys('after enter')
            wait(lambda: message in self.run_git(repo, 'stash', 'list'), 'enter did not stash with the message at %s' % size)
            s.wait_rows(lambda rs: not s.has(row, rs), 'Changes still list the stashed %s at %s' % (STAGED_NAME, size))
            self.run_git(repo, 'stash', 'pop', '--index')
            s.act('action', 'git-view', 'shift+r')
            s.wait_rows(lambda rs: s.has(row, rs), 'Changes do not list %s again at %s' % (STAGED_NAME, size))
            # ⎋ closes the prompt, stashes nothing, and gives the keys back to the Git View.
            self.open_stash_prompt(size)
            s.act('action', 'git-prompt', 'escape')
            s.wait_rows(lambda rs: not s.has('git-prompt', rs), 'escape did not close the prompt at %s' % size)
            git_view_has_the_keys('after escape')
            self.assertEqual(self.run_git(repo, 'stash', 'list'), '', 'escape stashed at %s' % size)

    def long_file_git_window(self, name):
        """The Window of a new Session in a new repository whose LONG_FILE has CHANGED_LINE changed."""
        window = self.git_window(name, [])
        repo = self.s.root/'projects'/name
        lines = ['line %d' % number for number in range(1, LONG_FILE_LINES + 1)]
        (repo/LONG_FILE).write_text('\n'.join(lines) + '\n')
        self.run_git(repo, 'add', LONG_FILE)
        self.run_git(repo, '-c', 'user.name=Verify', '-c', 'user.email=verify@example.test', '-c', 'commit.gpgsign=false',
                     'commit', '-q', '-m', 'long file')
        lines[CHANGED_LINE - 1] = 'changed line %d' % CHANGED_LINE
        (repo/LONG_FILE).write_text('\n'.join(lines) + '\n')
        return window

    def diff_line(self, number, rs):
        """The identifier of the context line with this number on both sides, without its `git-line-`."""
        value = 'kind=context old=%d new=%d' % (number, number)
        row = next((row for row in rs if row.get('accessibilityIdentifier', '').startswith('git-line-')
                    and row.get('accessibilityValue') == value), None)
        return row and row['accessibilityIdentifier'][len('git-line-'):]

    def test_the_git_view_line_number_gutter_follows_the_terminal_font_size_and_shows_a_5_digit_number_whole(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        # The Terminal's `font-size` from a Ghostty config file that the Config names. libghostty reads it after its
        # default files, so it decides.
        ghostty = s.root/'config/fs-ghostty.conf'
        ghostty.write_text('font-size = %d\n' % TERMINAL_SIZES[0])
        names_ghostty = 'ghostty:\n  config_file: %s\n' % ghostty
        self.write_config('ui:\n  font_size: 12\n' + names_ghostty)
        self.open_git_view(self.long_file_git_window('fs-git-gutter'))
        # The change's row, under the root row of Changes that < selects. ↩ gives its diff the keys.
        s.wait_rows(lambda rs: s.has(GIT_ROW + LONG_FILE, rs), 'Changes do not list %s' % LONG_FILE)
        s.act('action', 'git-view', 'shift+comma')
        s.act('action', 'git-view', 'j')
        s.wait_rows(lambda rs: self.selected(GIT_ROW + LONG_FILE, rs), 'j does not select %s' % LONG_FILE)
        s.act('action', 'git-view', 'enter')

        def drawn(terminal_size):
            """The rows once the diff is drawn at the Terminal's size: the code's lines are that size's height. The Git
            View takes a new `font-size` when it next draws the diff, as a move of the keys to the list and back does."""
            def at_size():
                s.act('action', 'git-view', 'h')
                s.act('action', 'git-view', 'l')
                rs = s.rows()
                line = self.diff_line(9999, rs)
                return rs if line and height(s.row('git-line-' + line, rs)) == code_line_height(terminal_size) else None
            return wait(at_size, lambda: 'the diff is not drawn with lines %d points high at the Terminal\'s font-size '
                        '%d' % (code_line_height(terminal_size), terminal_size), step=.5)

        def measure(rs, terminal_size):
            """The gutter of the line 10000 and the widths of the numbers 9999 and 10000 in it, on its new side."""
            four, five = self.diff_line(9999, rs), self.diff_line(10000, rs)
            gutter = bounds(s.row('git-gutter-' + five, rs))
            numbers = {}
            for line, text in [(four, '9999'), (five, '10000')]:
                number = s.row('git-number-%s-new' % line, rs)
                self.assertEqual(number.get('accessibilityValue'), text, 'the line %s has another number: %s' % (text, number))
                numbers[text] = bounds(number)
            x, _, w, _ = numbers['10000']
            self.assertTrue(gutter[0] - ROUNDING <= x and x + w <= gutter[0] + gutter[2] + ROUNDING,
                            'the number 10000, %.0f to %.0f, leaves its gutter, %.0f to %.0f, at the Terminal\'s '
                            'font-size %d' % (x, x + w, gutter[0], gutter[0] + gutter[2], terminal_size))
            # Digits are monospaced, so a whole 5-digit number is 5/4 as wide as a whole 4-digit one. A number cut to
            # fit its column is as wide as the column's room, so the two would be the same width.
            self.assertAlmostEqual(numbers['10000'][2], 1.25 * numbers['9999'][2], delta=ROUNDING,
                                   msg='the number 10000 is %.1f points wide and 9999 %.1f at the Terminal\'s font-size '
                                   '%d: 10000 is cut off' % (numbers['10000'][2], numbers['9999'][2], terminal_size))
            return gutter[2], numbers['10000'][2]

        widths = {}
        for terminal_size in TERMINAL_SIZES:
            ghostty.write_text('font-size = %d\n' % terminal_size)
            widths[terminal_size] = measure(drawn(terminal_size), terminal_size)
        (small_gutter, small_number), (large_gutter, large_number) = (widths[size] for size in TERMINAL_SIZES)
        self.assertGreater(large_gutter, small_gutter + ROUNDING,
                           'the line-number gutter is %.0f points wide at the Terminal\'s font-size %d and %.0f at %d'
                           % (small_gutter, TERMINAL_SIZES[0], large_gutter, TERMINAL_SIZES[1]))
        # The numbers are a point smaller than the code, which is a point smaller than the Terminal.
        small_font, large_font = (size - 2 for size in TERMINAL_SIZES)
        self.assertAlmostEqual(large_number, small_number * large_font / small_font, delta=ROUNDING * 2,
                               msg='the number 10000 is %.1f points wide at the Terminal\'s font-size %d and %.1f at %d'
                               % (small_number, TERMINAL_SIZES[0], large_number, TERMINAL_SIZES[1]))
        # `ui.font_size` does not size the code or its gutter.
        self.set_size(18, extra=names_ghostty)
        rs = drawn(TERMINAL_SIZES[-1])
        self.assertEqual(measure(rs, TERMINAL_SIZES[-1]), (large_gutter, large_number),
                         'ui.font_size: 18 changed the line-number gutter or its numbers')

    def open_palette(self, name):
        """Presses the View menu item until the palette shows. SwiftUI rebuilds the menu a moment after the state it
        reads changes, and a press in that moment can miss."""
        s = self.s

        def opened():
            s.driver('press', name)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if s.has(PALETTE_SEARCH):
                    return True
            return False
        wait(opened, '%s did not open' % name, seconds=20)
        self.addCleanup(self.close_palette)

    def close_palette(self):
        # A palette that the last action closed can still be in the dump, and gone at the Close.
        if self.s.has(PALETTE_SEARCH):
            self.s.driver('action', PALETTE_SEARCH, 'Close')
        self.s.wait_rows(lambda rs: not self.s.has(PALETTE_SEARCH, rs), 'the palette did not close')

    def run_command(self, title):
        """Opens Commands and presses the row of the Command `title`, as ↩ on it does."""
        s = self.s
        self.open_palette('Commands')
        s.act('focus', PALETTE_SEARCH)
        s.act('set', PALETTE_SEARCH, title)
        key = 'palette-row-command-' + title
        s.wait_rows(lambda rs: s.has(key, rs), 'Commands does not list %s' % title)
        s.act('press', key)

    def assert_palette_in_app_window(self, rs, size):
        """The palette is as wide as at 12 times the factor, but never wider than the App Window less its margins, and
        it is drawn whole inside the App Window."""
        x, y, w, h = bounds(self.s.row(PALETTE, rs))
        app_x, app_y, app_w, app_h = self.app_window(rs)
        self.assertAlmostEqual(w, min(PALETTE_WIDTH * size / 12, app_w - PALETTE_MARGIN), delta=ROUNDING,
                               msg='the palette is %.0f points wide in an App Window %.0f wide at %s' % (w, app_w, size))
        self.assertTrue(app_x - ROUNDING <= x and x + w <= app_x + app_w + ROUNDING
                        and app_y - ROUNDING <= y and y + h <= app_y + app_h + ROUNDING,
                        'the palette, at %s, leaves the App Window, at %s, at %s'
                        % ((x, y, w, h), (app_x, app_y, app_w, app_h), size))

    def test_at_18_a_palette_row_and_the_search_field_grow_by_half_the_title_keeps_its_room_and_the_palette_fits_the_app_window(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        row = 'palette-row-topic-fs-size'
        keys = [PALETTE, PALETTE_SEARCH, row]
        app_width = self.app_window()[2]
        # With room for the palette at 18, every width in it grows by the factor, and so does the room for the title.
        self.assertGreaterEqual(app_width, PALETTE_WIDTH * 1.5 + PALETTE_MARGIN, 'the App Window is too narrow for the check')
        frames = {}
        for size in [12, 18]:
            self.set_size(size)
            self.open_palette('Go to…')
            rs = self.settled(keys, 'Go to… does not show the row of fs-size at %s' % size)
            frames[size] = {key: bounds(s.row(key, rs)) for key in keys}
            self.assertTrue(s.row(row, rs).get('accessibilityLabel', '').startswith('fs-size'),
                            'the row of fs-size is labeled %r at %s' % (s.row(row, rs).get('accessibilityLabel'), size))
            self.assert_palette_in_app_window(rs, size)
            # The search field shows its text whole in its row.
            s.act('focus', PALETTE_SEARCH)
            self.assert_field_has_the_keys('the search field', size)
            self.close_palette()
        small, large = frames[12], frames[18]
        self.assert_text_grows_by_half(row, 0, small[row][3], large[row][3])
        self.assert_text_grows_by_half(PALETTE_SEARCH, 0, small[PALETTE_SEARCH][3], large[PALETTE_SEARCH][3])
        self.assert_text_grows_by_half(PALETTE, 0, small[PALETTE][2], large[PALETTE][2], side='wide')
        # A row's padding and spacing do not grow, so a row 1.5 times as wide gives its title, 1.5 times as wide, at
        # least the room it shows whole in at 12; and the row's height grows with the title's.
        self.assertGreaterEqual(large[row][2], 1.5 * small[row][2] - ROUNDING,
                                'the row of fs-size is %.0f points wide at 12 and %.0f at 18, too narrow for its title'
                                % (small[row][2], large[row][2]))

    def test_at_12_and_18_the_palettes_keys_scrolling_and_a_click_choose_the_row_drawn_there(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        for order, topic_id in enumerate(PICK_TOPICS):
            self.store.put(dict(id=topic_id, title=topic_id, slug=topic_id, home_project=str(self.project), order=100 + order))
            self.addCleanup(self.store.remove, topic_id)
        rows = lambda rs: [key for key in s.ids(rs) if key.startswith('palette-row-topic-')]
        value = lambda key, rs: s.row(key, rs).get('accessibilityValue', '')
        highlighted = lambda rs: next((key for key in rows(rs) if 'selected' in value(key, rs)), None)
        for size in [12, 18]:
            self.set_size(size, topics=IN_PLAY)
            row_height = PALETTE_ROW * size / 12

            def in_view(key, rs):
                """The row is drawn whole in the list's scroll view, and as tall as a row at this size."""
                if not s.has(key, rs):
                    return False
                bottom, top = frame(s.row(key, rs))
                list_bottom, list_top = frame(s.row(PALETTE_LIST, rs))
                return (list_bottom - ROUNDING <= bottom and top <= list_top + ROUNDING
                        and abs(top - bottom - row_height) <= ROUNDING)

            self.run_command('Choose In Play…')
            rs = s.wait_rows(lambda rs: s.has(PALETTE_LIST, rs) and highlighted(rs) and in_view(highlighted(rs), rs),
                             'Choose In Play does not show its highlighted row at %s' % size)
            # 6.5 rows of the size, and one header, show before the list scrolls.
            list_bottom, list_top = frame(s.row(PALETTE_LIST, rs))
            self.assertAlmostEqual(list_top - list_bottom, PALETTE_VISIBLE_ROWS * row_height, delta=ROUNDING,
                                   msg='the list of %d rows is %.0f points tall at %s'
                                   % (len(PICK_TOPICS) + 5, list_top - list_bottom, size))
            # ↓ moves the highlight to the row drawn directly under it, and on past the rows shown at first, scrolling
            # each one into view.
            moved = [highlighted(rs)]
            for step in range(len(PICK_TOPICS) - 1):
                s.act('action', PALETTE_SEARCH, 'Select Next Row')
                rs = s.wait_rows(lambda rs: highlighted(rs) not in [None, moved[-1]] and in_view(highlighted(rs), rs),
                                 lambda: '↓ does not highlight the next row in view after %s at %s' % (moved[-1], size))
                moved.append(highlighted(rs))
                if step == 0:
                    self.assertAlmostEqual(frame(s.row(moved[0], rs))[0], frame(s.row(moved[1], rs))[1], delta=ROUNDING,
                                           msg='%s is not drawn directly under %s at %s' % (moved[1], moved[0], size))
            self.assertFalse(in_view(moved[0], rs), 'the list did not scroll from its first rows at %s' % size)
            # Space checks the highlighted row, the one drawn there.
            self.assertNotIn('checked', value(moved[-1], rs), '%s starts checked at %s' % (moved[-1], size))
            s.act('action', PALETTE_SEARCH, 'Space')
            s.wait_rows(lambda rs: 'checked' in value(moved[-1], rs),
                        lambda: 'Space does not check the highlighted %s at %s' % (moved[-1], size))
            # A click in the middle of a row drawn there, once the list stands still, checks that row and highlights
            # it. A row takes the first click, so the click reaches it in the background.
            target = moved[-3]
            frames = []

            def still(rs):
                frames.append(s.row(target, rs).get('accessibilityFrame'))
                return frames[-2:] == [frames[-1]] * 2 and in_view(target, rs)
            rs = s.wait_rows(still, '%s is not in view, standing still, at %s' % (target, size))
            self.assertNotIn('checked', value(target, rs), '%s starts checked at %s' % (target, size))
            s.act('click', target)
            s.wait_rows(lambda rs: 'checked' in value(target, rs) and highlighted(rs) == target,
                        lambda: 'a click on %s does not check and highlight it at %s: %s' % (target, size, value(target, s.rows())))
            self.close_palette()

    def text(self, key, rs):
        row = self.s.row(key, rs)
        return row.get('accessibilityValue') or row.get('accessibilityLabel')

    def mark_read_pill(self, size):
        """Mark Read, on the shown Window with nothing Unread, shows its explanation Pill. A press while the app is
        busy does nothing, so it presses until the Pill shows. The Pill lives 3.5 seconds and springs in, so it is
        measured once its frame stands still."""
        s = self.s
        s.wait_rows(lambda rs: not s.has('pill', rs), 'the last Pill did not go at %s' % size, seconds=10)

        def shown():
            s.driver('press', 'Mark Read')
            return s.row('pill').get('accessibilityValue') == PILL_VALUE
        wait(shown, lambda: 'Mark Read showed no explanation Pill at %s: %r' % (size, s.row('pill')), seconds=10)
        frames = []

        def still(rs):
            frames.append(s.row('pill', rs).get('accessibilityFrame'))
            return frames[-1] and frames[-2:] == [frames[-1]] * 2
        return s.wait_rows(still, 'the Pill did not stand still at %s' % size, seconds=3)

    def test_at_18_a_pill_grows_by_half_shows_its_whole_text_and_fits_the_app_window(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        s.show(self.windows['fs-size'][0])
        frames = {}
        for size in [12, 18]:
            self.set_size(size)
            rs = self.mark_read_pill(size)
            frames[size] = bounds(s.row('pill', rs))
            self.assertEqual(s.row('pill', rs).get('accessibilityLabel'), PILL_TITLE)
            x, _, w, _ = frames[size]
            app_x, _, app_w, _ = self.app_window(rs)
            # The Pill takes the palette's width at most, so in an App Window with room it is narrower than that.
            self.assertTrue(app_x - ROUNDING <= x and x + w <= app_x + app_w + ROUNDING,
                            'the Pill, %.0f to %.0f, leaves the App Window, %.0f to %.0f, at %s'
                            % (x, x + w, app_x, app_x + app_w, size))
            # It is as wide as its texts, up to the palette's width, so while it is narrower than that it shows its
            # whole value, which it cuts in the middle only for want of room.
            self.assertLess(w, min(PALETTE_WIDTH * size / 12, app_w - PALETTE_MARGIN) - ROUNDING,
                            'the Pill is as wide as it may be at %s, so it may cut its value off' % size)
        small, large = frames[12], frames[18]
        self.assertAlmostEqual(small[3], PILL_HEIGHT, delta=ROUNDING, msg='the Pill is not %d points high at 12' % PILL_HEIGHT)
        self.assert_text_grows_by_half('pill', 0, small[3], large[3])
        self.assertGreater(large[2] - PILL_SIDES, 1.3 * (small[2] - PILL_SIDES),
                           'the Pill is %.0f points wide at 12 and %.0f at 18: its texts did not grow' % (small[2], large[2]))

    def test_at_18_the_config_problems_banner_grows_by_half_and_shows_its_whole_title(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        keys = ['config-problems', 'config-problems-title', 'config-problems-close']
        frames = {}
        for size in [12, 18]:
            # A removed key is a problem, which the banner shows.
            self.set_size(size, extra='  sidebar:\n    font_size: 14\n')
            rs = self.settled(keys, 'the Config problems banner does not show at %s' % size)
            self.assertTrue(any(REMOVED_KEY in row.get('accessibilityLabel', '') + row.get('accessibilityValue', '')
                                for row in rs), 'the banner does not show "%s" at %s' % (REMOVED_KEY, size))
            frames[size] = {key: bounds(s.row(key, rs)) for key in keys}
            x, _, w, _ = frames[size]['config-problems']
            app_x, _, app_w, _ = self.app_window(rs)
            self.assertAlmostEqual(w, min(BANNER_WIDTH * size / 12, app_w - BANNER_MARGIN), delta=ROUNDING,
                                   msg='the banner is %.0f points wide in an App Window %.0f wide at %s' % (w, app_w, size))
            self.assertTrue(app_x - ROUNDING <= x and x + w <= app_x + app_w + ROUNDING,
                            'the banner leaves the App Window at %s' % size)
        small, large = frames[12], frames[18]
        self.assertGreaterEqual(self.app_window()[2], BANNER_WIDTH * 1.5 + BANNER_MARGIN, 'the App Window is too narrow for the check')
        self.assert_text_grows_by_half('config-problems', 0, small['config-problems'][2], large['config-problems'][2], side='wide')
        # The title grows on one line, and it ends before the room of the banner's texts ends, 8 points before the close
        # button, so it shows whole: a title without room wraps there.
        self.assert_text_grows_by_half('config-problems-title', 0, small['config-problems-title'][3],
                                       large['config-problems-title'][3])
        for size, frame_of in frames.items():
            title_x, _, title_w, _ = frame_of['config-problems-title']
            self.assertLess(title_x + title_w, frame_of['config-problems-close'][0] - 8 - ROUNDING,
                            'the banner has no room beside its title at %s, so it wraps or cuts it' % size)
        for side in [2, 3]:
            self.assertAlmostEqual(small['config-problems-close'][side], BANNER_CLOSE, delta=ROUNDING)
            self.assertAlmostEqual(large['config-problems-close'][side], 1.5 * BANNER_CLOSE, delta=ROUNDING,
                                   msg='the close button did not grow by half: %s' % (large['config-problems-close'],))

    def test_at_18_find_in_panes_bar_grows_by_half_shows_its_whole_status_and_fits_over_the_terminal(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        s.show(self.windows['fs-size'][0])
        keys = ['terminal-find-bar', 'terminal-find-field', 'terminal-find-status']
        frames = {}
        for size in [12, 18]:
            self.set_size(size)
            s.act('action', 'terminal-panel', 'Find in Pane')
            s.wait_rows(lambda rs: s.has('terminal-find-field', rs), 'Find in Pane did not show its bar at %s' % size)
            self.addCleanup(lambda: s.has('terminal-find-done') and s.act('press', 'terminal-find-done'))
            s.act('focus', 'terminal-find-field')
            s.act('set', 'terminal-find-field', 'fs-no-such-text')
            s.wait_rows(lambda rs: s.row('terminal-find-status', rs).get('accessibilityValue', s.row('terminal-find-status', rs)
                                                                          .get('accessibilityLabel')) == 'Not found',
                        'Find in Pane does not say Not found at %s' % size)
            rs = self.settled(keys, 'the find bar does not show at %s' % size)
            frames[size] = {key: bounds(s.row(key, rs)) for key in keys}
            x, y, w, h = frames[size]['terminal-find-bar']
            term_x, term_y, term_w, term_h = bounds(s.row('terminal-panel', rs))
            self.assertAlmostEqual(w, min(FIND_BAR_WIDTH * size / 12, term_w - FIND_BAR_MARGIN), delta=ROUNDING,
                                   msg='the find bar is %.0f points wide over a Terminal %.0f wide at %s' % (w, term_w, size))
            self.assertTrue(term_x - ROUNDING <= x and x + w <= term_x + term_w + ROUNDING
                            and term_y - ROUNDING <= y and y + h <= term_y + term_h + ROUNDING,
                            'the find bar, at %s, leaves the Terminal, at %s, at %s'
                            % ((x, y, w, h), (term_x, term_y, term_w, term_h), size))
            # The field shows its text whole.
            self.assert_field_has_the_keys('the find field', size)
            s.act('press', 'terminal-find-done')
            s.wait_rows(lambda rs: not s.has('terminal-find-field', rs), 'Done did not close Find in Pane at %s' % size)
        small, large = frames[12], frames[18]
        self.assertGreaterEqual(bounds(s.row('terminal-panel'))[2], FIND_BAR_WIDTH * 1.5 + FIND_BAR_MARGIN,
                                'the Terminal is too narrow for the check')
        self.assertAlmostEqual(small['terminal-find-bar'][3], FIND_BAR_HEIGHT, delta=ROUNDING)
        self.assert_text_grows_by_half('terminal-find-bar', 0, small['terminal-find-bar'][3], large['terminal-find-bar'][3])
        self.assert_text_grows_by_half('terminal-find-bar', 0, small['terminal-find-bar'][2], large['terminal-find-bar'][2],
                                       side='wide')
        # The status grows on one line, as at 12, so it shows whole: a status without room wraps in the bar.
        self.assert_text_grows_by_half('terminal-find-status', 0, small['terminal-find-status'][3],
                                       large['terminal-find-status'][3])

    def test_at_18_a_hint_grows_by_half_and_shows_its_whole_key(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        rest = lambda rs: next((key for key in s.ids(rs) if key.startswith('hint-topic-')
                                and len(s.row(key, rs).get('accessibilityValue') or '') == 1), None)
        held = lambda key, rs: (s.row(key, rs).get('accessibilityValue') or '').startswith('⌃')
        keys, badges = {}, {}
        for size in [12, 18]:
            self.set_size(size)
            # A card's key at rest.
            rs = s.wait_rows(lambda rs: rest(rs), 'no card shows its key at rest at %s' % size)
            key = rest(rs)
            rs = self.settled([key], 'the key at rest does not show at %s' % size)
            keys[size] = bounds(s.row(key, rs))
            # Holding Control shows the card's badge in its place.
            s.act('action', 'quick-switch-input', 'Hold Control')
            self.addCleanup(s.act, 'action', 'quick-switch-input', 'Release modifiers')
            s.wait_rows(lambda rs: held(key, rs), 'holding Control shows no badge on %s at %s' % (key, size))
            rs = self.settled([key], 'the badge does not show at %s' % size)
            badges[size] = bounds(s.row(key, rs))
            s.act('action', 'quick-switch-input', 'Release modifiers')
            s.wait_rows(lambda rs: not held(key, rs), 'releasing Control does not hide the badge at %s' % size)
        for side in [2, 3]:
            self.assertAlmostEqual(keys[12][side], REST_KEY, delta=ROUNDING, msg='the key at rest is %s at 12' % (keys[12],))
            self.assertAlmostEqual(keys[18][side], 1.5 * REST_KEY, delta=ROUNDING,
                                   msg='the key at rest did not grow by half: %s' % (keys[18],))
        # The badge is as wide as its keys, which it never cuts.
        self.assert_text_grows_by_half('the badge', BADGE_PADDING, badges[12][3], badges[18][3])
        self.assertGreater(badges[18][2] - BADGE_SIDES, 1.3 * (badges[12][2] - BADGE_SIDES),
                           'the badge is %.0f points wide at 12 and %.0f at 18: its keys did not grow'
                           % (badges[12][2], badges[18][2]))

    def test_at_18_the_empty_topic_pages_title_grows_by_half_and_shows_whole(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        self.store.put(dict(id=EMPTY_TOPIC, title=EMPTY_TOPIC, slug=EMPTY_TOPIC, home_project=None))
        self.addCleanup(self.store.remove, EMPTY_TOPIC)
        self.addCleanup(s.show, self.windows['fs-size'][0])
        s.wait_rows(lambda rs: s.has('topic-' + EMPTY_TOPIC, rs), 'the card of %s does not show' % EMPTY_TOPIC)
        s.act('action', 'topic-' + EMPTY_TOPIC, 'Go to Topic')
        frames = {}
        for size in [12, 18]:
            self.set_size(size)
            rs = self.settled(['empty-topic-title'], 'the Empty Topic page does not show at %s' % size)
            self.assertEqual(self.text('empty-topic-title', rs), EMPTY_TOPIC)
            frames[size] = bounds(s.row('empty-topic-title', rs))
            # The page has 24 points of padding on each side, and the title is narrower than the room inside it, so it
            # shows whole: a title without room wraps there.
            self.assertLess(frames[size][2], bounds(s.row('terminal-panel', rs))[2] - 24 - 24 - ROUNDING,
                            'the Empty Topic page has no room beside its title at %s' % size)
        # The title grows on one line.
        self.assert_text_grows_by_half('empty-topic-title', 0, frames[12][3], frames[18][3])

    def test_at_18_a_hover_labels_panel_grows_by_half_with_its_detail(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        row = 'pane-' + self.panes[1]
        s.show(self.windows['fs-panes'][0])
        self.addCleanup(s.act, 'hover', 'agents-header')
        frames = {}
        for size in [12, 18]:
            self.set_size(size)
            s.wait_rows(lambda rs: s.has(row, rs), 'the open card does not show its Pane row at %s' % size)
            s.act('hover', row)
            rs = s.wait_rows(lambda rs: self.hover_label(rs), 'no hover label on %s at %s' % (row, size), seconds=5)
            # The Pane's title fits its row, so the label shows only its detail: the Pane's path.
            self.assertEqual(len(self.hover_label(rs)), 1, 'the hover label shows %s at %s' % (self.hover_label(rs), size))
            label = bounds(s.row('hover-label', rs))
            ids = s.ids(rs)
            detail = bounds(next(r for r in rs[ids.index('hover-label') + 1:] if r.get('accessibilityRole') == 'AXStaticText'))
            frames[size] = label, detail
            # The panel is as large as its detail and its padding, which do not cut it.
            self.assertAlmostEqual(label[2], detail[2] + HOVER_LABEL_SIDES, delta=ROUNDING * 2,
                                   msg='the hover label, %s, is not its detail, %s, and its padding at %s' % (label, detail, size))
            self.assertAlmostEqual(label[3], detail[3] + HOVER_LABEL_PADDING, delta=ROUNDING * 2,
                                   msg='the hover label, %s, is not its detail, %s, and its padding at %s' % (label, detail, size))
            s.act('hover', 'agents-header')
            s.wait_rows(lambda rs: not self.hover_label(rs), 'the hover label did not close at %s' % size, seconds=5)
        (small, small_detail), (large, large_detail) = frames[12], frames[18]
        self.assert_text_grows_by_half('the hover label\'s detail', 0, small_detail[3], large_detail[3])
        self.assert_text_grows_by_half('hover-label', HOVER_LABEL_PADDING, small[3], large[3])
        self.assertGreater(large_detail[2], 1.3 * small_detail[2],
                           'the hover label\'s detail is %.0f points wide at 12 and %.0f at 18' % (small_detail[2], large_detail[2]))

    def browser_window(self):
        """A Window of its own Topic whose Browser shows the fixture page in its only Tab, shown in the app. The Sidebar
        is hidden until the check ends."""
        s = self.s
        page = s.root/'font-size-page.html'
        page.write_text(BROWSER_PAGE)
        self.store.put(dict(id=BROWSER_TOPIC, title=BROWSER_TOPIC, slug=BROWSER_TOPIC, home_project=str(self.project)))
        self.addCleanup(self.store.remove, BROWSER_TOPIC)
        # One tmux call, so the app never reads the Window without its Browser options.
        options = [arg for option, value in [('@muxify_tabs', page.as_uri()), ('@muxify_active_tab', '0'),
                                             ('@muxify_browser', 'on')]
                   for arg in (';', 'set-option', '-w', '-t', BROWSER_TOPIC + ':', option, value)]
        s.tmux('new-session', '-d', '-s', BROWSER_TOPIC, '-c', str(self.project), SHELL,
               ';', 'set-option', '-t', BROWSER_TOPIC, '@muxify_topic', BROWSER_TOPIC, *options)
        self.addCleanup(s.tmux_ok, 'kill-session', '-t', '=' + BROWSER_TOPIC)
        self.addCleanup(s.show, self.windows['fs-size'][0])
        s.show(s.tmux('display-message', '-p', '-t', BROWSER_TOPIC + ':', '#{window_id}'))
        self.addCleanup(lambda: s.row('toggle-sidebar').get('accessibilityValue') == 'off' and s.act('press', 'toggle-sidebar'))
        s.act('press', 'toggle-sidebar')
        s.wait_rows(lambda rs: not s.has('sidebar-panel', rs) and self.page_width(rs) is not None,
                    lambda: 'the Sidebar does not hide, or the Browser does not show the page: %s' % self.tab_title())

    def tab_title(self, rs=None):
        rs = rs if rs is not None else self.s.rows()
        key = next((key for key in self.s.ids(rs) if key.startswith('browser-tab-title-')), None)
        return key and self.text(key, rs)

    def page_width(self, rs):
        """The width of the page's viewport in CSS pixels, from its title, None before the page reports it."""
        found = re.search(r'fs-page vw=(\d+)', self.tab_title(rs) or '')
        return found and int(found.group(1))

    def test_at_18_the_browsers_tab_strip_tabs_and_address_field_grow_by_half_and_the_page_keeps_its_zoom(self):
        s = self.s
        self.addCleanup(self.write_config, '')
        self.browser_window()
        tab = next(key for key in s.ids() if key.startswith('browser-tab-title-'))[len('browser-tab-title-'):]
        named = {key: key + '-' + tab if key in ('browser-tab', 'browser-tab-close') else key for key in BROWSER_CHROME}
        frames, pages, panels = {}, {}, {}
        for size in [12, 18]:
            self.write_config('ui:\n  font_size: %s\n' % size)
            s.wait_rows(lambda rs: s.has('browser-tab-strip', rs)
                        and abs(height(s.row('browser-tab-strip', rs)) - 36 * size / 12) <= ROUNDING,
                        lambda: 'the tab strip is not %.0f points high at %s: %s' % (
                            36 * size / 12, size, [(r.get('accessibilityIdentifier'), r.get('accessibilityFrame'))
                                                   for r in s.rows() if 'browser' in r.get('accessibilityIdentifier', '')]))
            rs = self.settled([*named.values(), 'browser-tab-title-' + tab], 'the Browser does not show at %s' % size)
            frames[size] = {key: bounds(s.row(name, rs)) for key, name in named.items()}
            frames[size]['title'] = bounds(s.row('browser-tab-title-' + tab, rs))
            panels[size] = bounds(s.row('browser-panel', rs))
            widths = []
            # The page reports its width every 200 milliseconds, so it is read once it is the same twice.
            s.wait_rows(lambda rs: widths.append(self.page_width(rs)) or widths[-1] and widths[-2:] == [widths[-1]] * 2,
                        'the page reports no width at %s: its Tab shows %r' % (size, self.tab_title()))
            pages[size] = widths[-1]
            # The Tab takes its most width, and its title the room in it up to its close button: the title is cut there,
            # so the room it leaves is less than a character, and it shows as much of its text as the Tab has room for.
            tab_x, _, tab_w, _ = frames[size]['browser-tab']
            title_x, _, title_w, _ = frames[size]['title']
            close_x = frames[size]['browser-tab-close'][0]
            self.assertAlmostEqual(tab_w, TAB_WIDTH * size / 12, delta=ROUNDING,
                                   msg='the Tab is %.0f points wide at %s' % (tab_w, size))
            left = close_x - TAB_TITLE_SPACING - (title_x + title_w)
            self.assertTrue(-ROUNDING <= left < size,
                            'the title, at %s, leaves %.1f points before the close button, at %.0f, at %s'
                            % (frames[size]['title'], left, close_x, size))
            self.assertTrue(tab_x < title_x and title_x + title_w < tab_x + tab_w,
                            'the title, at %s, leaves its Tab, at %s, at %s' % (frames[size]['title'], frames[size]['browser-tab'], size))
        small, large = frames[12], frames[18]
        self.assertGreaterEqual(panels[18][2], TAB_WIDTH * 1.5 + TAB_STRIP_SIDES * 1.5, 'the Browser is too narrow for the check')
        for key, design in BROWSER_CHROME.items():
            self.assertAlmostEqual(small[key][3], design, delta=ROUNDING, msg='%s is %s at 12' % (key, small[key],))
            self.assert_text_grows_by_half(key, 0, small[key][3], large[key][3])
        for key in ['browser-back', 'browser-tab-close']:
            self.assert_text_grows_by_half(key, 0, small[key][2], large[key][2], side='wide')
        # The title's room grows by more than half, as the Tab's padding and spacing do not grow, and its text grows.
        self.assertGreaterEqual(large['title'][2], 1.5 * small['title'][2],
                                'the title has %.0f points at 12 and %.0f at 18' % (small['title'][2], large['title'][2]))
        self.assertGreater(large['title'][3], 1.3 * small['title'][3],
                           'the title is %.0f points high at 12 and %.0f at 18' % (small['title'][3], large['title'][3]))
        # The page keeps its own zoom: in a Browser as wide at both sizes, its viewport is as wide, a CSS pixel a point.
        self.assertAlmostEqual(panels[12][2], panels[18][2], delta=ROUNDING,
                               msg='the Browser is %.0f points wide at 12 and %.0f at 18' % (panels[12][2], panels[18][2]))
        self.assertEqual(pages[12], pages[18], 'the page is %s CSS pixels wide at 12 and %s at 18' % (pages[12], pages[18]))
        self.assertAlmostEqual(pages[12], panels[12][2], delta=ROUNDING,
                               msg='the page is %s CSS pixels wide in a Browser %.0f points wide' % (pages[12], panels[12][2]))
