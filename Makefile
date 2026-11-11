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

.PHONY: all setup tools project build test test-linux test-live-linux test-release test-update sparkle verify verify-gate run install release host-cli host-cli-linux host-cli-darwin clean

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
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages $(XCODEBUILD_SETTINGS) -quiet CODE_SIGN_IDENTITY="$(MUXIFY_SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(MUXIFY_DEVELOPMENT_TEAM)" build

test: project
	./scripts/check-folder-paths.sh
	# xcodebuild gives a test only the variables named TEST_RUNNER_<name>, as <name>.
	TEST_RUNNER_MUXIFY_REQUIRE_TMUX="$$MUXIFY_REQUIRE_TMUX" xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Debug -destination "platform=macOS,arch=arm64" \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages $(XCODEBUILD_SETTINGS) test

# swift test for the CLI and MuxifyCore on Linux, in Docker (OrbStack on a Mac) with the Swift image of make host-cli,
# tmux and git, and MUXIFY_REQUIRE_TMUX=1. TEST_LINUX_PLATFORM=linux/amd64 picks another architecture than the host's.
test-linux:
	./scripts/test-linux.sh

# The live SSH tests (the Host CLI install and the phone's commands, and the SSH lanes) on a throwaway OrbStack
# machine per architecture, arm64 and amd64, deleted afterwards. Skips with a message without orb on PATH.
test-live-linux:
	./scripts/test-live-linux.sh

test-release:
	python3 -m unittest discover -s Tests/ReleaseTests -v

# Fetches the Sparkle 2 tools that scripts/sparkle-version.env pins into vendor/sparkle: sign_update,
# generate_keys and sparkle-cli, built from the release's source.
sparkle:
	./scripts/setup-sparkle.sh

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
