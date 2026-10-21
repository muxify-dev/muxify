# Testing

Run the normal suite with `make test`. Live SSH tests are skipped unless you
provide a destination with working key authentication and a verified host key.

`swift test --package-path Packages/MuxifyCore` runs only the tests of the
MuxifyCore package: Topic records and plans, Worktrees, the Config and tmux
parsing. It needs neither Xcode nor libghostty.

## Live SSH test

For an OrbStack Ubuntu VM (use its actual Linux username):

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

The live test uses the production SSH attachment, command and event paths.
It checks terminal type/true-color capabilities, client targeting, Window/Pane
mutations, Browser and Agent metadata, detach, connection-loss detection and a
fresh connection with state preserved, and background SSH shutdown that leaves
tmux Sessions and a sibling SSH connection running. Unit tests check cleanup
thread/order and deferred quit replies.
App Window tests check Environment deduplication, focused/originating-window
routing, live ⌘N and Focus Terminal overrides, native window-cycle shortcut
pass-through and isolated Browser views in hidden disposable native windows,
without starting Ghostty or connecting to tmux.
It creates and removes its own isolated remote tmux server; existing Sessions,
Agent configuration and SSH setup are left alone. It does not exercise Ghostty
rendering or the app's UI reconnect scheduler.

## Developer Tools test

Set `TEST_RUNNER_MUXIFY_TEST_WEBKIT=1` when running desktop tests to also check
the real Developer Tools frontend, page-state preservation, docking across Tab
host changes and inspector cleanup. This test opens disposable native windows.
