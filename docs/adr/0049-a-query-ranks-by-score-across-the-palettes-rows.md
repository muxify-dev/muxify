# A query ranks by score across the palette's rows

Weak matches showed above strong ones in a Command Palette. Typing "claude mods" in Go to… showed five Worktree Session Paths, then the Snoozed Topic "What are Claude Code mods?", which was the best match of all. This ADR changes the rules that caused it, one section for each rule.

## A word must match at 55% of its own score or better

fzf shows every row that holds the letters of a word in order. Every Worktree path starts with `~/.local/state/muxify/worktrees/`, and that start holds most letters of most words. So "claude" matched `~/.local/state/muxify/worktrees/muxify/unify-app-focus-and-move-its` letter by letter.

Now a word counts as a match in a field only when its score there is at least 55% of the score of the word against itself. In real searches, initials ("mfs" for `muxify-focus-something`) and parts of a word ("ify" in `muxify`) scored 64% or more. Letters spread over a path scored 25% to 46%. A word of one character has no minimum, so a letter inside a word still matches.

## Every separator earns the same bonus

fzf's default scheme gives a word that starts after a space a bonus of 10, after `/` 9, and after `-` or other punctuation 8. Topic titles separate words with spaces, and Session names with `/` and `-`. So a Topic beat a Session for the same word: "woodoku" scored 100% in "GS - Block Blitz from Woodoku Blast" and 92% in `game_server/gs-woodoku-blast-in-echidna`.

The palettes now use fzf's history scheme, which gives every separator a bonus of 8. Those rows now tie, and the rules for an equal match decide. The matcher keeps fzf's default scheme too, and its tests still compare it with fzf's own scores.

## Snoozed and Settled Topics rank by their score for a query

[ADR 0012](0012-topics-are-a-source-of-the-command-palette.md) put Snoozed and Settled Topics after every other Source's rows, even when they matched better. That rule is right when nothing is typed: these Topics are seldom the place to go. When the user types the title of a Snoozed Topic, that Topic is the place to go.

- With an empty query, the Snoozed and Settled Topics stay last, as before.
- With a query, they rank by score. They join the Topics section, without their own headers.
- On an equal match, an open row goes before a Snoozed or Settled Topic.

## Considered Options

- **Drop rows below a fraction of the best row's score.** Rejected: the list changes when the best row changes, so rows appear and go while the user types.
- **Match only the end of a Session Path's folder.** Rejected: it removes this noise, but not the noise of other long fields that share a start.
