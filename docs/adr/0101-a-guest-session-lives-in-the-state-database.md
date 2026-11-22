# A Guest Session lives in the state database

> Supersedes in part [ADR-0018](0018-a-lock-lives-on-the-tmux-session.md): the Lock is no longer the tmux option `@muxify_lock`.

A Guest Session was only the tmux Session option `@muxify_lock` (ADR 0018). When tmux restarted, the Lock ended with the Session, so the user lost the card, the Session, its Windows and its place among the Guests. A Guest Topic came back, because its record is outside tmux. The user wants a Guest Session to come back too.

We keep each Lock as a row of the `guest_sessions` table in the state database, beside `topics` and `open_places`. The row has a stable id, the Guest Session's order (in the scale of the Topic records) and its Remembered Session, in the shape that a Topic record keeps for one Session. The live Session points at its row with `@muxify_session_id`, as a Topic's Session points at its saved Session. This removes the reason that ADR 0018 rejected a file: the row does not use the tmux Session id.

- **Live and Dormant.** A row with a live Session is a Guest Session. A row with no live Session is a Dormant Guest Session. Its card stays at its place among the Guests, dimmed, as a Dormant Topic is.
- **Coming back.** Opening a Dormant Guest Session creates the Session again with its Windows, Panes, Agents and tabs, as Reopen does for a Topic. `topics.reopen_at_launch` creates it at launch.
- **Ending.** Bench, Kill, New Topic from this Session and Move to Topic remove the row. A Session that ends on the same tmux server removes it. A tmux restart, a Muxify start and a reconnect do not: the rule is the one that Topics use for their Remembered Sessions.
- **One truth.** Muxify no longer writes `@muxify_lock`. A Session that still has it and no row gets a row with that order, and the option is removed.
- **The phone and other clients.** The Host CLI sends a Dormant Guest Session in `unpinned.guests` as a new card kind, `dormant_session`, and the rows as a `guest_sessions` event. Both go only to a client that declares the `guest-sessions` capability, so an older phone gets no Dormant card. A live Guest Session stays a `session` card, and its windows keep `lock_order` for a client without the capability, so an older Mac still shows it.

## Considered Options

- **Recreate every Guest Session at once after each tmux restart.** Rejected: a Dormant Topic waits until the user opens it, and the two kinds of Guest would act differently.
- **Keep `@muxify_lock` as a copy beside the row.** Rejected: two truths that can disagree, and the phone reads the Host's list, not tmux.
- **Make a Guest Session a Topic.** Rejected for the reasons of ADR 0018 and ADR 0061: it has no title and cannot be Settled or Pinned.

## Consequences

- A Session that ends while Muxify does not run keeps its row and shows as Dormant until the user Benches it.
- Each Host keeps its own Guest Sessions in its own state database.
- An older Muxify on the same machine does not see the rows; it shows a Guest Session as a No Topic Session. An older phone shows no Dormant Guest Session until it declares `guest-sessions`.
