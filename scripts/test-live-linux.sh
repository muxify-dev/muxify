#!/usr/bin/env bash
# Runs the live SSH tests (LiveHostCLITests and LiveSSHTests) against a throwaway
# OrbStack machine for each architecture: arm64, then amd64 through Rosetta.
# It builds the Host CLI assets (make host-cli) and the tests once, then for each
# architecture creates a uniquely named Ubuntu machine with tmux, git and curl,
# runs only the live tests over SSH as <machine>@orb, and deletes the machine,
# also when a step fails. It never uses or changes a machine it did not create.
#
# Without orb on PATH (CI, or a Mac without OrbStack) it prints a skip message
# and exits 0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v orb >/dev/null 2>&1; then
  echo "make test-live-linux: skipped, orb is not on PATH (it needs OrbStack)"
  exit 0
fi

ARCHS=(arm64 amd64)
ONLY_TESTING=(-only-testing:MuxifyTests/LiveHostCLITests -only-testing:MuxifyTests/LiveSSHTests)
# As make test runs xcodebuild.
XCODEBUILD=(xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Debug
  -destination "platform=macOS,arch=arm64" -derivedDataPath build
  -clonedSourcePackagesDirPath build/SourcePackages diagnostic_message_length=0)

created=()
cleanup() {
  for machine in ${created[@]+"${created[@]}"}; do
    orb delete -f "$machine" >/dev/null 2>&1 || echo "make test-live-linux: could not delete OrbStack machine $machine" >&2
  done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

make host-cli project
"${XCODEBUILD[@]}" -quiet build-for-testing "${ONLY_TESTING[@]}"

for arch in "${ARCHS[@]}"; do
  machine="muxify-live-$arch-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
  if orb list -q | grep -qx "$machine"; then
    echo "make test-live-linux: OrbStack machine $machine already exists" >&2
    exit 1
  fi
  created+=("$machine")
  echo "==> $arch: creating OrbStack machine $machine"
  orb create --arch "$arch" ubuntu "$machine"
  orb -m "$machine" -u root sh -c \
    'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq tmux git curl >/dev/null'
  echo "==> $arch: running the live tests on $machine@orb"
  # xcodebuild gives a test only the variables named TEST_RUNNER_<name>, as <name>.
  TEST_RUNNER_MUXIFY_SSH_TEST_HOST=orb \
  TEST_RUNNER_MUXIFY_SSH_TEST_USER="$machine" \
  TEST_RUNNER_MUXIFY_SSH_TEST_IDENTITY="$HOME/.orbstack/ssh/id_ed25519" \
    "${XCODEBUILD[@]}" test-without-building "${ONLY_TESTING[@]}"
  orb delete -f "$machine"
  created=()
done
echo "make test-live-linux: passed on ${ARCHS[*]}"
