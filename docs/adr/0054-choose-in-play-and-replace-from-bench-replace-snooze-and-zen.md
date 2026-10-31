# Choose In Play and Replace from Bench replace Snooze and Zen

> **Partly superseded by [ADR-0064](0064-in-play-places-stay-open-and-guests-show-in-their-own-section.md):** a Settle of an In Play card no longer moves the top of the Bench up. It leaves an Open Place. Choose In Play also lists the Guest Topics, and the places that no checked card fills are Open Places. The other rules below still apply.

With `topics.in_play` set, the Bench ([ADR 0055](0055-the-sidebar-shows-only-the-topics-in-play.md)) already keeps out of view the Topics that the user does not work on now. Snooze and Zen did the same job in a second way, and the user used Snooze mostly to hide one part of the day's Topics, such as personal Topics during work. We remove Snooze, Unsnooze, Snooze Topics…, Unsnooze Topics… and Zen. Two Actions set the In Play Topics instead. Both use palette steps that already exist, and both show only while `topics.in_play` is set.

- **Choose In Play…** has two steps. The first is the Check step of [ADR 0035](0035-a-check-step-checks-topics-for-snooze-and-unsnooze.md). The current In Play cards start checked. The step has no Tag rows: a query such as `#work` narrows the rows, and the user checks each card by its own row. The second step is one choose-a-row for each place, with the rows in their current order, so ↩ on each place keeps the order. Each checked card gets a place: the places after the last In Play place are the top of the Bench, so the checked cards after the last In Play place go there in the order the user chose.
- **Replace from Bench…** works on the card of the Location while it is In Play, a Topic or a Locked Session. The Benched card that the user chooses takes its place. The replaced card goes to the end of the Bench, and the Location goes to the card that came In Play. There is no Config option for this.
- **New Topics** go to the top of the Bench. A Topic that Reopen or Start Fresh brings back goes there too. `topics.insert_position` applies only without `topics.in_play`.
- **Settle** of an In Play card leaves the list to close the gap: the top of the Bench moves up into the place.
- **On upgrade**, a running Zen ends as before. Then each Snoozed Topic goes to the top of the Bench, in the order it would wake. Without `topics.in_play`, it goes where `topics.insert_position` puts it.

This supersedes [ADR 0031](0031-zen-remembers-the-snoozes-it-changed.md) and [ADR 0036](0036-a-tag-row-in-snooze-topics-checks-only-topics-that-are-not-snoozed.md). The Check step of ADR 0035 stays and now serves Choose In Play, but without its Tag rows, because only Snooze Topics… needed them.

## Considered Options

- **Keep Snooze beside the Bench.** Rejected: two ways to hide a Topic, and the timed return that only Snooze gives was rarely used.
- **A Tag Lens, which shows only one Tag's Topics In Play.** Rejected: the user keeps #work and #personal Topics In Play at the same time.
- **A rank number on each Topic, or a Swap In step with a cursor that inserts between cards or replaces a card.** Rejected: the cursor hid a mode, and a number per Topic made each move a separate decision.
- **Mark Forster's Final Version Perfected: one pass of "do I want this more than the last dot?" for each place, with saved dots.** Rejected: In Play holds about five places. Choosing the first, then the next, orders five cards in four short choices. FVP needed saved dots and a new kind of palette step.
- **A Config option for where Replace from Bench sends the replaced card.** Rejected: the end of the Bench, as in Forster's lists, keeps the top of the Bench for the cards the user put there.

## Consequences

- The rules that hid the Agent marks of Snoozed Topics, and of No Topic during Zen, go away. With `sidebar.agents_scope: all`, the Agents section shows the marks of Benched Topics. The Bench line still shows none.
