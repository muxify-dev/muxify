# A folder is the same folder through symlinks

The Config names Session Paths with the path the user wrote, such as `~/Dev/work/notifire`, where `~/Dev` can be a symlink. git, tmux's `pane_current_path` and `muxify topic` arguments give the real path. Muxify compared these with about 50 lexical comparisons, so `muxify topic new --directory ~/Dev/work/notifire` did not find its Session Path, and a Worktree beside its repository showed under the real path. We decided that every folder Muxify compares is a `Folder` value with two paths: `path`, the spelling that Muxify shows, writes to Topic records and gives to tmux `-c`, and `real`, with symlinks resolved, which is the only thing that equality and "contains" use. Each boundary makes the `real` path one time, on the machine that owns the folder: the discovery script's `pwd -P` and git's Worktree list, `pane_current_path` as tmux gives it, and local `realpath` for CLI arguments and Topic record paths, which are local only. tmux's `session_path` is the Config spelling, so it gets its `real` path from local `realpath`, or on a Remote Environment from the Folders that discovery found.

## Considered Options

- **One helper that resolves both paths when it compares them.** Rejected: on a Remote Environment it reads this Mac's disk, and a raw `String` stays easy to compare in the wrong way.
- **Write real paths to Topic records.** Rejected: it needs a migration, other programs write the records in any spelling, and a record must follow the Config when a symlink target changes.
- **Give tmux the real path.** Rejected: the shell prompt must show the path that the user wrote in the Config.

## Consequences

A folder that is gone, such as a removed Worktree, has its standardized path as its `real` path, so a lookup does not fail on it. VisitLog keys change to the `real` path one time, when the log loads.
