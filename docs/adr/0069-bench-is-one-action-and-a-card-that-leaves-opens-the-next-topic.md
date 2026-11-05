# Bench is one Action, and a card that leaves opens the Next Topic

> Supersedes the End Guest part of [ADR-0064](0064-in-play-places-stay-open-and-guests-show-in-their-own-section.md).

Two Actions took a card out of In Play. Bench Topic was for a Topic, and End Guest was for a Guest Session. In the Guests section, a Guest Topic and a Guest Session look the same, so the user had to remember the card kind to find the Action. Also, after Bench Topic the user stayed on the Benched Topic, which the Bench line now hid. Settle already opened the Next Topic.

We make **Bench** one Action for every card In Play: a Topic in a place, a Guest Topic and a Guest Session. A Topic goes to the top of the Bench, as Bench Topic did. A Guest Session is Unlocked, as End Guest did. A Session has no record, so it cannot wait on the Bench ([ADR-0061](0061-a-guest-is-in-play-above-the-limit-and-keeps-its-position.md)). It waits in No Topic, and the user finds it in the Sessions source of a Command Palette.

When the user is on the card, **Settle, Forget and Bench open the Next Topic**: the nearest card below it that the Sidebar shows. With In Play and no such card, Muxify opens the first In Play card, also when the Bench is empty and the Sidebar shows no Bench line. With In Play, the Next Topic is never a Pinned Topic, because a Pinned Topic is not In Play. When the user is on another card, the Location does not change. After Bench, the Next Topic opens only when the Sidebar shows it. A Benched card keeps its Sessions, so when no other card is In Play, the user stays on it, and does not go to another card on the hidden Bench.

The Command and the card menus say "Bench". The palette row keybinding is `bench`; `end_guest` and `bench_topic` are gone. The CLI does not change: `muxify topic bench` Benches a Topic and `muxify session unlock` Benches a Guest Session, so the Command mirrors both verbs, as Make a Guest mirrors `topic make-guest` and `session lock`.

## Considered Options

- **A neutral name, such as "Take Out of Play".** Rejected: it is a new term beside Bench, and the user types "bench" to find it.
- **Let a Guest Session wait on the Bench.** Rejected: it reverses ADR-0061. A Benched Session needs a place in the order without a Topic record, and Choose In Play and Replace from Bench must then list Sessions.
- **Keep two names, chosen by the Sidebar section.** Rejected: there are still two names for one intent.
- **A Config key to turn off the wrap to the first In Play card.** Rejected: the user wants the wrap every time, but never to a Pinned Topic.

## Consequences

- With a Guest Session, Show Bench does not show the Session after Bench. The glossary entry says this.
- A Config that binds `end_guest` or `bench_topic` shows an "unknown action" problem until the user changes it to `bench`.
