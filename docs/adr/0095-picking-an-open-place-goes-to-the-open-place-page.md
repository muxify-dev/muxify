# Picking an Open Place goes to the Open Place page

A click on an Open Place card, or its Hint's key, opened the palette step "What takes this place?" ([ADR 0064](0064-in-play-places-stay-open-and-guests-show-in-their-own-section.md)). The Location did not change, so the Topic that the user left stayed in the Terminal's place behind the palette. The palette is modal: while it was open, the Hints did not show, the Sidebar took no gestures, and a quick-switch key could not take the user to another card first. The step ranked its rows as every palette list does. On an empty query it hid the Guests, and a query sorted the rows by match, so a Topic was never where the Sidebar shows it. The phone's Fill Open Place sheet lists the Guests, then the Bench, in the order of the Topics list, and does not sort them.

We decide that **picking an Open Place goes to its Open Place page**.

- **The Open Place is a Location.** A click on its card, or its Hint's key, makes the Open Place the App Window's Location (`Location.openPlace`). The Open Place page shows in the Terminal's place, as the Empty Topic page does. The Sidebar shows the Open Place card as the Location, with the border of the card that holds the Location. The window title is "Open Place N", where N is its In Play place. Each Open Place has its own page. The Active Topic on the page is none.
- **The rows.** The page lists the Guest Topics, then the Benched Topics, each section in the order of the Topics list (`InPlayCut`). It never ranks them and never puts the current Topic first. The whole Bench shows, also when the Sidebar hides it. A Guest Session has no row, because it cannot take a place until it is a Topic. A section with no row does not show. Each row draws the pieces of its closed Sidebar card: the title, the Tags, the Topic Note, the summary of its Sessions and the Agent mark on its spine.
- **Search filters.** A search field at the top takes Focus when the page opens. Typing hides the rows that do not match, and the rows that stay keep their order. The match uses the palette's fuzzy match on the title, the Topic Note, the Session names and the Tags (`#tag`), and the row marks the matched characters. The palette's select keys (↑ ↓ ⌃J ⌃K) move the selection while the field has Focus.
- **Fill.** A click on a row, or the palette's accept key (↩) on the selected row, fills the place with that Topic through `fill_open_place`, as `muxify topic fill-place` does, and then opens the Topic. A Guest loses its Guest mark. The row has no other action and no card menu.
- **⎋ does not leave.** With a query, ⎋ clears it. Without one, ⎋ does nothing. The page is a Location: the user leaves it as any Location, with a quick-switch key, a click or a Command.
- **Nothing modal.** Every App Window keybind acts on the page: Select Card, the Topic steps (which go to the card beside the Open Place), and the Hints while ⌃ is held. A move to another card leaves the place open, and its Hint's key or a click comes back to the page.
- **When the place closes.** A fill from the command line, the phone or a drag, or a lower `topics.in_play`, can close the Open Place while its page shows. Then the Location goes to the Window that the Client shows, as it does when the Topic of an Empty Topic page goes away.
- **Focus.** The page stands in the Terminal's place for Focus too: where the Focus rule ([ADR 0065](0065-focus-goes-back-to-a-view-when-the-app-window-holds-it.md)) gives Focus back to the Terminal, it goes to the page's search field. With Focus in the Browser or a palette, the field shows no Focus ring and the selected row is grey.
- **The palette step goes away.** The step `fillOpenPlace` and its rows are removed. The Open Place page is the one way to fill an Open Place on the Mac, beside the Sidebar drag. The command `muxify topic fill-place` and the request `fill_open_place` do not change.

The page is SwiftUI, as ADR 0083 asks for a page in a window. Its list is a search list of the Command Palette's kind, which ADR 0083 keeps in SwiftUI: it scrolls, as the palette's list does, but it neither animates every frame nor drags. It scrolls to the selected row without an animation, and the freeze that ADR 0083 records came from an animated `scrollTo`. Its rows reuse the SwiftUI pieces of the Sidebar card.

## Considered Options

- **Keep the palette step, and only list the rows in the Topics list's order.** Rejected: the step is modal. The Hints hide and the Sidebar takes no gestures while it is open, and the Location stays on the Topic the user left, so the step does not show where the user is.
- **A sheet, as the phone has.** Rejected: a sheet is modal too, and ADR 0014 asks for its own reason to take input in a sheet. The phone has no keyboard keybinds to lose. The Mac has.
- **Rank the rows by match, as the palette does.** Rejected: the user knows the Topics by their place in the Sidebar. A filter that keeps the order finds a Topic as fast, and does not move the rows under the pointer while the user types.
- **⎋ goes back to the last Location.** Rejected: the page is a Location like any other, and no other Location has a key that goes back. A key that sometimes clears and sometimes leaves is easy to press twice by mistake.

## Consequences

- ADR 0014 says that every Action runs in the palette's view. Fill an Open Place now runs in the Open Place page: the page is a Location that takes input, not a step, so the palette's ⎋ and ⌫ rules do not apply to it.
- The text in ADR 0064 about the choose-a-row step of an Open Place does not apply.
- `Location` has a third case. Each switch on it names the Open Place page, and the Router treats it as a page: it moves no Client and attaches nothing.
- E2e checks in `topics_bench_sidebar` prove that the Open Place key shows the page, that Select Card leaves it, and that ↩ fills the place. They also prove the Focus on arrival, the Hints, both cases of ⎋, the text for no match, the leave when the place closes, the order of the rows, a click on a Guest row, and the empty state.
