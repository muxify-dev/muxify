# The Environment module

This document collects the decisions about the Environment module and says what each one means for Muxify. [ADR 0046](adr/0046-one-environment-module-for-each-environment.md) records why each decision was made. This document adds the plan and the work each decision causes.

## The idea in one paragraph

Each Environment gets one module that is the only way to see and change it. The module runs on the machine that has the tmux server, as `muxify environment watch`. The app, the phone app and later readers talk to it with one protocol: JSON lines on stdin and stdout. For Local, the app starts `watch` as a child process. For a Remote, the app copies its own `muxify` to the remote and starts `watch` there over the terminal's SSH master. The module keeps one promise: the next state a reader sees includes every change it sent.

## Decisions and what they mean

| Decision | What it means for us |
|---|---|
| **One module for each Environment.** It reads tmux and the Topic records, does every write, and runs the rules. | `WorkspaceStore` keeps only the work of one screen. Two App Windows on Local stop reading tmux twice and stop writing Unread twice. A bug like "my change did not show" has one place to look. |
| **Every write is an `EnvironmentRequest`**, including `select-pane`, `split-window`, `resize-pane`, `new-window`, `switch-client` and Browser state writes. `EnvironmentService` becomes internal. | Every raw tmux write in the app must become a request. The Browser bug, where a Remote App Window sends Browser commands to Local (`WorkspaceStore.swift:714`), goes away. |
| **One protocol for Local and Remote.** The module runs next to tmux, and the app has one client for both. | You use Local every day, so every day you also test the Remote path. The rules lock, the Config of the rules and the Topic records are on the same machine as tmux. A crash of the module does not stop the app. |
| **The app copies its `muxify` to a remote**, a universal binary, to `~/.local/share/muxify/bin/<version>/muxify`. It copies only when the path is missing, and keeps the last two versions. | A Remote gets Topics and the rules, and the user installs nothing. Both ends always have the same version. The release build must contain a universal `muxify`. |
| **A remote that cannot run `muxify` gets a fallback**: the same module inside the app, with an SSH transport, behind the same protocol. | Linux remotes keep working as today, with no Topics. The two fixes to today's Remote loop go into this fallback. |
| **One revision**: the id of the module and a number. It replaces the 11 ordering flags of `WorkspaceStore`. | The Router waits for the revision of its switch. A restarted `watch` has a new id, and the reader asks for a full state. The rule "never show a read that started before a write" gets a unit test. |
| **Every Perform gives a revision, a failed one too.** The state has a connection field: no server, timeout or connection lost. | A timeout no longer looks like "tmux is not running". A request that saves the records and then fails in tmux still shows its part done. |
| **The stream sends a full state once, then only changes, with the new values.** A gap in revisions, or a new connection, asks for a full state. | A phone on a slow link gets one small line for each change. The client keeps a full state, so SwiftUI and the Router do not change how they read. |
| **Viewing facts and visits come from each reader**, the phone too. Each reader names its tmux Client. When a stream closes, its Clients view nothing. A Client that no reader names counts for nothing. | Unread is right with two windows and with the phone. No server option is needed for a phone app in the background. |
| **A visit is a request.** The module sets the visited Agents and Topic Read, when Manual Read is off. | `readTopicsOnVisit` no longer writes records past the Service. A visit on a Remote also sets the Topic Read. |
| **One rules owner for each tmux server**, through a file lock on that machine. Others only read and perform. | Unread, the upgrade of older records and Topic memory never have two writers. With no owner, no rules run, and the next owner catches up. |
| **The rules use the Config of the connecting client**, sent in the first line. A module with no settings, such as one CLI command, uses the Config file on its machine. | A remote follows your Mac's Manual Read setting. The state shows the settings in force. |
| **The last seen Status is kept in tmux**, as `@muxify_agent_seen_status`, in the same command list as the Unread change. | An Agent that finishes while Muxify is closed becomes Unread when the next owner starts. Today that change is lost. |
| **The Local `watch` lives from app launch to app quit.** It exits at the end of its stdin. The app starts a new one after a crash. | No daemon. Unread works with no App Window open. A Debug and a release build can run together: the rules lock picks one owner. |
| **A Remote `watch` lives as long as the terminal's SSH master.** | A Remote has one reader until the connection gets another owner. |
| **The CLI makes its own module for one command**, with Read now, queries and Perform only. | The CLI works when Muxify is not running, as today. |
| **The records watch stays a stamp poll**, one for each Environment. The module reloads at once after its own writes. | One poll instead of one for each App Window. The poll finds only outside writes, such as the CLI's. |
| **tmux stays visible**: Sessions, Windows and Panes stay tmux terms, and the terminal stays a real tmux Client. Two screens on one Session follow each other. | No second backend, no Pane streams, no grouped Sessions in this change. Each stays possible later. |

