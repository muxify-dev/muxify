---
name: muxify
description: Muxify commands for an Agent in a tmux Pane. Use to open, read, click, fill or screenshot a web page, such as a dev server; to check git status, diff or run a command across every Session of this Topic; to start a helper Agent in a new Window or read another Agent's conversation; or to change Topics, Sessions and Windows.
---

# Muxify

Muxify is a macOS front end for tmux. It groups tmux Sessions into Topics, one Topic for each thing the user wants to get done, and shows a Browser beside each tmux Window. The `muxify` command gives you the same controls the user has.

Check once: `muxify browser available`. Exit 0 (`local` or `remote`) means Muxify shows this Pane, so this skill applies. Exit 1, or no `muxify` command, means Muxify does not show this Pane: use your usual tools. Exit 2 means tmux could not be read; stderr says why.

## Your own place

Every command acts on your own Pane, and through it on your Window, Session and Topic, because it reads `$TMUX_PANE`. Leave out `--topic`, `--session`, `--window` and `--pane` for your own work. Give a target only when the user names one.

## The user's work

The other Sessions, Windows and Agents belong to the user or to other Agents that work for the user. Read them freely. Ask the user before you stop or remove anything:

- `session kill`, `window kill`, and `session remove-from-topic --kill` stop every process in them, Agents too. Your own Pane is one of them when you leave out the target.
- `topic settle` and `topic forget`, most of all with `--kill-sessions` or `--remove-worktrees`.

The Topic's title, Note, Tags, Pin, In Play order, and Read or Unread marks are how the user arranges their day. Change them when the user asks.

## Tasks

Read the reference for the task before you run its commands:

- A web page: open, read, click, fill, press, wait, run JavaScript, screenshot, close. Read [references/browser.md](references/browser.md).
- The other Sessions of this Topic: their git status, one diff, a command in each folder, a new Session or Worktree, moving a Window. Read [references/topics-and-sessions.md](references/topics-and-sessions.md).
- Other Agents: start a helper in a new Window, list Agents and their Status, read a conversation. Read [references/agents.md](references/agents.md).

`muxify --help` gives every verb, its flags and what it prints. `--json` prints one line of JSON, for a result you parse. A failure prints the reason on stderr and exits non-zero; the message names the command to run next.
