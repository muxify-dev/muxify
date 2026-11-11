# Compare notes

The notes of the compare run (`make compare`, see `README.md` in this folder). The report shows each scene's section
under the scene's pictures.

The first section is the cost of the pilot: what the move of the Sessions list from SwiftUI to AppKit took. Then
each scene has one section. A task that leaves a difference between the two versions in a scene writes it there, and
why it stays. A section with no text means no known difference.

## Cost of the pilot

What the move of the Sessions list from SwiftUI to AppKit took, tasks 01 to 11 of the task set `swiftui-to-appkit`.
The lines were counted on the tree of task 11, by a one-off script. A "line" is every line of a file or of a
declaration, with its doc comments and its blank lines. A "code line" is a line that is neither blank nor only a
comment. A declaration runs from its top-level `struct`, `class`, `enum` or `extension` line, with the doc comments
above it, to the next one.

The AppKit code written for the Sessions list: 3,822 lines, 2,815 of them code. It is 13 new files and parts of 3:

- `SessionCardView.swift` 685, `SessionCardDrag.swift` 615, `WindowRowView.swift` 524, `SidebarCardChrome.swift` 422, `SidebarLabel.swift` 288, `PaneRowView.swift` 253, `SessionsListView.swift` 250, `SidebarAgentMark.swift` 149, `SidebarHintView.swift` 120, `SidebarMenu.swift` 104, `SidebarRowView.swift` 101, `LayerGlide.swift` 98, `ObservedUpdate.swift` 31.
- Parts: `SidebarLogo` in `SidebarLogo.swift` 62, `SessionsListVersion`, `SessionsListEnvironment` and `SessionsListHost` in `SessionsList.swift` 66, `RowHoverLabel` in `HoverLabel.swift` 54.

Beside it, 560 lines (328 code) are the definitions that both versions read, so the two cannot drift (rule 2 of ADR 0074): `AgentMarkMetrics.swift`, `PaneRowMetrics.swift`, `SessionsListMetrics.swift`, `WindowRowMetrics.swift`, the `Card…` enums, `StuckHeader` and `CardMotion` in `SidebarCard.swift`, the Hint metrics in `HintView.swift`, `ListLift` in `ListDrag.swift`, `SessionsListEmptyState`, `SessionCardPress` and `SessionsListMenus` in `SessionsList.swift`, and `LogoImages`. The SwiftUI views changed only to read them. The unit tests of the set are 1,579 new lines in `Tests/`.

The SwiftUI code that the AppKit code mirrors: 1,291 lines, 1,072 of them code. These are the declarations that draw
the SwiftUI Sessions list:

- `SidebarView.swift`: `SessionsSection`, `SessionCard`, `WindowRow`, `BellMark`, `PaneRow`, `Logo` and the `SelectedRow` extension, 358.
- `SidebarCard.swift`: `SidebarCard`, `BalatroBorder`, `CardHeader`, `NoteLine`, `PinMark`, `GuestMark`, `LockMark`, `CardList`, 444.
- `HintView.swift`: `HintBadge`, `HintKey`, `CardHintSlot`, `CardRestKey`, `WindowHint` and its `View` extension, 138.
- `ListDrag.swift`, the SwiftUI side of the drag: `ListDragHandle`, `OpenHandCursor`, `ListDragItem`, `ListDragFixed`, `DropSlot`, 186.
- `HoverLabel.swift`: `HoverAnchorView`, `HoverLabelModifier`, `HoverTitle`, 64; `AgentMarks.swift`: `AgentMarkView`, `AgentMarkSpine`, `Breathing`, 57; `RowMark.swift` 25; `TerminalActivityGlyph` 19.

So the AppKit list takes about 2.6 code lines for each SwiftUI code line. Most of the SwiftUI views above also draw
the Topics list, which keeps them.

