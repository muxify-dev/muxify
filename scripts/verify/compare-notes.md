# Compare notes

The notes of the compare run (`make compare`, see `README.md` in this folder). The report shows each scene's section
under the scene's pictures.

The first section is the record of the pilot. Then each scene of an area that has two versions has one section, under
the scene's name. A task that leaves a difference between the two versions in a scene writes it there, and why it
stays. A section with no text means no known difference. When the user signs an area off and its SwiftUI version is
deleted, the sections of its scenes go with its scenes.

## The record of the pilot: what the Sessions list cost

The pilot moved the Sessions list from SwiftUI to AppKit (ADR 0074), and the user signed it off. Its SwiftUI
version, its switch and its thirteen scenes are deleted; this note stays as the record of what the move took. It is
no scene's section, and the report does not show it.

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

## topic-cards

Task 05 of the set `remove-swiftui` draws the closed Topic card. The gate passes, and side by side the two pictures
look the same. The difference picture marks three things, none of which a person sees:

- The many-coloured border of the Location's card. The SwiftUI border adds its saturation as a Core Animation filter
  (`.saturation`), which the driver's `snapshot` does not draw, and the AppKit border bakes the same saturation into
  its colours (`CardSelectionBorderView`). So the SwiftUI picture shows the colours unsaturated, such as `00b4ee` for
  `00b9f9`. On the screen the two are the same, as the pilot measured with a capture of the screen.
- The edges of the glyphs of the titles, the Summaries, the keys of the Hints and "Settle". Each glyph stands on the
  same pixel in both pictures; its anti-aliased edge differs by one step of a colour part, such as `acadb1` for
  `acadb0`.
- Nothing else. The Topic Note stood half a point lower in the AppKit card at first: SwiftUI's `Text` draws its first
  baseline where TextKit puts it, a whole point, and `SidebarLabel` drew it at the font's ascender, which is the same
  place at a whole font size but not at the Note's 11.5 points. `SidebarTextLayout` now takes the baseline from TextKit.

The Guest note of a Topic card shows only with `topics.in_play`, which also shows the Guests line: `locked-cards`
shows it.

Task 11 reads the named actions of each card, `card-topic-<id>`, and of its header, `topic-<id>`: the card's menu, with
Unpin on the Pinned card, Clear Topic Note on the card with a Note and Reopen and Start Fresh on the Dormant card, and
the header's own list, which has no Settle Topic…, no Reopen and no Start Fresh, and another order. Both versions read
them from `TopicsListMenus`, and the gate passes with them.

## locked-cards

Task 05 of the set `remove-swiftui`. Two shots: `locked-cards`, a Locked card with its lock and the bell of a Window
that rang; and `guest-cards`, with `topics.in_play: 1`, the Guests line, a Guest Topic and the Locked Session as a
Guest. The gate passes in both, and side by side the pictures look the same. The difference picture marks the
many-coloured border of the Location's card and the edges of glyphs, for the reasons in `topic-cards`.

The AppKit list draws the Guests line from this task on, because a Guest shows only under it; the Bench line and the
Open Places come with task 08.

Task 11 reads the named actions of the Locked card and its header in both shots, with Unlock Session in the first and
Bench in the second, and of the Guest Topic's card and header, with Bench.

## topic-open

Task 06 of the set `remove-swiftui`. Three shots: `topic-open`, the open card of the Location's Topic with three
Sessions, five rows and "4 more…" beside Settle; `topic-open-all-rows`, the same card once "N more…" was pressed; and
`topic-open-empty`, the open card of an Empty Topic, which lists no Session. The gate passes in all three, and side by
side the pictures look the same: the Session lines, the dividers between the Sessions, the Window rows with their Pane
counts and no bell for the Window that rang, the Pane rows under a split Window and in place of a Session's only
Window, "N more…" and the footer line beside Settle stand on the same pixels. The difference picture marks:

- The fill of the open card, one step of 255 lighter in red and green in the SwiftUI picture: 70, 74, 80 against
  69, 73, 80. It is the pilot's difference (the note of its `cards` scene in the git history before task 01 of this
  set): the AppKit card's fill is a layer with its shadow (`CardFillView`), and the shadow shows through a fill that
  faint by one step; the driver's `snapshot` draws SwiftUI's fill with no shadow under it. One step cannot be seen,
  but it marks the whole open card, its rows too, and so most of the share of pixels that differ.
