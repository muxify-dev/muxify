import AppKit

/// A part of the AppKit Sessions list that a click presses (ADR 0074): a card's header or a row. It takes every click
/// on it, and its parts take none. A press works on the first click while Muxify is not the front app, and it ends
/// where the mouse comes up, as a tap in SwiftUI. To accessibility, a part that is an element presses with its action.
class SidebarPressView: NSView {
    var onPress: () -> Void = {}

    override var isFlipped: Bool { true }

    /// The point is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}

/// A row of an open card in the AppKit Sessions list (ADR 0074): a Window row or a Pane row. The row that shows the
/// Location has the soft tint, which fades in and out, and a row under the pointer has the faint fill.
class SidebarRowView: SidebarPressView {
    let fill = RowFillView()
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    /// The row shows the Location, so it has the tint. A row sets it before it calls `showFill`.
    var showsLocation = false

    private var fillState: RowFillView.Fill { showsLocation ? .tint : hovering ? .hover : .clear }

    /// Shows the fill of the row's state. With `fades`, the tint fades from where it shows now.
    func showFill(fades: Bool) { fill.show(fillState, fades: fades) }

    /// As `PanelDivider`'s: the row hears the pointer come and go also while Muxify is not the front app.
    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        showFill(fades: false)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        showFill(fades: false)
    }

    #if DEBUG
    /// The colour the row's fill has now, and the fade of the tint that runs, for the tests.
    var fillColor: CGColor? { fill.shownColor }
    var tintFade: CAAnimation? { fill.fade }
    #endif
}

/// A row of an open card, as the card lays its rows out and lists their accessibility rows.
@MainActor protocol CardRowView: NSView {
    /// The row's height in a card `width` wide.
    func height(width: CGFloat) -> CGFloat
    /// The row's accessibility rows, from the left.
    var accessibilityParts: [NSView] { get }
}
