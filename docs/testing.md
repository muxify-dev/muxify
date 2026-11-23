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

## Prove each behaviour once

Prove each behaviour once, at the cheapest layer that can see it. An e2e check
in `scripts/verify/` proves only what needs the running app: drawing, focus,
gestures, and tmux→app wiring. A Swift test proves the rest.

When a Swift test and an e2e check prove the same thing, keep the Swift test
and remove the check. Only `make test` and `make test-linux` run in CI;
`make verify` does not.

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
- **Its file descriptors.** Close each pipe end it makes, and let go in its
  tearDown of what holds a descriptor, such as servers and clients: XCTest keeps
  every test case to the end of the run, and on Linux a `Process` that nobody
  calls `waitUntilExit()` on is never freed, so a pipe left to deinit stays open.
  `CLIIntegrationTestCase` and the MuxifyCore classes that start a real tmux
  server run `DescriptorCheck` (MuxifyTestSupport), which fails a test that
  ends with more open descriptors than its class started with.

A test never writes a fixed path that another test reads.

A timing assert runs beside other test processes, so the machine can be busy.
Give it a bound that the buggy behaviour cannot meet, not one tuned to an idle
machine: "two 2 s runs at the same time" stays below the 4 s they take one after
the other.

## Wait for a signal, with the shared wait

A test waits for what it asserts, never for a fixed time: a busy machine can
overrun any sleep. Wait with the shared waits of `MuxifyTestSupport`, which all
three test bundles import, never with a private polling loop:

- `eventually("the hook did not run") { … }` looks at its condition every
  20 ms for up to 10 s (`timeout:` names another time) and fails the test with
  the message if it never holds. Called on the main thread, the sync form runs
  the main run loop between looks, so main-queue work can happen. An async test
  gets the async form.
- `settled("the subscription did not settle") { recorder.items }` waits until
  no new item has come for a quiet period (1.2 s, `quiet:`), up to a deadline,
  and returns the items it saw.
- `waitForTheMainQueue()` waits until the main queue has run the work queued
  on it before the call, such as the update SwiftUI queued for a change. A view
  test calls it where it would otherwise run the run loop for a short time. It
  works only in synchronous code: an async test or setUp runs in a job of the
  main queue, which runs nothing else until the job ends.

Both report a timeout through `fail:`, which defaults to `XCTFail`; a test of
the waits themselves passes its own.

### The time scale

`MUXIFY_TEST_TIME_SCALE` multiplies every deadline and quiet period of the
shared waits. Unset, empty, not a number or below 1 means 1, so a local run
fails fast. CI's test steps set it to 3, as a CI runner is slower and busier
than a Mac. `make test` forwards it to the test process (as
`TEST_RUNNER_MUXIFY_TEST_TIME_SCALE`), and `make test-linux` passes it into
Docker, so `MUXIFY_TEST_TIME_SCALE=3 make test` waits as CI waits. A bound on
elapsed time that a test keeps, where speed is the behaviour under test, goes
through `scaled(_:)` too.

## Stress a flaky test

A test that passes on a Mac and fails in CI often depends on what CI changes: a
slower, busier machine and another number of test workers. A stress run makes
those differences on purpose, so the test fails on your machine instead of on
master.

`make test-stress` runs `make test`'s `xcodebuild test`, without the lints and
the Python unittests, with:

- the time scale 3, as CI sets it;
- a CPU hog that keeps every core busy for the whole run
  (`scripts/with-cpu-hog.sh`), stopped by PID when the run ends, also when it
  fails or is interrupted;
- twice as many parallel test workers as the Mac has cores;
- 5 iterations that stop at the first failure (`-run-tests-until-failure`).

It never retries, so a pass means no test failed. A failed run prints each
failure's message and line, as `make test` does, and exits with the test run's
status. `STRESS_ITERATIONS` sets the number of iterations, and `STRESS_ONLY`
names one test target, class or test, as `-only-testing` takes it:

```sh
make test-stress STRESS_ONLY=MuxifyCoreTests/EventuallyTests STRESS_ITERATIONS=50
```

`make test-linux STRESS=1` is the same stress run on Linux: the time scale 3,
the CPU hog inside the container, and `STRESS_ITERATIONS` runs of `swift test`
that stop at the first failure. `STRESS_FILTER` passes `swift test --filter`,
and `STRESS_PACKAGE` chooses `core` (MuxifyCore), `cli` or `both` (the
default):

```sh
make test-linux STRESS=1 STRESS_PACKAGE=core STRESS_FILTER=EventuallyTests STRESS_ITERATIONS=50
```

A fix to a flaky test is proven by 50 iterations of its class under stress, on
the platform where it failed. A single pass of `make test` proves nothing about
a flaky test.

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
