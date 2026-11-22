#!/usr/bin/env bash
# Runs a command while a CPU hog keeps every core busy, as a CI runner is busy, and exits with the command's status.
# Usage: with-cpu-hog.sh COMMAND [ARGUMENT...]. make test-stress and the stress mode of make test-linux run their tests
# through it (docs/testing.md).
#
# The hog is one busy loop per online core. They stop by PID when the command ends, also when it fails or the run is
# interrupted, and each loop also stops by itself once this script is gone, so a killed script leaves none behind.
set -uo pipefail

[ $# -gt 0 ] || { echo "usage: with-cpu-hog.sh COMMAND [ARGUMENT...]" >&2; exit 2; }

cores="$(getconf _NPROCESSORS_ONLN)"
hogs=()
cleanup() {
  [ ${#hogs[@]} -gt 0 ] && kill "${hogs[@]}" 2>/dev/null
  wait "${hogs[@]}" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for ((core = 0; core < cores; core++)); do
  (
    while kill -0 $$ 2>/dev/null; do
      for ((spin = 0; spin < 200000; spin++)); do :; done
    done
  ) &
  hogs+=($!)
done
echo "with-cpu-hog.sh: $cores busy loops (PIDs ${hogs[*]})" >&2

# The command runs in the background so that a signal to this script stops it and the hog at once: bash would run the
# trap only after a command in the foreground had ended.
"$@" &
command=$!
trap 'kill -TERM "$command" 2>/dev/null; wait "$command"; exit 130' INT TERM
wait "$command"
