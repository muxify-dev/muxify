# Environment watch prototype

This throwaway prototype measures the Environment module plan in `docs/environment-module.md`. It does not change the app.

Run the complete measurement from the repository root:

```sh
python3 prototypes/environment-watch/measure.py
```

The command builds the release Inventory reader, runs five trials per case, and prints one table. It saves the individual runs in `measurements.json`. It saves the table in `measurements.md`. Use `--repeats 1 --cycles 1 --output /tmp/environment-smoke.json` for a shorter check.

The script needs Swift, Python 3, and tmux with `refresh-client -B`. It checks passwordless `ssh localhost`. It does not change SSH settings or host keys. If SSH is unavailable, the table has Local cases only.

## What runs

`InventoryProbe` uses `Tmux.readSnapshot`, `Tmux.snapshotArguments`, and `Tmux.parseSnapshot` from the repository's MuxifyCore package. One persistent helper starts tmux for each Inventory read or write. The fixture has three Sessions, twelve Windows, and twenty-four Panes. Twelve Panes report a Claude Agent and run `sleep`.

`watch.py --mode poll` reads the whole Inventory on control events and a one-second timer. It uses the app's event filter and combines pending event refreshes. Each reader has its own process and control client.

`watch.py --mode watch` uses one process for both readers. The measurement client applies each line to two separate mirrors for the two-reader case. Watch reads on control events, subscription notifications, requests, and a five-second timer. It sends a full Inventory first and changed records after that. The `watch_1s` case uses a one-second fallback timer. This case separates the effect of delta output from the effect of a slower timer. The `watch_all` case keeps the five-second timer, and its Status subscription covers every Session (`--status-sessions all`). It uses one subscription for the attached Session, with an `S:` loop in its format: `#{S:#{W:#{P:#{pane_id}=#{@muxify_agent_status};}}}`.

Both modes use the same release helper and the same requests. The first reader sends each request. The second reader observes its result. Each run changes Agent Status in the attached Session, clears Unread, and switches Windows. It then changes Status in another Session, repeats Mark Read as a no-op, and sends one invalid Window request. Each run lasts at least `cycles * 1.5 + 14` seconds before shutdown. The default is twenty seconds. Case order reverses on alternate trials.

The script uses a new directory and socket for every tmux server. It removes `TMUX` and `TMUX_PANE` from child environments. It uses an empty tmux Config. Before `kill-server`, it checks the server's socket path. It then waits for the server PID to exit. It does not start Muxify.app.

## Pipe contract

Start watch with an explicit socket inside `TMUX_TMPDIR`:

```sh
python3 prototypes/environment-watch/watch.py --tmux /opt/homebrew/bin/tmux --socket "$TMUX_TMPDIR/server"
```

The first output line has `type: full`, `version: 1`, a `module` UUID, `revision: 1`, and a `values` map. Each later state increments the revision by one. A `delta` line has only changed map entries and a `removed` list. Each entry contains its new value. The map keeps complete raw Inventory rows and typed Pane and Window values for the measurement checks. This is a measurement representation, not the proposed production schema.

Requests are JSON lines:

```json
{"id":"1","op":"mark_read","target":"%0"}
{"id":"2","op":"select_window","target":"@1"}
```

Mark Read clears the Pane's Unread option and preserves Status. Select Window changes the target Session's active Window. A request reply has `type: reply`, its `id`, the `module`, its `revision`, and an `error` string or null. The next state has that exact revision, even after an invalid target or a no-op. A failed Inventory read preserves the last values and sets `connection: read_failed`. The prototype does not implement reconnection or slow-reader recovery.

One event loop runs requests and Inventory reads in order. It sends the reply before the state. The client checks consecutive revisions, the module id, and the requested value in the first state at the reply's revision. The same client starts a Local child or starts the command through an SSH master. EOF on stdin stops watch and its helper. The final diagnostic line has `type: metrics`.

## Measurement limits

CPU seconds include the Python reader process, its Swift helper, their reaped tmux children, and the Python client. An SSH case also counts its local SSH client and master. They exclude the tmux server and fixture commands. A separate column gives the tmux server's CPU time from the first reader's start to the last reader's exit, read with `ps`. It includes the fixture's load commands, which are the same in every case. `ps` reports it in hundredths of a second. Protocol bytes and lines include both directions of the prototype JSON pipe, including the final metrics line. The tmux output column counts stdout from helper commands. Control-client traffic has separate counters in `measurements.json`. The tmux start count includes helper commands and the persistent control client. It excludes fixture setup and load commands. These are not packet captures or measurements of the current app's network traffic.

The polling mode reproduces the Inventory trigger pattern. It does not run WorkspaceStore, SwiftUI, Topic rules, process inspection, or SSH ownership probes. The fixture has no Codex reports. Python serialization and the helper pipe add costs to both modes. These results compare the prototype loops, not total app CPU.

A `%*` Status subscription covers the attached Session. tmux checks subscriptions at most once per second. In `watch`, the five-second timer covers the other Sessions. In `watch_all`, the `S:` loop covers them. An Inventory read for another reason can also reveal a Status change.

Request latency starts before the client writes a request and ends when its state line reaches the client. Status latency starts before the fixture writes the tmux option and ends when the state line reaches the client. These times include the real tmux command. Percentiles combine observations across trials. The table gives median CPU and its minimum and maximum. Counts and byte totals are trial medians.
