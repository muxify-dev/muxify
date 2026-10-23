---
status: accepted
---

# Git operations run in the Git View, on lazygit's keys

The Git View stages, discards and commits. We bring more of lazygit to it: fetch, pull and push, branches, stashes, amend, cherry-pick, reset, merge and rebase, and continuing a merge or rebase. [ADR 0014](0014-every-action-runs-in-the-palettes-view.md) makes every Action run in the palette's view, but an Action is on a Topic, Session, Window, Pane, Agent or Tab. A git operation is on a repository's branches, commits and stashes, so it is not an Action.

Git operations run in the Git View, on lazygit's keys, each in the Git View tab that matches the lazygit panel that has it. When an operation needs a choice, a value or a confirmation, it asks in the Git View, in a menu or a one-line prompt there, as the Discard changes menu and the commit box already do. The keyboard stays in the Git View, and a lazygit user's keys work.

Muxify runs each operation itself. It does not hand an operation to the terminal in a new tmux Window, and a merge or rebase in progress is continued, skipped or aborted from the Git View, not "in the terminal".

Git operations are not changes that the palette makes, so [ADR 0039](0039-the-cli-can-do-what-the-command-palette-can-do.md) does not ask for CLI bricks for them. Agents and scripts run git themselves.

## Considered Options

- **Palette steps, as for Actions.** Rejected: branches, commits and stashes would have to be Sources, each operation would need a CLI brick, and one lazygit key would become ⌘K, a search and ↩.
- **Hand the operations that ask something to a new tmux Window, as `e` opens the editor.** Rejected: the Git View does what lazygit does without leaving it.
