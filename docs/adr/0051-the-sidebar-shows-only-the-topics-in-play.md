# The Sidebar shows only the Topics In Play

When the Config sets `topics.in_play`, the Sidebar shows the Pinned Topics and the first N other cards, Topics or Locked Sessions. The other open Topics and Locked Sessions are the Bench, and they hide behind one line under the In Play cards. The goal is to limit how many Topics the user sees at one time. Each rule below keeps that limit in place and does not let it lose a Topic the user works on.

- **Pinned Topics do not count toward N.** A Pinned Topic always shows. Pin is how the user keeps a Topic in view, so the limit does not override it.
- **Locked Sessions count toward N.** A Locked Session is not a Topic, but its card takes the user's attention as a Topic's card does. A Locked Session cannot be Pinned, so it is In Play or Benched by its place in the list.
- **Only the user shows or hides the Bench.** Going to a Topic, In Play or Benched, leaves the Bench as it is. A user who leaves the Bench shown has a reason to, so going to a Topic In Play does not hide it.
- **The card of the Location always shows.** If that card is not In Play and the Bench is hidden, it shows alone under the line. This covers a Benched Topic or Benched Locked Session after a Command Palette jump, or after the user hides the Bench while on one. It also covers a No Topic Session that is not Locked. Its card shows only while the user is on it, so it does not count toward N. It shows directly under the line, also when the Bench is shown: then it is above the first Benched card. At the end of a long Bench, it would be out of view, and it would move each time the Bench shows or hides. A jump does not show the whole Bench, because then every jump would show all the Topics again.
- **Hints and Topic steps go only to the cards that show.** With the Bench hidden, ⌃4 goes to the fourth card that shows, or does nothing. `select_next_topic` and `select_prev_topic` go through the cards that show and then wrap, so repeated steps do not go through the whole Bench. To reach a Benched Topic, the user shows the Bench or uses a Command Palette. The Next Topic after a Snooze or Settle still comes from the full list, because it replaces a Topic that leaves the list.
- **A drag moves a card across the shown line only.** The line stays under the same number of cards, so a card dragged past it changes places with the cards it passes: it goes In Play or to the Bench, and the last card In Play or the first Benched card goes the other way. While the Bench is hidden, a card stays on its side of the line. A card dragged down would put a hidden Benched card In Play in its place, and the drag cannot show that card or where it lands.
- **The line has no count and no Agent marks.** A number of waiting Topics, or a mark from one of them, pulls attention to the Bench, which the limit exists to avoid. There is no Config option to add them.
- **The Bench is in the Topics list's scroll view.** The line scrolls with the cards, and a shown Bench continues the same list. The "more below" line counts only the cards that show.

`toggle_bench` (default `shift+cmd+s`) and the Toggle Bench Command show and hide the Bench.

## Considered Options

The line was chosen over four other designs: an "In Play 3/3" header with empty slots, a stack of card edges, a pill at the bottom of the Sidebar with one-line rows, and a dashed "visitor" card with a Put In Play Action. The line uses the "more below" line that the Sidebar already has, and it adds the fewest new states.