The harness, the driver and the compare run, as lines added and removed by the set (`git diff --numstat` against
the set's base, `b81e694`):

- The option `SESSIONS_LIST` for the two versions: `sandbox.py` +57 −13, `run.py` +40 −23, `report.py` +6 −4, `Makefile` +11 −2 (with the target `compare`). Together +114 −42.
- The compare run, all new: `compare_scenes.py` 577, `compare.py` 296, `compare_report.py` 168, `compare_gate.py` 149, `picture_diff.swift` 83. Together 1,273, and these notes.
- The driver: `TestDriver.swift` +48 −20 (the commands `sessions-list` and `actions`, and a row's depth in the dump), and `DisplayLinkProbe.swift` +14 (the report of a glide).
- The checks of the harness, with the gate's checks on made-up rows: `suites/harness.py` +119 −2. `README.md` +73 −3.
- The new suite `sessions_list_sidebar.py`: 608 lines.

The attempts of each task, from the set's `manifest.json` and the journal in `attempts/`:

- 01 the switch and bare cards: 1.
- 02 the compare run: 2. The first stopped on an API error.
- 03 Session cards: 2. The user stopped the first.
- 04 Window rows: 1. 05 Pane rows, Agent marks and N more: 1. 06 the stuck header and the scroll to the Location: 1.
- 07 Hints and hover labels: 2. The first failed: the lock screen, and before it full-screen windows, covered the App Window, so the hover checks could not run.
- 08 context menus: 1. 09 the Window row drag: 1.
- 10 empty states, font sizes and the light theme: 2. The first failed: a full-screen window covered the App Window.
- 11 both versions pass, and AppKit is the default: 1, this attempt.
- 12 the sign-off: the user's.

Harder than expected:

- Sameness in the picture needed rules that only SwiftUI's own output shows. An `NSTextField` drew its text twice in the driver's picture, so titles are a self-drawn label (`SidebarLabel`). A layer's border drew its corners without smoothing, so outlines are fills with a ring mask. The coloured border needed a capture of the screen to learn that SwiftUI mixes its gradient in Oklab and saturates it in sRGB.
- The accessibility rows had to copy what SwiftUI makes by itself: a row gives its identifier to its parts, the named actions come from the last to the first, "Main working copy" carries the row's identifier, and a symbol's frame is its glyph's bounds.
- The drag of a Window row was the largest part: `SessionCardDrag.swift` is a sixth of the AppKit code.
- The screen, not the code, cost the attempts that failed: a full-screen window or the lock screen covers the App Window, and then no hover check and no `hover` scene can run.
- Suites that the set had to pass failed on `master` already, and were repaired: see "Suites that changed" below.

Easier than expected:

- The riskiest part cost nothing: SwiftUI's pager moves, scales, fades and clips the hosted AppKit list, and hides it from clicks and from accessibility, with no change to the pager.
- No model changed. One small observer, `ObservedUpdate`, reads the `@Observable` models.
- The scroll that froze the app is now a glide of the list's own clip view, 0.15 s, that comes to rest by construction. `sidebar_pager_scroll` only needed the glide reported to the Diagnostics probe.
- The suites that drive the Sessions list passed against the AppKit list with no change to a check.
- Six of the ten tasks before this one took one attempt.

What the Topics list would reuse as it is:

- The rows and their parts: `WindowRowView`, `PaneRowView` and `MoreRowView` on `SidebarRowView`, `SidebarLabel`, `SidebarAgentMark`, `SidebarHintView`, `SidebarLogo`, `RowHoverLabel`, and `SidebarMenu` for the menus with their named actions.
- The card's chrome in `SidebarCardChrome.swift` (fill, outline, coloured border, spine, the backdrop of a header that sticks), the drag of a Window row in `SessionCardDrag`, `LayerGlide`, `ObservedUpdate`, and every shared definition. `SessionCardView` can draw the No Topic Session card.
- The shared arithmetic of the drag (`StackLayout.follow`, `shift`, `ListLift`) and of a header that sticks (`StuckHeader.offset`).
- The compare run as it is: the gate, the report, the picture diff, the switch's pattern and the driver's commands.

What the Topics list would need on top:

- The Topic card: its header with the pin and the Tags (`CardTags`), Settle and Reopen in its corner (`CardCorner`) with the footer line, the Locked card, the Session headings and the Topic item rows. In `SidebarView.swift`, `TopicsSection` to `LockedCard` is about 1,000 lines of SwiftUI.
- The list around the cards: the groups (`TopicGroupBlock`), the Bench (`BenchScroll`), the drag of a card between play and the Bench with its trades (`TradeMark`, `TradeGhost`, `TradeArc`), the pills and the scroll at the list's edges (`TopicsListEdge`, `EdgeAutoScroller`), and `reveal` (`ScrollDriver`). These five files are 703 lines.
- Scenes of the Topics list in the compare run, and a new count for `topics_bench_scroll_sidebar`: it counts the bodies of `TopicCard` with the driver's `counts`, and an AppKit card has no body. The count of the AppKit card's updates must keep what the check proves: a scroll draws no card again.

Suites that changed. No check changed for the move: no suite measures the SwiftUI Sessions list itself, so each check
proves the same thing against both versions.

- `sessions_list_sidebar` is new. It checks the switch, the default (a missing `sessionsListAppKit` shows the AppKit list, false shows the SwiftUI list, also after a change while the app runs), and the presses, clicks, named actions, glide, swipe and font size against both lists.
- `sidebar_pager_scroll` changed only its notes: the AppKit list reports its glide to the probe, and the check still fails when it reads no scroll animation.
- `suites/harness.py` gained the checks of the gate.
- These failed on `master` for either list, and their fixtures were repaired; each check still proves what it proved. `sidebar_swipe` and `interface_font_size` use a repository, because the header shows the Git button only in one (218dfa6). `agents_unread` runs the Agent of its Git View check in a repository, because Show Git View is disabled outside one. `tmux_events` starts the Session `main` itself, because the app no longer makes one (5fb30e8). `sidebar_layout` waits until the app has read its new Config. `topics_cards_sidebar` reads the footer line beside Settle once the card has come to rest, because the rows show before the card's glide ends.
- `client_terminal` reads its two lines once both are written: the shell makes the file before `printf` writes to it, so a read could find one line, and the check failed by chance.

The checks reported as FLAKY in the full runs of task 11, three against each list. Each passed in its rerun, and none is in the Sessions list:

- The hover checks of `hover_labels_sidebar` and `interface_font_size`, with both lists: the user's full-screen windows covered the App Window whole, and they passed once a part of it showed.
- `session_paths_palette`, the saved Session Paths after a restart, with both lists: FLAKY on `master` too, in the run before task 01.
- `topics_bench_sidebar`, a drag of a card across the Bench, with both lists: its check of a tall benched card and others of the same drag were FLAKY on `master` too. The set moved arithmetic of `ListDrag` into `StackLayout.follow` and `shift` with the same values, which `TopicOrderTests` checks.
- `git_view_remotes`, with both lists, most often the pull that waits in the write queue: the staging did not run within 15 s after the pull. The cause was not found. It is in the Git View, of which the set changed only where the outline of its icon is defined.
- `local_session_end` and `attachments_terminal`, late in the parallel pass: the Terminal's tmux Client did not attach within 20 s, or the Recorder Window of an attachment check did not appear in time. The set does not touch the Terminal.
- `client_terminal`, with the AppKit list: the read of a half-written file, repaired above.

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

Both shots show the Sessions page at the same offset, shrunk and faded alike. Held past the end of Sessions, the gate
matches the 16 rows of the list within half a point. Held from Topics at 0.400, where the dump has no rows, the
pictures show it: the page's left edge, the coloured border of the first card, stands on device pixels 327 and 328 in
both, the Sidebar cuts the page off at pixel 520 in both, and the cards' lines of text stand on the same rows of
pixels. A closed card's title is 209 of 255 at its brightest in both, where it is 227 at rest, and the card's fill and
the Sidebar's ground differ by at most one step, so both pages fade by the same amount.

The glyphs differ inside their own pixels. The page's scale of 0.985 puts them on fractions of a pixel, and SwiftUI's
text and `SidebarLabel` share such a fraction out to the pixels differently: SwiftUI's glyph edges are a little
softer, and the sum of the steps between neighbouring pixels over the text is about 3 % lower in the SwiftUI picture.
At rest the two versions draw the same glyphs, with the same sum. The open card's fill: as in `cards`. Its coloured
border: as in `card-marks`.
