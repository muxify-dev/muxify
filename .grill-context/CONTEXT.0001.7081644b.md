---
fragment: 7081644b
generation: 0001
branch: master
---

~ Git View
  A view of the repository in the current Window's folder: its Changes, history, branches and stashes in Git View tabs, with the selected one's diff. From it, the user stages, discards and commits Changes, or lines of them, and runs lazygit's git operations on branches, commits and stashes, such as push, checkout, merge and cherry-pick. A branch goes into its commits, and a selected commit or stash shows its Diff files under them. It opens as a popup over the App Window or in the terminal's place. Each Window has its own, kept as it was left while another Window is shown.
  avoid: lazygit (when you mean ours), git panel, diff viewer
  was: A view of the repository in the current Window's folder: its Changes, history, branches and stashes in Git View tabs, with the selected one's diff. Changes, or lines of them, can be staged and discarded from it, and what's staged committed. A branch goes into its commits, and a selected commit or stash shows its Diff files under them. It opens as a popup over the App Window or in the terminal's place. Each Window has its own, kept as it was left while another Window is shown.

+ Git View menu
  A list of choices that a key opens in the Git View, each choice with its own key, such as Discard changes or Reset. A confirmation is a Git View menu with one choice.
  avoid: popup, dialog, sheet, palette step
  under: Git

+ Git View prompt
  A one-line field in the Git View for one value, such as a branch name.
  avoid: input box, dialog, palette field
  under: Git

+ Copied commits
  The commits the user marks in the Git View to cherry-pick onto the branch they are on. They belong to the repository, not to one Window: marked in one Worktree's Git View, they can be pasted in another's. They stay marked until they are pasted or cleared.
  avoid: clipboard (when you mean these), marked commits, picked commits
  under: Git
