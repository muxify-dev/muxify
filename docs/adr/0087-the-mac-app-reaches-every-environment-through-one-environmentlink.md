# The Mac app reaches every Environment through one EnvironmentLink

Today each App Window's `WorkspaceStore` decides at about 70 places whether its Environment is remote. It reaches tmux through `TmuxConnection`, which runs raw tmux and `/bin/sh` scripts here or over `RemoteSSH` execs. It reads Topic records through its own `TopicWatcher` on the Mac's `muxify.db`, and builds one of two `EnvironmentService`s, a local one and a remote one without Topics. The Git View hands its shell scripts to the store. We decide that each App Window holds one `EnvironmentLink` for its Active Environment and reaches that machine only through it. The link offers the typed commands and subscriptions of [ADR 0085](0085-muxify-reaches-a-host-only-through-typed-commands-and-subscriptions.md): commands are `async`, and each subscription is a stream of keyed events. There are three implementations. `LocalEnvironmentLink` calls MuxifyCore in-process. `HostEnvironmentLink` sends the same commands over the server's channel. `SessionsOnlyEnvironmentLink` is the fallback when no server can run. One code path then serves Local and a Host, and a feature that works locally works on a Host.

## The link

- **What it replaces.** The store's `connection`, `topicWatcher`, `topicService()` and `remoteService()`, `runGitScript`, `runGitNetworkScript` and `makeGitWatcher()`. The store keeps `windows`, `records`, `openPlaces` and `config` as today, but fills them only from its link's `environment` and `config` events. UI code that read `store.topicWatcher.records` reads `store.records`.
- **Local runs the server's publisher.** `LocalEnvironmentLink` makes its `environment` events with the same MuxifyCore publisher the server runs: the control Client, the all-Sessions `refresh-client -B` subscription, `data_version`, the 5 s safety read and the per-Session diff. It replaces the store's 1 s `refresh()` poll, `TmuxEvents` and `TopicWatcher`'s 0.25 s timer. Its `repository` events come from ADR 0072's FSEvents watcher.
- **`TmuxConnection` stops being the execution seam.** For a Host it shrinks to the SSH master, the Ghostty attach command, the Client marker and `retire`/`cleanup`, owned by the link, which also opens the server's `-T` channel on that master. `run`, `runScript`, `startTerminalScript`, `pasteAttachments` and `snapshot()` become typed commands. So do `perform(_:before:)`'s raw `before` tmux list and the pending Browser `set-option` flush, which become view commands sent ahead of the request. No raw tmux argument list leaves `LocalEnvironmentLink` or the server.
- **The App Window's own Client.** `HostEnvironmentLink` sends its marker's nonce in `hello`. The server reads `@muxify_client_<nonce>` and puts `ownClient` (tty, pid), `home` and `hostName` in its `server` event. `ownClient` is null until the attach writes the marker, and the store waits, as on `.notReady` today. The server keeps today's per-command check that a `-c <tty>` view command still targets that Client. The link stamps `sourceID` on the Mac, from its own instance id and the server's `serverID`.
- **A link never changes target.** Changing the Active Environment retires the old link. Every waiting request ends `cancelled`, its subscriptions end and its channel closes. A Host link also runs today's `retire` flush and master exit. The new link's first `item`s replace `windows`, `records`, `openPlaces` and `config` whole. The store's `generation` check stays and drops any late reply from a retired link.
- **Testable without SSH.** `HostEnvironmentLink` takes its byte stream as a pair of file handles. The SSH channel is one way to get them, so tests connect it through pipes to the server's MuxifyCore code in the test process, on a throwaway tmux. Store tests use a `FakeEnvironmentLink`.

## Features, not `isRemote`

Each `!isRemote` guard becomes one of two questions.

- **`link.isOnThisMac`**, a fact about the machine: Reveal Folder, Install Extensions, the Browser finding local servers, pasting a local file URL, `Tmux.binary`, `FolderResolver` and the local Client marker.
- **`link.features.contains(.x)`**, what the Environment serves. Features are coarse: `.topics`, `.git`, `.worktrees`, and one for each later capability. `LocalEnvironmentLink` has them all. `HostEnvironmentLink` derives them from `hello`, as protocol 1's base plus the capabilities both sides declared ([ADR 0084](0084-the-mac-app-and-the-host-server-agree-on-a-protocol-and-capabilities-never-on-a-build.md)), and writes the one Diagnostics line per connect. `SessionsOnlyEnvironmentLink` has a fixed small set.

`isRemote` stays only where the UI says the window is remote: the badge, the title and the "Connecting…" state. `EnvironmentService` loses `topicsAvailable`, `scripts:` and `environmentName:`. On a Host it always runs inside the server, with Topics. Its Worktree scripts run on whatever machine it runs on, and the record drops `environment` ([ADR 0088](0088-a-muxify-worktrees-record-lives-on-the-machine-that-has-it.md)).

## The Sessions-only fallback

