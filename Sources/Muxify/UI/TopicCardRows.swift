import AppKit
import MuxifyCore

/// The rows of one Session in an open card of the AppKit Topics list, as `CardList` lists a `CardBlock` in SwiftUI: the
/// Session line over them, and its Window and Pane rows.
struct TopicCardBlock: Equatable {
    let sessionID: String
    /// The Session line's text, the Session's name. Nil for a Locked card, whose rows have no Session line.
    var line: String?
    /// The Topic is not open: the Session line fades and the rows dim (`TopicCardRowsOpacity`).
    var fades = false
    var rows: [CardRowContent]
}

/// What an open card of the AppKit Topics list lists under its header: the rows of its Sessions, or the remembered
/// Sessions of a Settled card. The card lays it out under its header and lists its accessibility rows.
@MainActor protocol TopicCardBody: NSView {
    /// The height of what it lists in a card `width` wide.
    func height(width: CGFloat) -> CGFloat
    /// The rows from the top, as the card lists them to accessibility.
    var accessibilityParts: [NSView] { get }
    /// False while the card is closed: the card keeps what it listed, which fades where it stands and takes no click.
    var isOpen: Bool { get set }
}

/// What an open card of the AppKit Topics list lists under its header, as `CardList` lists it in SwiftUI
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): the blocks of its Sessions, a divider over each
/// block after the first, then "N more…" when the card holds rows back. A Topic card keeps room at the end for its
/// action in the corner: "N more…" stops before it, or a footer line holds it.
///
/// To accessibility the view is no element: the card lists its rows, each Session line, Window row, Pane row and
/// "N more…" as one row.
final class TopicCardRowsView: NSView, TopicCardBody {
    /// A press on a Session line, with the Session's ID.
    var onSession: (String) -> Void = { _ in }
    /// A press on "N more…".
    var onShowAllRows: () -> Void = {} {
        didSet { more.onPress = onShowAllRows }
    }
    let rowViews = CardRowViews(inTopicsList: true)
    /// The card header's identifier.
    private let headerIdentifier: String
    private let more: MoreRowView
    /// The Session lines of the blocks, by Session ID.
    private var lines: [String: SessionLineView] = [:]
    private var dividers: [CardBlockDividerView] = []
    /// The blocks from the top: each Session line, when it has one, and the rows under it.
    private var blocks: [(line: SessionLineView?, rows: [CardRowView])] = []
    private var showsMore = false
    /// The room the action in the card's corner takes at the end of the rows; 0 for a card with none.
    private var cornerWidth: CGFloat = 0
    private var footerHeight: CGFloat = 0

