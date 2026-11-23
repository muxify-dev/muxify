#!/bin/sh
# A test waits for a signal, never for a fixed time (docs/testing.md, "Wait for a signal, with the shared wait"). This
# fails on a fixed sleep in the Swift tests of the app, MuxifyCore and the CLI, and in the shared test support, unless
# an `// absence:` comment says why: a sleep is allowed only before asserting that something did not happen. The
# marker goes on the sleep's own line or in the comment lines just above it.
#
# A fixed sleep is a call of Thread.sleep, Task.sleep, a clock's sleep(for:) or sleep(until:), sleep(, usleep( or
# nanosleep(, or a run of a run loop with run(until:) or run(mode:before:). Every date a test gives a run loop counts as
# fixed: a wait that looks again goes through the shared waits. A commented-out sleep is not a sleep.
#
# A shell or Python script that a test hands to tmux or a shell sleeps in that process, not in the test, so it is not a
# Swift sleep and passes: shell's `sleep 600` has no parenthesis, and a bare sleep( after a dot, as Python's
# time.sleep(, is not Swift's.
#
# The one exemption is the shared waits' own poll, in EXEMPT: the sleep between two looks of eventually and settled.
cd "$(dirname "$0")/.." || exit 2
EXEMPT='Packages/MuxifyCore/Sources/MuxifyTestSupport/Eventually.swift'

found=$(rg -n --no-heading --with-filename --type swift \
    -e '\b(Thread|Task)\.sleep\b' \
    -e '\.sleep\s*\(\s*(for|until):' \
    -e '(^|[^.\w])(u|nano)?sleep\s*\(' \
    -e '\.run\s*\(\s*until:' \
    -e '\.run\s*\(\s*mode:[^)]*before:' \
    Tests/MuxifyTests Tests/MuxifyCLITests Packages/MuxifyCore/Tests/MuxifyCoreTests \
    Packages/MuxifyCore/Sources/MuxifyTestSupport)
# rg exits 1 when it finds nothing. Any other failure, such as no rg (127), must not pass as a clean tree.
case $? in
0) ;;
1) exit 0 ;;
*)
    echo "check-test-sleeps.sh could not search the tests. It needs ripgrep (rg)." >&2
    exit 2 ;;
esac

files=$(printf '%s\n' "$found" | cut -d: -f1 | sort -u)
# The first input is rg's file:line:text matches; each source file with a match follows, to read its markers.
IFS='
'
# shellcheck disable=SC2086 # one file per line, split on newlines only
offending=$(printf '%s\n' "$found" | awk -v exempt="$EXEMPT" '
    NR == FNR {
        file = $0; sub(/:.*/, "", file)
        rest = substr($0, length(file) + 2); line = rest; sub(/:.*/, "", line)
        if (file != exempt) match_at[file ":" line] = 1
        next
    }
    FNR == 1 { above_marked = 0 }
    {
        comment = $0 ~ /^[ \t]*(\/\/|\/\*|\*)/
        marked = index($0, "// absence:") > 0
        if (!comment && (FILENAME ":" FNR) in match_at && !marked && !above_marked) {
            code = $0; sub(/^[ \t]+/, "", code)
            printf "%s:%d: a fixed sleep without an \"// absence:\" marker: %s\n", FILENAME, FNR, code
        }
        # A marker counts for the line after a run of comment lines that holds it.
        above_marked = comment ? (above_marked || marked) : 0
    }' - $files)
status=$?
[ $status -eq 0 ] || { echo "check-test-sleeps.sh could not read the tests." >&2; exit 2; }

if [ -n "$offending" ]; then
    printf '%s\n' "$offending"
    echo "A test waits for a signal with the shared waits, never for a fixed time. Sleep only before asserting that something did not happen, with an \"// absence:\" comment that says why. See docs/testing.md." >&2
    exit 1
fi
