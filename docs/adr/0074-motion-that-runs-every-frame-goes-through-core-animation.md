# Motion that runs every frame goes through Core Animation, never through SwiftUI state

The App Window is one large SwiftUI view tree. A value that changes every frame, whether from a SwiftUI clock (`TimelineView`, `repeatForever`, `phaseAnimator`), a trackpad gesture, or a spring that animates `@State`, makes SwiftUI update and lay out that tree on every frame. Every row's geometry readers, hover hit-tests and accessibility nodes run again, even though only a transform changed.

This happened twice:

- The Working marks kept the main thread about 85% busy at idle.
- The Sidebar pager's swipe, where `position` drove `.offset`, `.scaleEffect` and `.opacity` on both mounted pages, kept the main thread about 60% busy and the app at about 42% CPU while the user swiped. About 95% of that main-thread time was SwiftUI graph updates and about 3% Muxify code.

So motion that runs every frame lives in layers that Muxify owns, and SwiftUI only hears where it begins and ends:

- The Working marks are `CAKeyframeAnimation`s on layers inside an `NSViewRepresentable`.
- Each Sidebar page (Topics, Sessions) is its own `NSHostingView` in an AppKit container. The swipe sets the container's layer transforms directly, and the settle is a `CASpringAnimation`.

## Considered Options

- **Pictures of the pages slid in a Core Animation overlay.** This keeps one SwiftUI tree, but the page that is not on screen is clipped away, so a fresh picture of it could not be guaranteed, and both pages would freeze while they slide. Rejected.
- **Cheaper SwiftUI modifiers (`geometryGroup`, `visualEffect`, fewer geometry readers).** These reduce the cost per frame but keep a per-frame SwiftUI update over the whole tree, and every new row type adds to it again. Rejected.

## Consequences

- Each page is a separate SwiftUI graph. Environment values set above the pager must be handed to each page's root.
- A page gets a new root only when its content or its environment changes, never for the mode or a swipe. A new root makes SwiftUI run the body of every card on the page again, so the mode reaches the AppKit container apart from the pages, and the container alone decides which page takes hits and is in the accessibility tree.
- A committed mode still changes values in a page's environment, such as the Quick Switch Hints, which move to the cards of the shown page. A card reads such a value in a small view of its own (`CardHints`, `HintHidesMark`), so the change runs that view again, not the card's body.
- A transaction opened outside a page, such as `withAnimation`, does not reach a page's views.
- SwiftUI geometry, AppKit `convert`, accessibility frames and hit-testing do not see a layer transform. They report a page's resting place while it moves, so a page takes no clicks or hover while it moves.
- Verify checks prove the motion through the pager's Debug position and update counter, not through row frames.
