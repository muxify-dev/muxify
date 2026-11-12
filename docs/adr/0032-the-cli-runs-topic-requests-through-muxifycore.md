# The CLI runs Topic requests through MuxifyCore

> **Locks and merge superseded by [ADR-0080](0080-writes-take-no-lock-and-the-last-write-to-a-field-wins.md):** no Topic request takes a lock of Muxify's own, `topics.lock` and `topic-edits.lock` are gone, and each write is one SQLite transaction that changes only its own columns, so the last write to a field wins. The service, and the CLI running it in its own process, stand.

Every Topic read and edit goes through one service in the `MuxifyCore` package: the app's sheets, the `muxify://topic` URL and the command line tool all send a `TopicRequest` and get a `TopicResponse`. The command line tool runs the service in its own process, so it works when Muxify is off and can give a real result and exit code. This makes the command line tool a second writer of the Topic records ([ADR 0028](0028-topic-records-live-outside-tmux.md)), so the service takes two locks and merges each write. Every `muxify topic` command and `muxify window move` run this way.

## Considered Options

- **The URL scheme with a reply file.** The app stays the one writer and writes a JSON result to a path that the command line tool waits on. Rejected: Muxify must run, `open` can take the focus, and every request waits on the app's main thread.
- **A socket that the app serves.** Fast, and it can stream events. Not now: [ADR 0004](0004-agents-report-status-through-pane-options.md) rejected a socket for Extensions because of the client protocol, finding the socket, and the loss of requests while Muxify is off. It is the planned next transport. The requests and responses are versioned `Codable` values for this reason: a socket server, in the app or in its own process, is then only a new transport for the same service.
- **The app compiles the Topic code into its own module, and only the command line tool links a package.** Rejected: the app could then call the plans and the executor directly, which is a second edit path that only a review would stop. With a package, they are internal and the compiler stops it.

## Consequences

- Two locks in the state folder, beside the records. The record lock (`topics.lock`) covers each read and write of the records and the Zen record, for milliseconds. The edit lock (`topic-edits.lock`) covers one full edit, from its read to its last tmux command, so two edits cannot choose the same Topic or Session name. Take the edit lock first, then the record lock, never the other way. Snooze, Zen and the remembered-Session writes take only the record lock.
- A write rereads the records under the record lock and merges by JSON key: a key that the writer changed takes its new value, and every other key keeps the value on disk. So an edit that planned from an old read does not erase a Snooze that another process wrote. When two writers change one key, the last write wins.
- The app writes its unsaved remembered Sessions and Browser state before it sends a request. The service reads only the records and tmux, so a request from the command line tool does not see the app's last unsaved changes.
- The `muxify://topic` URL stays for automations that have no shell. It is a thin map onto `TopicRequest` and gives no result to the sender.
- `topic list` uses the same record decoder as the app, so an entry that is not a valid record is not listed.
- `project list` and `agent list` read the records directly through `TopicStore`, not through the service. The read takes only the record lock, in shared mode, so it never sees half of a write. They change nothing and need no caller Pane, and `agent list` lists Agents, not a Topic, so a `TopicRequest` gives them nothing. `topic list` is a Topic request and goes through the service.
