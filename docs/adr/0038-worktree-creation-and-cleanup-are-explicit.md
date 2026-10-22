# Worktree creation and cleanup are explicit and independent of Topic membership

Grouping Sessions never implicitly creates a Worktree. Explicit creation allocates branches and folders from the Topic slug (`fix-payments`, `fix-payments-2`, and so on), checking both branch and folder availability so one Topic can create several Worktrees of the same repository. Remember each exact branch, path, repository and starting commit; moving a Session between Topics preserves this provenance instead of inferring ownership from its new Topic or name.

Keep Worktree is the default everywhere. Deletion is explicit opt-in and is offered only for clean, Muxify-created Worktrees inside its managed Worktree area that no remaining live Session or Pane uses. Settle additionally requires merged work; Forget and Remove-and-Kill may explicitly remove clean unmerged Worktrees. Never automatically delete branches. Shared Worktrees are filesystem resources, not Session identities, so cleanup considers each physical Worktree once and preserves it while any remaining user needs it.

This replaces the creation allocation and cleanup-default portions of [ADR 0030](0030-a-repository-is-one-project.md), while retaining its managed-folder safety boundary.
