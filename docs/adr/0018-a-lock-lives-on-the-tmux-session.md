# A Lock lives on the tmux Session

> **Update 2026-10-30:** With `topics.in_play`, a Locked Session is a Guest: it is In Play above the limit and never waits on the Bench ([ADR 0061](0061-a-guest-is-in-play-above-the-limit-and-keeps-its-position.md)). The Lock stays the only state of the Session: `@muxify_lock` holds its order, and `in_play` decides if it is a Guest. A new Topic made from a Guest Session takes its place and gets the Guest mark in its record.

A Locked Session is a No Topic Session that keeps a card, with a number, among the Topic cards. Its position is in the same order as the Topics, so the user can move it, and a Topic made from it takes its place. We store the Lock as the tmux Session option `@muxify_lock`, whose value is the card's order in the same scale as the `order` field of the Topic records (ADR 0028). The Lock has no file: it ends with the Session, when the Session is killed or tmux restarts, and each Environment has its own Locks, as for `@muxify_topic`. tmux stays the source of truth for what is live (ADR 0001).

## Considered Options

- **A `locks.json` record beside `topics/`.** Rejected: Muxify must remove an entry when its Session ends, and tmux Session ids change after a restart, so the file would hold Locks that point at nothing.
- **Only in Muxify's memory.** Rejected: an app restart would lose every Lock while the Sessions stay live.
- **Make the Lock a Topic.** Rejected: a Locked Session must not be Settled, Snoozed or Reopened. A user who wants that makes a Topic from the Session.

## Consequences

- A Lock that should come back after a tmux restart is a Topic, not a Lock.
- When a Locked Session goes into a Topic, through "New Topic from this Session" or "Move to Topic", the option is removed. A new Topic takes the Locked Session's `order`.
- Zen keeps only Topics. While Zen is on, Locked Sessions are hidden, but nothing is Snoozed, so they come back when Zen ends.