`SessionsOnlyEnvironmentLink` runs on today's `RemoteSSH` exec path, over the same master. It serves the snapshot, view commands, Attachment upload, the Config read and Session Path discovery. Topics, every Git View operation, `repository` and Worktrees answer `unsupported`, so their Actions are hidden and the Git View says why it is unavailable. When the server's restarts run out (3 in 60 s, [ADR 0086](0086-the-host-clis-server-lives-on-a-channel-of-the-attachments-ssh-master.md)), the store swaps `HostEnvironmentLink` for this link in place. It hands over the master and the attach without calling `retire`, and bumps `generation`. The App Window stays Sessions-only until the next attachment, which tries the server first. Nothing retries in the background.

Until the server's first state, and while it restarts, `HostEnvironmentLink` shows the Sessions of this link on the same master, so connecting is never slower than without a server. It hands it nothing else: the Config, Session Paths, uploads, requests, Git and Worktrees wait for the server. A Sessions-only App Window still runs the Session requests that need no Topic record, such as New Session and Kill Session, through an `EnvironmentService` whose state folder is empty and its own, so it never reads this Mac's Topic records; a request that needs one is refused.

## The Config

`LocalEnvironmentLink`'s `config` stream forwards the app-wide `ConfigStore`, which stays the owner of the local file. `HostEnvironmentLink`'s is the server's `config` subscription. `SessionsOnlyEnvironmentLink` reads the Config at connect, on Reload Config and when a Command Palette opens, as `RemoteConfigFile` does. A Host stream can say the Host has no Config, and then the store uses the local one (ADR 0010).

## Requests from the Host

`HostEnvironmentLink` hands each incoming `browser`, `select` and `ask` request to a handler that its own store installs ([ADR 0089](0089-host-programs-reach-the-mac-through-a-socket-of-their-own-server.md)). Nothing global on the Mac sees them.

- `browser` goes to `BrowserAgentService.handle(_:in: store)`. The local socket listener passes its consumer store.
- `select` goes to the same path as `muxify://select`, in that App Window.
- `ask` goes to the Git View's `GitPrompt` for the operation that started it.

A request that has no handler, such as an `ask` with no Git operation waiting, ends `unavailable`.

The `@muxify_open` consumer is chosen by the existing rule, `catalog.window(forEnvironment:)`, the App Window used last on that Environment. When that answer becomes a window on a Host, the Mac sends that window's server `claim_open`, and the server writes its own socket into `@muxify_browser_socket`. A window that stops being the consumer sends `release_open`. `publishBrowserSocket` stays Local-only.

## Credentials

Git fetch, push, pull and deleting a remote branch work the same on both machines. The MuxifyCore command takes an `ask(prompt, secret)` callback. It runs git with `GIT_ASKPASS` and `SSH_ASKPASS` set to the CLI's askpass helper, with `SSH_ASKPASS_REQUIRE=force`, and with a placeholder `DISPLAY` when none is set, for OpenSSH before 8.4. On a Host, the helper reaches its server's socket. Locally, `LocalEnvironmentLink` opens a one-off socket for the command and gives its path to the bundled CLI's helper in the same environment variable. `GitCredentialPrompt`'s patterns move to MuxifyCore and classify the prompt as secret or not, because askpass is not told. An unknown host key reaches the user the same way. `TerminalCommand`'s PTY prompt parsing is deleted. On a Host, the Mac sends `git_network { network, operation }`, and each question comes back as `ask { prompt, secret, operation }`, which the link hands to the Git View that started that operation; an `ask` that no operation waits for ends `unavailable`. A cancelled question makes the helper exit non-zero at once; the operation's later questions are refused at once, and a command still running a second later is stopped, so git never hangs on a question nobody answers.

## Considered Options

- **The Host path only**, with Local keeping `TmuxConnection`, `TopicWatcher` and the scripts. Rejected: two paths stay apart for good, which is what [ADR 0085](0085-muxify-reaches-a-host-only-through-typed-commands-and-subscriptions.md) set out to end.
- **A thin adapter over Local's current reads**, turning the 1 s poll, `TmuxEvents` and `TopicWatcher` into link events. It changes less of a path that works today. Rejected: two producers of one event stream, so a freshness bug on a Host never shows up locally, and the timers stay.
- **Keeping the Git View's shell scripts for the fallback**, so that the Git View still works in Sessions-only. Rejected: every Git operation would have two implementations, the MuxifyCore port and the script, for a fallback that should be rare.
- **Retrying the server in the background after the fallback.** Rejected: a server that keeps crashing would flicker the App Window between full and Sessions-only.
- **A PTY locally and askpass on a Host.** Rejected: two prompt mechanisms, which behave differently on each machine.

## Consequences

- This supersedes ADR 0041's "Credentials, also on a Remote Environment" section, and its rejection of a `GIT_ASKPASS`/`SSH_ASKPASS` helper. The reason for that rejection was that the helper "has no way back to Muxify" on a Remote Environment, and the server's socket now gives it one.
- The Local path changes as much as the Host path: the store's poll, `TmuxEvents`, `TopicWatcher`'s timer, `TerminalCommand` and the Git View's scripts all go.
- The Mac's half of the protocol is covered by tests on CI, without SSH or OrbStack.
