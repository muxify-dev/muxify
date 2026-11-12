# Muxify's state lives in one SQLite database

The Topic records, the Open Places, the Muxify Worktree records and Browser History are tables in one SQLite database, `$XDG_STATE_HOME/muxify/muxify.db`, on the Mac and on each Host alike. This supersedes [ADR 0066](0066-the-topic-records-live-in-one-file.md), one `topics.json`, and the storage parts of [ADR 0028](0028-topic-records-live-outside-tmux.md) (the records folder), [ADR 0059](0059-browser-history-ranks-pages-by-a-decaying-score.md) (`browser-history.json`) and [ADR 0062](0062-a-muxify-worktree-can-exist-without-a-topic.md) (`worktrees/<uuid>.json`). What each record holds, and where the Topic link lives (on the tmux Session), do not change.

Each JSON file was read whole and written whole, and every writer had to lock, reread and merge it by key to keep another process's change. A database changes one row in place, in a transaction, so the writers need no lock files and no merge code of their own: a write changes only the columns it changed, and the last write to a field wins ([ADR 0080](0080-writes-take-no-lock-and-the-last-write-to-a-field-wins.md)). It also writes one file in place, so a virus scanner does not see a new file for each write, the reason for ADR 0066.

## The tables

- `topics`: one row for each Topic, keyed by its id. A column for each scalar field (`title`, `slug`, `outcome`, `order`, `created_at`, `settled_at`, `session_order`, `pinned`, `guest`, `unread`, `note`), and JSON text for `sessions` and `tags`. Session entries are open JSON, and both lists are only ever written whole.
- `open_places`: one row for each Open Place, its id and order.
- `worktrees`: one row for each Muxify Worktree record, keyed by its id, with a UNIQUE `path`.
- Browser History: its History entries, which the app keeps in memory and writes behind, as before.

The database is in WAL mode, so a reader never blocks a writer, with a busy timeout of 10 seconds, after which a request fails as `storeBusy`. SQLite comes from the pinned SwiftPM package `swiftlang/swift-toolchain-sqlite`, compiled into MuxifyCore, so the app, the Mac CLI and the static musl Linux Host CLI run the same SQLite. MuxifyCore reaches it through its own thin wrapper over the C API.

## The schema changes only by adding

Two builds open one database: the dev build beside `/Applications/Muxify.app`, or two Host CLI versions. So a migration only adds: a new table, or a new column that is nullable or has a default. `PRAGMA user_version` counts the migrations. A build that finds a newer `user_version` keeps working and ignores what it does not know. A change that is not additive needs its own ADR. This retires `TopicRecord.unknownFields`, which kept the keys of a newer build in the file.

## Considered Options

- **GRDB or SQLite.swift.** Rejected: GRDB's Linux support is partial, and both are large for five tables and a handful of queries.
- **The system `libsqlite3`.** Rejected: the static Linux SDK has none, and the Host CLI is static.
- **Fully normalized `topic_sessions` and `topic_tags` tables.** Rejected: both lists are written whole, and a Session entry is open JSON.
- **The JSON files kept, with fewer locks.** Rejected: without a lock, a whole-file write loses another process's change.
- **A `muxify state dump` command**, to keep the state readable as ADR 0066 did. Rejected: the `sqlite3` CLI reads it.

## Consequences

- The first open of a missing database imports `topics.json`, `worktrees/*.json` and `browser-history.json` in one transaction, then renames each one to `<name>.migrated`. Muxify never reads them again. A build from before this change then finds no records, and shows no Topics until it updates. The two formats are never kept in step.
- The database holds only valid records. The import skips an entry that is not a valid record, a Worktree file that does not decode, or a Browser History file that does not decode. It writes a Diagnostics problem line for each, and the entry stays readable in its `.migrated` file. The invalid-entry rules of ADR 0066 go: no reserved ids, no entry written back, no `unreadableFile`.
- The upgrades from before `topics.json` go: the `topics/` folder and its `open-places` file (ADR 0066), and `zen.json` and `snoozed_until` (ADR 0054). The import reads only `topics.json`.
- The app's watcher polls `PRAGMA data_version` on its own connection every 0.25 seconds, and reads the records again only when it changes.
- The `session-paths/` cache, the `codex/` reports that a shell hook writes, UserDefaults, the Config and the Diagnostics log stay files.
- `scripts/verify` reads and seeds the records through Python's `sqlite3`.
