---
status: accepted
---

# A Muxify Worktree can exist without a Topic

The user made Worktrees with a shell script: `worktree create <name>` in any tmux Session, with a per-project `.worktree.json` that copies files, links folders and runs hooks. Muxify could make a Worktree only as part of a Topic's Add a Session. So we let Muxify make a Worktree that no Topic owns, and every Worktree that Muxify makes, in a Topic or not, gets the same Worktree setup and the same record.

## A record proves that Muxify made the Worktree

Each Muxify Worktree has one record, `$XDG_STATE_HOME/muxify/worktrees/<uuid>.json`, with its Environment, repository, folder, branch and starting commit. One file per Worktree, as for Topics ([ADR 0028](0028-topic-records-live-outside-tmux.md)), so two writers that make two Worktrees never merge one file. `muxify worktree list` reads these records, and Remove Worktree acts only on a Worktree that has one. A Topic's remembered Session names its Worktree's record with `worktree_id`.

The folder is no longer the proof. The default root stays `$XDG_STATE_HOME/muxify/worktrees/<repository>/<name>`, but `worktrees.root_path` in the Config and `worktreePath` in a project's `.worktree.json` can move it anywhere. A Worktree inside the root that has no record, such as one the old script made, is never listed or removed. Worktrees that a Topic made before records existed stay removable through their Topic record, inside the default root only, as before.

## `worktree create` is a second creation brick

[ADR 0039](0039-the-cli-can-do-what-the-command-palette-can-do.md) made "Add a Session on a new Worktree" the one brick that makes a Worktree, so that no Worktree is left without an owner. `worktree create <name>` is a second brick: it makes the Worktree, its record and a No Topic Session `<repository>/<name>`, then runs postCreate in that Session's first Window. The Session is part of the brick because postCreate runs there, where the user sees it and can stop it. The palette mirror is New Worktree.

## Removal

Remove Worktree runs preDelete before `git worktree remove`. It refuses a Worktree that a live Session or Pane uses unless `--kill` (⌘↩) kills them, and refuses a dirty Worktree or a failed preDelete unless `--force`. `--force` never skips the record. Removal drops the Topic's remembered Session too, so Reopen does not make the Worktree again. Branches are never deleted. Settle, Forget and Remove from Topic keep [ADR 0038](0038-worktree-creation-and-cleanup-are-explicit.md)'s rules and get no `--force`.

## Remote Environments

The palette Actions work on a Remote Environment over its owned SSH connection ([ADR 0006](0006-remote-environments-use-owned-ssh-connections.md)), and the records stay on the Mac, keyed by Environment. The CLI stays local: it talks to the local tmux server, and no `muxify` binary runs on the remote machine. Topics stay local, so a remote Muxify Worktree never has a Topic.

## Considered Options

- **Only Topics make Worktrees.** Rejected: the user wants the script's flow in any Session, and a Topic for each quick Worktree is ceremony.
- **A marker in the Worktree's private git folder.** It would travel with the Worktree and work remotely without a store on the Mac. Rejected for one folder of records that `list` reads without asking git in every repository.
- **One `worktrees.json` file.** Rejected: two processes that make Worktrees at once would merge one file.
- **A trust step for hooks**, as direnv has. Rejected for now: `.worktree.json` is usually the user's own uncommitted file, as with the script.

This amends [ADR 0038](0038-worktree-creation-and-cleanup-are-explicit.md) and [ADR 0039](0039-the-cli-can-do-what-the-command-palette-can-do.md).
