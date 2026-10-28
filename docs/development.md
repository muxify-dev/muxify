# Development

## How it works

Each Muxify App Window runs a `tmux attach` client in a libghostty terminal, so
tmux draws your Windows and Panes exactly as it does in Ghostty, with your
`~/.config/ghostty/config`. A tmux control-mode client and a once-a-second poll
keep the sidebar in sync. Muxify keeps its own state (Browser Tabs and visibility,
Agent Statuses) in tmux options on the Window or Pane it belongs to, so it
survives a relaunch and goes away with the Window. Agents report their Status
through Extensions installed into each Agent's own hook or plugin system.

See [CONTEXT.md](../CONTEXT.md) for vocabulary and [ADRs](adr) for design decisions.

The Topic records and plans, the Config and the tmux runner are in the
`MuxifyCore` package in `Packages/MuxifyCore`. The app and the command line tool
both link it, so both read and change Topics with the same code.

### Agent marks

`AgentMark` in `MuxifyCore` decides the one Agent mark an Agent shows, from its
Status, its Unread flag, the `notifications` switches and whether its group is
quiet (a Snoozed Topic, or No Topic while Zen is on). `TopicsModel` computes
every mark once: `agentMarks` for each Agent by Pane ID, `Row.mark` for each
Topic or Locked Session card, and `sessionMarks` for each Session card in
Sessions mode. A group's mark is its strongest member's. A quiet group has no
mark on its card; an Agent's own row there keeps only the Working mark. Do not
decide a mark anywhere else.

The app draws a mark in two views in `UI/AgentMarks.swift`, and each takes its
color from `ui.agent_colors` through the `agentColors` environment value:

- `AgentMarkView` is the mark of a row: a Pane row, an Agents row, a Command
  Palette result and the badge on a Palette Agent's icon. A Notification is a
  dot. The Working mark is `TerminalActivityIndicator`: eight square pixels on a
  three-by-three perimeter, 10×10 pt overall, that light up clockwise in
  discrete steps. The blocks are 3 pt on Retina displays and 2 pt on 1×
  displays, with a physical pixel between blocks.
- `AgentMarkSpine` is the 3 pt bar along a card's left edge. The Working mark's
  bar fades in and out.

`ui.pulse: false` and Reduce Motion keep every Working mark still. The
`ContentView` sets the environment values once, and the Command Palette is an
overlay inside it, so the Sidebar and the Palette always agree. A terminal bell
is not an Agent mark: it is a gray `bell.fill` symbol. None of these rules
changes the Status or Unread Pane options.

## Build

Requires macOS 14+ on Apple silicon, Xcode 26+, and Homebrew. Running the app
also requires `tmux`.

```sh
make run       # vendor libghostty, generate the Xcode project, build and open
make install   # install a Release build into /Applications (or INSTALL_DIR)
```

`make build` and `make run` sign ad-hoc. macOS then sees each build as a new
app, and you must grant Local Network, Accessibility and Input Monitoring again.

`make install` re-signs the Release build with `scripts/sign-local.sh`. On first
use the script creates a self-signed "Muxify Local Signing" certificate in its
own keychain, `~/Library/Keychains/muxify-local-signing.keychain-db`, and adds
that keychain to your search list. A random password for that keychain is kept
in your login keychain. Every installed build then has the same designated
requirement, and macOS keeps the grants. If the script reports a broken
keychain, delete it with `security delete-keychain` and run `make install`
again; macOS then asks for the grants once more.

To sign every build instead, set `MUXIFY_SIGN_IDENTITY` to a certificate in your
keychain and `MUXIFY_DEVELOPMENT_TEAM` to its team ID, for example in your shell
profile. `make install` then uses that certificate and skips the script:

```sh
export MUXIFY_SIGN_IDENTITY="Apple Development"
export MUXIFY_DEVELOPMENT_TEAM="ABCDE12345"
```

The team ID is the `OU` field of the certificate, not the ID in its name. To
see it, run:

