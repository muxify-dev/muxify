import CoreGraphics

/// Where the Sessions list puts its cards. The SwiftUI list and the AppKit list both read it, so the two cannot drift
/// (ADR 0074).
enum SessionsListMetrics {
    /// The gap between two cards.
    static let cardSpacing: CGFloat = 6
    /// The room between the cards and the sides of the list.
    static let horizontalInset: CGFloat = 6
    /// The room above the first card and below the last.
    static let verticalInset: CGFloat = 4
}
