---
status: accepted
---

# The CLI can do what the Command Palette can do

An Agent moved a commit to a new Worktree in a new Topic. The CLI could not do this. `topic new --project` used the main checkout, and `topic add-project --worktree` then made nothing and gave no error (`"created": false`). The Agent needed six steps, `git` and raw tmux to do what the palette can do. So we make this rule: each change to the Environment that the Command Palette can make, the CLI can also make, and each change that the CLI can make, the palette can also make. Both send the same request to MuxifyCore ([ADR 0032](0032-the-cli-runs-topic-requests-through-muxifycore.md)), so they cannot do different things. No Action changes the Environment from the app only.

## Bricks, not one verb for each palette Action

The two sides must be able to make the same changes, but their verbs do not have to match. The CLI's unit is a brick: one request that makes one valid change in the domain. After each brick, the state is valid. A brick returns the ids that the next brick needs, so a script does not parse text or ask tmux. A palette Action is one brick or a short sequence of bricks. New Topic is two: an Empty Topic, then Add a Session.

- An Agent cannot see the palette. Between two palette steps, a human sees the state. Between two bricks, an Agent reads the JSON. A brick boundary is where an Agent can look at the state and decide what to do next.
- A larger unit gives no more safety. If a script stops between two bricks, the state is still valid. For example, an Empty Topic is left, which the user can use or Forget.
- Bundled verbs need one flag for each combination of choices, and each new palette step adds more combinations. With bricks, a new step adds one brick.

A brick does not combine two changes. There is no `topic new --worktree` and no `window new --new-topic`. A brick also does not split one change into parts that leave a state that is not valid. "Add a Session on a new Worktree" is one brick, although it runs `git`, writes the record and runs tmux. If it were split, a failure could leave a Worktree that no Topic owns. Bricks know nothing about Agents: an Agent starts with `window new -- <command>`, and the caller supplies the Agent's command line.

## Which Commands have a mirror

A Command must have a mirror on the other side if it changes state that continues after the App Window closes and that other clients can see: the tmux server, the Topic records, Worktrees on disk, Read state and Zen. Thus Pin, Move Topic Up and Down, Zen, Mark Read and Unread, and New, Rename and Kill of tmux Windows and Sessions move into MuxifyCore as requests, and get CLI verbs.

These Commands need no mirror:

- Commands that change only the view of one App Window: Maximize, Focus, the Sidebar, Next and Previous Session or Topic, and Browser Tabs. The Tab part of Move Pane with Active Tab is in this group. The CLI mirrors only the move.
- macOS Commands: Reveal Folder, Copy Folder, Copy tmux Target, Paste Folder.
- App setup: Open Config, Reload Config, Install Extensions, Install Command Line Tool. The config file is the shared state, and an Agent edits it directly.
- Reads, such as `show`, `status`, `diff`, `exec`, `list` and `agent conversation`. They are for scripts and Agents, and they stay CLI-only.

"No mirror required" does not mean "not allowed". A view Command can get a CLI verb when an Agent needs it to show the user something, such as `session open`, `topic open`, `window open` and `browser open`.

Typing into the terminal counts as something the palette can do. After New tmux Window, the user types the command in the new Pane. So `window new -- <command>` needs no palette step.

## How a palette step maps to the command line

| Palette step ([ADR 0014](0014-every-action-runs-in-the-palettes-view.md)) | CLI form |
|---|---|
| The current item | the caller Pane, or `--pane`, `--window`, `--session` or `--topic` |
| Run at once | the verb alone |
| Choose a row, or type one value | a positional argument or an option |
| A toggle in a step | a flag |
| Check step ([ADR 0035](0035-a-check-step-checks-topics-for-snooze-and-unsnooze.md)) | a repeated option |
| Confirm | nothing: to run the command is to confirm |
| ⌘↩, the form that stops processes | an explicit flag, such as `--kill` |

A new Action ships with its CLI verb, and a new CLI write ships with its palette step.

## Consequences

- `topic new "title"` makes an Empty Topic, as New Topic does in the palette. It no longer adds a Session from the caller Pane's folder, and it works outside tmux. `topic new` without a title becomes `window move --new-topic`. `topic new "title" --directory <dir>` combines two changes, so it fails and names `topic new` and then `topic add-session`. The old forms fail with an error that names the new form. There are no aliases.
- Add a Session gets a palette step that starts the new Worktree from a ref or an existing branch. It ships with the CLI's `--base` and `--branch` ([ADR 0038](0038-worktree-creation-and-cleanup-are-explicit.md)).
- `window new --topic` makes the Window in the Topic's only Session. If the Topic has more than one Session, it fails and asks for `--session`. If the Topic has no Session, it fails and names `topic add-session`. It does not make a Session.
- `agent start` and `AgentKind.startCommand` go away.

This extends [ADR 0014](0014-every-action-runs-in-the-palettes-view.md) and [ADR 0032](0032-the-cli-runs-topic-requests-through-muxifycore.md).

## Considered Options

- **One CLI verb for each palette Action.** Rejected: the palette's boundaries are made for a human who sees the screen. An Agent needs smaller parts that it can combine, and it reads the state between them.
- **The CLI only, one way: the CLI can do more than the palette.** Rejected: then the two sides drift apart again, and that drift caused the incident.
- **Keep the old `topic new` forms for one release, or as aliases.** Rejected: aliases keep two meanings of `topic new` for good. An error that names the new form tells each old script what to change.