    /// `identifier` is the card header's, whose "N more…" is `<identifier>-more`.
    init(identifier: String) {
        self.headerIdentifier = identifier
        more = MoreRowView(identifier: identifier)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A closed card's rows take no click and no pointer. The view takes no click of its own: a click between two rows
    /// goes to the card.
    var isOpen = false {
        didSet {
            for case let row as SidebarRowView in blocks.flatMap(\.rows).map({ $0 as NSView }) { row.isShown = isOpen }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Shows the blocks, then "N more…" for `moreCount` rows held back, with `moreMark` as its value: the strongest
    /// Agent mark of those rows. With `reservesCorner` the rows keep the room of the card's action. A row that already
    /// showed keeps its view, so its tint fades when the Location moves, unless `fades` is false.
    func show(_ contents: [TopicCardBlock], moreCount: Int, moreMark: AgentMark?, reservesCorner: Bool,
              environment: SidebarListEnvironment, fades: Bool) {
        let rows = rowViews.show(contents.flatMap(\.rows), environment: environment, fades: fades)
        var shownLines = lines
        lines = [:]
        var start = 0
        blocks = contents.map { content in
            let blockRows = Array(rows[start..<start + content.rows.count])
            start += content.rows.count
            for row in blockRows {
                row.alphaValue = content.fades ? TopicCardRowsOpacity.notOpen : 1
                (row as? SidebarRowView)?.isShown = isOpen
            }
            guard let text = content.line else { return (nil, blockRows) }
            let line = shownLines.removeValue(forKey: content.sessionID) ?? SessionLineView()
            let sessionID = content.sessionID
            line.onPress = { [weak self] in self?.onSession(sessionID) }
            line.show(text, identifier: headerIdentifier + "-session-" + sessionID, environment: environment)
            line.alphaValue = content.fades ? TopicCardRowsOpacity.notOpen : 1
            lines[content.sessionID] = line
            return (line, blockRows)
        }
        while dividers.count < max(0, blocks.count - 1) { dividers.append(CardBlockDividerView()) }
        dividers.removeLast(max(0, dividers.count - max(0, blocks.count - 1)))
        showsMore = moreCount > 0
        if showsMore { more.show(count: moreCount, value: moreMark?.rawValue ?? "", environment: environment) }
        cornerWidth = reservesCorner ? CardCorner.width(environment.fontSize) : 0
        footerHeight = reservesCorner ? CardCorner.footerHeight(environment.fontSize) : 0
        let views: [NSView] = dividers + blocks.flatMap { block in (block.line.map { [$0] } ?? []) + block.rows.map { $0 as NSView } }
            + (showsMore ? [more] : [])
        if subviews != views { subviews = views }
        layOut()
    }

    /// The height of the rows in a card `width` wide.
    func height(width: CGFloat) -> CGFloat { place(width: width, placing: false) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() { _ = place(width: bounds.width, placing: true) }

    /// Stacks the blocks from the top as `CardList` does: `CardSpacing.block` between two blocks, with the divider in
    /// that room, and `CardSpacing.row` between two rows of a block. "N more…" or the footer line follows the blocks.
    /// Returns the height; with `placing`, it also puts the views there.
    private func place(width: CGFloat, placing: Bool) -> CGFloat {
        var top: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                top += CardSpacing.block
                if placing {
                    dividers[index - 1].frame = NSRect(x: CardBlockDivider.inset, y: top - CardBlockDivider.rise,
                                                       width: max(0, width - 2 * CardBlockDivider.inset), height: StuckHeader.dividerWidth)
                }
            }
            let views: [NSView] = (block.line.map { [$0] } ?? []) + block.rows.map { $0 as NSView }
            for (row, view) in views.enumerated() {
                if row > 0 { top += CardSpacing.row }
                let height = (view as? SessionLineView)?.height(width: width) ?? (view as? CardRowView)?.height(width: width) ?? 0
                if placing { view.frame = NSRect(x: 0, y: top, width: width, height: height) }
                top += height
            }
        }
        // The stack of the blocks keeps its place before "N more…" or the footer line also when it has no block.
        if showsMore || footerHeight > 0 { top += CardSpacing.row }
        if showsMore {
            let moreWidth = max(0, width - cornerWidth)
            let height = more.height(width: moreWidth)
            if placing { more.frame = NSRect(x: 0, y: top, width: moreWidth, height: height) }
            top += height
        } else {
            top += footerHeight
        }
        return top
    }

    /// The rows from the top, as the card lists them to accessibility.
    var accessibilityParts: [NSView] {
        blocks.flatMap { block in (block.line.map { [$0 as NSView] } ?? []) + block.rows.flatMap(\.accessibilityParts) }
            + (showsMore ? [more] : [])
    }
}

/// A Session that a Settled Topic's record remembers, as its open card lists it: its Session line, then a row for each of
/// its remembered Windows.
struct RememberedSessionContent: Equatable {
    let sessionID: String
    /// The Session line's text, the Session's name.
    let line: String
    var windows: [RememberedRowContent]
}

/// What an open Settled card lists under its header, as `RememberedSessions` lists it in SwiftUI
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): for each remembered Session its Session line,
/// faded as a Settled Topic's, then the rows of its remembered Windows, all `CardSpacing.row` apart, and at the end the
/// room of the card's action, Reopen. A press on a Session line or a row does nothing: nothing of them is live.
///
/// To accessibility the view is no element: the card lists its Session lines and rows, each one row.
final class RememberedSessionsView: NSView, TopicCardBody {
    /// The card header's identifier.
    private let headerIdentifier: String
    /// The Session lines and the rows, from the top.
    private var parts: [NSView] = []
    private var lines: [String: SessionLineView] = [:]
    private var rows: [String: RememberedRowView] = [:]
    private var footerHeight: CGFloat = 0

