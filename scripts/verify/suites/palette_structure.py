from pathlib import Path
import re
import unittest


class PaletteStructure(unittest.TestCase):
    def test_actions_do_not_add_sheets_or_alert_accessories(self):
        root = Path(__file__).resolve().parents[3]
        exceptions = set()
        found = set()
        for path in (root / 'Sources/Muxify').rglob('*.swift'):
            source = path.read_text()
            if re.search(r'\.sheet\s*\(|\.accessoryView\s*=|enum\s+PresentedSheet\b', source):
                found.add(str(path.relative_to(root)))
        self.assertEqual(found, exceptions)

    def test_new_alerts_require_an_explicit_exception(self):
        root = Path(__file__).resolve().parents[3]
        existing_alerts = {
            'Sources/Muxify/App/CommandLineToolInstaller.swift': 1,
            'Sources/Muxify/App/ExtensionInstaller.swift': 1,
            'Sources/Muxify/Browser/BrowserTab.swift': 1,
            'Sources/Muxify/Workspace/WorkspaceStore.swift': 4,
        }
        found = {}
        for path in (root / 'Sources/Muxify').rglob('*.swift'):
            count = len(re.findall(r'\bNSAlert\s*\(', path.read_text()))
            if count:
                found[str(path.relative_to(root))] = count
        self.assertEqual(found, existing_alerts)
