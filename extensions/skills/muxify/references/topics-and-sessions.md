# Topics and Sessions

A Topic is one thing the user wants to get done. It groups Sessions, and its Sessions can be in different repositories, such as a backend and a client changed for the same fix. Your Session is one of them. Each Session has Windows, and each Window has Panes.

## See the whole Topic

- `muxify topic show` prints the Topic's id, label and Tags, and each live Session's name, folder and branch. With `--json`, also its Windows, Panes and Agents.
- `muxify topic status` prints `git status --short --branch` for each Session. Use it before you report work as done, to find changes in the other repositories of the Topic.
- `muxify topic diff` prints one patch of the Topic's work in every Session, since each Session's base. `--stat` gives a summary. Use it to review the full change, not only your repository's part.
- `muxify topic exec -- <command> [<argument>...]` runs the command once in the folder of each Session, all at the same time, and prints each output under a `==> <session> <==` line. It types nothing into a Pane. Use it to run the tests or the build of every repository of the Topic. `--session` runs it in one Session.

## Add to the Topic

- `muxify window new -- <command>` makes a Window in your Session and runs the command there. Use it for a process that must keep running, such as a dev server or a watcher, so the user can see it and stop it. It prints the new Window's id.
- `muxify topic add-session <dir>` makes a Session in another folder for this Topic. `--worktree` makes a new Worktree on a new branch named from the Topic, so your work does not change the user's checkout.
- `muxify window move` moves a Window to another Session or Topic.

## Worktrees outside a Topic

- `muxify worktree create <name> --no-open` makes a Muxify Worktree of the repository you are in, on the branch `<name>`, with a No Topic Session `<repository>/<name>` in it. The project's `.worktree.json` copies files into it and runs its postCreate hooks in that Session's first Window. Leave out `--no-open` only when the user wants to see the new Session now.
- `muxify worktree list` prints the Muxify Worktrees of this repository: name, branch, `clean`, `dirty` or `missing`, path, the Sessions in it and its Topic. `--all` lists every repository's.
- `muxify worktree remove <name>` runs the preDelete hooks and removes the Worktree. The branch stays. Ask the user first, most of all for `--kill` or `--force`.

## Change the Topic

`topic rename`, `topic note`, `topic tag`, `topic pin`, `topic move`, `topic choose-in-play` and the `mark-read` and `mark-unread` verbs change how the user sees their Topics. Run them when the user asks.

`topic settle` marks the Topic as done. Without flags it keeps the Sessions and Worktrees. With `--kill-sessions` it stops every process in them, and with `--remove-worktrees` it removes the merged Worktrees that the Topic made. Ask the user before you settle.
