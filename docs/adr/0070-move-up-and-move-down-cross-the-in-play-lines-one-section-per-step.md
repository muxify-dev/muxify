# Move Up and Move Down cross the In Play lines, one section per step

> **Partly superseded by [ADR-0081](0081-in-play-is-the-only-topics-mode.md):** `topics.in_play` is always set, so Move Up and Move Down always cross the lines. The text below about a Config without `topics.in_play` does not apply.

With `topics.in_play` set, the keyboard needed a different Command for each change of section: Bench, Make a Guest, Fill Place with its choose step, or Choose In Play. Only a Sidebar drag changed the section in one gesture. Move Topic Up and Move Topic Down stepped past the next card in list order, and the cut at the lines ([ADR-0064](0064-in-play-places-stay-open-and-guests-show-in-their-own-section.md)) then decided the section. Nobody designed that result.

We make Move Up and Move Down section-aware. Inside a section, a step is a reorder, as before. A step that would cross the Guests line or the Bench line changes the card's section, one section per step, and each step goes back with the opposite key:

- **In Play place.** Up and Down inside the places swap the card with its neighbor. A neighbor that is an Open Place swaps the same way. The first place has no Up. Down from the last place makes the card the top Guest, and it leaves an Open Place at its place.
- **Guest.** Up and Down inside the Guests reorder. Up from the top Guest fills the lowest Open Place, and the card loses its Guest mark. When no place is open, it is a Trade with the card in the last place, which becomes the top Guest. A Guest Session cannot take a place, so it has no Up from the top. Down from the last Guest is Bench: a Topic goes to the top of the Bench without its mark and leaves no Open Place, and a Guest Session is Unlocked.
- **Benched Topic.** While the Bench shows, Up and Down reorder inside the Bench, and Up from the top of the Bench is Make a Guest. While the Bench is hidden, Up from any Benched card is Make a Guest, and Down does nothing, because no card shows below it.
- **Pinned Topic, or no `topics.in_play`.** No change. A card moves only among the cards with its Pin.

The CLI cannot see the Sidebar, so `muxify topic move` and `muxify session move` act as if the Bench shows. The CLI keeps its reorder of the Bench, and `muxify topic make-guest` takes a Benched Topic In Play in one step.

**The user stays on the card.** When a step takes the card the user is on to a hidden Bench, the Location does not change, and the Next Topic does not open. This differs from Bench ([ADR-0069](0069-bench-is-one-action-and-a-card-that-leaves-opens-the-next-topic.md)). Bench says "I am done with this card for now". A step is one of a series of key presses, and the user presses Up next to take the card back. The Sidebar shows the card under the Bench line while the user is on it.

## Considered Options

- **Make the lines walls, so Move stops at them.** Rejected: the user then still needs four Commands to change a section, and that is the problem.
- **Down from the last place goes to the end of the Guests, and Up from the top Guest takes the first Open Place.** Rejected: the card then jumps over other cards, and the opposite key does not take it back.
- **Down from the last place moves the last Guest to the Bench to keep the Guests the same length.** Rejected: a key step then moves a card that the user is not on.
- **Make Move act as the Sidebar drag does, with a Trade at each line.** Rejected: a drag names the other card, and a key step does not. A Trade on each step pushes the neighbor into the other section without the user choosing it.
- **The CLI gets a flag for the state of the Bench.** Rejected: the CLI user has no Bench to fold, and `topic make-guest` already does the step in one call.

## Consequences

- A drag and a key step act differently at a line. A drag across a line is still a Trade.
- Move Topic Up and Move Topic Down are enabled at more cards: the last place, the top and the last Guest, and a Benched card while the Bench is hidden.
