# Compare notes

The notes of the compare run (`make compare`, see `README.md` in this folder). The report shows each scene's section
under the scene's pictures.

The first section is the cost of the pilot: what the move of the Sessions list from SwiftUI to AppKit took. Then
each scene has one section. A task that leaves a difference between the two versions in a scene writes it there, and
why it stays. A section with no text means no known difference.

## Cost of the pilot

## cards

The fill of the open card is one step of 255 lighter in red and green in the SwiftUI picture: 70, 74, 80 against
69, 73, 80 on the run's dark theme. One step cannot be seen, but it makes the difference picture mark the whole open
card, its rows too, and so most of the share of pixels that differ. The AppKit card's fill is a layer with its shadow
(`CardFillView`), and a layer's shadow shows through a fill that faint: the text colour at 8 % over black at 28 %
takes the card down about one step. The SwiftUI picture has the value of the fill with no shadow under it. Outside
the card both pictures show the same pixels, because the shadow there is fainter than one step.

The Window rows match within that step: the tint of the Location's row, the app icons, which differ by at most one
step where the SVG is drawn, and the titles. The coloured border of the Location's card and the text: as in
`card-marks`.

## window-parts

The fill of the open card: as in `cards`. The parts of the row match within that step: the app icon, the title and
"Main working copy", the bell, the Git View icon, the globe and the Tab count, and the Pane count with the capsule of
its Zoomed Pane.

## window-formats

The fill of the open card: as in `cards`. The text, symbol and app icon parts on both sides, the title and the Summary
match within that step.

## pane-rows

The fill of the open card: as in `cards`. The Pane rows match within that step, under a Window row and in its place:
the Working mark's pixels, which stand on the same device pixels with the same opacities, the Notification dots, the
split icons, the titles and the tint of the row that stands in for the Location's Window row, with its rounded corners.
The titles differ on subpixels only, in single pixels at the edge of a glyph. The coloured border of the Location's
card: as in `card-marks`.

## card-marks

The coloured border of the Location's card differs in colour in the pictures, by up to 7 %, and is the same on
screen. SwiftUI's `.saturation(1.15)` is a Core Animation filter (`colorSaturate`), and
`CALayer.render(in:)`, which the driver's `snapshot` uses, leaves filters out. So the SwiftUI picture shows the
border's colours without the saturation, and the AppKit picture shows them with it, as the screen shows both
borders. A one-off capture of a SwiftUI window on screen showed how SwiftUI makes the colours: its angular gradient
mixes two colours in Oklab, and the saturation then works on each colour in sRGB. `CardSelectionBorderView` makes its
colours the same way, and they match that capture within about 3 of 255 in a channel on average.

The text differs on subpixels only, by less than 1 % in a channel.

## hints

The Hints match pixel for pixel in all three shots: the Window rows' keys at rest, and the badges of the cards and of
the Window rows, whose dark box, light border and continuous corners are the same pixels in both pictures. A card's
badge ends where its key at rest ends and covers the end of the title, and the title keeps its lines. The keys of a
badge are cut off at their frame, as SwiftUI cuts off a text, so the left edge of ⌘ shows no pixel past it.

The capsule of a card's key at rest differs on its edge by at most 3 of 255, which cannot be seen: `CardRestKeyView`
draws it with AppKit's path, and SwiftUI draws its `Capsule` with its own. The app icons differ on their outer edge by
up to 10 of 255, in single rows and columns of device pixels; the `window-parts` pictures show the same. `SidebarLogo`
draws the logo's image with AppKit, and SwiftUI's `Image` samples it in its own way; the Hints do not cause it. The
fill of the open card: as in `cards`. Its coloured border: as in `card-marks`.

## hover

The hover label opens in the same place in both pictures, with its title exactly on the row's title, and shows the
same full title and the same detail line. Its pixels differ by at most 2 of 255: the label is translucent, and the open
card's fill and coloured border under it differ as in `cards` and `card-marks`. The app icons: as in `hints`.

## more-rows

The fill of the open card: as in `cards`. The Window rows and "N more…" match within that step. The coloured border of
the Location's card: as in `card-marks`.

## long-titles

The coloured border of the Location's card and the text: as in `card-marks`.

## stuck-header

The stuck header matches: its background, the chrome's colour under the faint fill, is 70, 74, 80 in both pictures,
and its divider is the same two device pixels of 88, 92, 97 in the same rows. The rows that scroll under it stand in
the same places. The fill of the open card under the header: as in `cards`. The coloured border of the Location's
card and the text: as in `card-marks`.

## empty

"No windows" and "No tmux server" stand in the same place in both pictures, in the middle of the list, on one line,
in the font of a Window row's title and the secondary text colour. The text differs on subpixels only, in single
pixels at the edge of a glyph.

The SwiftUI list showed the text one or two letters to a line, in a column 12 points wide: its scroll view took the
width of its content, and with no card that was the two insets. Its content now takes the width of the list, which it
already had with any card, so the empty state there has the room of the whole list, as in the AppKit list.

## sizes-and-light

At 18 and 24 the cards, the Window rows and their parts stand in the same places and match within one step of 255,
as at 12: the titles, the Summaries, "Main working copy", the symbols and counts, and the keys at rest of the cards.
The app icons keep their size, as paddings do. The fill of the open card at 18 and 24: as in `cards`. Its coloured
border: as in `card-marks`.

In the light theme the fill of the open card is 4 steps of 255 darker in the AppKit picture: 213, 213, 212 against
217, 217, 217, and the tint of the Location's Window row under it 3 steps. The cause is the one in `cards`: the
picture of the SwiftUI list has no shadow of the open card at all, also outside the card, where the AppKit picture
has one step of it. The driver's `snapshot` leaves SwiftUI's shadow out. On a light ground the shadow shows through
the fill of 8 % by 4 steps, and on the run's dark ground by 1. A one-off capture of the screen, of a SwiftUI card and
a `CardFillView` card side by side, showed the same pixels for both: 216, 216, 215 in the light appearance and 72,
75, 82 in the dark one. The closed cards, the borders, the text and the logos match within one step.

## mid-swipe
