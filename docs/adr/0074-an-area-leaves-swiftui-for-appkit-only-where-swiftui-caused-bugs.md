# An area leaves SwiftUI for AppKit only where SwiftUI caused bugs

Muxify's interface is SwiftUI, 40 files and about 11,900 lines, around a Terminal and a Browser page that are AppKit. Some bugs came from SwiftUI itself. The worst was in the Sidebar. An animated `scrollTo` in the Sessions list never reached its target while the page was scaled for the slide between Topics and Sessions, SwiftUI started the scroll again every frame, and the app froze for 1 to 4 minutes (`7cb4cb6`). That fix removed the scale, and the `scrollTo` stayed. The Topics list already scrolls through `ScrollDriver`, which moves the AppKit clip view, because `ScrollViewReader` scrolls only within the height of the last layout and keeps its target armed after the scroll (`bc36254`, `25af327`). So we asked whether to write every view again in AppKit.

We read the history before we decided. Of about 92 fix commits, about 11 were SwiftUI's. About 27 were bugs in app logic that lived in a view, and the others had nothing to do with views. The SwiftUI ones are in the Sidebar's scrolling and in the life cycle of the window scene (`d1a5960`, `4bdfda1`). The Git View, the Command Palette, the Browser's tabs and toolbar, and the App Window header have no SwiftUI bug that a user saw.

We decide that an area moves to AppKit only where SwiftUI caused bugs, one area at a time. The first area is the Sidebar's Sessions list: the list of Session cards that Switch to Sessions shows.

- The Sessions list is AppKit all the way down: its scroll view, the Session cards, the Window rows and Pane rows, the marks, the context menus and the drag of a Window row. No SwiftUI view is hosted inside it. It sits in the SwiftUI Sidebar as one hosted view.
- The moved area must look and behave the same. "The same" means that a person cannot tell the two apart in pictures side by side. It does not mean equal pixel for pixel: two text and layout engines do not put glyphs on the same subpixels. A misbehaviour that the move fixes, such as a scroll that now comes to rest, is an allowed difference.
- The SwiftUI version and the AppKit version live side by side until the user signs the area off. A hidden user default chooses between them, and the app follows a change of it while it runs. It is not a Config key, because it goes away with the SwiftUI version, which is deleted after the sign-off.
- A compare run in the end-to-end harness proves the sameness. For a fixed list of scenes it takes a picture of each version. The frame of every element with an accessibility identifier must match within half a point. The pictures and their difference go into a report that stays after the run, for a person to judge. The pixel difference is a number in the report, and it does not fail the run.
- The end-to-end suites are the specification of the behaviour. Each suite that drives the area passes against both versions without a change, so the AppKit views give the same accessibility rows: roles, identifiers, labels, values, help and named actions. A suite changes only when it measures SwiftUI itself.
- The Topics list is the next area, after the sign-off of the Sessions list. It uses the AppKit card, rows and marks that the Sessions list brought.

Every AppKit view of a moved area follows four rules:

- It lays out by frames: a flipped `NSView` sets the frames of its subviews, with no Auto Layout. The header that sticks, a card that opens and a dragged row are all moves of a frame.
- A padding, a spacing or a font size that both versions need has one definition that both read, as `CardSpacing` has, so the two cannot drift.
- It reads the `@Observable` models as they are, through `withObservationTracking`, and it updates once in a turn of the run loop. The models do not change for the move.
- It animates with Core Animation, with the durations and curves that the SwiftUI code names, such as ease-out over 0.15 seconds for a card that opens.

## Considered Options

- **Write every view again in AppKit.** Rejected: most of the bugs were not SwiftUI's, and the focus and drag bugs were app logic that an AppKit view would have too. The design of the 11,900 lines exists only as numbers in the views, and no tool could prove that a new view looks the same. The animations, the materials, the menu bar and the accessibility tree that the suites read would all be built by hand.
- **An AppKit scroll view with the SwiftUI cards hosted inside it.** Rejected: the header of an open card sticks to the top of the list, and a dragged Window row stops under it. Both read the scroll through SwiftUI coordinate spaces, which do not reach across a hosted view, so both would be built again in any case, with a second boundary between the two frameworks to keep right.
- **Keep the views in SwiftUI and move every scroll to `ScrollDriver`.** Rejected: `ScrollDriver` finds the scroll view that SwiftUI makes, and it waits for SwiftUI's layout through a run-loop observer. It depends on how SwiftUI is built inside, which a macOS release can change.
- **Stay on SwiftUI and use the scroll APIs of macOS 15.** Not tried: the deployment target is macOS 14, and nothing shows that these APIs avoid the scroll that never comes to rest.

## Consequences

- The app keeps two interface frameworks. New view code in an area that moved is AppKit.
- While both versions of an area live, a change to that area is made in both.
- The Session card, the Window row and the Pane row exist twice while the Topics list is SwiftUI, because the Topics list shows them too.
- Bugs of focus and of drag logic do not go away with a move. They were not SwiftUI's.
