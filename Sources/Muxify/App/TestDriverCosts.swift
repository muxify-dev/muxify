#if DEBUG
import MuxifyCore
import SwiftUI

/// The two past CPU costs, brought back on purpose so the `diagnostics` verify suite can prove that the Diagnostics
/// log catches each one (scripts/verify/suites/diagnostics.py). Both are off until the TestDriver's `idle_clock` or
/// `card_rebuild` command turns them on, and exist only in Debug builds.
@Observable final class TestDriverCosts {
    /// Read and set on the main thread, where bodies run and the driver answers.
    nonisolated(unsafe) static let shared = TestDriverCosts()

    /// Case 1, the idle cost: how many Working-mark-like views SwiftUI clocks fade, each under its own clock at frame
    /// rate, while the user does nothing. The Working marks did this before #114, each under a
    /// `TimelineView(.animation(minimumInterval: 1/30))`.
    /// Measured on 2026-11-11 in a verify Sandbox with 4 Working Agents, its App Window covered by other windows, as
    /// the app's CPU from `ps` over 10-15 s: 120 views took 18-27% of a core, 400 30-38%, 800 39-47% and 1600 52-81%;
    /// SwiftUI draws fewer frames as the views grow, so the share grows slowly and varies. The `diagnostics` check uses
    /// 1600: its Bursts averaged 51-80% of a core, the main thread up to 99% busy, AttributeGraph leading the digest at
    /// 43-48%. A Burst needs 30% for 3 s; the old marks of 4 Agents took about 14%.
    var idleClockViews = 0

    /// Case 2, the card rebuild on each Sidebar switch: how many views every Sidebar card lays out again over itself
    /// from the shown mode, read in the card's body, so each switch between Topics and Sessions runs every card's body
    /// and those views again. Quick Switch Hints did this before #119: the card's body read them, they move with the
    /// mode, and its Hints overlay was built again from them.
    /// Measured on 2026-11-11 in a verify Sandbox with 15 Topic and 15 Session cards, as the app's CPU from `ps` over
    /// 15 s of the check's swipes, each a swipe and a wait until the pages rest: about 26% of a core with it off,
    /// which is the driver reading the accessibility tree, 29% with 200 views, 44% with 1000, 62% with 2000 and 79%
    /// with 4000, which froze the main thread. Each switch ran about 30 SidebarCard bodies. The `diagnostics` check
    /// uses 2000: its Bursts averaged 64-70% of a core, AttributeGraph leading the digest at 44-46%.
    var cardRebuildViews = 0

    /// The Sidebar mode shown, which every card's body reads while the rebuild is on.
    var mode: SidebarMode?

    /// Read at the top of every Sidebar card's body. While the rebuild is off it reads only `cardRebuildViews`, so a
    /// switch runs no card's body.
    var cardRebuild: (mode: SidebarMode, views: Int)? {
        cardRebuildViews > 0 ? mode.map { ($0, cardRebuildViews) } : nil
    }
}

/// Case 2's views over a card: clear views as wide as the mode makes them, laid out again on each switch.
struct CardRebuildCost: View {
    let mode: SidebarMode
    let views: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<views, id: \.self) { _ in Color.clear.frame(width: mode == .topics ? 0.1 : 0.2) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Case 1's views: small bars at the App Window's corner, each faded by its own SwiftUI clock at frame rate, as the
/// Working marks were before #114.
struct IdleClockCost: View {
    private let costs = TestDriverCosts.shared
    private static let period: TimeInterval = 1.6

    var body: some View {
        let views = costs.idleClockViews
        if views > 0 {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(3), spacing: 1), count: 40), spacing: 1) {
                ForEach(0..<views, id: \.self) { _ in
                    // Each under its own clock, as each Working mark was.
                    TimelineView(.animation) { context in
                        Color.accentColor.frame(width: 3, height: 3)
                            .opacity(0.675 + 0.325 * cos(2 * .pi * context.date.timeIntervalSinceReferenceDate / Self.period))
                    }
                }
            }
            .frame(width: 160)
            .padding(4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
