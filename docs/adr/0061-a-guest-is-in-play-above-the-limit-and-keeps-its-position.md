# A Guest is In Play above the limit and keeps its position

> **Partly superseded by [ADR-0064](0064-in-play-places-stay-open-and-guests-show-in-their-own-section.md):** a Guest no longer keeps its position among the In Play cards. The Guests show in their own section, under a Guests line after the In Play places. A regular card that leaves a place leaves an Open Place. A Trade across the Guests line gives the Guest mark to the card that leaves the places. Bench Topic takes the place of End Guest for a Guest Topic, and Choose In Play lists the Guest Topics. The rules for Make a Guest, the Lock and the mark in the record still apply.

With `topics.in_play` set, a user who goes to a Benched Topic from a Command Palette had two ways to keep it in view: Replace from Bench or a Trade. Both send another card to the Bench. Often the user wants the Topic in view for a short time only, without a change to the regular In Play cards. A Locked Session had the same problem: it took one of the N places, so a Lock pushed a Topic to the Bench.

We add the **Guest**: a card In Play above the limit. In Play is the first N + G cards that are not Pinned, where N is `topics.in_play` and G is the number of Guests. N counts only the cards that are not Guests.

- **Make a Guest** works on a Benched Topic or a No Topic Session. The card goes to the end of In Play, directly above the Bench line, with the Guest mark. No other card goes to the Bench.
- **End Guest** on a Guest Topic puts it at the top of the Bench, so In Play is one card shorter. On a Guest Session it Unlocks the Session, so its card ends.
- **A Lock and a Guest Session are one state.** A Session keeps only `@muxify_lock` ([ADR 0018](0018-a-lock-lives-on-the-tmux-session.md)). With `in_play` set, every Locked Session is a Guest: it never waits on the Bench and never gets a regular place. To give a Session a regular place, the user makes a Topic from it. Without `in_play`, a Locked Session is as before. With `in_play` set, the menus and the Commands offer Make a Guest and End Guest in place of Lock Session and Unlock Session. Both write the same Lock.
- **A Topic keeps its mark in its record**, as `guest: true` ([ADR 0028](0028-topic-records-live-outside-tmux.md)). Without `in_play`, the mark has no effect, and the record keeps it. Settle and Pin remove it.
- **A Guest keeps its position.** When a card that is not a Guest leaves the list (Settle, Forget, Pin), the Guests stay at the same positions. The other cards move up only through the positions that no Guest holds, and the top Benched card fills the last free one.
- **A Guest that leaves** (Settle, Pin, End Guest, the end of its Lock) makes In Play one card shorter. No Benched card moves up. The other Guests keep their positions, and a Guest past the new end of In Play goes to the end.
- **A Trade or Replace from Bench on a Guest** gives the Guest mark to the card that comes In Play. The Guest Topic goes to the Bench as a usual card, and the Lock of a Guest Session ends. A Trade of a card that is not a Guest does not touch the Guests.
- **A drag in In Play is a reorder.** The mark stays on its card. A Guest can move by one position when another card moves past it.
- **Choose In Play leaves the Guests out.** The check step does not list them. Its N places skip the positions that Guests hold: with a Guest at position 1, place 1 is position 2. The Guests stay where they were.
- **Pin a Guest** removes its mark. **Unpin**, with `in_play` set, puts the Topic at the top of the Bench, where a new Topic goes.
- **New Topic from a Guest Session**: the new Topic takes the card's place and gets the Guest mark.
- **The mode switch.** When the Config sets `in_play`, each Lock becomes a Guest at the end of In Play, after the first N Topics. When the Config removes it, each Guest Session stays a Locked Session at its place.
- There is no limit to the number of Guests.

The Sidebar card of a Guest shows a quiet "Guest" mark where a Pinned Topic shows its pin. The CLI has `topic make-guest` and `topic end-guest` for a Topic. `session lock` and `session unlock` make and end a Guest Session ([ADR 0039](0039-the-cli-can-do-what-the-command-palette-can-do.md)).

## How the order keeps the positions

The order of the Topics list is one number for each card, as before. MuxifyCore computes every Guest rule in `TopicOrder`. `InPlayCut` cuts the cards at the Bench line: every Guest is In Play, and the first N other cards. Each change that the rules above name writes the order In Play first, then the Bench. `TopicTransaction` writes every change of the list, from the app and from the CLI. When a change takes a card out of the list, it writes the order again, so that each Guest keeps its position.

## Considered Options

- **A Guest at the end of In Play always, with no position of its own.** Rejected: a drag puts a Guest where the user wants it, and the next Settle of a regular card would move it back to the end.
- **A Guest Session as a second state beside the Lock, with its own tmux option.** Rejected: then a Session has three states (No Topic, Locked, Guest), and a Lock without `in_play` and a Guest with it mean the same to the user: "keep this Session in view".
- **A Lock that waits on the Bench, as a Topic does.** Rejected: a Locked Session has no record, so the Bench cannot keep it when it is out of view, and it is not a Topic to Settle or Reopen.
- **The Locks keep their places when the Config sets `in_play`.** Rejected: a Lock at position 2 then takes a position that a Topic had, and the first N Topics are no longer together under the Pinned Topics.

## Consequences

- When the Session of a Guest ends, or tmux restarts, no write happens. The Guests under it move up one position.
- The app moves the Locks when it first sees `in_play` set, also at its next start when the Config changed while it did not run. A flag in its defaults records the move, and only a Config without `in_play` clears it. So a restart does not move the Guests again. The CLI does not move them.
- If the user has many Locks when they set `in_play`, In Play gets long. The user ends the Guests that they do not need.
- A Trade or an End Guest of a Guest Session ends its Lock. When the user removes `in_play` later, that Session has no card.

This changes [ADR 0055](0055-the-sidebar-shows-only-the-topics-in-play.md), where a Locked Session counted toward N, and [ADR 0018](0018-a-lock-lives-on-the-tmux-session.md).
