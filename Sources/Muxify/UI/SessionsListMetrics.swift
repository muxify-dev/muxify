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

/// The glide of the Sessions list to the card of the Location's Session, when the Location moves to a Window of
/// another Session (ADR 0074).
enum SessionsListScroll {
    /// The glide takes this many seconds, with ease-out. Both versions of the list read it.
    static let glideDuration = 0.15

    /// The offset from the top of the content at which a card from `top` to `bottom` shows whole, by the least move
    /// from `offset` in a viewport `height` high, inside the scroll range from 0 to `end`. A card higher than the
    /// viewport shows its top. Nil when the list does not move: the card shows whole, or the range has no room.
    static func offset(showing top: CGFloat, to bottom: CGFloat, from offset: CGFloat, height: CGFloat, end: CGFloat) -> CGFloat? {
        let target: CGFloat
        if top < offset {
            target = top
        } else if bottom > offset + height {
            target = min(top, bottom - height)
        } else {
            return nil
        }
        let inRange = min(max(0, target), max(0, end))
        return inRange == offset ? nil : inRange
    }
}
