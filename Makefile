APP := build/Build/Products/Debug/Muxify.app
RELEASE_APP := build/Build/Products/Release/Muxify.app
INSTALL_DIR ?= /Applications
# Ad-hoc by default, and make install re-signs with a local self-signed
# certificate. Name a certificate and its team to sign every build instead.
# A certificate lets macOS keep Local Network, Accessibility and Input
# Monitoring grants across rebuilds.
MUXIFY_SIGN_IDENTITY ?= -
MUXIFY_DEVELOPMENT_TEAM ?=
# xcodebuild passes the terminal width to clang as -fmessage-length, and clang
# puts it in each SDK module's hash. A build after a terminal resize then plans
# two variants of each module in build/ and fails with "unexpected variant
# during dependency scanning". A fixed length makes the hash the same.
XCODEBUILD_SETTINGS := diagnostic_message_length=0
# More settings for the xcodebuild of make build and make test, empty unless the caller names some. CI turns on
# Xcode's compilation cache with it.
XCODEBUILD_EXTRA_SETTINGS ?=
# The xcodebuild test run of make test and make test-stress. xcodebuild gives a test only the variables named
# TEST_RUNNER_<name>, as <name>; env leads so that make test-stress can run the whole line under its CPU hog.
XCODEBUILD_TEST = env TEST_RUNNER_MUXIFY_REQUIRE_TMUX="$$MUXIFY_REQUIRE_TMUX" TEST_RUNNER_MUXIFY_TEST_TIME_SCALE="$$MUXIFY_TEST_TIME_SCALE" \
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Debug -destination "platform=macOS,arch=arm64" \
	-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages $(XCODEBUILD_SETTINGS) $(XCODEBUILD_EXTRA_SETTINGS) test
# The iterations of make test-stress and of make test-linux STRESS=1 (docs/testing.md).
STRESS_ITERATIONS ?= 5
STRESS_ONLY ?=

.PHONY: all setup tools project build test test-stress test-linux test-live-linux test-release test-update sparkle release-secrets verify verify-gate run install release host-cli host-cli-linux host-cli-darwin clean

all: build

setup: tools
	@if [ ! -f vendor/ghostty/lib/libghostty.a ] || \
	    [ ! -f vendor/ghostty/include/ghostty.h ] || \
	    [ ! -f vendor/ghostty/build-info.json ] || \
	    [ ! -f vendor/ghostty/resources/terminfo/78/xterm-ghostty ] || \
	    [ ! -d vendor/ghostty/resources/ghostty/themes ] || \
	    [ ! -f vendor/ghostty/resources/ghostty/shell-integration/zsh/ghostty-integration ]; then \
		./scripts/setup-ghostty.sh; \
	fi

tools:
	command -v xcodegen >/dev/null || brew install xcodegen

project: setup
	xcodegen generate --quiet

build: project
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Debug -destination "platform=macOS,arch=arm64" \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages $(XCODEBUILD_SETTINGS) $(XCODEBUILD_EXTRA_SETTINGS) -quiet CODE_SIGN_IDENTITY="$(MUXIFY_SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(MUXIFY_DEVELOPMENT_TEAM)" build

test: project
	./scripts/check-folder-paths.sh
	./scripts/check-palette-structure.sh
	./scripts/check-test-sleeps.sh
	# The verify runner's own tests (scripts/verify/test_run.py). They never launch the app, so they run here, not in make verify.
	python3 -m unittest scripts.verify.test_run
	# xcodebuild's parallel output names a failed test but not why, so a failed run prints each failure's message and
	# line from the result bundle.
	$(XCODEBUILD_TEST) || { status=$$?; ./scripts/print-test-failures.py; exit $$status; }

# make test's xcodebuild test run, without the lints and the Python unittests, with the time scale 3, a CPU hog on every
# core, twice the core count of test workers, and STRESS_ITERATIONS iterations that stop at the first failure. It never
# retries. STRESS_ONLY names one test target, class or test, as -only-testing does: MuxifyCoreTests/EventuallyTests.
test-stress: project
	export MUXIFY_TEST_TIME_SCALE=3; ./scripts/with-cpu-hog.sh $(XCODEBUILD_TEST) \
		-parallel-testing-enabled YES -parallel-testing-worker-count $$((2 * $$(sysctl -n hw.ncpu))) \
		-test-iterations $(STRESS_ITERATIONS) -run-tests-until-failure $(if $(STRESS_ONLY),-only-testing:$(STRESS_ONLY)) \
		|| { status=$$?; ./scripts/print-test-failures.py; exit $$status; }

