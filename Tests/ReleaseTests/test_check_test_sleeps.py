import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SUPPORT = "Packages/MuxifyCore/Sources/MuxifyTestSupport"
FOLDERS = ["Tests/MuxifyTests", "Tests/MuxifyCLITests", "Packages/MuxifyCore/Tests/MuxifyCoreTests", SUPPORT]

# One unmarked fixed sleep of each kind the lint knows.
SLEEPS = [
    "Thread.sleep(forTimeInterval: 0.3)",
    "try await Task.sleep(nanoseconds: 300_000_000)",
    "try await Task.sleep(for: .milliseconds(300))",
    "try await ContinuousClock().sleep(for: .milliseconds(300))",
    "usleep(300_000)",
    "sleep(1)",
    "RunLoop.main.run(until: Date().addingTimeInterval(0.3))",
    "RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.3))",
]

CLEAN = """import XCTest

final class CleanTests: XCTestCase {
    func testItWaitsForTheSignal() throws {
        eventually("the file never came") { FileManager.default.fileExists(atPath: "/tmp/x") }
        // Thread.sleep(forTimeInterval: 1) is not called: a commented-out sleep is not a sleep.
        try server.run(["new-session", "-d", "exec sleep 600"])
        let script = \"\"\"
            while not os.path.exists(go): time.sleep(0.02)
            \"\"\"
        _ = script
    }
}
"""


@unittest.skipUnless(shutil.which("rg"), "the sleep lint needs ripgrep (rg)")
class CheckTestSleepsTests(unittest.TestCase):
    """scripts/check-test-sleeps.sh on fixture source trees."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="muxify-sleep-lint-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy(ROOT / "scripts/check-test-sleeps.sh", self.root / "scripts")
        for folder in FOLDERS:
            (self.root / folder).mkdir(parents=True)
        self.write("Tests/MuxifyTests/CleanTests.swift", CLEAN)
        self.env = dict(os.environ)

    def write(self, relative, content):
        path = self.root / relative
        path.write_text(content)
        return path

    def lint(self):
        return subprocess.run(["/bin/sh", str(self.root / "scripts/check-test-sleeps.sh")],
                              env=self.env, text=True, capture_output=True)

    def test_a_clean_tree_passes(self):
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")

    def test_each_unmarked_sleep_fails_with_its_file_and_line(self):
        for folder in FOLDERS:
            for sleep in SLEEPS:
                with self.subTest(folder=folder, sleep=sleep):
                    name = f"{folder}/SleepTests.swift"
                    self.write(name, f"import XCTest\n\nfunc wait() async throws {{\n    {sleep}\n}}\n")
                    result = self.lint()
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertEqual(result.stdout.splitlines(),
                                     [f'{name}:4: a fixed sleep without an "// absence:" marker: {sleep}'])
                    self.assertIn("never for a fixed time", result.stderr)
                    self.assertIn("docs/testing.md", result.stderr)
                    (self.root / name).unlink()

    def test_every_unmarked_sleep_of_a_file_is_listed(self):
        self.write("Tests/MuxifyCLITests/SleepTests.swift",
                   "func wait() {\n    Thread.sleep(forTimeInterval: 0.1)\n    // Some reason.\n    usleep(1)\n}\n")
        result = self.lint()
        self.assertEqual(result.returncode, 1)
        self.assertEqual([line.split(": ")[0] for line in result.stdout.splitlines()],
                         ["Tests/MuxifyCLITests/SleepTests.swift:2", "Tests/MuxifyCLITests/SleepTests.swift:4"])

    def test_a_sleep_marked_on_its_line_or_just_above_passes(self):
        self.write("Packages/MuxifyCore/Tests/MuxifyCoreTests/AbsenceTests.swift", """func wait() async throws {
    // absence: the stopped watch fires nothing for a write.
    Thread.sleep(forTimeInterval: 0.5)
    // absence: no event follows, which the next comment line explains.
    // The watch was stopped before the write.
    try await Task.sleep(nanoseconds: 300_000_000)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3)) // absence: the Listener does not follow the switch.
}
""")
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_marker_counts_only_for_the_sleep_just_below_it(self):
        self.write("Tests/MuxifyTests/AbsenceTests.swift", """func wait() async throws {
    // absence: nothing comes.
    Thread.sleep(forTimeInterval: 0.5)
    Thread.sleep(forTimeInterval: 0.5)
}
""")
        result = self.lint()
        self.assertEqual(result.returncode, 1)
        self.assertEqual([line.split(": ")[0] for line in result.stdout.splitlines()],
                         ["Tests/MuxifyTests/AbsenceTests.swift:4"])

    def test_the_shared_waits_poll_is_exempt_and_nothing_else_in_the_support(self):
        self.write(f"{SUPPORT}/Eventually.swift", """func eventually(until condition: () -> Bool) async {
    while !condition() {
        try? await Task.sleep(nanoseconds: UInt64(TestTime.poll * 1_000_000_000))
    }
}

private func pause(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    guard Thread.isMainThread else { return Thread.sleep(until: until) }
    _ = RunLoop.current.run(mode: .default, before: until)
}
""")
        self.assertEqual(self.lint().returncode, 0)

        self.write(f"{SUPPORT}/TmuxWindowFixture.swift", "func start() {\n    Thread.sleep(forTimeInterval: 0.2)\n}\n")
        self.write("Tests/MuxifyTests/Eventually.swift", "func wait() {\n    Thread.sleep(forTimeInterval: 0.2)\n}\n")
        result = self.lint()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(sorted(line.split(": ")[0] for line in result.stdout.splitlines()),
                         [f"{SUPPORT}/TmuxWindowFixture.swift:2", "Tests/MuxifyTests/Eventually.swift:2"])


class CheckTestSleepsSearchTests(unittest.TestCase):
    def test_it_exits_2_when_it_cannot_search(self):
        with tempfile.TemporaryDirectory(prefix="muxify-sleep-lint-") as temp:
            root = Path(temp)
            (root / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/check-test-sleeps.sh", root / "scripts")
            for folder in FOLDERS:
                (root / folder).mkdir(parents=True)
            (root / "Tests/MuxifyTests/SleepTests.swift").write_text("func wait() {\n    sleep(1)\n}\n")
            tools = root / "tools"
            tools.mkdir()
            for status in [127, 2]:
                with self.subTest(status=status):
                    fake = tools / "rg"
                    fake.write_text(f"#!/bin/sh\nexit {status}\n")
                    fake.chmod(0o755)
                    env = dict(os.environ, PATH=f"{tools}{os.pathsep}{os.environ['PATH']}")
                    result = subprocess.run(["/bin/sh", str(root / "scripts/check-test-sleeps.sh")],
                                            env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertIn("needs ripgrep (rg)", result.stderr)


if __name__ == "__main__":
    unittest.main()
