import importlib.util
import io
import json
import os
import shlex
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
# Recorded from local runs with a throwaway test that failed once, crashed once or always failed, and trimmed: the
# macOS ones are xcresulttool get test-results tests without the devices, with the checkout's path as /ROOT.
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "flaky-tests"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


REPORTER = load("report_flaky_tests", "scripts/report-flaky-tests.py")
RETRIES = load("swift_test_retries", "scripts/swift-test-retries.py")


def xcresult(name):
    return json.loads((FIXTURES / ("xcresult-%s.json" % name)).read_text())


def log(name):
    return (FIXTURES / ("swift-test-%s.log" % name)).read_text()


class ReporterTests(unittest.TestCase):
    """scripts/report-flaky-tests.py on recorded results."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="muxify-flaky-")
        self.addCleanup(self.temp.cleanup)
        self.summary = Path(self.temp.name) / "summary.md"
        REPORTER.FAILURES.ROOT = "/ROOT"

    def report(self, flaky):
        output = io.StringIO()
        with redirect_stdout(output):
            REPORTER.report(flaky, str(self.summary))
        return output.getvalue()

    def test_a_passing_macos_run_has_no_flaky_test_and_prints_nothing(self):
        flaky = REPORTER.flaky_in_xcresult(xcresult("passing"))
        self.assertEqual(flaky, [])
        self.assertEqual(self.report(flaky), "")
        self.assertFalse(self.summary.exists())

    def test_a_test_that_failed_every_macos_attempt_is_not_flaky(self):
        self.assertEqual(REPORTER.flaky_in_xcresult(xcresult("failing")), [])

    def test_a_macos_test_that_failed_and_then_passed_is_flaky_with_its_failure_message(self):
        flaky = REPORTER.flaky_in_xcresult(xcresult("flaky"))
        self.assertEqual(flaky, [(
            "MuxifyCoreTests / ThrowawayFlakyTests / testBFailsOnceThenPasses()",
            "Packages/MuxifyCore/Tests/MuxifyCoreTests/ThrowawayFlakyTests.swift:20: "
            "failed - throwaway: the first attempt fails",
        )])
        output = self.report(flaky)
        self.assertEqual(output.splitlines(), [
            "::warning title=FLAKY test::FLAKY: MuxifyCoreTests / ThrowawayFlakyTests / testBFailsOnceThenPasses() "
            "failed and then passed on a retry: Packages/MuxifyCore/Tests/MuxifyCoreTests/ThrowawayFlakyTests.swift:20: "
            "failed - throwaway: the first attempt fails",
        ])
        summary = self.summary.read_text()
        self.assertIn("## Flaky tests\n", summary)
        self.assertIn("- `MuxifyCoreTests / ThrowawayFlakyTests / testBFailsOnceThenPasses()`: ", summary)

    def test_the_failure_printer_finds_the_messages_of_a_retried_failure(self):
        cases = [case for node in xcresult("failing")["testNodes"]
                 for case in REPORTER.FAILURES.failed_cases(node, [])]
        self.assertEqual(len(cases), 1)
        names, messages = cases[0]
        self.assertEqual(names[-1], "testDAlwaysFails()")
        self.assertEqual({message["name"] for message in messages}, {"failed - throwaway: every attempt fails"})

    def test_a_linux_record_names_each_test_that_failed_or_crashed_and_then_passed(self):
        record = self.record_of([("crashed", 4), ("failed", 1), ("rerun-passed", 0)])
        flaky = REPORTER.flaky_in_linux_record(record)
        # The recorded run also caught a real FLAKY test: a tmux command of HostServerSocketTests timed out once.
        self.assertEqual(flaky, [
            ("core / ThrowawayFlakyTests.testACrashesOnceThenPasses",
             "MuxifyCoreTests/ThrowawayFlakyTests.swift:15: Fatal error: throwaway: the first attempt crashes"),
            ("core / HostServerSocketTests.testTheConsumersServerTakesTheOptionWhileItIsEmpty",
             '<EXPR>:0: threw error "The tmux command timed out"'),
            ("core / ThrowawayFlakyTests.testBFailsOnceThenPasses",
             "/src/Packages/MuxifyCore/Tests/MuxifyCoreTests/ThrowawayFlakyTests.swift:20: "
             "failed - throwaway: the first attempt fails"),
        ])
        output = self.report(flaky)
        self.assertEqual(len(output.splitlines()), 3)
        self.assertTrue(all(line.startswith("::warning title=FLAKY test::FLAKY: core / ") for line in output.splitlines()))
        self.assertEqual(self.summary.read_text().count("\n- `core / "), 3)

    def test_a_linux_test_that_failed_every_attempt_or_passed_at_once_is_not_flaky(self):
        self.assertEqual(REPORTER.flaky_in_linux_record(self.record_of([("failed", 1), ("failed", 1)])), [])
        self.assertEqual(REPORTER.flaky_in_linux_record(self.record_of([("rerun-passed", 0)])), [])

    def test_the_reporter_reads_every_record_of_a_linux_run_and_never_fails(self):
        folder = Path(self.temp.name) / "test-linux"
        folder.mkdir()
        (folder / "core.json").write_text(json.dumps(self.record_of([("failed", 1), ("rerun-passed", 0)])))
        (folder / "cli.json").write_text("not json")
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(REPORTER.main(["--linux", str(folder)]), 0)
        self.assertIn("::warning title=FLAKY test::FLAKY: core / ThrowawayFlakyTests.testBFailsOnceThenPasses", output.getvalue())
        self.assertIn("Could not read the test record", output.getvalue())

    def test_a_message_cannot_end_the_warning_early(self):
        output = self.report([("Some / test", "line one\nline two 100%")])
        self.assertEqual(output, "::warning title=FLAKY test::FLAKY: Some / test failed and then passed on a retry: "
                                 "line one%0Aline two 100%25\n")

    @staticmethod
    def record_of(attempts):
        record = {"name": "core", "attempts": []}
        for number, (name, status) in enumerate(attempts, 1):
            tests, complete = RETRIES.parse(log(name))
            record["attempts"].append({"attempt": number, "status": status, "complete": complete,
                                       "log": "core-%d.log" % number, "tests": tests})
        return record


class RerunChoiceTests(unittest.TestCase):
    """What scripts/swift-test-retries.py reruns after a recorded swift test attempt."""

    def test_a_failed_complete_run_reruns_only_its_failed_classes(self):
        tests, complete = RETRIES.parse(log("failed"))
        self.assertTrue(complete)
        self.assertEqual(tests["ThrowawayFlakyTests.testBFailsOnceThenPasses"]["result"], "failed")
        self.assertEqual(tests["ThrowawayFlakyTests.testCPasses"]["result"], "passed")
        self.assertEqual(RETRIES.rerun_classes(tests, complete), ["HostServerSocketTests", "ThrowawayFlakyTests"])
        self.assertEqual(RETRIES.filter_arguments(["HostServerSocketTests", "ThrowawayFlakyTests"]),
                         ["--filter", r"(^|\.)HostServerSocketTests/", "--filter", r"(^|\.)ThrowawayFlakyTests/"])

    def test_a_crashed_run_reruns_the_whole_target(self):
        tests, complete = RETRIES.parse(log("crashed"))
        self.assertFalse(complete)
        self.assertEqual(tests["ThrowawayFlakyTests.testACrashesOnceThenPasses"], {
            "result": "unfinished",
            "messages": ["MuxifyCoreTests/ThrowawayFlakyTests.swift:15: Fatal error: throwaway: the first attempt crashes"],
        })
        self.assertIsNone(RETRIES.rerun_classes(tests, complete))
        self.assertEqual(RETRIES.filter_arguments(None), [])

    def test_a_timed_out_run_reruns_the_whole_target(self):
        # timeout stops swift test in the middle of the run: the output ends inside a test, as after a crash.
        output = log("failed")
        cut = output.index("Test Case 'ThrowawayFlakyTests.testCPasses' passed")
        tests, complete = RETRIES.parse(output[:cut])
        self.assertFalse(complete)
        self.assertIsNone(RETRIES.rerun_classes(tests, complete))

    def test_a_filtered_rerun_that_passes_is_complete(self):
        tests, complete = RETRIES.parse(log("rerun-passed"))
        self.assertTrue(complete)
        self.assertEqual({test["result"] for test in tests.values()}, {"passed"})


class WrapperTests(unittest.TestCase):
    """scripts/swift-test-retries.py around a command that replays recorded swift test attempts."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="muxify-retries-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)

    def run_wrapper(self, attempts, retries=2):
        """Runs the wrapper with a command whose nth call prints the nth fixture and exits with its status."""
        script = self.folder / "swift-test"
        cases = "".join('  %d) cat %s; exit %d ;;\n' % (number, shlex.quote(str(FIXTURES / ("swift-test-%s.log" % name))),
                                                         status)
                        for number, (name, status) in enumerate(attempts, 1))
        script.write_text('#!/bin/bash\necho "$*" >> %s\nn=$(($(wc -l < %s)))\ncase $n in\n%s  *) exit 99 ;;\nesac\n' % (
            shlex.quote(str(self.folder / "calls")), shlex.quote(str(self.folder / "calls")), cases))
        script.chmod(0o755)
        output = io.StringIO()
        with redirect_stdout(output):
            status = RETRIES.main(["--name", "core", "--retries", str(retries), "--record", str(self.folder / "record"),
                                   "--", str(script), "attempt", "core"])
        calls = (self.folder / "calls").read_text().splitlines()
        record = json.loads((self.folder / "record" / "core.json").read_text())
        return status, calls, record, output.getvalue()

    def test_it_reruns_the_whole_target_after_a_crash_then_the_failed_class_and_passes(self):
        status, calls, record, output = self.run_wrapper([("crashed", 4), ("failed", 1), ("rerun-passed", 0)])
        self.assertEqual(status, 0)
        self.assertEqual(calls, ["attempt core", "attempt core",
                                 r"attempt core --filter (^|\.)HostServerSocketTests/ --filter (^|\.)ThrowawayFlakyTests/"])
        self.assertEqual([attempt["classes"] for attempt in record["attempts"]],
                         [None, None, ["HostServerSocketTests", "ThrowawayFlakyTests"]])
        self.assertEqual([attempt["complete"] for attempt in record["attempts"]], [False, True, True])
        self.assertIn("rerun 1 of 2 of core, the whole target", output)
        self.assertIn("rerun 2 of 2 of core, the classes that failed: HostServerSocketTests, ThrowawayFlakyTests", output)
        for number in (1, 2, 3):
            self.assertTrue((self.folder / "record" / ("core-%d.log" % number)).is_file())

    def test_a_test_that_fails_every_attempt_fails_the_run_after_the_last_retry(self):
        status, calls, record, _ = self.run_wrapper([("failed", 1), ("failed", 1), ("failed", 1)])
        self.assertEqual(status, 1)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(record["attempts"]), 3)

    def test_a_passing_run_runs_once(self):
        status, calls, record, output = self.run_wrapper([("rerun-passed", 0)])
        self.assertEqual((status, len(calls), len(record["attempts"])), (0, 1, 1))
        self.assertNotIn("rerun", output.replace("Selected", ""))


