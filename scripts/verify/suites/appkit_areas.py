"""The guard: SwiftUI does not come back into an area that moved to AppKit
(docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).

Muxify leaves SwiftUI one area at a time. Once the user signs an area off, its AppKit files import no SwiftUI. The
check reads the sources and needs no app, as palette_structure does. It fails when a file of an area that moved
imports SwiftUI, unless EXCEPTIONS names the file with the task or stage that removes its import. It also fails when a
file of an area is missing, and when an exception no longer imports SwiftUI, so the list stays true as the files
change.

Every task that adds AppKit files of a moved area adds them to AREAS here, in the same change. A task that removes
the reason for an exception removes the exception. At the last stage the check covers every file under Sources/.

Run from the repo root:
    python3 -m unittest -v scripts.verify.suites.appkit_areas
"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
UI = 'Sources/Muxify/UI/'
# The files of each area that moved, by the area's name.
AREAS = {
    'Sessions list': [UI + name + '.swift' for name in (
        'SessionsListView', 'SessionCardView', 'SessionCardDrag', 'SidebarCardChrome', 'SidebarLabel',
        'SidebarAgentMark', 'SidebarHintView', 'SidebarRowView', 'SidebarLogo', 'LayerGlide', 'ObservedUpdate',
        'AgentMarkMetrics', 'WindowRowMetrics', 'PaneRowMetrics', 'SessionsListMetrics', 'WindowRowView',
        'PaneRowView', 'SessionsList', 'SidebarMenu', 'LayerColoredView', 'StackLayout', 'ListLift', 'CardMetrics',
        'HintMetrics', 'HintPresentation', 'RowHoverLabel', 'GitViewIconShape', 'SidebarList', 'SidebarListHost')],
    'Topics list': [UI + name + '.swift' for name in ('TopicsListView', 'TopicCardView', 'TopicsListMetrics', 'CardHeaderView',
                                                       'TopicCardMetrics', 'TopicsLineView', 'TopicCardRows')],
}
# The files of an area that may import SwiftUI for now, each with the task or stage that removes the import. A task
# is one of the task set remove-swiftui (.cook/tasks/remove-swiftui/), which is stage 1.
EXCEPTIONS = {
    UI + 'WindowRowView.swift': 'task 14 (hover labels): the row hands its hover label a SwiftUI Text',
    UI + 'PaneRowView.swift': 'task 14 (hover labels): the row hands its hover label a SwiftUI Text',
    UI + 'SessionsList.swift': ('stage 2: SessionCardPress opens a card with SwiftUI\'s withAnimation, for the SwiftUI '
                                'Session card of the Topics list'),
    UI + 'SidebarListHost.swift': ('stage 2: the SwiftUI Sidebar hosts the AppKit Sessions list and Topics list through '
                                   'it'),
    UI + 'SidebarMenu.swift': ('stage 2: it serves the AppKit list and the SwiftUI views, which draw a menu with '
                               'SidebarMenuButtons'),
}
# `import SwiftUI`, also with an attribute such as `@preconcurrency` or a kind such as `import struct SwiftUI.Text`.
IMPORTS_SWIFTUI = re.compile(r'^[ \t]*(?:@\w+[ \t]+)*import[ \t]+(?:\w+[ \t]+)?SwiftUI\b', re.MULTILINE)


def imports_swiftui(path):
    return bool(IMPORTS_SWIFTUI.search((ROOT/path).read_text()))


class AppKitAreas(unittest.TestCase):
    def test_every_file_of_an_area_exists(self):
        missing = [(area, path) for area, paths in AREAS.items() for path in paths if not (ROOT/path).is_file()]
        self.assertEqual(missing, [], 'a file of an area that moved is missing: rename it here too')

    def test_no_file_of_an_area_that_moved_imports_swiftui(self):
        found = [(area, path) for area, paths in AREAS.items() for path in paths
                 if path not in EXCEPTIONS and (ROOT/path).is_file() and imports_swiftui(path)]
        self.assertEqual(found, [], 'a file of an area that moved imports SwiftUI '
                                    '(docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md)')

    def test_every_exception_is_a_file_of_an_area_that_still_imports_swiftui(self):
        files = {path for paths in AREAS.values() for path in paths}
        self.assertEqual(sorted(path for path in EXCEPTIONS if path not in files), [],
                         'an exception is no file of an area that moved')
        self.assertEqual(sorted(path for path in EXCEPTIONS if (ROOT/path).is_file() and not imports_swiftui(path)), [],
                         'an exception no longer imports SwiftUI: remove it from EXCEPTIONS')

    def test_the_check_finds_every_form_of_the_import(self):
        for line in ('import SwiftUI', '@preconcurrency import SwiftUI', 'import struct SwiftUI.Text',
                     '  import SwiftUI // a comment'):
            with self.subTest(line=line):
                self.assertTrue(IMPORTS_SWIFTUI.search('import AppKit\n%s\n' % line))
        for line in ('import SwiftUIIntrospect', '// import SwiftUI', '/// The SwiftUI list draws it.'):
            with self.subTest(line=line):
                self.assertFalse(IMPORTS_SWIFTUI.search('import AppKit\n%s\n' % line))


if __name__ == '__main__':
    unittest.main()
