#!/usr/bin/env python3
"""Names each FLAKY test of a CI test run with retries: a test that failed and then passed on a retry.

For each one it prints a GitHub ::warning with the failure message of its failed attempt, and adds a line to a
"Flaky tests" section of $GITHUB_STEP_SUMMARY when that is set (docs/testing.md). When no test was FLAKY it prints
nothing. It always exits 0: the caller keeps the status of the test run.

Usage: report-flaky-tests.py [bundle]       a result bundle of make test; without one, the newest under build/Logs/Test
       report-flaky-tests.py --linux DIR    the record that scripts/swift-test-retries.py kept for make test-linux
"""
import glob
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location("print_test_failures", os.path.join(HERE, "print-test-failures.py"))
FAILURES = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(FAILURES)


def flaky_in_xcresult(tests):
    """(name, message) of each test case in xcresulttool's JSON that passed after a failed repetition."""
    found = []

    def walk(node, names):
        names = names + [node.get("name", "")]
        if node.get("nodeType") == "Test Case":
            repetitions = [child for child in node.get("children", []) if child.get("nodeType") == "Repetition"]
            failed = [repetition for repetition in repetitions if repetition.get("result") == "Failed"]
            if node.get("result") == "Passed" and failed:
                messages = FAILURES.failure_messages(failed[0])
                message = FAILURES.place(messages[0]) + messages[0].get("name", "") if messages else "no failure message"
                # The test plan's name comes first; the bundle, the class and the case follow it.
                found.append((" / ".join(name for name in names[1:] if name), message))
            return
        for child in node.get("children", []):
            walk(child, names)

    for node in tests.get("testNodes", []):
        walk(node, [])
    return found


def flaky_in_linux_record(record):
    """(name, message) of each test in a record of scripts/swift-test-retries.py that failed and then passed."""
    first_failure = {}
    found = []
    for attempt in record.get("attempts", []):
        for name, test in attempt.get("tests", {}).items():
            if test["result"] in ("failed", "unfinished") and name not in first_failure:
                if test["messages"]:
                    first_failure[name] = test["messages"][0]
                elif test["result"] == "unfinished":
                    first_failure[name] = "the test never ended: the run crashed or timed out (status %s, %s)" % (
                        attempt.get("status"), attempt.get("log"))
                else:
                    first_failure[name] = "no failure message (%s)" % attempt.get("log")
            elif test["result"] == "passed" and name in first_failure:
                found.append(("%s / %s" % (record.get("name", "?"), name), first_failure.pop(name)))
    return found


def report(flaky, summary_path):
    if not flaky:
        return
    for name, message in flaky:
        print("::warning title=FLAKY test::FLAKY: %s failed and then passed on a retry: %s" % (
            escape(name), escape(message)))
    if summary_path:
        with open(summary_path, "a") as summary:
            summary.write("## Flaky tests\n\nEach of these failed and then passed on a retry. "
                          "A FLAKY test is a bug to fix (docs/testing.md).\n\n")
            for name, message in flaky:
                summary.write("- `%s`: %s\n" % (name, message.replace("\n", " ")))
            summary.write("\n")


def escape(text):
    # A workflow command's message ends at its line, and % introduces an escape.
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv):
    if argv[:1] == ["--linux"]:
        flaky = []
        for path in sorted(glob.glob(os.path.join(argv[1] if len(argv) > 1 else "build/test-linux", "*.json"))):
            try:
                with open(path) as file:
                    flaky += flaky_in_linux_record(json.load(file))
            except (OSError, ValueError, KeyError) as error:
                print("Could not read the test record %s: %s" % (path, error))
    else:
        bundle = argv[0] if argv else FAILURES.newest_bundle()
        if not bundle:
            return 0
        try:
            flaky = flaky_in_xcresult(FAILURES.read_tests(bundle))
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
            print("Could not read the test results of %s: %s" % (bundle, error))
            return 0
    report(flaky, os.environ.get("GITHUB_STEP_SUMMARY"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