class SwitchTests(unittest.TestCase):
    """MUXIFY_TEST_RETRIES reaches make test's xcodebuild only when it is set."""

    def dry_run(self, retries):
        """Runs make test's recipe from its retries on, with a fake xcodebuild that keeps its arguments."""
        recipe = subprocess.run(["make", "-n", "-C", str(ROOT), "test", "XCODEBUILD_TEST=xcodebuild test"],
                                capture_output=True, text=True, check=True).stdout
        # The checkout's failure printer and reporter have nothing to read here.
        script = recipe[recipe.index('retries="${MUXIFY_TEST_RETRIES:-0}"'):].replace("./scripts/", "true ")
        temp = tempfile.TemporaryDirectory(prefix="muxify-switch-")
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        xcodebuild = folder / "xcodebuild"
        xcodebuild.write_text('#!/bin/bash\necho "$*" > %s\n' % shlex.quote(str(folder / "args")))
        xcodebuild.chmod(0o755)
        env = {key: value for key, value in os.environ.items() if key != "MUXIFY_TEST_RETRIES"}
        if retries is not None:
            env["MUXIFY_TEST_RETRIES"] = retries
        env["PATH"] = str(folder) + os.pathsep + env["PATH"]
        result = subprocess.run(["/bin/sh", "-c", script], env=env, cwd=folder, capture_output=True, text=True)
        args = folder / "args"
        return result, args.read_text().strip() if args.exists() else None

    def test_unset_or_zero_runs_xcodebuild_without_retries(self):
        for retries in (None, "0"):
            result, args = self.dry_run(retries)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(args, "test")

    def test_a_count_turns_on_retry_on_failure_with_one_more_iteration(self):
        result, args = self.dry_run("2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args, "test -retry-tests-on-failure -test-iterations 3")

    def test_a_count_that_is_not_a_number_stops_the_run(self):
        result, args = self.dry_run("two")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(args)
        self.assertIn("MUXIFY_TEST_RETRIES is a number of retries, not two", result.stderr)


if __name__ == "__main__":
    unittest.main()
