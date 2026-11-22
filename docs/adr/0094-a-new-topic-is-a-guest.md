# A new Topic is a Guest

> **Partly superseded by [ADR-0102](0102-a-board-session-can-take-an-in-play-place.md):** a new Topic from a Board Session takes its place and its section, an In Play place or a place among the Guests, not always the Guest mark.

A new Topic went to the top of the Bench, or to the first free In Play place ([ADR-0081](0081-in-play-is-the-only-topics-mode.md)). On the Bench, the Sidebar hides it, so the user had to find it. Agents ran `muxify topic new` and then `muxify topic make-guest` to show it. In a free place, it took that place without the user's choice.

We decide that **every new Topic is a Guest**. It goes to the end of the Guests, directly above the Bench line, as Make a Guest puts a Benched Topic there.

- **One rule for every way to make a Topic.** New Topic on the Mac, the phone, `muxify topic new`, Move to a new Topic and the `muxify://topic` URL all make a Guest. The Topic store makes the Guest when it adds the record, in the same write, with the order code of Make a Guest.
- **A free place stays free.** A new Topic takes no In Play place, also when one is free or Open. The user chooses the Topics In Play.
- **The user decides the next step.** Up to In Play with Move Topic Up, Fill an Open Place, a trade or Choose In Play. Down to the Bench with Bench. Or the Topic stays a Guest.
- **No opt-out.** `muxify topic new` has no flag that makes a Topic that is not a Guest. A script that needs one runs `muxify topic bench` next.
- **What does not change.** A Topic from a Guest Session takes the Guest Session's place and its mark, as before. A Settled Topic that Reopen or Start Fresh brings back goes to the top of the Bench. A Pinned record goes last among the Pinned Topics.

## Considered Options

- **Guest only from the CLI, with `--no-guest`.** Rejected: the phone runs `muxify topic new` too, so its New Topic would make a Guest while the Mac's did not. An older Host CLI refuses an unknown flag, so the phone cannot send `--no-guest` to every Host.
- **A Config key for the place of a new Topic.** Rejected: ADR-0081 removed `topics.insert_position` for the same reason. Each rule of the list would need an answer for each value.

## Consequences

- The text in ADR-0061, ADR-0064 and ADR-0081 about where a new Topic goes does not apply.
- A script that expects a new Topic on the Bench or In Play must move it with `muxify topic bench`, `muxify topic fill-place` or `muxify topic move up`.
- The Guests can grow. Each new Topic adds one card above the Bench line until the user moves it.