## The plan

Each step is one change. It passes `make build`, `make test` and the verify suites, is rebased onto `master`, and merges alone. No step changes a behavior that the user can see, except where the step says so.

0. **Prototype** (not merged): measure today's loop against `watch` for one Local App Window, two Local App Windows and one Remote. Measure CPU, the number of tmux calls, the bytes on the network, and the time from a request to the revision that shows it.

   Done for Local, on branch `environments-module-prototype`, in the commit "Measure the Environment watch protocol against Inventory polling". The results are in `prototypes/environment-watch/RESULTS.md` on that branch.
   - The revision promise held: 250 checked requests, no-ops and failures included. A request took about 28 ms at p50.
   - The CPU gain comes from one shared read, not from the protocol. At the same 1 s freshness, one reader used 0.837 CPU seconds with `watch` and 0.824 with polling, over 20 s. Two readers used 1.320 with polling and about 0.47 with one shared `watch`.
   - With a 5 s timer, `watch` used 0.485 CPU seconds for one reader. But a Status change in a Session that is not attached then took about 2.8 s to show, against about 1 s today. The tmux subscription covers only the attached Session.
   - A second run closed that gap. One subscription with an `S:` loop in its format, `#{S:#{W:#{P:#{pane_id}=#{@muxify_agent_status};}}}`, pushes Status from every Session. With the 5 s timer, Status in another Session showed in about 0.8 s at p50, against about 1.0 s for polling. One reader used 0.444 CPU seconds against 0.694 for polling in that run, and the tmux server used less too. The results are in the commit "Push Status from every Session, so a slower fallback read keeps Status fast" on the same branch.
   - Change lines cut the protocol bytes by about 95 %.
   - Remote is not measured. The SSH probe found no trusted host key for `localhost`.
1. **Inventory reader** with typed failures.
2. **The module with revisions**, behind the protocol types, still inside the app, one for each App Window. The revision replaces the 11 flags.
3. **Perform**: every write is a request, and visits are requests.
4. **Rules and the rules lock**: Unread with `@muxify_agent_seen_status`, the upgrade of older records, Topic memory, records poll.
5. **`watch` and the Local child process.** Local App Windows share one module. A verify check: two Local App Windows, and Unread is written once.

   Condition: a Status change in any Session shows within about 1 s, as today. So `watch` subscribes to Status in every Session with an `S:` loop before it reads the Inventory less often than once a second. Each other value that `watch` shows needs a named push, or the timer, which can be up to 5 s late.
6. **Remote with the copied binary, and the fallback** for a remote that cannot run `muxify`. Topics show on a Mac remote.
7. **The CLI uses the module** for one command.

Not in the plan: a Linux build of `muxify` (its own step later), a connection owner that is not the terminal, and Pane streams.

## Still open

- **Who owns a Remote connection** when it is not the terminal. Needed before a Remote has two readers. Then also: whose rule settings win with two readers.
- **Remote protocol setup**: step 6 must apply the Local version handshake and recovery rules to the copied binary and SSH connection.
- **Which verify suite each step runs** to prove that no behavior changed.

## Step 3 implementation

Each App Window still owns its Environment module. The module fixes its transport at creation and serializes typed Perform requests. Pane actions, Browser saves, client markers and visits use this path. Every response has a revision, including failures and cancelled requests. Until step 7, the CLI ran the Service directly through a temporary CLI SPI.

The app still decides Unread, Snooze, Zen and Topic memory rules. Native terminal input, SSH setup and attachment file transfer remain transport work. Attachment readiness uses a separate bounded read; it cannot publish Inventory or complete a different request.

Retirement rejects new requests, cancels queued interactive requests, and drains admitted record and Browser saves before closing the transport. It retries owned client marker removals and logs final failures. The drain has a finite admitted queue and each tmux command has a timeout. Its total time grows with that queue; it has no fixed total deadline that would discard admitted saves.

Core checks cover Remote routing, Manual Read visits, partial failure, cancellation, attachment completion and failed marker removal. The Environment Browser suite uses two isolated tmux servers with matching Window IDs. It checks Remote Browser saves, final close persistence and a Topic URL that arrives before Local starts. The app write check rejects direct Service access and raw Environment writes outside the SSH bootstrap.


## Step 4 implementation

The Environment module now owns Unread decisions, Snooze wake, Zen expiry, Topic memory, and the records stamp poll. Its serial I/O queue runs rules and Perform. A failed or cached Inventory cannot authorize a rule. A partial rule failure publishes a fresh Inventory when it can and keeps a typed rule failure in the state. The app keeps navigation, visit detection, visibility facts, and wake toasts. A successful Topic request waits for current records at a later revision before its screen continuation runs.

