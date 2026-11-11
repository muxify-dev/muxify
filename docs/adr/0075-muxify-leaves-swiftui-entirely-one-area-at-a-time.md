# Muxify leaves SwiftUI entirely, one area at a time

ADR 0074 moved an area to AppKit only where SwiftUI caused bugs, and its first area, the Sidebar's Sessions list, is now AppKit and signed off. The pilot showed that an AppKit area can look and behave the same, and that the compare run can prove it. It also showed the cost of keeping two frameworks: every seam between them is built by hand, SwiftUI's coordinate spaces and environment do not reach across a hosted view, and while an area has two versions every change is made twice. We decide that Muxify leaves SwiftUI entirely. This replaces ADR 0074's rule that an area moves only where SwiftUI caused bugs. Its four build rules stay.

- Every area that is SwiftUI moves to AppKit, one at a time, up to the SwiftUI app itself: its window scene, its main menu and its keyboard shortcuts.
- Each area follows the pilot's pattern. The SwiftUI and the AppKit version live side by side behind a hidden user default. The compare run gets that area's scenes. Every end-to-end suite passes against both versions. The user judges the pictures and the motion, and signs the area off. Then the SwiftUI version and its switch are deleted.
- "The same" keeps ADR 0074's meaning. A person cannot tell the two versions apart in pictures side by side. The frame of every element with an accessibility identifier matches within half a point. The accessibility rows and named actions are the same. A misbehaviour that the move fixes is an allowed difference.
- The work goes in stages. Each stage is one task set with its own sign-off, planned after the stage before it is signed off. All stages land on the branch `swiftui-to-appkit`, and the user merges it when they choose.
- The areas move from the leaves to the root, as the pilot did: the Sidebar first, then the App Window's chrome, the Command Palette, the Browser's chrome and the Git View. Each moved area is one AppKit view hosted in the SwiftUI window. The SwiftUI app, its window scene, its main menu and the root layout move last, together, when nothing SwiftUI is left to host. The app cannot change while it runs, so the switch of that last stage is read at launch.
- At the end, no file under `Sources/` imports SwiftUI. The app starts from an `NSApplication` delegate, with AppKit windows and an AppKit main menu. A source check fails when SwiftUI comes back into an area that moved, and at the end anywhere.
- The deployment target stays macOS 14.
- Unit tests check arithmetic that has no view. A production view carries no accessor that only a test reads. Motion values live in shared definitions, and the user's eye judges motion.

## Considered Options

- **Stop after the Sessions list, as ADR 0074 decided.** Rejected: the app keeps two frameworks for good, with a hand-built seam wherever they meet and a second version to keep right during every move.
- **Write the whole app again at once.** Rejected: nothing could be compared while it was half done, and the user would judge everything in one sign-off at the end.
- **Move the app, its window scene and its main menu first, and host the SwiftUI areas that are left in AppKit windows.** Rejected: it ends the window scene's bugs sooner, but every SwiftUI area left would need the environment values of the root view handed to it by hand, and focus and keyboard shortcuts would cross a hosting seam until the end.
- **Capture reference pictures and dumps of the SwiftUI app once, and compare each AppKit area against them.** Rejected: the references go stale when a fixture or the design changes, and the user cannot flip between two running versions to judge motion.

## Consequences

- Until the last stage, the app has two frameworks. New view code in an area that moved is AppKit, and while an area has two versions a change to it is made in both.
- The branch lives through every stage. A change that reaches `master` in an area that already moved is made again in AppKit when the branch is rebased.
- Focus and drag bugs that were app logic do not go away with the move.
