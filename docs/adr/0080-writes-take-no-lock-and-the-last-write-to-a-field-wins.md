# Writes take no lock, and the last write to a field wins

No Topic request takes a lock of Muxify's own. The record lock (`topics.lock`) and the edit lock (`topic-edits.lock`) of [ADR 0032](0032-the-cli-runs-topic-requests-through-muxifycore.md) go, and so do their files. Each write is one short SQLite transaction that changes only the columns it changed. When two writers change the same field, the last write wins. This supersedes the lock and merge consequences of ADR 0032. The service itself, and the CLI running it in its own process, stay.

The record lock kept one whole-file write from losing another's change. A transaction that updates only its own columns does that in the database ([the SQLite ADR](0079-muxifys-state-lives-in-one-sqlite-database.md)). The edit lock held one edit from its first read to its last tmux command, through `git worktree add` and the preDelete hooks, so that two edits could not choose the same Topic or Session name. Those races need two edits in the same moment, by one user, and we take their rare cost over a lock that every edit waits on.

## Considered Options

- **One `BEGIN IMMEDIATE` transaction for each edit, read to last tmux command.** Rejected: every other write, such as Unread on a visit or the remembered Sessions, waits behind an edit that runs `git worktree add` or a hook, and fails after the busy timeout.
- **An edit lease row in the database**, with the holder's pid and a takeover of a dead holder's lease. Rejected: a lock with crash recovery of our own.
- **The edit lock kept as the one flock.** Rejected: we want no lock files.
- **A UNIQUE slug and a retry of the plan**, and a retry with the next free Session name when tmux reports a duplicate. Rejected: more code for a race that one user rarely makes.
- **A compare-and-set on the remembered Sessions**, as the app did. Rejected: a plain update is simpler, and the save runs again after each change to the Topic's Windows. A save from an older read can still drop a Session that another process just added to the record.

## Consequences

- A write changes only the columns that its plan changed, in one transaction. A Tag change during a Settle keeps both.
- The app's remembered-Session save is a plain update of `sessions`. It no longer checks that `sessions` is unchanged since it read it.
- Two Topics made at the same moment with the same title can get the same slug. The slug has no UNIQUE constraint. The second Topic's Session then fails to start with tmux's duplicate-session error, and the request fails.
- A Muxify Worktree's `path` is UNIQUE. A second Worktree at the same path fails in `git worktree add` or at the insert, and is not retried.
- Two edits of one Topic at the same moment can leave it out of step with tmux, such as a Settled Topic that lists a live Session. Nothing guards this beyond the membership check at confirm time.
- The app still runs one Topic request at a time in each App Window (`changingTopic`). That is not a lock between processes.
- `storeBusy` now means only that SQLite's busy timeout ran out.
