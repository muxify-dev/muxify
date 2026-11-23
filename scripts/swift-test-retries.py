#!/usr/bin/env python3
"""Runs one swift test target of make test-linux with retries, and records each test's attempts (docs/testing.md).

Usage: swift-test-retries.py --name core --retries 2 --record DIR -- COMMAND...

COMMAND runs the target's swift test once; a rerun appends one --filter per class to it. The output of each attempt
goes to the terminal and to DIR/<name>-<attempt>.log. After a failed attempt with a complete result, the next attempt
runs only the classes that failed; after a crash or a timeout (no complete result), it runs the whole target again.
It stops at the first passing attempt or after `retries` reruns, and exits with the last attempt's status, so a test
that failed every attempt fails the run. DIR/<name>.json records every attempt and each test's result in it, which
scripts/report-flaky-tests.py --linux DIR reads to name each test that failed and then passed as FLAKY.
"""
import argparse
import json
import os
import re
import subprocess
import sys

# swift-corelibs-xctest's lines: "Test Case 'Class.test' started at …", "… passed (0.1 seconds)", "… failed (…)".
CASE = re.compile(r"^Test Case '([^']+)' (started|passed|failed|skipped)\b")
# "/src/Tests/Foo.swift:12: error: Class.test : XCTAssertTrue failed - …"
ERROR = re.compile(r"^(.*?:\d+): error: (\S+) : (.*)$")
# A crash names its cause: "MuxifyCoreTests/Foo.swift:15: Fatal error: …".
FATAL = re.compile(r"^(.*?:\d+): Fatal error: (.*)$")
# The end of the run: "Test Suite 'All tests' failed at …", or 'Selected tests' for a run with --filter.
END = re.compile(r"^Test Suite '(All tests|Selected tests)' (passed|failed) at ")


def parse(output):
    """The run's tests as {name: {"result", "messages"}}, and whether XCTest reported the end of the run.

    A test that started and never ended, as in a crash or a timeout, is "unfinished".
    """
    tests = {}
    complete = False
    running = None
    for line in output.splitlines():
        line = line.strip()
        case = CASE.match(line)
        if case:
            name, event = case.groups()
            test = tests.setdefault(name, {"result": "unfinished", "messages": []})
            if event == "started":
                running = test
            else:
                test["result"] = event
                running = None
            continue
        fatal = FATAL.match(line)
        if fatal and running is not None:
            running["messages"].append("%s: Fatal error: %s" % fatal.groups())
            continue
        error = ERROR.match(line)
        if error:
            place, name, message = error.groups()
            # A failure comes between its test's start and end; a compiler error names no started test.
            if name in tests:
                tests[name]["messages"].append("%s: %s" % (place, message))
            continue
        if END.match(line):
            complete = True
    return tests, complete


def class_of(name):
    return name.rsplit(".", 1)[0] if "." in name else name


def failed(test):
    return test["result"] in ("failed", "unfinished")


def rerun_classes(tests, complete):
    """The classes the next attempt runs, or None for the whole target.

    A complete result names the classes that failed. Without one, after a crash or a timeout, the tests after the
    one that stopped the run never ran, so the whole target runs again; so it does when a failed run names no test.
    """
    if not complete:
        return None
    classes = sorted({class_of(name) for name, test in tests.items() if failed(test)})
    return classes or None


def filter_arguments(classes):
    # swift test matches --filter against Module.Class/test; one --filter per class, each anchored at the class.
    arguments = []
    for name in classes or []:
        arguments += ["--filter", r"(^|\.)%s/" % re.escape(name)]
    return arguments


def run(command, log_path):
    """Runs the command with its output on the terminal and in the log, and returns its status and output."""
    lines = []
    with open(log_path, "w") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                   errors="replace")
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            log.write(line)
            lines.append(line)
        status = process.wait()
    return status, "".join(lines)


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--retries", type=int, required=True)
    parser.add_argument("--record", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    command = options.command[1:] if options.command[:1] == ["--"] else options.command
    if not command:
        parser.error("no command")
    os.makedirs(options.record, exist_ok=True)
    record = {"name": options.name, "attempts": []}
    record_path = os.path.join(options.record, options.name + ".json")
    classes = None
    status = 0
    for attempt in range(1, options.retries + 2):
        if attempt > 1:
            what = "the classes that failed: " + ", ".join(classes) if classes else "the whole target"
            print("==> make test-linux: rerun %d of %d of %s, %s" % (attempt - 1, options.retries, options.name, what),
                  flush=True)
        log = "%s-%d.log" % (options.name, attempt)
        status, output = run(command + filter_arguments(classes), os.path.join(options.record, log))
        tests, complete = parse(output)
        record["attempts"].append({"attempt": attempt, "classes": classes, "status": status, "complete": complete,
                                   "log": log, "tests": tests})
        with open(record_path, "w") as file:
            json.dump(record, file, indent=1)
        if status == 0:
            break
        classes = rerun_classes(tests, complete)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
