# A new Topic from the last Window or Pane of a Guest Session takes its place

> **Partly superseded by [ADR-0102](0102-a-board-session-can-take-an-in-play-place.md):** a new Topic from a Board Session takes its place and its section, an In Play place or a place among the Guests, not always the Guest mark.

This extends [ADR-0094](0094-a-new-topic-is-a-guest.md). ADR-0094 says that a Topic from a Guest Session takes the Guest Session's place and its mark. That was true only when the user moved the whole Session. When the user moved the Guest Session's last Window or its last Pane into a new Topic, the Guest Session ended too, but the new Topic went to the end of the Guests. The user saw the same result in tmux, with the Topic in a different place.

We decide that **a new Topic takes the place of the Guest Session that the move ends**. The source can be the whole Session, its last Window, or the last Pane of its last Window. The new Topic gets the Lock's order value and the Guest mark. No other card moves.

- **One rule in MuxifyCore.** `TopicMembershipPlan` gives the Lock to the Topic store when the move ends a Locked Session, for each source. So the Mac app, the CLI, the phone and every Host CLI with this change do the same thing.
- **No Lock unset for a Window or Pane.** tmux ends the Session when its last Window leaves, and the Lock ends with it. The plan unsets the Lock option only for a whole Session, which stays alive in the new Topic.
- **The source card stays: the end of the Guests.** When the Guest Session keeps other Windows, or the source is a Guest Topic, the new Topic goes to the end of the Guests, as ADR-0094 says. Both cards stay, so there is no place to take.
- **The CLI moves a whole Session.** `muxify session move --new-topic ["title"]` and `muxify session move --topic <id|label>` move the Session that `--session`, `--pane` or the caller Pane names, as Move Session does in the palette ([ADR-0039](0039-the-cli-can-do-what-the-command-palette-can-do.md)). Before, the CLI could move only a Window or a Pane.

## Considered Options

- **Under the source card, when the source card stays.** Rejected: the Guests under the source move down one row, and the list gets a second rule for the position of a new Topic.
- **`window move --new-topic --session <name|id>` for a whole Session.** Rejected: with `--topic`, `window move --session` names the destination Session. With `--new-topic`, it would name the source. In the `session` verbs, `--session` always names the Session that the verb acts on.

## Consequences

- A Remote Host with an older Host CLI puts the new Topic at the end of the Guests until its Host CLI updates.
- If `move-window` fails after the record is written, the Topic and the Lock both show, as for a whole Session.
