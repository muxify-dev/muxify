---
status: accepted
---

# Where the Git View's operations differ from lazygit

[ADR 0040](0040-git-operations-run-in-the-git-view-on-lazygits-keys.md) gives the Git View lazygit's git operations and keys, and they behave as lazygit's do unless this ADR says otherwise. Each difference below is deliberate. Do not change one to match lazygit without a new ADR.

- **No auto-fetch, for now.** lazygit fetches every 60 s and fast-forwards the main branches. The Git View fetches only on `f`, so no ref moves unless the user asks.
- **Operations that change files ask first while an Agent is working there.** Checkout of a branch or a commit, pull, merge, rebase, hard reset, stash, apply, pop, cherry-pick and discard confirm first, naming the Agents, when an Agent that is working or blocked has a Pane in that Worktree. lazygit cannot know about Agents, and changing the files under a turn that is still running breaks its work.
- **A hard reset to a commit asks again when there are Changes**, and names how many files it discards, as `d` does. In lazygit the Reset menu of `g` is the only confirmation, and the Git View has no undo. The reset options of `D` are all about discarding the working tree, so each runs at once, as the choices of `d` do.
- **A branch checked out in another Worktree goes to a Window there.** Where lazygit offers to switch to that worktree, the Git View offers to go to the most recent Window with a Pane in it, or else opens Go to… on that Worktree's Session Path. The Git View's repository is its Window's folder, so it cannot switch by itself, and starting a Session stays a palette Action ([ADR 0014](0014-every-action-runs-in-the-palettes-view.md)).
- **Copied commits belong to the repository.** Each Window has its own Git View, so Copied commits are shared by every Window in any Worktree of the repository, and kept while Muxify runs. Copying in one Topic's Worktree and pasting in another's is the usual cherry-pick here.
- **Deleting a branch that a Topic remembers names the Topic.** When a Topic's Worktree folder is gone, Reopen checks out its remembered branch, and starts again from `base` when the branch is gone too ([topic records](../topic-records.md)). Deleting the branch loses that work for Reopen.
- **The page opens as a Tab in the Window's Browser, not with `open`.** lazygit's `o` runs `open <link>`. In the Git View the page opens as a ⌘-click on a link in the terminal does: the Browser reuses a Tab already on that page, shows itself, and the page gets Focus. A popup Git View closes, because it floats over the Browser; a fullscreen one stays open.
- **A pull request link comes from the remote of the branch's upstream, not always `origin`; a commit link uses `origin`, or the only remote.** lazygit reads `origin` for every branch. The Git View reads `branch.<name>.remote`, through `git ls-remote --get-url` so that `insteadOf` rules apply, because a branch that tracks a fork must open the fork's page. A branch with no upstream, or one on the remote `.`, opens nothing and says so. A commit has no upstream, so its link comes from `origin`, or else from the only remote when there is no `origin`; with no remote, or several and none called `origin`, it opens nothing and says "There is no 'origin' remote". A commit opens even when it isn't on the remote, as in lazygit.
- **`git_view.services` hosts are matched exactly, and the Config's entries come before the built-in ones.** lazygit tests for a substring and checks its built-in domains first, so `github.company.com` counts as github.com there. Here it is its own host, mapped by an entry or unsupported. An entry with no `:` or with an unknown provider goes to the Config problems banner and is skipped, where lazygit writes it only to its log.

## Credentials, also on a Remote Environment

As in lazygit, fetch, pull, push and deleting a remote branch run under a PTY with `LANG=C`. The Git View watches their output for lazygit's credential prompts, and for ssh's question about an unknown host, and asks in a Git View prompt that hides what the user types for a secret. On a Remote Environment the command runs over SSH with a remote PTY, so the prompts work there too. Other git commands run as before, with no terminal, and fail with git's message when they would ask.

## Considered Options

- **A `GIT_ASKPASS` and `SSH_ASKPASS` helper.** git and ssh would hand it the exact question, with nothing to parse. Rejected: on a Remote Environment the helper runs on the other machine and has no way back to Muxify.
- **Auto-fetch while the Git View is open, without lazygit's fast-forward.** Deferred, not rejected.
