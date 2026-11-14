# Muxify reaches a Host only through typed commands and subscriptions

Today the Mac app does all the work for a Remote Environment itself. It runs `EnvironmentService` in its own process and reaches the Host with about 16 kinds of `ssh … exec /bin/sh -c` calls: raw tmux commands, the Git View's scripts, the Git probe, the Header Git read, the Worktree scripts, Session Path discovery, the Config read, `ps`, the Codex reads and the Attachment upload. We decide that no script and no raw tmux command crosses the wire to the Host CLI's server. Every message is a typed MuxifyCore command or subscription. For the Local Environment, the Mac calls the same command in-process. For a Host, it sends the command over the server's channel, and the server runs it there. The phone uses the same commands and never sends a script. The server may run `git`, `sh` or tmux internally to do the work. Only a command's name and its arguments travel.

## Subscriptions

Each one pushes state, never deltas. Every event has a key, so a newer event replaces an unsent one with the same key (ADR 0083).

- **`environment`**: the inputs that the Mac's cards, Sidebar and palette already draw from, so that code does not change.
  - Events are `session <id>` (that Session's Windows and Panes, or null when it is gone), `topic <id>` (one Topic record, or null), `open_places`, and `server` (Clients, last Window, server running, socket, home). The first item holds all of them.
  - The server reads a whole `TmuxSnapshot` locally whenever a trigger fires, compares it per Session with what it sent last, and pushes only the keys that changed. That costs milliseconds and no round trip.
  - The triggers are the control Client's notifications; one all-Sessions `refresh-client -B` format subscription (about 1 s, tmux 3.2 and later), which sees option changes, Agent status, splits and `pane_current_*`; `data_version` every 0.25 s, plus an event for each of the server's own writes; and a whole read every 5 s as a safety net.
  - No global `after-*` hooks. They are shared tmux server state that `show-hooks` shows, and each server would have to name its own client in them.
- **`config`**: the Host's Config path, YAML text and overrides. The server watches the Config's folder and sends the text again when it changes, so an edit on the Host takes effect without Reload Config. The Mac parses it as it does today. This answers ADR 0010's want of a long-running process.
- **`repository { path }`**: `{ head, changed }` whenever HEAD, the index or the working tree changes. On a Host, inotify on the git directory feeds it, with a 2 s local probe as a safety net. Locally, ADR 0072's FSEvents watcher feeds it. It replaces the 2 s remote Git probe and the 2 s Header Git read. When it changes, the Git View asks for the new status.

## Commands

- **`environment`**: `EnvironmentRequest` as it is (version 2), answered with `EnvironmentResponse`. The server's `EnvironmentService` runs it on the Host. The Mac's two direct record writes go away. Unread on visit becomes a `markRead` request. The server writes the remembered Sessions itself from the snapshots it reads. Several servers writing the same value is harmless (ADR 0080).
- **View commands**: a typed set for the App Window's own tmux commands, which ADR 0039 gives no mirror. Examples are `select_pane`, `switch_client`, `split_pane`, `resize_pane`, `select_layout`, `set_last_window`, `set_agent_unread`, the Browser options, `capture_pane` and the PaneFinder's copy mode, `send_keys`, and `new_window` for the Config and Git editors.
- **Git**: one command for each operation the Git View has today, with the same inputs and outputs. These are status, log, file content and diff, the PR or commit link, stage, unstage, discard, commit, amend, merge, rebase, cherry-pick, reset, stash, branch rename and delete, and checkout.
  - Fetch, push and pull are commands too. The server runs git with an askpass helper. A prompt reaches the Mac as a request from the server, `ask { prompt, secret }`, and the Mac answers it. The helper's way to its server is part of the Host-to-Mac requests.
- **`session_paths { roots, depth }`**: the project folders for New Session and Add Session, found by MuxifyCore's discovery on the Host.
- **Worktrees**: the `EnvironmentRequest` Worktree commands, plus the start choices of a new Worktree (`git worktree list`, `for-each-ref`).
- **The Codex reads and `ps`**: run by the server as part of its snapshot read. They are not separate requests.
- **`upload { name, offset, data, last }`**: one Attachment, sent as a pipelined run of chunks of at most 64 KiB. The first `end` names the path on the Host. The paste is a view command. When a chunk fails, the paste fails and the server deletes the partial file.
- **`adopt_worktrees { rows }`**: sent once after `hello`, when the Mac has Worktree rows waiting to move to this Host ([ADR 0088](0088-a-muxify-worktrees-record-lives-on-the-machine-that-has-it.md)). Its `end` lists every row as `taken`, or `skipped` with a reason such as a name or path clash. The Mac deletes only the taken rows. A channel that ends before the `end` leaves every row in place.

## The Watch Session

Each server's control Client runs `new-session -A -s muxify-watch -f no-output,ignore-size cat`, so it joins the Watch Session or makes it (ADR 0063). When the user has no Session left, any server kills the Watch Session. The other servers' control Clients get `%exit`, and every server makes or joins it again when a user Session appears. A Muxify app on the same machine follows the same rule. The bootstrap's `kill -HUP` of the listener goes away, because the listener ends with its server.

## In code

- `HostRequest` in MuxifyCore's `Protocol` folder carries the surface, each case under its own key: `subscribe { environment }`, `subscribe { config }`, `environment` (the `EnvironmentRequest` as it is), `mark_read { topics, panes }` and `view` (a `ViewCommand`, answered `{ output }`). `HostServer` serves them against a `HostServerContext`: the Host's tmux server, its `muxify.db` and its Config, which `muxify server` reads again for each `environment` request.
- The `config` subscription's items are `HostConfig { path, home, text, overrides: [{ path, text }] }`, each the whole Config, keyed `config`. The first comes at once; the server watches the folders of the Config and its Overrides (inotify on Linux, FSEvents on a Mac) and pushes again when what reads changes. An item with no `text` says the Host has no Config. Override paths are named as the Mac's remote Config names them after `host:`.
- The `environment` subscription's items are `EnvironmentItem { changes }`. The first holds every key. Each later item holds one change and is sent as an event of that change's key: `{"session": id, "value": …}`, `{"topic": id, "value": …}` (`value` is `null` when it is gone), `{"open_places": …}` and `{"server": …}`. A Window carries what tmux and the Topic options give it. The Mac stamps `isRemote`, its home, host name and `sourceID` from the `server` event, which carries `server_id`, `home`, `host_name` and `own_client`.
- The own Client: the Mac's `hello` carries its Client marker's `nonce`. The server reads `@muxify_client_<nonce>`, and `own_client` is `null` until the marker names an attached Client. Writing the marker makes no tmux notification, so the publisher looks for it each second until it has one. A view command that acts as a Client runs only while the marker names that Client.
- `mark_read` clears the Topic Unread of `topics` and the Agent Unread of `panes`. The Host Server's publisher writes each Topic's remembered Sessions from every snapshot it reads, so the read after `mark_read` writes them too.
- Every command that writes reads again before its `end`, so the subscription has pushed the write's events by the time the Mac has its answer.
- `session_paths { roots }` gives each root its own `{ path, depth }`. It answers `{ output }`: `SessionPathDiscovery`'s output, run on the Host, which the Mac reads and saves as it reads a local run's. How a SessionPath is named stays on the Mac.
- `upload { name, offset, data, last }` answers every chunk with `{ path }`. `ProtocolClient.upload` keeps 8 chunks waiting at most. The channel hands requests to their handlers concurrently, so the server writes a chunk only once the chunks before it are written. The file is `.upload` in a private folder under the Host's `TMPDIR` until its last chunk renames it. A failed or cancelled chunk, and a server that stops with an upload unfinished, delete that folder.

## Considered Options

- **A raw `script { sh, args }` request**, kept for the Git View and the Worktree start choices, beside a raw `tmux { args }` request. It is less work: the existing scripts move as they are. Rejected for two reasons. The client then writes shell for another machine, and a phone would have to ship that shell too. The Local path would also stay apart from the Remote one.
- **A computed view** (`EnvironmentSnapshot` plus Panes) built on the Host. The card rules are in MuxifyCore either way. Rejected: the Mac would need a second set of view code fed by it, beside the code that draws Local from `TmuxSnapshot` and the records.
- **Git fetch, push and pull outside the protocol** on an `ssh -tt` exec, as today. Rejected: it breaks the rule. **No prompts**, failing the fetch and pointing at a Pane, was simpler and was also rejected.
- **Global tmux hooks for instant events.** Rejected for now (see `environment` above). The format subscription's second or so is no worse than today's 1 s poll, and it saves the round trip.

## Consequences

- The Git View's scripts become MuxifyCore code that runs on both machines. That is the biggest part of the port.
- One command set serves Local and Remote, so a feature that works locally works on a Host once the server runs that command. The `!isRemote` guards can go.
- The phone can later drop its own command lines and use the same commands.
- An older server answers `unsupported` to a command it does not know. What the App Window does then is the version contract's to decide.