A Local rules owner holds a file lock keyed by the canonical tmux socket path, including while that server is stopped. Each reader has a separate lifetime lock and an atomic facts file in the shared per-user directory under `/tmp`. The owner checks each reader's server incarnation, Client PID, tty, and Window against fresh Inventory. Reader facts update independently of tmux I/O, so hiding a Terminal does not wait for a blocked Inventory read. Process exit releases its locks; the next owner ignores and removes dead reader files. Retirement drains admitted writes and flushes pending Topic memory before releasing ownership. The owner lock file stays in place.

The last observed Agent Status is `@muxify_agent_seen_status`. `~` means an observed empty Status; an absent option means no prior observation, so migration does not invent Unread. Every Read or visit acknowledgement writes the observed Status and a unique `@muxify_agent_read_version` with the Unread change. Automatic updates compare that version, the normalized Unread mark, and the server incarnation in tmux before writing. A stale rule therefore cannot undo a Read, including when Status has changed back to an earlier value. Codex uses the effective Status from its report file.

The state includes the rule settings in force. The app supplies its Mac Config. A module without supplied settings loads its local Config. The module polls record stamps every 0.25 seconds and reads Inventory at a one-second fallback interval. Its own writes reload records before the next published revision. Clock rules recheck deadlines under the record lock. Topic memory keeps its 0.3-second delay, continuous-server evidence, and expected-record comparison. Local records and Inventory are captured together under the shared Topic edit lock. Memory flush takes that lock separately, so a CLI edit cannot expose its intermediate record and tmux state to memory rules.

Step 4 follows ADR 0046's Remote fallback exception. The fallback module still runs on the Mac, with a Mac-local lock keyed by the Remote login, host, port, and socket path. Two different Macs can still run rules on the same Remote server. Step 6 moves the copied module and its lock to the server's machine. A Remote App Window also keeps a Local helper module, so Local Snooze and Zen deadlines still run when no Local App Window remains. This helper uses the same rules lock and retires with its App Window. There is no shared `watch` child process in step 4, and each App Window still has its own module. Steps 5 through 7 remain separate work. No live SSH trial was used for this step.

Core checks exercise owner contention and release, persisted Status across ownership changes, Manual Read, explicit visits, non-owner viewing, hidden facts during blocked reads, stale-rule acknowledgement races, partial failure, record polling, Zen expiry, no-server Snooze wake, and Topic memory conflicts. The app check restarts its isolated process and confirms that its next owner finds an Agent update made while no owner ran.


## Step 5 protocol and ownership

The app owns one Local `muxify environment watch` child from launch until quit. Each App Window has its own reader and display state. Closing a reader removes its viewing facts and drains its admitted saves and cleanup. It does not stop the shared child. With no App Window open, the child continues Unread and clock rules. App quit closes the stream after the readers finish. End of stdin drains the module and stops the child.

The first JSON line names protocol version 1 and the rule settings. An unknown version receives a refusal and stops automatic restart. The child admits at most 128 Perform or Query requests at once. Overload closes the stream after admitted persistence drains, then the app starts a new child. App quit waits for that drain even if stdin has already closed. A stream starts with a full state. Later changes carry field values, their revision, and the full state's base revision. Module revision numbers can skip values because request admission and completion also advance them. The reader compares the base revision, not the difference between numbers. A missing base or new module ID requires a full state. An explicit changed-value wrapper distinguishes a field that did not change from a field that becomes nil.

Perform messages carry request IDs and reader IDs. Every completed Perform returns its revision, including failure. A reader stops treating its current state as confirmed when it submits a write. A visibility change also requests a synchronization revision. The reader waits for Inventory after that revision, so an older read cannot authorize a visit. A child crash fails uncertain requests without replay. Recovery also clears app waits for receipts from the old module. The app restores readers and cleanup ownership before it accepts the replacement child's full state.

The child prepares a Terminal attachment through the module. The App Window creates its Terminal and acknowledges attachment readiness. Attachment acknowledgements, viewing facts, and reader close must remain available while a Perform waits. They must also remain available when the output reader is slow. Pending state output can become one latest full state. Perform replies and wake notifications must not disappear during this replacement.

Local Topic and Inventory queries use typed messages too. Kill review and Move Pane read Inventory through the shared child. Published and queried Windows use the module ID and tmux server ID as their source identity. A child or server restart changes that identity, so an old selection cannot match a replacement Window with the same tmux ID. Local tmux commands retain their 10-second timeout.

The shared connection replaces the Local companion modules that Remote App Windows previously kept. Remote Environment requests still use the existing in-process fallback. Steps 6 and 7 later moved Remote binary copying and the ordinary CLI.

The Local child keeps a one-second Inventory fallback. The prototype's all-Session tmux subscription covers pane option Status, but Codex Status also comes from report files. That subscription alone does not justify a five-second fallback in production.

