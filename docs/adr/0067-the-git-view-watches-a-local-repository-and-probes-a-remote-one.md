# The Git View watches a local repository and probes a remote one

The Git View read its repository only every 10 seconds, on app activation, on `R` and after its own writes. After a commit in a Pane or by an Agent, the committed files stayed in Changes for up to 10 seconds. We decide that an open, current Git View reads its repository again as soon as the repository changes. How it notices depends on where the repository is.

- **Local Environment**: a file-system watcher (FSEvents) on the working tree, the Worktree's own git directory (HEAD, index) and the common git directory (refs), which for a linked Worktree lies outside the tree. Events are debounced by about 250 ms, one read runs at a time, and reads start at most once per second, so build output in ignored folders cannot flood it. The reads set `GIT_OPTIONAL_LOCKS=0`, so a read does not write `.git/index` and wake the watcher again.
- **Remote Environment**: FSEvents cannot see a folder on another machine, and a watcher process over ssh would be one more thing to start, keep alive and clean up for each repository. Instead, a cheap probe runs over the owned ssh connection every 2 seconds. It reads HEAD, the index's modification time and a hash of the status, and starts the full read only when one of them changed. The probe sets `GIT_OPTIONAL_LOCKS=0` too; otherwise its `git status` would rewrite the index, change the index's time on every probe and start a full read every 2 seconds.
- A closed or suspended Git View watches and probes nothing. It reads on open or resume, as before.
- The 10-second read stays as a fallback in both cases.

## Considered Options

- **A shorter timer for everything.** Rejected: a full read every second or two costs a `git status` and log on each tick for every open Git View, and it is still late.
- **A watcher process on the remote machine (`fswatch` or `inotifywait` over ssh).** Rejected: neither is installed by default, and each repository would need a long-lived process to manage. The probe needs only `git` and `sh`.
- **Refresh when an Agent's turn ends.** Rejected: it misses commits typed in a Pane.
