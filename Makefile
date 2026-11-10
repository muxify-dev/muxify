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

.PHONY: all setup tools project build test test-release verify verify-gate compare run install release clean

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

test-release:
	python3 -m unittest discover -s Tests/ReleaseTests -v

SUITE ?= $(basename $(notdir $(wildcard scripts/verify/suites/*.py)))

# Runs the suites, then the gate. With SUITE= it is a subset run, which never satisfies the gate.
# ARGS="--repeat N --shuffle" runs the selection N times, each time in a random check order.
# SESSIONS_LIST=appkit or SESSIONS_LIST=swiftui makes every suite launch the app with that Sessions list
# (docs/adr/0074-an-area-leaves-swiftui-for-appkit-only-where-swiftui-caused-bugs.md). Such a run never satisfies
# the gate either. Without it, a suite gets the app's default.
verify: build
	MUXIFY_VERIFY_SESSIONS_LIST=$(SESSIONS_LIST) python3 -m scripts.verify.run $(ARGS) $(SUITE)

# Passes only when the last full make verify passed on this exact tree.
verify-gate:
	python3 -m scripts.verify.gate

# Shows each scene in the SwiftUI Sessions list and in the AppKit one, fails when their rows differ, and writes the
# report build/verify/compare/index.html (scripts/verify/README.md, "The compare run"). SCENE="cards hints" runs
# these scenes. SELF=1 shows each scene twice in the SwiftUI list, which proves the run itself.
compare: build
	python3 -m scripts.verify.compare $(if $(SELF),--self) $(SCENE)

# CONFIG=path/to/config.yaml starts a new copy of the app with that Config, through MUXIFY_CONFIG.
run: build
	$(if $(CONFIG),open -n --env "MUXIFY_CONFIG=$(if $(filter ~%,$(CONFIG)),$(CONFIG),$(abspath $(CONFIG)))" $(APP),open $(APP))

release:
	BUILD_NUMBER="$(or $(BUILD_NUMBER),1)" ./scripts/package-release.sh "$(TAG)"

install: project
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Release -destination "platform=macOS,arch=arm64" \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages $(XCODEBUILD_SETTINGS) -quiet CODE_SIGN_IDENTITY="$(MUXIFY_SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(MUXIFY_DEVELOPMENT_TEAM)" build
	$(if $(filter -,$(MUXIFY_SIGN_IDENTITY)),./scripts/sign-local.sh "$(RELEASE_APP)")
	rm -rf "$(INSTALL_DIR)/Muxify.app"
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/"

clean:
	rm -rf build Muxify.xcodeproj
