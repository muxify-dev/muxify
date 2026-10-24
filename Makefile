APP := build/Build/Products/Debug/Muxify.app
RELEASE_APP := build/Build/Products/Release/Muxify.app
INSTALL_DIR ?= /Applications
# Ad-hoc by default. Name a certificate and its team, and macOS keeps
# Accessibility and Input Monitoring grants across rebuilds.
MUXIFY_SIGN_IDENTITY ?= -
MUXIFY_DEVELOPMENT_TEAM ?=

.PHONY: all setup tools project build test test-release verify verify-gate run install release clean prototype-sidebar-swipe

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
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages -quiet CODE_SIGN_IDENTITY="$(MUXIFY_SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(MUXIFY_DEVELOPMENT_TEAM)" build

test: project
	./scripts/check-folder-paths.sh
	swift test
	swift test --package-path Packages/MuxifyCore
	# xcodebuild gives a test only the variables named TEST_RUNNER_<name>, as <name>.
	TEST_RUNNER_MUXIFY_REQUIRE_TMUX="$$MUXIFY_REQUIRE_TMUX" xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Debug -destination "platform=macOS,arch=arm64" \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages test

test-release:
	python3 -m unittest discover -s Tests/ReleaseTests -v

SUITE ?= $(basename $(notdir $(wildcard scripts/verify/suites/*.py)))

# Runs the suites, then the gate. With SUITE= it is a subset run, which never satisfies the gate.
# ARGS="--repeat N --shuffle" runs the selection N times, each time in a random check order.
verify: build
	python3 -m scripts.verify.run $(ARGS) $(SUITE)

# Passes only when the last full make verify passed on this exact tree.
verify-gate:
	python3 -m scripts.verify.gate

# A separate app, Config and throwaway tmux server; Ctrl-C cleans up only this demo.
prototype-sidebar-swipe: build
	python3 -m scripts.verify.sidebar_swipe_prototype

# CONFIG=path/to/config.yaml starts a new copy of the app with that Config, through MUXIFY_CONFIG.
run: build
	$(if $(CONFIG),open -n --env "MUXIFY_CONFIG=$(if $(filter ~%,$(CONFIG)),$(CONFIG),$(abspath $(CONFIG)))" $(APP),open $(APP))

release:
	BUILD_NUMBER="$(or $(BUILD_NUMBER),1)" ./scripts/package-release.sh "$(TAG)"

install: project
	xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Release -destination "platform=macOS,arch=arm64" \
		-derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages -quiet CODE_SIGN_IDENTITY="$(MUXIFY_SIGN_IDENTITY)" DEVELOPMENT_TEAM="$(MUXIFY_DEVELOPMENT_TEAM)" build
	rm -rf "$(INSTALL_DIR)/Muxify.app"
	cp -R "$(RELEASE_APP)" "$(INSTALL_DIR)/"

clean:
	rm -rf build Muxify.xcodeproj
