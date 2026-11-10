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

## hover

## more-rows

## long-titles

The coloured border of the Location's card and the text: as in `card-marks`.

## stuck-header

## empty

## sizes-and-light

## mid-swipe
