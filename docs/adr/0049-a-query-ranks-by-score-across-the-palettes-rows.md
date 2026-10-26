# A query ranks by score across the palette's rows

Weak matches showed above strong ones in a Command Palette. Typing "claude mods" in Go to… showed five Worktree Session Paths, then the Snoozed Topic "What are Claude Code mods?", which was the best match of all. This ADR changes the rules that caused it, one section for each rule.

## A word must match at 55% of its own score or better

fzf shows every row that holds the letters of a word in order. Every Worktree path starts with `~/.local/state/muxify/worktrees/`, and that start holds most letters of most words. So "claude" matched `~/.local/state/muxify/worktrees/muxify/unify-app-focus-and-move-its` letter by letter.

Now a word counts as a match in a field only when its score there is at least 55% of the score of the word against itself. In real searches, initials ("mfs" for `muxify-focus-something`) and parts of a word ("ify" in `muxify`) scored 64% or more. Letters spread over a path scored 25% to 46%. A word of one character has no minimum, so a letter inside a word still matches.

## Considered Options

- **Drop rows below a fraction of the best row's score.** Rejected: the list changes when the best row changes, so rows appear and go while the user types.
- **Match only the end of a Session Path's folder.** Rejected: it removes this noise, but not the noise of other long fields that share a start.
