import Foundation

/// Whether the Sidebar animates a move of the selection: a card that opens, a scroll to the selected card, and the
/// turn of its border. A move soon after the one before it does not animate. In a quick run of switches each move cut
/// the last one's animations short, and every frame of them laid out the cards again, which kept the main thread busy.
///
/// It is not observable: the views read it in their change handlers, so it never makes a view update. It is shared by
/// the App Windows, as the user switches in one of them at a time.
@MainActor
enum SwitchPace {
    /// A move this soon after the one before it is part of a quick run.
    static let quick: TimeInterval = 0.35

    private static var lastMove = Date.distantPast
    /// Whether the last move came alone, not in a quick run.
    private(set) static var animates = true

    /// The store calls it when the selection moves to another Window, before the views update.
    static func moved(now: Date = Date()) {
        animates = now.timeIntervalSince(lastMove) >= quick
        lastMove = now
    }
}