    /// `identifier` is the card header's, whose Session lines are `<identifier>-session-<Session ID>`.
    init(identifier: String) {
        headerIdentifier = identifier
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A closed card's rows take no click and no pointer, and their hover labels close.
    var isOpen = false {
        didSet {
            for row in rows.values { row.isShown = isOpen }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Shows the Sessions. A Session line or a row that already showed keeps its view.
    func show(_ sessions: [RememberedSessionContent], environment: SidebarListEnvironment) {
        var shownLines = lines, shownRows = rows
        lines = [:]
        rows = [:]
        parts = sessions.flatMap { session -> [NSView] in
            let line = shownLines.removeValue(forKey: session.sessionID) ?? SessionLineView()
            line.show(session.line, identifier: headerIdentifier + "-session-" + session.sessionID, environment: environment)
            line.alphaValue = TopicCardRowsOpacity.notOpen
            lines[session.sessionID] = line
            return [line] + session.windows.map { content -> NSView in
                let row = shownRows.removeValue(forKey: content.windowID) ?? RememberedRowView(windowID: content.windowID)
                row.show(content, environment: environment)
                row.isShown = isOpen
                rows[content.windowID] = row
                return row
            }
        }
        footerHeight = environment.fontSize(RememberedRowMetrics.designFooterHeight)
        if subviews != parts { subviews = parts }
        layOut()
    }

    func height(width: CGFloat) -> CGFloat { place(width: width, placing: false) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() { _ = place(width: bounds.width, placing: true) }

    /// Stacks the Session lines and the rows from the top, `CardSpacing.row` apart, with the room of the card's action
    /// after them. Returns the height; with `placing`, it also puts the views there.
    private func place(width: CGFloat, placing: Bool) -> CGFloat {
        var top: CGFloat = 0
        for view in parts {
            let height = (view as? SessionLineView)?.height(width: width) ?? (view as? RememberedRowView)?.height ?? 0
            if placing { view.frame = NSRect(x: 0, y: top, width: width, height: height) }
            top += height + CardSpacing.row
        }
        return top + footerHeight
    }

    var accessibilityParts: [NSView] { parts }
}

/// The Session line of an open Topic card, over the Session's rows: `SessionHeading` in SwiftUI. Its name on one line,
/// cut with "…" when it does not fit, in a small bold text of the secondary colour. To accessibility it is one button,
/// `<card header's identifier>-session-<Session ID>`, named by the Session's name. A press goes to the Session, also on
/// the first click while Muxify is not the front app.
final class SessionLineView: SidebarPressView {
    private let label = SidebarLabel()

    init() {
        super.init(frame: .zero)
        label.ink = .secondary
        subviews = [label]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String, identifier: String, environment: SidebarListEnvironment) {
        label.text = text
        label.font = .systemFont(ofSize: environment.fontSize(SessionLineMetrics.fontSize), weight: .semibold)
        label.scale = environment.displayScale
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(text)
        layOut()
    }

    /// The name's line and the room above and below it.
    func height(width: CGFloat) -> CGFloat { SessionLineMetrics.top + label.lineHeight + SessionLineMetrics.bottom }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// The name from the leading padding, in the room the space after it leaves.
    private func layOut() {
        let room = bounds.width - SessionLineMetrics.leading - SessionLineMetrics.trailing - SessionLineMetrics.spacing
            - SessionLineMetrics.endGap
        let size = label.fit(width: max(0, room))
        label.frame = NSRect(x: SessionLineMetrics.leading, y: SessionLineMetrics.top, width: size.width, height: size.height)
    }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

/// The divider over a Session block of an open card, after the first: a line in the separator colour, as SwiftUI's
/// `Divider` draws one.
final class CardBlockDividerView: LayerColoredView {
    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func colorLayers() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