- The app icons of the Window rows, by at most 10 of 255 on their edge: `SidebarLogo` draws the logo's image with
  AppKit, and SwiftUI's `Image` samples it in its own way, as the pilot measured.
- The many-coloured border of the Location's card and the edges of glyphs, as in `topic-cards`.

An Empty Topic's open card lists no Session, and SwiftUI still keeps the room between the empty stack of Sessions and
the footer line: `TopicCardRowsView` keeps it too, so the card is 67 points high in both.

Task 11 reads the named actions of the open card and its header, of the Session lines (Move Up and Move Down) and of
the Topic rows (Move Window to Topic…) in each shot.

## no-topic-card

Task 06 of the set `remove-swiftui`. Two shots: `no-topic-card`, the open No Topic card of a Session with no Topic
that holds the Location, with its Window rows and the Pane rows of a split Window; and `no-topic-card-closed`, the same
card closed, with its Summary. The AppKit list draws it with the Sessions list's `SessionCardView`, whose Window rows
are the Topics list's (`topic-window-<id>`, one button each). The gate passes in both, and side by side the pictures
look the same. The difference picture marks the fill of the open card and the app icons, as in `topic-open`, and the
many-coloured border and the edges of glyphs, as in `topic-cards`.

Task 11 reads the named actions of the card, of its header and of its Window rows, which are the Topics list's: Move
Window to Topic….

## topics-stuck-header

Task 06 of the set `remove-swiftui`. The list scrolled to its end, with the header of the open card of the Location's
Topic, sixty Window rows long, stuck at the top over the rows that scroll under it. The gate passes, and side by side
the pictures look the same: the stuck header's background and its divider, and the rows under it, stand on the same
pixels. The difference picture marks the fill of the open card and the app icons, as in `topic-open`, and the
many-coloured border and the edges of glyphs, as in `topic-cards`; the titles of the rows differ by at most 2 of 255.

In one run the SwiftUI picture showed a row's hover label: the user's pointer rested on the App Window where that row
stood while the SwiftUI list showed. The runs after it showed no label in either picture. See "What the user changes
in a picture" in `README.md`.

## topic-tags

Task 07 of the set `remove-swiftui`. Four shots, with the Tags of the Config `work`, `personal`, `infrastructure`,
`documentation` and `research`: `topic-tags-corner`, Tag Marks in the corner of a Pinned card after its pin, with a
dimmed Mark for `gone`, a Tag the Config no longer defines, and of the open card of the Location's Topic and a Dormant
card; `topic-tags-title`, the first chip and "+N" after the title, chip texts from the Format part
`tags: '#{T:@#{tag}}'`, and the long title of the open card cut into its first line and the rest under the chips;
`topic-tags-line`, the chips on their own line, a row of six that ends with "+3", and a chip before "Dormant"; and
`topic-tags-settled`, an opened card of the Settled group with its Tag Marks. The gate passes in all four, and side by
side the pictures look the same: the Marks, the chips, "+N" and the title's lines stand on the same pixels. The
difference picture marks the fill of the open card, as in `topic-open`, and the many-coloured border and the edges of
glyphs, as in `topic-cards`.

- The chip of the Dormant card stood out at first: its text was up to 9 of 255 darker in the AppKit picture. SwiftUI's
  `opacity` dims each part of the card on its own, not the card as one picture, so the faint fill of a chip shows
  through its text. `SidebarTagsView` now rests at the card's opacity part by part, outside the card's dimmed view, and
  the chip's pixels are the same.
- The Tags are one static text, "Tags", with the names as its value, in both versions. SwiftUI's `help` gives the
  names as the hover label and not as accessibility help, so the AppKit Tags give them only as their tooltip.
- Until task 10 the Settled group was SwiftUI under either list. Since then the AppKit list draws its own, and the gate
  reads its rows in `topic-groups`, the area's part outside `topics-list` (see `settled-group`).

## bench

Task 08 of the set `remove-swiftui`. Two shots, with `topics.in_play: 2`: `bench`, the block that sticks (two Pinned
cards, Atlas In Play, an Open Place, the Guests line, the Guest Dune and the Bench line), the Bench just shown by a
press on its line, and the open card of the Location's Topic Gale, the last Benched card, kept where it stood under the
hidden Bench: the list moved by the arithmetic of `BenchedLocationPlace`, which both versions call; and
`bench-scrolled`, the list scrolled to its end, with Gale's header stuck right under the block while its rows, Elm
and Fir scroll under the block. The gate passes in both: every card, the lines and the Open Place stand on the same
frames, Gale too, so both versions moved the list by the same distance. Side by side the pictures look the same. The
difference picture marks:

