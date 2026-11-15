# A Muxify Worktree's record lives on the machine that has it

ADR 0062 kept a Remote Environment's Muxify Worktree records on the Mac, keyed by Environment, because no `muxify` ran on the remote machine. ADR 0076 put the Host CLI there, and it already writes its own records into the Host's `muxify.db`. As a result, one Host's Worktrees were split across two databases, and neither side could list or remove the other's. Now that the Host CLI's server serves a Remote App Window, we decide that **a record lives only in the database of the machine that has the Worktree**. On a Host, only the server or the Host CLI there writes or reads it. A Worktree and the Topic that owns it (`worktree_id`) live in the same database, and the Mac, the Host's Agents and the phone all see one list.

- **The Host decides where a Worktree goes.** The Host's config `worktrees.root_path` applies on the Host. The Mac's applies only on the Mac and no longer reaches across. Without it, the default is the Host's `$XDG_STATE_HOME/muxify/worktrees`, which is the Host CLI's state folder.
- **The record names no Environment.** A record always describes a Worktree on its own database's machine, so `MuxifyWorktreeRecord` drops `environment`. The Mac's `worktrees` table keeps the column with one meaning only: the row is waiting to move to that Environment's Host. No new row sets it. The Mac lists and acts only on rows where it is NULL.
- **The Mac's remote rows move on first connect.** When a Remote Environment's server first answers, the Mac sends that Environment's waiting rows. The server imports them as the database imports the old record files: a row whose id or path the Host already has is skipped and reported. The Mac deletes each row the Host accepted. A row that was not accepted stays and is tried again on the next connect. Waiting rows whose Environment is no longer in the Mac's config stay too, and they move if an Environment by that name connects again.
- **No server, no Worktree Actions.** When the server cannot run and the Remote App Window falls back to Sessions only, Create Worktree, Remove Worktree and the list of Muxify Worktrees are refused, with the same reason the window gives for Topics. The Mac cannot write the Host's record, and a Worktree with no record could never be removed by Muxify. Plain `worktree` rows from `git worktree list` stay as launch folders.

This supersedes the "Remote Environments" section of [ADR 0062](0062-a-muxify-worktree-can-exist-without-a-topic.md). The rest of ADR 0062 stands.

## Considered Options

- **Keep the records on the Mac, keyed by Environment.** Rejected: the Host's Topics, its Agents and the phone could not see Worktrees the Mac made, and the Host CLI's own records would stay a second, disjoint list.
- **Drop the Mac's remote rows in a migration.** Rejected: those Worktrees would have no record anywhere, so Remove Worktree and Forget would refuse them and the user would have to clean them up with git.
- **Leave the Mac's remote rows in place, unread.** Rejected: this strands them the same way as dropping them, only without saying so.
