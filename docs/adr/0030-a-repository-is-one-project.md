# Repository discovery supplies Worktree launch rows

Git determines repository layout, including bare repositories. Discovery offers
the main checkout and linked Worktrees as launch choices, wherever they live.

The former one-Session-per-repository membership rule is superseded by
[ADR 0036](0036-topics-group-sessions-not-repositories.md): Topics group Sessions,
not folders or repositories. A Topic may have several Sessions in one checkout.

[ADR 0038](0038-worktree-creation-and-cleanup-are-explicit.md) supersedes the old
creation and cleanup defaults. Worktrees are explicit opt-in, allocated with
branch and folder collision checks, and remembered with exact provenance.
Cleanup is opt-in and requires managed ownership, cleanliness and no remaining
Session or Pane users. Settle also requires merged work. Branches are never deleted.
