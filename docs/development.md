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
Status, its Unread flag and the `notifications` switches. `TopicsModel` computes
every mark once: `agentMarks` for each Agent by Pane ID, `Row.mark` for each
Topic or Locked Session card, and `sessionMarks` for each Session card in
Sessions mode. A group's mark is its strongest member's. Do not decide a mark
anywhere else.

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

Motion that runs every frame goes through Core Animation, never through SwiftUI
state ([ADR 0074](adr/0074-motion-that-runs-every-frame-goes-through-core-animation.md)).
The App Window is one SwiftUI view tree, and a value that changes every frame,
from a SwiftUI clock (`TimelineView`, `repeatForever`, `phaseAnimator`), a
trackpad gesture or a spring on `@State`, updates and lays out all of it on every
frame. So motion lives in layers that Muxify owns, and SwiftUI hears only where
it begins and ends:

- Core Animation moves both Working marks, in layers that SwiftUI places once.
  With an Agent at work, a SwiftUI clock kept the main thread busy almost all
  the time. The `working_marks` verify suite checks that the app stays idle
  while Working marks move.
- The Sidebar pager hosts the Topics page and the Sessions page each in its own
  `NSHostingView` (`SidebarPages`). A swipe sets their layers' transform and
  opacity, and the settle is a `CASpringAnimation` (`SidebarSlide`). SwiftUI
  hears only the committed mode. A layer transform is invisible to SwiftUI
  geometry, hit-testing and accessibility frames, so a page takes no click or
  hover while it moves, and a verify check reads the pager's Debug position,
  not a row's frame.

`ui.pulse: false` and Reduce Motion keep every Working mark still. The
`ContentView` sets the environment values once, and the Command Palette is an
overlay inside it, so the Sidebar and the Palette always agree. A terminal bell
is not an Agent mark: it is a gray `bell.fill` symbol. None of these rules
changes the Status or Unread Pane options.

### Sidebar cards on a switch

A switch between Sessions or Topics rebuilds `topics` and the Sidebar Formats
and moves `selectedWindowID`. Both lists stay mounted, and neither is lazy, so
anything a switch makes every card do, it does for every card of both lists.

- A card or row does not read `topics`, `sidebarFormatContexts`,
  `selectedWindowID` or `openSessionCards` in its body. Its list reads them
  once, into a `SessionCardState`, `TopicCardState` or `SidebarRowState` in
  `UI/SidebarCardState.swift`, and the card is `Equatable` on those values, so
  a card whose values did not change does not update. Its actions still call
  the store.
- A move of the selection animates only on its own. `SwitchPace` tells the
  cards' open and close, the scroll to the selected card and the border's turn
  when the move came in a quick run of switches; then they change at once.
  Each frame of those animations lays out the cards again, and in a quick run
  each switch cut the last one's animations short.

## Build

Requires macOS 14+ on Apple silicon, Xcode 26+, and Homebrew. Running the app
also requires `tmux`.

```sh
make run       # vendor libghostty, generate the Xcode project, build and open
make install   # install a Release build into /Applications (or INSTALL_DIR)
```

`make host-cli` builds the `muxify` CLI as static Linux binaries,
`build/host-cli/muxify-linux-aarch64` and `muxify-linux-x86_64`. It needs
Docker (OrbStack's on a Mac) and builds in the Swift image with the Swift
Static Linux SDK that `scripts/host-cli-version.env` pins. The SDK and the
Linux build folder stay in the `muxify-host-cli-cache` Docker volume, so a
second run is fast; `docker volume rm muxify-host-cli-cache` starts afresh.
`make host-cli` also builds `muxify-darwin-arm64` and writes `version`, the
line that every binary's `muxify --version` prints. `make host-cli-linux` and
`make host-cli-darwin` build one part each, so CI builds the Linux binaries on
Ubuntu and the Mac binary on macOS. On every push to `master`, CI checks each
binary against `version` and replaces the four assets of the rolling
prerelease `cli-latest`, and moves its tag to the commit.

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

Diagnostics is on by default, in Release builds too, so that the evidence for a
freeze, a crash or too much CPU exists before anyone notices the problem. The
Local Config can turn it off; a remote Config can neither turn it on nor off.
Like the rest of the Config, it applies when you save the file, with no
restart.

```yaml
diagnostics:
  enabled: false        # on by default
  display_links: true   # off by default
```

The app then writes to `~/Library/Logs/Muxify/`:

- `muxify-YYYY-MM-DD.log`, one Diagnostics log file a local day: the first line
  after local midnight goes into the next day's file. It holds the launch, or
  `on` and `off` when the Config turns it on or off, with the crash, hang and
  CPU reports macOS wrote for the app since the newest day file was last
  written; each freeze of the main thread over a second; a `minute` record
  each minute (below); Muxify's own messages and the errors the system logged
  for the app; and the app, window, Space, screen and sleep changes.
- A record is one line that a program can read: the timestamp, a kind word
  (`minute`, `burst`, `freeze`, `digest` or `limit`), then space-separated
  `key=value` fields. A value holds no spaces, a list is comma-separated, and
  a pair in a list is `name:value`. `DiagnosticsRecord` in MuxifyCore writes
  and parses them. The other lines are free text.
- The `minute` record's fields, in this order:
  - `cpu.app.avg` and `cpu.app.peak`: the app's average CPU over the minute
    and its highest one-second CPU, in % of one core. The app reads its CPU
    once a second, so a short spike shows in the peak.
  - `main.busy`: the share of the minute, in %, that the main run loop was
    awake, from after-waiting to before-waiting.
  - `mem.app`: the app's memory (phys footprint) in MB; `threads`;
    `open_files`.
  - `input`: `idle`, or
    `keys:N,clicks:N,scrolls:N,sidebar_switches:N,palette_opens:N`: the key
    presses, clicks and scroll events the app received, and the Sidebar mode
    switches and Command Palette opens they made. Counts only, never which
    key, text, a title or a URL.
  - `window`: the App Window, `visible` or `occluded` and `active` or
    `inactive`, as `visible,active`; `none` with no App Window.
  - `working_marks`: the Working marks of the Active Environment's Agents;
    `marks_move`: `true` when `ui.pulse` is on and Reduce Motion is off.
  - `sidebar`: the Sidebar mode shown, `topics` or `sessions`; `topic_cards`
    and `session_rows`: the Topic cards and Session rows it lists.

  The `window` to `session_rows` fields are the state at the end of the
  minute, in the focused App Window.
- When a day's file opens, every Diagnostics log file last written over 7 days
  ago is deleted, the older `muxify.log` and `muxify.1.log` too.
- Once a day's file passes 50 MB, it writes one `limit` line, and for the rest
  of that day takes only the `minute`, `burst`, `freeze` and `digest` lines.
- `diagnostics.display_links: true` adds the display-link probe. Its
  `animation` and `display link` lines follow each AppKit animation and the
  display links it leaves running: thousands of those links freeze the app on
  a Space switch. It writes a line for each animation and once filled 20 MB in
  an hour, so it is off by default. The `sidebar_pager_scroll` verify suite
  turns it on.
- `freeze-<time>.txt`: a `sample` of every thread, started a second into a
  freeze, and `cpu-<time>.txt`, started after a minute over half a core. The
  folder keeps the newest 20.

To find the trouble, start with
`grep -E "freeze|LEAK|stuck|report|system log|limit" ~/Library/Logs/Muxify/muxify-*.log`.
`grep " minute " ~/Library/Logs/Muxify/muxify-*.log` gives the minutes.
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
