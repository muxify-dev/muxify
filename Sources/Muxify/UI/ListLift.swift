import CoreGraphics

/// The look and the motion of an item that a list's drag presses and lifts, for the SwiftUI drag and the AppKit drag
/// of a Window row (ADR 0074), so the two cannot drift.
enum ListLift {
    /// A spring as SwiftUI's `spring(duration:bounce:)` names it.
    struct Spring: Equatable {
        let duration: Double
        let bounce: Double
    }

    /// How far the pointer moves before a press is a drag; a press that moves less is still a click.
    static let slop: CGFloat = 4
    /// A pressed item sinks to this, with ease-out over `pressDuration`, until it lifts or the press ends.
    static let pressScale: CGFloat = 0.98
    static let pressDuration = 0.12
    /// A lifted item grows by this much around `anchor`, a point of its size, on the spring `lift`.
    static let scale: CGFloat = 1.03
    static let anchor = CGPoint(x: 0.5, y: 0.3)
    static let lift = Spring(duration: 0.25, bounce: 0.3)
    /// The items make room for the placeholder, and a dropped item glides into it, on this spring.
    static let land = Spring(duration: 0.3, bounce: 0.15)
    /// A press that moved on an item that cannot move ends on this spring.
    static let cancel = Spring(duration: 0.25, bounce: 0)
    /// A lifted item goes back to its place on this spring: when its view goes away, or when the list did not show
    /// its new order in time.
    static let back = Spring(duration: 0.3, bounce: 0)
    /// How long a dropped item waits for the list to show the new order before the list goes back to the order it shows.
    static let settleLimit: Duration = .seconds(3)

    /// The shadow of a lifted item: black at this opacity, with this radius, this far below the item.
    static let shadowOpacity = 0.4
    static let shadowRadius: CGFloat = 14
    static let shadowDrop: CGFloat = 10
    /// The plate a pressed or lifted item stands on: the chrome's background under the text colour at
    /// `plateFillOpacity`, in a border of the text colour at `plateBorderOpacity`.
    static let plateFillOpacity = 0.1
    static let plateBorderOpacity = 0.14
    static let plateBorderWidth: CGFloat = 1
    /// The placeholder where a lifted item would land: the accent colour at `slotFillOpacity`, in a dashed border of
    /// it at `slotBorderOpacity`.
    static let slotFillOpacity = 0.08
    static let slotBorderOpacity = 0.55
    static let slotBorderWidth: CGFloat = 1.5
    static let slotDash: [CGFloat] = [5, 4]

    /// How far a lifted item may move up before its top leaves the visible part of its scroll view, and down before
    /// its bottom does, from how far its top is below the visible top and its bottom above the visible bottom. Grown by
    /// `scale` around `anchor`, its top stands a little higher than its place and its bottom a little lower.
    static func room(visibleTop: CGFloat, footroom: CGFloat, height: CGFloat, scale: CGFloat = scale) -> (headroom: CGFloat, footroom: CGFloat) {
        (visibleTop - (scale - 1) * anchor.y * height, footroom - (scale - 1) * (1 - anchor.y) * height)
    }
}
