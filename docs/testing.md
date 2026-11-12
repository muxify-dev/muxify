# Testing

Run the normal suite with `make test`. It runs the app, MuxifyCore and CLI
tests in one `xcodebuild test`, so MuxifyCore compiles once. Live SSH tests
are skipped unless you provide a destination with working key authentication
and a verified host key.

`swift test` runs only the CLI tests.

`swift test --package-path Packages/MuxifyCore` runs only the tests of the
MuxifyCore package: Topic records and plans, Worktrees, the Config and tmux
parsing. It needs neither Xcode nor libghostty.

`make test-linux` runs both of these on Linux, in Docker (OrbStack on a Mac)
with the Swift image of `make host-cli`, git, tmux built from the release that
Homebrew gives the Mac, and `MUXIFY_REQUIRE_TMUX=1`. It uses the host's
architecture; `TEST_LINUX_PLATFORM=linux/amd64` picks another. When the host's
resolver does not answer for the Ubuntu mirrors, add
`TEST_LINUX_DOCKER_ARGS="--dns 1.1.1.1"`.

## Tests run in parallel

All three test bundles are parallelizable, locally and in CI, and xcodebuild
picks the worker count. Test classes run at the same time in separate
processes; the tests of one class run in order, in one process. So every test
owns its state:

- **Its tmux server.** Start it with an explicit socket (`-S`) and a
  `TMUX_TMPDIR` in a unique folder, such as `TestDirectory()` or a
  `/tmp/mx…-<UUID>` folder, and remove `TMUX` and `TMUX_PANE` from the
  environment of every process it starts.
- **Its temporary folder.** Make a new one with a UUID in its name, and remove
  it when the test ends.
- **Its UserDefaults suite.** Give the subject a fresh suite and remove it when
  the test ends, as the `WorkspaceStore` and `AppWindows` tests do with
  `isolatedDefaults()`. Do not save and restore keys of `UserDefaults.standard`:
  another process can read them in between.

A test never writes a fixed path that another test reads.

A timing assert runs beside other test processes, so the machine can be busy.
Give it a bound that the buggy behaviour cannot meet, not one tuned to an idle
machine: "two 2 s runs at the same time" stays below the 4 s they take one after
the other.

## Live SSH test

The live tests (`LiveSSHTests` and `LiveHostCLITests`) skip unless
`MUXIFY_SSH_TEST_HOST` and `MUXIFY_SSH_TEST_USER` name a host. A plain
`make test` and CI do not set them, so they skip there.

`make test-live-linux` runs them on OrbStack. It runs `make host-cli`, then for
arm64 and then amd64 (through Rosetta) it creates a throwaway Ubuntu machine with
a unique `muxify-live-…` name, installs tmux, git and curl, runs only the live
tests over SSH as `<machine>@orb`, and deletes the machine, also when a step
fails. It never uses or changes your own machines. Without `orb` on `PATH` it
prints a skip message and exits 0.

For any other host, set the variables yourself (use its actual Linux username):

```sh
TEST_RUNNER_MUXIFY_SSH_TEST_HOST=ubuntu.orb.local \
TEST_RUNNER_MUXIFY_SSH_TEST_USER="<user_name>" \
TEST_RUNNER_MUXIFY_SSH_TEST_IDENTITY="$HOME/.orbstack/ssh/id_ed25519" \
  make test
```

`TEST_RUNNER_` forwards these variables through Xcode to the test process.
`MUXIFY_SSH_TEST_PORT` is optional; without it, SSH config supplies the port
(otherwise 22). The live connection reads normal SSH config and forwards the agent.
Set `TEST_RUNNER_MUXIFY_SSH_TEST_REQUIRE_AGENT=1` to also verify the remote
forwarded socket can reach your agent (requires server support).

The SSH test uses the production SSH attachment, command and event paths.
It checks terminal type/true-color capabilities, client targeting, Window/Pane
mutations, Browser and Agent metadata, detach, connection-loss detection and a
fresh connection with state preserved, and background SSH shutdown that leaves
tmux Sessions and a sibling SSH connection running. Unit tests check cleanup
thread/order and deferred quit replies.
App Window tests check Environment deduplication, focused/originating-window
routing, live ⌘N and Focus Terminal overrides, native window-cycle shortcut
pass-through and isolated Browser views in hidden disposable native windows,
without starting Ghostty or connecting to tmux.
The SSH test creates and removes its own isolated remote tmux server; existing Sessions,
Agent configuration and SSH setup are left alone. It does not exercise Ghostty
rendering or the app's UI reconnect scheduler.

The Host CLI test runs the app's install over the production SSH script lane,
expects `installed <version>` and `~/.local/bin/muxify --version` to print
`build/host-cli/version`, runs the install again and expects `current`, then runs
the phone's commands (`environment show`, `topic new/show/rename/note/tag set/
add-session/session-paths/settle/reopen/start-fresh`, `browser open`) with that
`muxify`, each with JSON that names the Topic, and expects `browser tabs` to exit 1.
It gives the remote side its own `HOME` and tmux server under a fresh temporary
directory, and removes both.

The Host CLI test needs `make host-cli` first and fails with "run make host-cli"
without it. It serves `build/host-cli/` from the Mac with `python3 -m http.server`;
the host fetches it from `MUXIFY_SSH_TEST_SERVE_HOST`, by default
`host.orb.internal` (OrbStack's name for the Mac, served on loopback only). For
another host, set it to the Mac's address; the server then listens on every
interface.

## Developer Tools test

Set `TEST_RUNNER_MUXIFY_TEST_WEBKIT=1` when running desktop tests to also check
the real Developer Tools frontend, page-state preservation, docking across Tab
host changes and inspector cleanup. This test opens disposable native windows.
