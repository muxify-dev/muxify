# Topic record files

Store one UTF-8 JSON object in `$XDG_STATE_HOME/muxify/topics/<id>.json`.
If `XDG_STATE_HOME` is absent, use `~/.local/state/muxify/topics/`.
The filename must match the `id` field. The id must be a nonempty filename without `/`.

```json
{
  "id": "reward-drop",
  "title": "Fix reward drop",
  "slug": "reward-drop",
  "created_at": "2026-10-06T20:00:00Z",
  "settled_at": null,
  "outcome": null,
  "order": 0,
  "snoozed_until": null,
  "session_order": "manual",
  "tags": ["backend", "release"],
  "sessions": [
    {
      "id": "78199a21-e769-41c6-97e0-70843149f16f",
      "name": "debug/reward-drop",
      "base_name": "debug",
      "directory": "/worktrees/game_server/reward-drop",
      "repository_path": "/work/game_server",
      "worktree_path": "/worktrees/game_server/reward-drop",
      "worktree_created": true,
      "base": "full-starting-commit-id",
      "branch": "reward-drop",
      "windows": [
        {
          "window_id": "@12",
          "directory": "/worktrees/game_server/reward-drop",
          "name": "investigate",
          "pane_count": 2,
          "start_command": "",
          "agent": "claude",
          "agent_conversation": "conversation-id",
          "browser_tabs": ["https://example.com/issue/123"],
          "browser_active_tab": 0,
          "browser_open": true,
          "terminal_open": false
        }
      ]
    }
  ]
}
```

Only `id` is required. Dates use strings. `snoozed_until` can also be `"never"`.
An absent or null `title` gives an Untitled Topic. A slug such as `untitled-3`
gives the label `Untitled 3`. Without that slug, the view assigns a free number
in Topic id order. Manual display order does not change those numbers.
A non-null `settled_at` removes the Topic from the Topics view.

