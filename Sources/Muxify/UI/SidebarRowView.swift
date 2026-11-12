import AppKit
import MuxifyCore

/// A part of an AppKit list that a click presses (ADR 0074): a card's header or a row. It takes every click on it, and
/// its parts take none. A press works on the first click while Muxify is not the front app, and it ends where the mouse
/// comes up, as a tap in SwiftUI. To accessibility, a part that is an element presses with its action.
///
/// A Control-click is a right-click, as in SwiftUI: it opens the menu that a right-click opens there, and it presses
/// nothing and starts no drag. A part that does more with a press than `onPress` does it in `pressDown`, `pressMoved`
/// and `pressUp`, which a Control-click never reaches.
///
/// A part with a `drag` is the handle of the unit `dragID` of that drag, as SwiftUI's `listDrag` makes a view the
/// handle of a `ListDrag` item: a Window row of its Window unit, or a Session line of its Session block. A press that
/// moves lifts the unit, and a press let go before that is a click, which the drag hands to `onPress`.
class SidebarPressView: NSView {
    var onPress: () -> Void = {}
    /// The drag of the unit that the part is the handle of, and the unit's ID. Without a drag, a click presses the part
    /// where the mouse comes up.
    weak var drag: StackDrag?
    var dragID = ""
    /// A press that moves lifts the unit: the pointer is the open hand over the part.
    var isDraggable = false {
        didSet {
            if isDraggable != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }
    /// The mouse went down on the part without Control and has not come up: the mouse's moves and its coming up
    /// belong to a press.
    private var pressing = false

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        if isDraggable { addCursorRect(bounds, cursor: .openHand) }
    }

    /// The point is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    final override func mouseDown(with event: NSEvent) {
        pressing = !event.modifierFlags.contains(.control)
        guard pressing else { return rightMouseDown(with: event) }
        pressDown(at: event.locationInWindow)
    }

    final override func mouseDragged(with event: NSEvent) {
        if pressing { pressMoved(to: event.locationInWindow) }
    }

    final override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        pressUp(at: event.locationInWindow)
    }

    /// The mouse went down on the part at `point`, in the window.
    func pressDown(at point: NSPoint) {
        drag?.press(dragID, at: point)
    }

    /// The mouse moved to `point` in the window while it presses the part.
    func pressMoved(to point: NSPoint) {
        drag?.drag(dragID, to: point)
    }

    /// The mouse came up at `point` in the window: on the part, the part is pressed. A handle's drag decides whether
    /// the press was a click.
    func pressUp(at point: NSPoint) {
        if let drag { return drag.release(dragID, onTap: onPress) }
        if bounds.contains(convert(point, from: nil)) { onPress() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}

/// A row of an open card in the AppKit Sessions list (ADR 0074): a Window row or a Pane row. The row that shows the
/// Location has the soft tint, which fades in and out, and a row under the pointer has the faint fill. After the
/// pointer rests on the row, its hover label opens over it; the label closes when the pointer leaves the row and when
/// the row goes away.
class SidebarRowView: SidebarPressView {
    let fill = RowFillView()
    /// The row's hover label. The row gives it its title and what it shows.
    let hoverLabel = RowHoverLabel()
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    /// The row shows the Location, so it has the tint. A row sets it before it calls `showFill`.
    var showsLocation = false

    /// False for a row of a closed card: the card keeps the row, which fades where it stands, and the row has gone away
    /// for the user. It takes no pointer, and its hover label closes.
    var isShown = true {
        didSet {
            guard isShown != oldValue, !isShown else { return }
            hovering = false
            showFill(fades: false)
            hoverLabel.disappear()
        }
    }

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
        guard isShown else { return }
        hovering = true
        showFill(fades: false)
        hoverLabel.pointer(inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        showFill(fades: false)
        hoverLabel.pointer(inside: false)
    }

    /// A row that leaves the window, as when its Window or its card goes, closes its label.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverLabel.disappear() }
    }
}

/// A row of an open card, as the card lays its rows out and lists their accessibility rows.
@MainActor protocol CardRowView: NSView {
    /// The row's height in a card `width` wide.
    func height(width: CGFloat) -> CGFloat
    /// The row's accessibility rows, from the left.
    var accessibilityParts: [NSView] { get }
}

/// The views of the Window rows and Pane rows of the open cards in an AppKit list: a row that already showed keeps its
/// view, by its Window or Pane ID, so its tint fades when the Location moves and a lifted row keeps the pointer. The
/// Sessions list's Session card and the Topics list's cards make their rows here.
@MainActor final class CardRowViews {
    /// The rows are in the Topics list: a Window row is `topic-window-<id>`, one button to accessibility as the SwiftUI
    /// Topics list gives it, where the Sessions list gives `session-window-<id>` to each of its parts.
    private let inTopicsList: Bool
    private var windows: [String: WindowRowView] = [:]
    private var panes: [String: PaneRowView] = [:]
    /// A click on a Window row.
    var onSelectWindow: (TmuxWindow) -> Void = { _ in }
    /// A press on a Pane row, with the Pane's ID.
    var onSelectPane: (String) -> Void = { _ in }
    /// The context menu of a Window row.
    var windowMenu: (TmuxWindow) -> SidebarMenu? = { _ in nil }
    /// The named accessibility actions of a Window row of the Topics list, which is one button.
    var windowActions: (TmuxWindow) -> SidebarMenu? = { _ in nil }

    init(inTopicsList: Bool) {
        self.inTopicsList = inTopicsList
    }

    /// The views of the rows, from the top, each showing its content. A row that showed and has no content now goes.
    /// The tint of a row that already showed fades when the Location comes or goes, unless `fades` is false.
    func show(_ contents: [CardRowContent], environment: SidebarListEnvironment, fades: Bool) -> [CardRowView] {
        var shownWindows = windows, shownPanes = panes
        windows = [:]
        panes = [:]
        return contents.map { content -> CardRowView in
            switch content {
            case .window(let content):
                let window = content.window
                let row = shownWindows.removeValue(forKey: window.id)
                    ?? WindowRowView(windowID: window.id, identifier: (inTopicsList ? "topic-window-" : "session-window-") + window.id,
                                     isButton: inTopicsList)
                row.onPress = { [weak self] in self?.onSelectWindow(window) }
                row.menuItems = { [weak self] in self?.windowMenu(window) }
                row.actions = { [weak self] in self?.windowActions(window) }
                row.show(content, environment: environment, fades: fades)
                windows[window.id] = row
                return row
            case .pane(let content):
                let row = shownPanes.removeValue(forKey: content.paneID) ?? PaneRowView(paneID: content.paneID)
                row.onPress = { [weak self] in self?.onSelectPane(content.paneID) }
                row.show(content, environment: environment, fades: fades)
                panes[content.paneID] = row
                return row
            }
        }
    }
}