```sh
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

Use these variables only on your own Mac. Release packaging and CI always sign
ad-hoc.

Desktop build targets run `make setup` first to prepare a fresh machine: it
installs `xcodegen` with Homebrew if missing, then runs `scripts/setup-ghostty.sh`
if the library or resources are not vendored yet. The script builds the exact
commit in `scripts/ghostty-version.env`, in the ignored `vendor/ghostty-src/`
directory. It downloads that commit's exact Zig compiler with a SHA-256 check
and installs Xcode's Metal Toolchain if missing. The library, terminfo, themes,
shell integration, and upstream dependency notices are vendored together;
an installed Ghostty.app is not used.

Explicit development overrides (not accepted by release packaging):

```sh
GHOSTTYKIT=/path/to/GhosttyKit.xcframework \
  GHOSTTY_RESOURCES=/path/to/ghostty/zig-out/share \
  ./scripts/setup-ghostty.sh
GHOSTTY_SRC=~/src/ghostty ./scripts/setup-ghostty.sh    # builds it with zig
```

If a custom checkout requires another Zig version, set `ZIG=/path/to/zig`.
For prebuilt development overrides, `GHOSTTY_NOTICES=/path/to/notices.txt` can
supply the matching build's dependency notices. To refresh the default pinned
library and resources, run `./scripts/setup-ghostty.sh` without overrides.

From the installed app's **Muxify** menu, **Install Command Line Tool** links
`muxify` into `~/.local/bin`. The link points into the app bundle, so install it
from the copy you keep. Every copy of the app, Debug builds too, puts its own
bundled `muxify` first on the `PATH` of the tmux server it starts, so the link
matters only in shells outside that server. See
[Extensions](../extensions/README.md#install) for Agent setup and
[Testing](testing.md) for unit and live tests.

## Diagnostics

To find out why the app froze, crashed or used too much CPU, turn on
Diagnostics in the Config. It works in Release builds too, and costs nothing
while it is off. Like the rest of the Config, it applies when you save the
file, with no restart.

```yaml
diagnostics:
  enabled: true
```

The app then writes to `~/Library/Logs/Muxify/`:

- `muxify.log`: the launch, or `on` and `off` when the Config turns it on or
  off, with the crash, hang and CPU reports macOS wrote for the app since the
  log was last written; each freeze of the main thread over a
  second; CPU, memory, threads and open files each minute; Muxify's own
  messages and the errors the system logged for the app; and the app, window,
  Space, screen and sleep changes. Its `animation` and `display link` lines
  follow each AppKit animation and the display links it leaves running:
  thousands of those links freeze the app on a Space switch. It keeps one
  older file, `muxify.1.log`, of up to 20 MB.
- `freeze-<time>.txt`: a `sample` of every thread, started a second into a
  freeze, and `cpu-<time>.txt`, started after a minute over half a core. The
  folder keeps the newest 20.

To find the trouble, start with
`grep -E "freeze|LEAK|stuck|report|system log" ~/Library/Logs/Muxify/muxify.log`.
A verify run writes these files into its sandbox's `logs/`, never into yours.

## Beta releases

### Verify a download

Betas are ad-hoc signed, not Developer ID signed or notarized. Each release
includes `SHA256SUMS`. Download it alongside the ZIP and run:

```sh
shasum -a 256 -c SHA256SUMS
```

This checks file integrity, not the publisher's identity. No Ghostty, Zig or
Xcode installation is needed to run the desktop beta.

### Publish

The [release workflow](../.github/workflows/release-beta.yml) runs on `macos-26`
with Xcode 26.6. It caches the pinned Ghostty build, tests Muxify, builds a Release
app, verifies its ad-hoc signature, and publishes a **GitHub prerelease**, never
the latest stable release. No Apple account or signing secrets are needed.
Pull requests and pushes to `master`/`main` run the tests without publishing.
Default-branch builds warm the dependency cache that beta tags can reuse
(GitHub does not share tag-only caches between different tags).

After committing and pushing the release tooling and app changes, publish a beta:

```sh
git tag v0.1.0-beta.1
git push origin v0.1.0-beta.1
```

The version must use `vMAJOR.MINOR.PATCH-beta.N` with a positive beta number.
The app's marketing version comes from the tag and its build number from the
GitHub Actions run number. The workflow can also be dispatched manually with an
existing beta tag. It refuses to replace an existing GitHub release; use a new
beta tag instead.

To test the tooling or build the same package locally without publishing:

```sh
make test-release
make test
make release TAG=v0.1.0-beta.1 BUILD_NUMBER=1
```

Packages are written under `build/releases/<tag>/`: the ZIP, `SHA256SUMS`,
release notes, and build provenance. Dependency notices are bundled under
`Muxify.app/Contents/Resources/ThirdPartyNotices/`.
