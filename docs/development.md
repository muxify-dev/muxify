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

Use these variables only on your own Mac. Release packaging ignores them: it
signs with the identity that `MUXIFY_RELEASE_IDENTITY` names (see
[Releases and Tip Builds](#releases-and-tip-builds)).

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
  each minute, a `burst` record for each Burst and `digest` records for each
  sample (below); Muxify's own messages and the errors the system logged
  for the app; and the app, window, Space, screen and sleep changes.
- A record is one line that a program can read: the timestamp, a kind word
  (`minute`, `burst`, `freeze`, `digest` or `limit`), then space-separated
  `key=value` fields. A value holds no spaces, a list is comma-separated, and
  a pair in a list is `name:value`, split at its last colon, so a name may
  hold colons. `DiagnosticsRecord` in MuxifyCore writes
  and parses them. The other lines are free text.
- The `minute` record's fields, in this order:
  - `cpu.app.avg` and `cpu.app.peak`: the app's average CPU over the minute
    and its highest one-second CPU, in % of one core. The app reads its CPU
    once a second, so a short spike shows in the peak.
  - `main.busy`: the share of the minute, in %, that the main run loop was
    awake, from after-waiting to before-waiting.
  - `mem.app`: the app's memory (phys footprint) in MB.
  - `cpu.<group>.avg`, `cpu.<group>.peak` and `mem.<group>` for each of
    the other process groups, in the same units as the app's. The app is
    the first of the four groups; the others are:
    - `commands`: the processes the app starts, such as git, tmux and ssh.
      Children that exited come from the children's rusage total, and live
      children, such as `ssh` and the `tmux -C` control clients, from a
      read of each one. `sample`, Diagnostics' own sampler, is in neither,
      so taking a sample does not look like load. `mem.commands` is the
      live children's memory.
    - `webkit`: the Browser's WebContent processes, one for each loaded
      page, found through the web view's process identifier, which the app
      reads once a minute. It is a lower bound: a page can have more
      processes than the one it names, and a new page's process counts
      from the minute after it starts.
    - `tmux`: the Local tmux server. It serves all of its clients, Muxify's
      and any other, such as a terminal attached outside Muxify, so its
      load is not all Muxify's.

    A group whose read fails is left out of the record, never written as
    zero: no Browser page, no Local server, or a process another user owns.
    The app reads each group's CPU once a second, off the main thread, and
    its memory at the end of the minute. The average is over the seconds
    the group was read.
  - `threads`; `open_files`.
  - `input`: `idle`, or
    `keys:N,clicks:N,scrolls:N,sidebar_switches:N,palette_opens:N`: the key
    presses, clicks and scroll events the app received, and the Sidebar mode
    switches and Command Palette opens they made. Counts only, never which
    key, text, a title or a URL.
  - `bodies`: how many times each counted SwiftUI view's body ran over the
    minute, as `SidebarCard:300,TopicsSection:2`, by name; a name with zero
    is left out, and `none` when every count is zero. The counter
    (`BodyCount` in `App/BodyCount.swift`) is in every build and counts only
    while Diagnostics is on. The counted views are `SidebarCard`,
    `TopicCard`, `TopicsList` and `TopicsListPart`, the Sidebar page roots
    `TopicsSection` and `SessionsSection`, and the Working-mark views
    `AgentMarkView` and `AgentMarkSpine`. Diagnostics never resets the
    counter; a count that fell, after the TestDriver's `counts reset=True`,
    counts again from zero, so a figure is never negative.
  - `window`: the App Window, `visible` or `occluded` and `active` or
    `inactive`, as `visible,active`; `none` with no App Window.
  - `working_marks`: the Working marks of the Active Environment's Agents;
    `marks_move`: `true` when `ui.pulse` is on and Reduce Motion is off.
  - `sidebar`: the Sidebar mode shown, `topics` or `sessions`; `topic_cards`
    and `session_rows`: the Topic cards and Session rows it lists.

  The `window` to `session_rows` fields are the state at the end of the
  minute, in the focused App Window.
- A Burst is a stretch of high CPU that a minute's average hides, such as
  10–20 seconds of quick Sidebar swipes at about 42%. The app finds them in
  its per-second CPU (`BurstDetector` in MuxifyCore; the thresholds are
  constants there):
  - A Burst starts when the app is at or over 30% of one core for 3 seconds
    in a row, and ends after 3 seconds in a row below it. A shorter dip is
    part of the Burst.
  - When a Burst starts, the app takes a 5-second `sample` of every thread
    into `burst-<time>.txt`, off the main thread, and another every 10
    minutes while the Burst lasts. It takes at most one Burst sample a
    minute and 40 a local day; these caps start again at each launch. A
    sample the caps or a running sample hold back is tried again each second
    while the Burst lasts; a Burst that never gets one is still recorded.
  - When the Burst ends, it writes one `burst` record:
    - `start`: its local start time, as `2026-11-11T17:07:19.250`;
      `length`: in seconds, to the end of its last second over the
      threshold.
    - `cpu.avg` and `cpu.peak`: the app's average and highest one-second
      CPU over the Burst, in % of one core.
    - `main.busy.peak`: the main run loop's awake share of the Burst's
      busiest second, in %.
    - `input`: the user's input over the Burst, in the `minute` record's
      form.
    - `bodies`: the counted SwiftUI bodies that ran over the Burst, in the
      `minute` record's form.
    - `window` to `session_rows`: what was moving when the app found the
      Burst, 3 seconds in, as in the `minute` record.
    - `samples`: the sample file names, comma-separated, or `none`.
    - `open=true` only when Diagnostics stopped or the app quit while the
      Burst ran.
- After each sample, freeze and Burst alike, the app folds the sample's main
  thread off the main thread (`SampleDigest` in MuxifyCore) and writes three
  `digest` records, each with `sample`, the sample's file name:
  - `samples`: the main thread's samples; `busy`: the share, in %, not
    waiting in the run loop (`__CFRunLoopServiceMachPort` and below);
    `libraries`: the top 8 libraries by self time, as `library:%`.
  - `symbols`: the top 15 symbols by self time, as `symbol@library:%`.
  - `frames`: the top 15 frames from the app binary by inclusive time, as
    `symbol:%`. A frame that recurs on one stack path counts once.

  A frame's self time is its count less its immediate children's. Every %
  is of the busy samples, so the run loop's wait does not drown the rest. A
  symbol is shortened to one word: whitespace becomes `_`, an argument list
  that holds a space, a comma or a bracket becomes `(...)`, and it is cut at
  80 characters. An empty list is `none`. A sample the app cannot read, or
  with no main thread, gets a free-text `digest:` line instead.
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
  freeze, and `burst-<time>.txt`, taken during a Burst (above). After each
  sample, the raw `freeze-`, `burst-` and older `cpu-` files last written over
  3 days ago are deleted, and then the oldest until the rest take under
  300 MB in all (`SampleRetention` in MuxifyCore). Their `digest` records stay
  in the day's log.

To read a day, run `muxify diagnostics summary` (today) or
`muxify diagnostics summary --date YYYY-MM-DD`; `--folder PATH` reads
another folder, such as a verify sandbox's `logs/`. It prints, in this order:
the day's records, minutes and gaps (each labelled with the sleep, screens
asleep, `off` or `quit` line nearest it, or `unknown`); CPU p50, p90 and max
of each process group over idle minutes and minutes with input; the main
thread's `main.busy`; memory; the 10 worst Bursts by `cpu.avg × length` and
the freezes, each with its digest; the errors by kind; and a trend line for
each day file. It needs no running app, and it skips the lines it does not
know.

To find the trouble by hand, start with
`grep -E "freeze|LEAK|stuck|report|system log|limit" ~/Library/Logs/Muxify/muxify-*.log`.
`grep " minute " ~/Library/Logs/Muxify/muxify-*.log` gives the minutes, and
`grep " burst " ~/Library/Logs/Muxify/muxify-*.log` the Bursts, and
`grep " digest sample=burst-" ~/Library/Logs/Muxify/muxify-*.log` the digests
of their samples.
A verify run writes these files into its sandbox's `logs/`, never into yours.

## Releases and Tip Builds

### Verify a download

Builds are not yet Developer ID signed or notarized. Each one includes
`SHA256SUMS`. Download it alongside the ZIP and run:

```sh
shasum -a 256 -c SHA256SUMS
```

This checks file integrity, not the publisher's identity. No Ghostty, Zig or
Xcode installation is needed to run Muxify.

### Package

`scripts/package-release.sh` (`make release`) packages one of two kinds of build
for the updater:

- `tip` packages a **Tip Build**. Its short version
  (`CFBundleShortVersionString`) is the short commit SHA, and its ZIP is
  `Muxify-tip-<short-sha>-arm64.zip`.
- `vX.Y.Z` or `vX.Y.Z-beta.N` packages a **Release**. Its short version is the
  tag without the `v`, and its ZIP is `Muxify-<version>-arm64.zip`.

It refuses any other argument before it builds. The build number
(`CFBundleVersion`) is `git rev-list --count HEAD`, so builds on `master` are in
order. A shallow checkout would count only the commits it fetched, so the
script refuses one.

The script signs with a named identity from a named keychain, both given
through the environment. CI gives the "Muxify Release Signing" certificate, so
every build keeps one designated requirement and macOS keeps its grants across
updates. A missing identity is an error that names it; there is no ad-hoc
fallback.

```sh
export MUXIFY_RELEASE_IDENTITY="Muxify Release Signing"
export MUXIFY_RELEASE_KEYCHAIN=/path/to/release.keychain-db   # unlocked
```

The script stamps two keys into the packaged copy's `Info.plist`:
`MuxifyUpdateFeedBaseURL`, the base URL of the update feeds
(`https://github.com/muxify-dev/muxify/releases/download/appcast/`), and
`SUPublicEDKey` from `scripts/sparkle-public-key.env`. The release secrets
script fills that file once; while its key is empty, packaging refuses to run.
It stamps a copy in `build/package/`, so the Release product that
`make install` also builds stays unstamped: a Debug or `make install` build
never updates itself.

### The updater

The app links Sparkle 2 as a Swift package, at the version
`scripts/sparkle-version.env` pins, and bundles its license notice as
`ThirdPartyNotices/Sparkle.txt`; packaging refuses an app without it. The
updater exists only when `Info.plist` has `MuxifyUpdateFeedBaseURL`, where it
reads `<base>stable.xml`, or when `MUXIFY_UPDATE_FEED_URL` names a feed, which
also turns it on in a Debug build. Without either there is no updater, no
**Check for Updates** Command and no **Check for Updates…** menu item.
`Sources/Muxify/Updates/` holds it: Sparkle's `SPUUpdater` with Muxify's own
user driver, which feeds the one `UpdateModel` that every App Window's Update
Button shows (ADR 0077). Each check and its result go to the Diagnostics log as
`update:` lines.

The local Config's `update` section drives the background checks: with
`update.check` true, the default, `UpdateModel` runs one at launch, the first
launch included, and then every 24 hours by the wall clock, looking once an
hour. Sparkle's own schedule stays off (`SUEnableAutomaticChecks` is false). A
background check shows only "Update Available", and Sparkle leaves out a version
the user skipped; a check that finds nothing or fails changes nothing on screen
and goes only to the Diagnostics log. `update.channel` picks `<base>stable.xml`
or `<base>tip.xml`, which Sparkle asks for through its delegate at each check;
`MUXIFY_UPDATE_FEED_URL` replaces either. `ConfigStore` applies the section at
each reload: turning `check` off stops the schedule, turning it on starts it
with a check, and a changed channel checks at once. A remote Config's `update`
is ignored. Moving from `tip` to `stable` keeps the Tip Build until a Release
has a higher build number, since Sparkle never offers a lower one.

An update downloads only after Install and Relaunch: `SUAutomaticallyUpdate`
and `SUAllowsAutomaticUpdates` are false. The Update Button then shows
"Downloading: N%", "Preparing: N%" and "Installing…". Sparkle's installer quits
Muxify with a quit Apple event, which runs the same `applicationShouldTerminate`
cleanup as ⌘Q, and relaunches the new copy. A failed download, a zip whose
signature does not verify and a failed install show "Update Failed" with
Sparkle's message; a translocated or read-only copy shows "Move Muxify to
Applications to update it." The download, the install and each failure go to
the Diagnostics log too.

Sparkle's updater does not start on an `http` feed without `SUPublicEDKey`, so a
Debug build carries the test key in `scripts/sparkle-debug-public-key.env`
(`scripts/stamp-debug-update-key.sh`). Its private half,
`scripts/verify/fixtures/sparkle-test-ed-key`, signs only test feeds.
`make verify SUITE=update` serves a feed over `http` from its run directory
and drives the Update Button and the Update Popover against it, with
`update.check: false` so that no background check races the checks. A second
app with the default Config proves that the launch and a channel change show
the Update Button by themselves, and that Focus and the front app stay. One check
presses Install and Relaunch on a zip that is not signed with the test key: it
sees the download's progress, then "Update Failed", and the app is unchanged and
still running. No check installs an update, which would relaunch the app.

### Feeds and release secrets

`scripts/write-feed.py` writes a Sparkle feed with exactly one item for one ZIP:
`--channel stable` for a Release, whose `--notes-url` is its release page, or
`--channel tip` for a Tip Build, whose `--notes-url` is its commit page. It also
takes `--zip`, `--build` (the build number), `--version` (a Release's version, or
a Tip Build's short commit SHA), `--date` (ISO 8601 with a time zone),
`--download-url` and `--output`. A Tip Build's item shows
`<short-sha> (<yyyy-mm-dd>)`. The script reads the EdDSA private key on its
standard input and pipes it to `sign_update --ed-key-file -`; if `sign_update`
fails, it writes no feed. It finds `sign_update` on `PATH` or in
`vendor/sparkle` (`make sparkle`).

```sh
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | scripts/write-feed.py --channel tip ... --output tip.xml
```

`make release-secrets` (`scripts/make-release-secrets.sh`) makes the release
secrets once, in a fresh folder it names: the "Muxify Release Signing"
certificate as a base64 `.p12` with its random password, and an EdDSA key pair
made with `generate_keys --account muxify-release`, whose private key it
exports. It writes the public key into `scripts/sparkle-public-key.env`, and
prints the `gh secret set` commands for `SPARKLE_ED_PRIVATE_KEY`,
`MUXIFY_RELEASE_CERTIFICATE_P12` and `MUXIFY_RELEASE_CERTIFICATE_PASSWORD`. It
sets no secret. Back up the private key: losing it ends every update. If the
public-key file already holds a key, it refuses; `make release-secrets FORCE=1`
replaces it, and every installed copy then stops updating.

To test the tooling or build a package locally without publishing:

```sh
make test-release
make test
make release              # a Tip Build; TAG=tip is the default
make release TAG=v0.1.0   # a Release
```

To sign a local package with your own certificate, set
`MUXIFY_RELEASE_IDENTITY="Muxify Local Signing"` and
`MUXIFY_RELEASE_KEYCHAIN=~/Library/Keychains/muxify-local-signing.keychain-db`
after `make install` has made it.

Packages are written under `build/releases/<tag>/` (`build/releases/tip/` for a
Tip Build): the ZIP, `SHA256SUMS`, release notes, and `build-info.json`, which
records the build number, short version, signing identity and commit.
Dependency notices are bundled under
`Muxify.app/Contents/Resources/ThirdPartyNotices/`.

### Publish

The [release workflow](../.github/workflows/release.yml) runs on `macos-26`
with Xcode 26.6 and publishes everything to GitHub (ADR 0078). Its `build` job
checks out full depth, caches the pinned Ghostty build and tests Muxify. Pull
requests, and pushes to `main`, stop there: they never read the release secrets
or package. Default-branch builds warm the dependency cache that tags can reuse
(GitHub does not share tag-only caches between different tags).

On a push to `master` or a `v*` tag, the `build` job then imports the "Muxify
Release Signing" certificate into a temporary keychain, packages with
`scripts/package-release.sh`, writes the feed with `scripts/write-feed.py`
(`sign_update` needs macOS) and uploads the ZIP, its feed, `SHA256SUMS`,
`build-info.json` and the release notes as the `package` artifact. Ubuntu jobs
publish it:

- **A Tip Build** comes from every push to `master`. `publish-tip` uploads its
  ZIP to the rolling `tip` prerelease, moves the `tip` tag to the commit,
  deletes all but the ten newest `Muxify-tip-*` ZIPs, then uploads `tip.xml` to
  the rolling `appcast` prerelease. It is independent of `publish-cli`, which
  publishes the Host CLI to `cli-latest` (ADR 0076) as long as the tests pass,
  even when packaging fails.
- **A Release** comes from a `vX.Y.Z` or `vX.Y.Z-beta.N` tag whose commit is on
  `master`; the `build` job refuses any other tag. `publish` creates the GitHub
  release with the ZIP, `SHA256SUMS` and `build-info.json`. Its notes are the
  install section, then GitHub's generated notes since the previous `v*` tag. A
  plain `vX.Y.Z` becomes the repository's Latest release; a beta is a
  prerelease that is never Latest. Then it uploads `stable.xml` to `appcast`.

`tip`, `appcast` and `cli-latest` are prereleases that are never Latest, and
both publish jobs create theirs when missing. Each job uploads its ZIP before
its feed, so a copy that reads a new feed always finds its ZIP. `publish-tip`
and `publish` share the concurrency group `appcast`. GitHub keeps only one
pending job per group, so a queued job can be cancelled by a newer one; rerun a
cancelled `publish` from the Actions page.

To cut a Release, push its commit to `master` first, then tag it:

```sh
git push origin master
git tag v0.1.0            # or v0.1.0-beta.1
git push origin v0.1.0
```

The workflow can also be dispatched manually with an existing tag. It refuses
to replace an existing GitHub release; use a new tag instead.

The workflow needs three repository secrets, and a job that packages fails with
the name of any that is missing:

- `SPARKLE_ED_PRIVATE_KEY`: the EdDSA private key that signs every ZIP for
  Sparkle.
- `MUXIFY_RELEASE_CERTIFICATE_P12`: the "Muxify Release Signing" certificate and
  key, as a base64 `.p12`.
- `MUXIFY_RELEASE_CERTIFICATE_PASSWORD`: the `.p12`'s password.

`make release-secrets` makes all three once, writes the public key into
`scripts/sparkle-public-key.env`, which you commit, and prints the `gh secret
set` commands to run (see [Feeds and release secrets](#feeds-and-release-secrets)).
Until the public key is committed, packaging refuses to run, so `master` builds
publish the Host CLI but no Tip Build.