# swift test for the CLI and MuxifyCore on Linux, in Docker (OrbStack on a Mac) with the Swift image of make host-cli,
# tmux and git, and MUXIFY_REQUIRE_TMUX=1. TEST_LINUX_PLATFORM=linux/amd64 picks another architecture than the host's.
# MUXIFY_TEST_TIME_SCALE reaches the tests as make test passes it. STRESS=1 is the stress mode: the time scale 3, a CPU
# hog in the container and STRESS_ITERATIONS runs that stop at the first failure; STRESS_FILTER passes swift test's
# --filter, and STRESS_PACKAGE (core, cli or both, the default) chooses MuxifyCore, the CLI or both.
test-linux:
	./scripts/test-linux.sh

# The live SSH tests (the Host CLI install and the phone's commands, and the SSH lanes) on a throwaway OrbStack
# machine per architecture, arm64 and amd64, deleted afterwards. Skips with a message without orb on PATH.
test-live-linux:
	./scripts/test-live-linux.sh

test-release:
	python3 -m unittest discover -s Tests/ReleaseTests -v

# Fetches the Sparkle 2 tools that scripts/sparkle-version.env pins into vendor/sparkle: sign_update and
# generate_keys from the release's archive, and sparkle-cli, built from the release's source.
sparkle:
	./scripts/setup-sparkle.sh

# Makes the release certificate and the Sparkle EdDSA key pair in a fresh folder, writes the public key into
# scripts/sparkle-public-key.env, and prints the gh secret set commands. Sets no secret. FORCE=1 replaces a key.
release-secrets:
	./scripts/make-release-secrets.sh $(if $(FORCE),--force)

# Proves in a throwaway run directory that Sparkle's own installer updates a self-signed Release build to the
# next build from a feed on localhost, and refuses a zip signed with another EdDSA key. Never launches Muxify.
test-update:
	./scripts/prove-update.sh

SUITE ?= $(basename $(notdir $(wildcard scripts/verify/suites/*.py)))

# Runs the suites, then the gate. With SUITE= it is a subset run, which never satisfies the gate.
# ARGS="--repeat N --shuffle" runs the selection N times, each time in a random check order.
verify: build
	python3 -m scripts.verify.run $(ARGS) $(SUITE)

# Passes only when the last full make verify passed on this exact tree.
verify-gate:
	python3 -m scripts.verify.gate

# CONFIG=path/to/config.yaml starts a new copy of the app with that Config, through MUXIFY_CONFIG.
run: build
	$(if $(CONFIG),open -n --env "MUXIFY_CONFIG=$(if $(filter ~%,$(CONFIG)),$(CONFIG),$(abspath $(CONFIG)))" $(APP),open $(APP))

# The Host CLI assets in build/host-cli: static Linux binaries built in Docker (scripts/host-cli-version.env pins it),
# a release Mac binary, and the version line that all three print. CI builds each part on its own runner:
# host-cli-linux needs only Docker, host-cli-darwin only the Mac's Swift.
host-cli:
	./scripts/build-host-cli.sh

host-cli-linux:
	./scripts/build-host-cli.sh linux

host-cli-darwin:
	./scripts/build-host-cli.sh darwin

# TAG=tip (the default) packages a Tip Build, TAG=vX.Y.Z or vX.Y.Z-beta.N a Release, into build/releases/<tag>.
# It signs with the identity MUXIFY_RELEASE_IDENTITY names, from the unlocked keychain MUXIFY_RELEASE_KEYCHAIN.
release:
	./scripts/package-release.sh "$(or $(TAG),tip)"

install: project
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Release -destination "platform=macOS,arch=arm64" \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages $(XCODEBUILD_SETTINGS) -quiet CODE_SIGN_IDENTITY="$(MUXIFY_SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(MUXIFY_DEVELOPMENT_TEAM)" build
	$(if $(filter -,$(MUXIFY_SIGN_IDENTITY)),./scripts/sign-local.sh "$(RELEASE_APP)")
	rm -rf "$(INSTALL_DIR)/Muxify.app"
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/"

clean:
	rm -rf build Muxify.xcodeproj
