# The Bench scrolls alone, and no card moves when it shows

With `topics.in_play` set, the card of the Location on the Bench showed directly under the Bench line, also when the Bench was shown ([ADR 0055](0055-the-sidebar-shows-only-the-topics-in-play.md)). So a click on a card in a shown Bench moved that card to the top of the Bench, and the card under the pointer was then a different one. The Topics list did not change, but the Sidebar showed an order that was not the list's.

We keep the order of the Topics list in the Sidebar at all times, and we keep the card of the Location at the same position on the screen when the Bench shows or hides.

- **Nothing reorders for display.** A shown Bench shows each Benched card at its place in the Topics list. A click, a quick switch or a Jump To does not move a card.
- **The Bench has its own scroll area.** The Pinned cards, the In Play cards, the Bench line and the opened No Topic Session do not scroll with it. So the In Play cards are always in view, also with a long Bench.
- **A hidden Bench shows only the card of the Location**, directly under the line, as before.
- **The Bench opens scrolled to the card of the Location.** When the Bench shows while the user is on a Benched card, its scroll area opens so that this card stays where it was: directly under the line. The Benched cards before it are above the top edge of the area. When the user is on another card, the Bench opens at its top. A drag that opens the hidden Bench opens it the same way.
- **A "more above" line** shows how many cards are above the top edge of the Bench area, as the "more below" line does for the cards below the bottom edge. A click on it scrolls up.
- **The Bench area has empty space after its last card**, a little less than the area's height. So the last card can come to the top of the area too. The space is always there, as in an editor that scrolls past the end of a file.
- **A Jump To a Benched card out of view scrolls the Bench area to it.**
- **A drag at the top or bottom edge of a scroll area scrolls that area.** A drag from one area onto a card in the other is a Trade, as before.
- **The opened No Topic Session** has no place in the Topics list. It stays directly under the line, outside the Bench's scroll area.

Hints keep their rule: ⌃N goes to the Nth card that shows, also when that card is out of view in the Bench area. A change of the window's height does not scroll the Bench again.

## Considered Options

- **The card of the Location directly under the line, also when the Bench is shown.** This was ADR 0055. Rejected: a click on a shown Bench moved the card that the user clicked.
- **Each card at its place in a shown Bench, in one scroll area for the whole list.** Rejected: the card of the Location moves each time the Bench shows or hides, and at its place in a long Bench it can be out of view. To keep it in view, the list would scroll the In Play cards off the top.
- **Jump To from a Command Palette puts the Topic at the top of the Bench.** Then the card of the Location is under the line when the Bench is hidden and when it is shown. Rejected: going to a Topic would change the Topics list, and each other way to go to a Topic (an Agent notification, the CLI, the Next Topic after a Settle) would need its own answer.
- **Empty space after the last card only when a show needs it.** Rejected: the area's height then changes while the user scrolls, and the cards can jump.

## Consequences

- When the user scrolls the Bench area to the end, one card shows, with empty space under it.
- A drag across the Bench line crosses from one scroll area into the other.
- The Benched cards keep their places for each other in a drag, as every other card does. The rule that held the card of the Location right under the line in a drag is gone.

This changes [ADR 0055](0055-the-sidebar-shows-only-the-topics-in-play.md): "The card of the Location always shows" and "The Bench is in the Topics list's scroll view".
