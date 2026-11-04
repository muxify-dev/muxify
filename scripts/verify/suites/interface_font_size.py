"""The Interface font size, `ui.font_size`: Muxify's own text keeps its ratio to 12, and the fixed sizes that hold it
grow with it (ADR 0067). Each check rewrites the sandbox Config, at 12 and then at 18, and measures elements in the
dump. Paddings and spacing do not scale, so a check compares the part of an element that holds its text: the element's
height less its padding.

The Bench's geometry follows the edge pill, whose band grows with the size, so the Bench's rules also hold at 18: a
Benched card stands directly below the Bench line or the "more above" pill, and neither covers it (ADR 0063).

The App Window header's height, `ui.header_height`, is a length at 12 that grows by the same factor, so its buttons,
which grow too, still fit in it. A maximum width that grows, such as the Git button's, gives way in a header without
room for it, so no button leaves the App Window.

Run from the repo root after `make build`:
    python3 -m unittest -v scripts.verify.suites.interface_font_size
"""

import math
import re
import subprocess
import unittest

from scripts.verify.sandbox import Sandbox, frame
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

    @classmethod
    def write_config(cls, extra, topics=''):
        """The Config with `extra` after the Session Paths, then the FIXTURE, whose `topics` section ends with `topics`."""
        cls.config.write_text('sessions:\n  paths:\n    - path: ' + str(cls.project) + '\n' + extra + FIXTURE + topics)

    def set_size(self, size, topics=''):
        """Writes `ui.font_size` and waits until the Sidebar has the width of an undragged Sidebar at that size."""
        self.write_config('ui:\n  font_size: %s\n' % size, topics)
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
            app_window = bounds(next(row for row in rs if row.get('accessibilityRole') == 'AXWindow'))
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
        self.addCleanup(s.restart_app, LAUNCH_ARGS)
        s.restart_app(LAUNCH_ARGS + ['-sidebarWidth', '10000'])
        self.write_config('ui:\n  font_size: 24\n')
        s.show(window)
        # The Sidebar's widest bound, 420 at 12 (`SidebarWidth.designBounds`), at 24.
        widest = 420 * 2
        rs = s.wait_rows(lambda rs: s.row('toggle-git-view', rs).get('accessibilityLabel') == branch
                         and abs(width(s.row('sidebar-panel', rs)) - widest) < 1
                         and abs(height(s.row(HEADER, rs)) - 60) < 1,
                         'the header does not show the branch beside a %d-point Sidebar at ui.font_size: 24' % widest)
        rs = self.settled([HEADER, 'toggle-git-view'] + HEADER_BUTTONS, 'the header does not settle at 24')
        app_window = bounds(next(row for row in rs if row.get('accessibilityRole') == 'AXWindow'))
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