`tags` holds the Topic's Tags, without `#`, A→Z. A Tag has only lower case
letters `a` to `z`, digits and `-`, and it is not empty. Muxify reads an entry
as the user types a Tag: it makes upper case lower case and removes one `#` at
the start, so `Backend` and `#backend` are the Tag `backend`. Muxify keeps an
entry that is still not a Tag, and writes it back after the Tags. It reads a
`tags` value that is not an array as no Tags, and writes the value back until
a Tag change gives the Topic Tags. A Topic without Tags and without such
entries has no `tags` key. The Config's `topics.tags` says which Tags exist
(see [Tags](configuration.md#tags)), so `tags` may hold a name that the Config
no longer defines, such as a Tag the user removed or renamed there. Muxify
keeps that name in the record and shows it dimmed. A Tag change can remove it,
but cannot add it again.
Edit Tags in the app and `muxify topic tag` change the field through the Topic
service. They change only the `tags` key, and only for an open Topic. A change
that adds a Tag the Config does not define fails with the kind `tag_undefined`
and writes nothing.

The store retains unknown JSON fields during writes, including nested fields
in remembered Sessions and Windows. Writes replace the file atomically. The
app checks for external changes every 0.25 seconds.

The app and `muxify` both write these files. Each write holds an exclusive
`flock` on `$XDG_STATE_HOME/muxify/topics.lock`, and each read holds a shared
one. The file stays empty, and Muxify never removes it. A program that writes
the record files must hold the exclusive lock while it reads, changes and
writes them. A write rereads the files under the lock. A Topic edit changes
only the JSON keys that it changed itself, so it keeps a Snooze that another
writer set while the edit ran.

Live membership comes only from the tmux Session option. For example:

```sh
tmux set-option -t my-session @muxify_topic reward-drop
```

Remembered Sessions have independent `id`, `name`, `base_name` and `directory` fields.
Folders do not identify Sessions: several members can use the same directory.
Muxify-created, restored and moved members carry their remembered `id` in the Session
option `@muxify_session_id`. An existing unmarked Session initially uses a key made
from the server incarnation, tmux Session ID and creation time. External renames keep
that identity and membership. The Sidebar shows the actual name, stripping only the
known Topic suffix for `#{session_base_name}`. There is no home folder or home Session.
If a kept original still uses a remembered identity, Reopen gives the recreated Session
a fresh identity; two live Sessions must never share it.

The order of `sessions` is the Topic's order of its Sessions. Without
`session_order`, Muxify lists the Sessions by their tmux creation time in the
order that the Config's `topics.session_order` names, and records them oldest
first, so Reopen creates them in their old order. `"session_order": "manual"`
means the user moved a Session: Muxify then lists the Sessions in the order of
`sessions`, matched by `id`, and puts a live Session that `sessions`
does not name at the end that `topics.session_order` gives new Sessions. Sort
Sessions by Creation removes the field. Another value counts as absent.

Muxify records the live Sessions after a 0.3 second write delay. An unchanged
snapshot does not write a file. Confirmed Muxify closures and removals observed
between complete inventories of the same running server remove the stopped Session
or Window. A confirmed last closure leaves an Empty Topic. An absent server,
failed read, initial reconnect inventory or a different server incarnation does not
prove closure: unknown disappearances preserve the last saved layout. Settle saves
the layout before its explicit Kill choices, so Reopen can restore it.

Remove from Topic, Remove from Topic and Kill, and a Move of a Session take
the Session out of the record's `sessions` in the same edit that changes tmux.
Removing or moving the last Window of a Session does the same, because tmux ends
the Session. A Topic whose `sessions` is then empty is Empty: going to it
offers Add a Session and creates nothing. A Topic with a saved layout but no live
members is Dormant; Reopen preserves each remembered name, allocating `+2`, `+3`, etc.
before its Topic suffix only when occupied. It never adopts an unrelated Session. When
another writer changed `sessions` while the app's write delay ran, the app drops
that pending write, so it cannot put a removed Session back. Plain Remove from
Topic keeps the Worktree for the Session that now has no Topic. Remove from
Topic and Kill removes the clean Worktree that the Topic made for the Session
when the request names it, as Forget does: Git removes it without force and
keeps its branch.

A remembered Session always stores its launch `directory`. Worktree launches also store
`repository_path`, `worktree_path` and `branch`, and `worktree_created` is true when Muxify made
the Worktree. A Worktree that the Topic made also stores `base`, the full id of
the commit that its branch started at. Muxify reads this commit before it makes
the Worktree, so a branch that moves later does not change `base`. A record from
before this field has no `base`. When Reopen makes a Worktree again because its
folder is gone, it checks out the branch if the branch still exists. If the
branch is gone too, the new branch starts at `base`, so `base` stays true. If
the repository no longer has that commit, Reopen fails and changes nothing.
Without `base`, the new branch starts at the repository's HEAD. `muxify topic diff`
shows a Worktree Session's work since `base`, and since the merge base with the
default branch when there is no `base`. Settle removes only a Worktree that the Topic made inside
`$XDG_STATE_HOME/muxify/worktrees/`. If a Worktree that Settle would remove
has modified or untracked files, an explicit cleanup request fails and changes nothing: the Topic
stays open and its Sessions stay live. Each Window stores its active Pane's `directory`
and `start_command`, its tmux `name`, its Browser Tab URLs
in `browser_tabs` and the active Tab's index in `browser_active_tab`. `browser_open` and `terminal_open` hold the
Window's Browser and Terminal toggles; Reopen shows the Browser alone when `browser_open` is true and `terminal_open` is
false. Maximize is not stored. `start_command` holds the active Pane's start arguments as serialized by tmux's
`pane_start_command` format. An empty string means the default shell. Reopen
must parse this tmux argument format before execution. It must not send the
stored string directly to a shell. If the
active Pane runs an Agent, `agent` names its kind and `agent_conversation`
holds its conversation id when available.

Each Window also stores `layout`, tmux's `#{window_layout}`, and `panes`, one
object for each Pane in tmux order. A Pane stores its tmux `index`, its
`directory`, and `active`, which is true for the Window's active Pane. An Agent
Pane stores `agent` and `agent_conversation` as the Window does. A Pane that runs
another program, not a shell, stores its full command line in `command`. Muxify
reads it with `ps` on the Environment's machine, because tmux gives only the
program's name. A zoomed Pane is not stored as zoomed.

Reopen makes each Pane again in its folder, then sets `layout`, and makes the
remembered active Pane active. It resumes each Agent Pane. It types each
`command` at the Pane's shell prompt but does not run it: the user presses ↩.
A Window without `panes`, from an older record, gets one Pane with the Window's
`directory` and Agent.
`window_id` matches a live Window to its record so that renaming or reordering
Windows retains unknown fields. It is not a target for Reopen after a restart.

Start Fresh keeps the identity, name, directory and Worktree provenance of each
remembered Session. It makes one shell Window there, with no Tabs and no Agent.
When the new Sessions are live, the record remembers them in place of the old
Windows.

## Locked Sessions

A Lock (ADR 0018) has no record file. tmux keeps it in the Session option
`@muxify_lock`. Its value is the place of the Session's card in the Topics list,
in the same scale as the `order` of the Topic records:

```sh
tmux set-option -t notes @muxify_lock 3.5
```

Only a No Topic Session can be Locked. Muxify ignores the option on a Session
whose `@muxify_topic` names an open Topic. A Lock is never Pinned, so its card
moves among the Topics that are not Pinned. When a move renumbers the list,
Muxify writes the new `order` values to the records and the new
`@muxify_lock` values to tmux. A new Lock goes after the last Topic that is not
Pinned. The Lock ends when the user Unlocks the Session, when the Session ends,
and when the Session goes into a Topic. A Topic that the user makes from a
Locked Session takes the Lock's value as its `order`.

`muxify session lock` and `muxify session unlock`, and the URLs
`muxify://topic/lock?session=<name>` and `muxify://topic/unlock?session=<name>`,
change a Lock through the Topic service.

## Zen record

While Zen is on, Muxify keeps one record in `$XDG_STATE_HOME/muxify/zen.json`,
beside the `topics/` folder. It is not in that folder, because each JSON file
there is a Topic record.

```json
{
  "kept_topic_id": "reward-drop",
  "until": "2026-10-08T17:00:00Z",
  "changes": [
    { "topic_id": "docs-pass", "previous_snoozed_until": null },
    { "topic_id": "flaky-ci", "previous_snoozed_until": "2026-10-08T15:00:00Z" }
  ]
}
```

`kept_topic_id` is the Topic that Zen keeps. It is required: Zen always keeps
a Topic, because No Topic is not a Topic. A record without it does not load.
`until` is the
`snoozed_until` value that Zen wrote on each Topic in `changes`. Each change
also keeps the Topic's `snoozed_until` value from before Zen. Zen does not
change a Topic that is Snoozed until `never` or past `until`, so that Topic is
not in `changes`.

End Zen puts back each earlier value that is still in the future, and removes
the Snooze when that value is past. It skips a Topic that was Settled, or whose
`snoozed_until` is no longer `until`. Then it deletes the file. When `until`
comes, the Topics wake as for any Snooze, and Muxify deletes the file. Settling
the kept Topic also ends Zen.

## Forget

Forget removes `topics/<id>.json` after it kills or detaches the Topic's live Sessions.
The Topic cannot be Reopened. Forget applies to open, Dormant, Snoozed, and Settled Topics.
Each live Session uses the same Kill or Keep with no Topic choice as Settle.
Every Session defaults to Keep; keeping restores its base name, with `+x` on collision.
Every Worktree defaults to Keep. Missing `worktree_created` is not permission to delete.
Cleanup checks all live Sessions and all Panes, not just active Panes, and never deletes branches.

Forget can remove each clean Worktree that the Topic made inside
`$XDG_STATE_HOME/muxify/worktrees/`, even if its branch is not merged.
It keeps modified or untracked files, Worktrees outside that folder, and Worktrees used by a kept Session.
The confirmation names the Worktrees that stay. Git removes the Worktree without force and keeps its branch.

`muxify topic forget --topic <id|label>` uses the default Session choices.
Add `--remove-worktrees` to remove eligible Worktrees. The URL forms are
`muxify://topic/forget?topic=<id>` and `muxify://topic/forget?pane=<pane-id>`.
Both use the Topic service. They keep Worktrees unless the request selects them.

Forget ends Zen if Zen keeps that Topic. The record transaction restores the other Topics' Snoozes.
A stale record update or remembered-Session write cannot create the removed Topic again.
Only an explicit creation with no previous record can create a Topic file.

## One-off beta migration

Quit Muxify and stop Topic CLI edits before migrating. There is no legacy record reader.
The Bash entry point requires Python 3 and reads tmux without changing Sessions:

```sh
bash scripts/migrate-topic-sessions.sh --dry-run
bash scripts/migrate-topic-sessions.sh --apply
```

Use `--state-dir /path/to/muxify` for another state directory and `--socket /path/to/socket`
to inspect a particular server. Use `--no-tmux` to explicitly accept folder-derived names
when inventory is unavailable. Live members recover their exact names and stable identities;
inactive names cannot be recovered from the old files, so every fallback is reported.
The script removes the old home field, preserves unknown fields and explicit Worktree
provenance, backs up all changed records before replacement, and is idempotent. It does
not invent a Session for an Empty Topic. Backups stay beside `topics/`, outside the files
the app reads. Review the dry-run and keep that backup until restoration is verified.
