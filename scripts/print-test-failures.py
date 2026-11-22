#!/usr/bin/env python3
"""Prints each failed test of a test result bundle with its failure messages and the file and line of each.

xcodebuild's parallel output names a failed test but not why it failed, so without this a red CI run says no more.
Usage: print-test-failures.py [bundle]; without one, the newest under build/Logs/Test. It always exits 0: the caller
keeps the status of the test run.
"""
import glob
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def newest_bundle():
    bundles = glob.glob(os.path.join(ROOT, "build", "Logs", "Test", "*.xcresult"))
    return max(bundles, key=os.path.getmtime) if bundles else None


def failed_cases(node, names):
    """Each failed test case under `node`, with the names of the nodes above it and its failure messages."""
    names = names + [node.get("name", "")]
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
        messages = [child for child in node.get("children", []) if child.get("nodeType") == "Failure Message"]
        yield names, messages
        return
    for child in node.get("children", []):
        yield from failed_cases(child, names)


def place(message):
    location = message.get("sourceLocation") or {}
    path = location.get("filePath")
    if not path:
        return ""
    return "%s:%s: " % (os.path.relpath(path, ROOT), location.get("lineNumber", "?"))


def main():
    bundle = sys.argv[1] if len(sys.argv) > 1 else newest_bundle()
    if not bundle:
        print("No test result bundle under build/Logs/Test.")
        return 0
    try:
        output = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
                                check=True, capture_output=True, text=True).stdout
        tests = json.loads(output)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print("Could not read the test results of %s: %s" % (bundle, error))
        return 0
    cases = [case for node in tests.get("testNodes", []) for case in failed_cases(node, [])]
    if not cases:
        print("No failed test in %s." % bundle)
        return 0
    shown = os.path.relpath(bundle, ROOT) if os.path.abspath(bundle).startswith(ROOT + os.sep) else bundle
    print("Failed tests in %s:" % shown)
    for names, messages in cases:
        # The test plan's name comes first; the bundle, the class and the case follow it.
        print("  " + " / ".join(name for name in names[1:] if name))
        for message in messages or [{"name": "no failure message"}]:
            print("    " + place(message) + message.get("name", ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