| Published value | Refresh source in step 5 |
| --- | --- |
| Sessions, Windows, Panes, Client locations, and layout | The shared tmux control events and the one-second Inventory fallback. |
| Agent identity, Status, Unread, and seen Status | The one-second Inventory fallback, including Codex report files. Own writes request a fresh read. |
| Pane command lines and remembered Session details | Command-line discovery with the shared Inventory read. |
| Topic records, Snooze, Zen, and Topic memory | The module's 0.25-second records and rules poll, plus reads after its own writes. |
| Branches and connection failures | The shared Inventory and rules read. |
| Rule settings, ownership, and rule failures | The next module read after settings or ownership changes. |
| Wake notifications | Rule execution and delivery to each reader, with duplicate suppression. |

One reader's visibility update must not replace another reader's facts. Each reader keeps its own lifetime and facts under the existing rules directory. The one module still competes for the rules-owner lock. A closed reader stops viewing immediately, even while an Inventory read waits for tmux.

## Step 6 Remote transport

The Terminal opens its SSH master before the app selects the watch transport. The app checks the Remote platform through that master. A Mac with macOS 14 or later receives the bundled CLI at `~/.local/share/muxify/bin/<version>/muxify`. The version is the SHA-256 of the bundled bytes, so different Debug builds cannot reuse the same path by mistake. Uploads use a temporary file and must match that digest before publication. A connection reuses an existing build and keeps the two most recently used builds. Release bundles contain both arm64 and x86_64 CLI code.

The copied watch runs beside the Remote tmux server. Its Topic records and rules lock stay on that machine. Startup checks the Terminal's marker and Client identity. Later reads and requests reject a replacement tmux server. An admitted edit can finish after it removes its own Client. Published and queried Inventory use the watch's module identity and include Remote Client, home, and host facts. The Mac sends its rule settings in the hello message.

An unsupported machine uses `EnvironmentWatch` inside the app with the SSH transport and no Topics. Pipes carry the same JSON lines to `EnvironmentWatchClient`. This mode rejects Topic queries and writes. It does not read Local records to answer a Remote query. The chosen mode stays fixed for the connection. A copied watch failure does not select fallback or replay an uncertain request.

Each Remote App Window owns one reader and one watch connection. Closing the App Window drains the reader and watch before the Terminal's master retires. Terminal exit stops the watch. Local retains its shared watch and continues its clock rules while Remote App Windows are open.

Protocol version 2 adds existing Worktree paths to full and delta state. The module reads those paths on its own machine. Reopen previews therefore do not test Remote paths on the Mac. Topic menus, previews, queries, Zen, and saves use the Active Environment's capability and records.

## Step 7 CLI lifetime

Each ordinary CLI command that reads or changes an Environment uses one in-process module. A command scope waits for its reads and Perform replies, then waits for retirement on success or failure. It starts no records poll and takes no rules lease. When Topic state exists, a read takes the current Topic records under the record lock. It does not wait for the edit lock, because an edit holds that lock for its whole length. A read creates no state directory. Queued queries use the module's I/O queue and receive a cancellation result if the module retires.

Topic commands, Session and Agent lists, and Pane conversation reads keep their default-server targeting. Browser commands and Session or Window open keep the caller's tmux server through their existing process runner. Commands that need no Topics use a module without Topic access. Transcript files, Git commands, Extension installation, and app URL opening remain CLI work.

Browser availability, Window resolution, and exact Session lookup are typed queries. Browser open is a typed Perform that appends its URLs before the CLI exits. When tmux fails, the error gives tmux's message, and the CLI exits with tmux's status. The CLI transport keeps that status, so the failure on the wire carries no exit status. Protocol and request version 3 add these cases. Existing Topic response fields and CLI formatting stay unchanged. Protocol version 4 adds `worktreesRoot` to Perform and the `muxifyWorktreeStarts` query for Muxify Worktrees (ADR 0062). The module gets its Worktree scripts and its Environment name when it starts. The Remote fallback runs the scripts over the connection, with the Remote Environment's name. A copied `muxify` on the Remote machine runs them there and keeps their records there. EnvironmentService is internal to Core, and the temporary CLI SPI is gone.

## After Snooze and Zen

Master removed Snooze and Zen. The step sections above still name them as they were when each step landed. The module now has no clock rules and no wake notifications, so the state, the watch protocol and the readers carry no wake.

The rules owner upgrades records that an older Muxify wrote. It runs the same upgrade that master's app ran, with the arrival place from the rule settings. The upgrade runs on the machine that has the records, so a Remote server's records get the upgrade on that server. The rule settings and the Topic settings in each Perform carry `topics.in_play`, so a Topic that a request brings back goes to the top of the Bench also through the watch.
