# A Board Session can be Pinned, and Unpin makes a Guest

> Supersedes in part [ADR-0102](0102-a-board-session-can-take-an-in-play-place.md) ("A Board Session is never Pinned") and [ADR-0061](0061-a-guest-is-in-play-above-the-limit-and-keeps-its-position.md) ("Unpin puts the Topic at the top of the Bench").

ADR 0102 kept Pin for Topics. The user wants to keep a Session at the top of the Board without making a Topic from it. We let every card be Pinned. Bench, Settle, Forget, the Topic Note and Tags stay Topic-only, because they act on a Topic record.

- **Pin** works on a Board Session as on a Topic: the card goes last among the Pinned cards; from an In Play place it leaves an Open Place; a Guest loses its Guest mark. Move Up and Move Down reorder the Pinned cards, Topics and Board Sessions together.
- **Unpin** puts the card at the end of the Guests, as a Guest, for a Topic and for a Board Session, also when an In Play place is free. It never fills an Open Place. The Bench holds only Topics, so a Board Session cannot go to the top of the Bench; one rule for every card is easier to predict than two.
- **A Pinned Board Session** lives as a Pinned Topic: Dormant among the Pinned cards after a tmux restart, with Reopen, Start Fresh and `topics.reopen_at_launch`. Bench is not offered on it. When its Session ends or goes into a Topic, its card leaves the Board and leaves no Open Place. A new Topic from it is a Pinned Topic at its place.
- **The names.** The Commands and the card menu say "Pin" and "Unpin" on every card. The Keybinds key `pin_topic` and the CLI verbs `muxify topic pin|unpin` stay; the CLI takes `--board-session <id>`.
- **The state database.** Step 7 adds `pinned` to `board_sessions`.
- **The protocol.** `board` widens in place, as ADR 0102 renamed `guest-sessions` in place: no release has it. A `board_sessions` row has an optional `pinned`, the `pinned` section can hold `session` and `dormant_session` cards, and `pin`/`unpin` take a `board_session` target. A reader without `board` gets a live Pinned Board Session as a No Topic Session. An older Mac reads `lock_order` and shows it as a Guest.

## Considered Options

- **Unpin to the next free In Play place, else the end of the Guests** (the rule of a returning Topic). Rejected: the user wants the card where they can see it, and one rule for every card.
- **A capability `board.pins` with a fallback.** Rejected: no released peer speaks `board`.
- **Note and Tags on a Board Session too.** Rejected for now: they need their own columns and wire values.