- The pills "N more above" and "N more below", which the AppKit list draws from task 09: "2 more above" over Fir under
  the block and "1 more below" in `bench`, "3 more above" in `bench-scrolled`. They stand outside `topics-list` in both
  versions, so the gate reads no row of them; their rows in the two dumps are the same, with their labels and frames.
  The pictures differ only at the ends of their capsules and in their shadows, as `topic-overflow` says.
- The dashes of the Open Place's border, at their ends, by a fraction of a pixel after its first corner. Both borders
  start at the middle of the right edge and run the same way, but the AppKit border's corners are circular arcs
  (`CGPath(roundedRect:)`, as `DropSlotView` draws its dashed border), and SwiftUI's continuous corners are a little
  longer, so the dashes after a corner start a little later. Each dash stands on the same pixels.
- The fill of the open card, as in `topic-open`, and the many-coloured border and the edges of glyphs, as in
  `topic-cards`.

The scene turns card Hints off (`hints.cards`): the Hints of the cards and of the Open Place are compared with task
14. The AppKit Open Place shows its Hint in its room since task 13, which the Bench suite's Open Place check needs.

## topic-overflow

Task 09 of the set `remove-swiftui`. Three shots of a Topics list longer than its view: `topic-overflow`, with
`topics.in_play: 1`, the Bench shown and scrolled 300 points, with "5 more above" over the top of the Bench area and "9
more below" over the bottom of the list, each over a card that it covers in part; `topic-overflow-slide`, the Bench
scrolled 15 points, with the "more above" pill half come in from under the block; and `topic-overflow-end`, without In
Play, the list 14 points from its end, with the "more below" pill gone 20 points down its band. The gate passes in all
three. It reads no row of the pills, which stand outside `topics-list` in both versions, as SwiftUI's overlays do; in
the two dumps their rows are the same: their roles, labels and frames. Side by side the pictures look the same. The
difference picture marks:

- The edges of the glyphs of the cards and of each pill's count, the many-coloured border of the Location's card and
  "Settle", as in `topic-cards`. Each pill's arrow stands on the same pixels in both pictures.
- The ends of each pill's capsule. SwiftUI's capsule has continuous corners (`Capsule(style: .continuous)`), a little
  flatter at its ends than the circular capsule that the AppKit pill draws (`CGPath(roundedRect:)`, as the Open Place's
  border in `bench`). Only the column of pixels at each end differs: SwiftUI's border tints it faintly along 11 points
  of the capsule's height, the AppKit border along 5 points. AppKit has no public path of a continuous capsule. A
  layer's continuous corners do not serve: the pill draws its capsule as a path so that the picture shows its shadow
  (`CALayer.render(in:)`, which the driver's `snapshot` uses, draws no shadow of a layer without content), and a
  layer's border with continuous corners was a pixel thicker near the ends than SwiftUI's `strokeBorder`, which
  showed more than this.
- The shadow under each pill, by one step of a colour part at most: one step stronger right under the capsule, and one
  step weaker right over it. The AppKit pill draws it with Core Graphics, outside the capsule only, as SwiftUI's shadow
  of the composited pill shows.

## settled-group

Task 10 of the set `remove-swiftui`. Seventeen Settled Topics, a page of 15 and two more. Two shots: `settled-group`,
the Settled group open under the list, with the card of the newest Settled Topic opened by a press, which shows its
Reopen choice: its outcome, how long ago it was Settled, its two remembered Sessions with their Session lines and the
rows of their remembered Windows with their clocks, and Reopen in its corner, over the closed Settled cards at their
resting opacity; and `settled-group-end`, the group's own scroll view scrolled to its end, with "Show 2 more". The
group stands outside `topics-list`, as SwiftUI puts it, so the area names its container, `topic-groups`, whose rows
the gate compares too; the SwiftUI group has the same container. The gate passes in both shots, with the named action
of the group's header, and side by side the pictures look the same: the header, the divider, the border, the cards,
the ages, the rows and "Show 2 more" stand on the same pixels. The difference picture marks:

- The fill of the open card, one step of 255, as in `topic-open`. It is most of the share of pixels that differ.
- The many-coloured border of the card that holds the Location, which the press moved to the Settled card, and the
  edges of the glyphs of "Settle" and "Reopen", as in `topic-cards`.

Task 11 reads the named actions of the opened Settled card and of its header in both shots: Forget Topic…, its menu.
