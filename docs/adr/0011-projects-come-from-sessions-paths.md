# Session Paths come from `sessions.paths`

One Config section, `sessions.paths`, discovers launch folders for the palette,
Topics and CLI. Entries support glob paths, depth, display depth and symlinks.
Discovery runs on each Environment's machine. Topics stay local.

Repository layout comes from Git, including bare repositories and Worktrees
outside the discovery roots. Plain repositories offer their main checkout as
`repo`; linked Worktrees use `repo/folder`. Aliases are display-only.

The earlier folder-based matching and repository ownership model is superseded
by [ADR 0036](0036-topics-group-sessions-not-repositories.md) and
[ADR 0037](0037-the-sessions-source-lists-sessions-individually.md).
Launch matching now uses exact Session names. Duplicate launch names keep the
first configured entry and warn instead of silently renaming.
