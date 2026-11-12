import AppKit
import MuxifyCore

/// The rows of one Session in an open card of the AppKit Topics list, as `CardList` lists a `CardBlock` in SwiftUI: the
/// Session line over them, and its Window and Pane rows.
struct TopicCardBlock: Equatable {
    let sessionID: String
    /// The Session line's text, the Session's name. Nil for a Locked card, whose rows have no Session line.
    var line: String?
    /// A drag on the Session line moves the block within its Topic, as the SwiftUI list's `SessionHeading` with a
    /// `SessionLineOrder`: in the card of an open Topic. Elsewhere a press on the line only goes to the Session.
    var isOrdered = false
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
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): the blocks of its Sessions
/// (`SessionBlockView`), a divider over each block after the first, then "N more…" when the card holds rows back. A
/// Topic card keeps room at the end for its action in the corner: "N more…" stops before it, or a footer line holds it.
///
/// A drag on the Session line of an open Topic's card moves its block, with its rows, among the card's blocks
/// (`StackDrag`, as `TopicCard.sessionDrag` in SwiftUI), and the dividers hide while it moves. A drag on a Window row
/// moves it among the Windows of its block.
///
/// To accessibility the view is no element: the card lists its rows, each Session line, Window row, Pane row and
/// "N more…" as one row.
final class TopicCardRowsView: NSView, TopicCardBody {
    /// A press on a Session line, with the Session's ID.
    var onSession: (String) -> Void = { _ in }
    /// A drag on a Session line let go: the Session moves before or after another Session of the Topic.
    var onMoveSession: (String, DropPlacement<String>) -> Void = { _, _ in }
    /// A drag on a Window row let go: the Window moves, with its Pane rows, before or after another Window of its Session.
    var onMoveWindow: (TmuxWindow, DropPlacement<String>) -> Void = { _, _ in }
    /// The top of the visible part of the list for the rows, in a clip view: under the card's header while it sticks.
    var visibleListTop: (NSClipView) -> CGFloat = { $0.bounds.minY }
    /// The context menu of a Session line, and its named accessibility actions, with the Session's ID.
    var sessionMenu: (String) -> SidebarMenu? = { _ in nil }
    var sessionActions: (String) -> SidebarMenu? = { _ in nil }
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
    /// The blocks from the top.
    private var blocks: [SessionBlockView] = []
    /// The drag of the blocks, which the Session lines start, and whose placeholder stands among them.
    private lazy var sessionDrag = StackDrag(host: self, spacing: CardSpacing.block, cornerRadius: CardBlockLift.cornerRadius)
    /// A press that moves on a Session line lifts its block: the store has not turned the drag off.
    private var movesSessions = false
    private var environment = SidebarListEnvironment()
    private var showsMore = false
    /// The room the action in the card's corner takes at the end of the rows; 0 for a card with none.
    private var cornerWidth: CGFloat = 0
    private var footerHeight: CGFloat = 0

    /// `identifier` is the card header's, whose "N more…" is `<identifier>-more`.
    init(identifier: String) {
        self.headerIdentifier = identifier
        more = MoreRowView(identifier: identifier)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// A closed card's rows take no click and no pointer, and a drag in them ends. The view takes no click of its own:
    /// a click between two rows goes to the card.
    var isOpen = false {
        didSet {
            for case let row as SidebarRowView in blocks.flatMap(\.rows).map({ $0 as NSView }) { row.isShown = isOpen }
            if !isOpen { abandonDrags() }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// Shows the blocks, then "N more…" for `moreCount` rows held back, with `moreMark` as its value: the strongest
    /// Agent mark of those rows. With `reservesCorner` the rows keep the room of the card's action. A press that moves
    /// on an ordered block's Session line lifts the block while `movesSessions`, and on a Window row lifts its unit while
    /// `movesWindows`. A row that already showed keeps its view, so its tint fades when the Location moves, unless
    /// `fades` is false.
    func show(_ contents: [TopicCardBlock], moreCount: Int, moreMark: AgentMark?, reservesCorner: Bool, movesSessions: Bool,
              movesWindows: Bool, environment: SidebarListEnvironment, fades: Bool) {
        self.environment = environment
        self.movesSessions = movesSessions
        let rows = rowViews.show(contents.flatMap(\.rows), environment: environment, fades: fades)
        var shownLines = lines
        var shownBlocks = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        lines = [:]
        var start = 0
        blocks = contents.map { content in
            let blockRows = Array(zip(content.rows, rows[start..<start + content.rows.count]))
            start += content.rows.count
            for (_, row) in blockRows {
                row.alphaValue = content.fades ? TopicCardRowsOpacity.notOpen : 1
                (row as? SidebarRowView)?.isShown = isOpen
            }
            let line = content.line.map { text in
                self.line(content.sessionID, text: text, kept: shownLines.removeValue(forKey: content.sessionID), content: content)
            }
            let block = shownBlocks.removeValue(forKey: content.sessionID) ?? makeBlock(content.sessionID)
            block.show(line: line, rows: blockRows, movesWindows: movesWindows, environment: environment)
            return block
        }
        // A Window row lifted in a block that went away goes back with it.
        for block in shownBlocks.values { block.abandonDrag() }
        while dividers.count < max(0, blocks.count - 1) { dividers.append(CardBlockDividerView()) }
        dividers.removeLast(max(0, dividers.count - max(0, blocks.count - 1)))
        showsMore = moreCount > 0
        if showsMore { more.show(count: moreCount, value: moreMark?.rawValue ?? "", environment: environment) }
        cornerWidth = reservesCorner ? CardCorner.width(environment.fontSize) : 0
        footerHeight = reservesCorner ? CardCorner.footerHeight(environment.fontSize) : 0
        let views: [NSView] = dividers + [sessionDrag.slot] + blocks + (showsMore ? [more] : [])
        if subviews != views { subviews = views }
        sessionDrag.show()
        layOut()
    }

    /// The Session line of a block: `kept` when it already showed. The line of an ordered block is the handle of the
    /// block's drag, as SwiftUI's `listDrag` on `SessionHeading`: the open hand shows over it while the store has not
    /// turned the drag off, and then a press that moves on it is neither a click nor a drag.
    private func line(_ sessionID: String, text: String, kept: SessionLineView?, content: TopicCardBlock) -> SessionLineView {
        let line = kept ?? SessionLineView()
        line.onPress = { [weak self] in self?.onSession(sessionID) }
        line.menuItems = { [weak self] in self?.sessionMenu(sessionID) }
        line.actions = { [weak self] in self?.sessionActions(sessionID) }
        line.show(text, identifier: headerIdentifier + "-session-" + sessionID, environment: environment)
        line.alphaValue = content.fades ? TopicCardRowsOpacity.notOpen : 1
        line.drag = content.isOrdered ? sessionDrag.handle(sessionID) : nil
        line.isDraggable = content.isOrdered && movesSessions
        lines[sessionID] = line
        return line
    }

    private func makeBlock(_ sessionID: String) -> SessionBlockView {
        let block = SessionBlockView(sessionID: sessionID)
        block.onMoveWindow = { [weak self] in self?.onMoveWindow($0, $1) }
        block.visibleListTop = { [weak self] clip in self?.visibleListTop(clip) ?? clip.bounds.minY }
        return block
    }

    /// The height of the rows in a card `width` wide.
    func height(width: CGFloat) -> CGFloat { place(width: width, placing: false) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() { _ = place(width: bounds.width, placing: true) }

    /// Stacks the blocks from the top as `CardList` does: `CardSpacing.block` between two blocks, with the divider in
    /// that room. Each block stands moved by its drag's offset. "N more…" or the footer line follows the blocks.
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
            guard placing else {
                top += block.height(width: width)
                continue
            }
            top = sessionDrag.place(block, at: top, width: width)
            // A moving Window stays above the next block when it gives way past the end of its own.
            if block.holdsDraggedUnit { block.layer?.zPosition = 2 }
        }
        if placing { sessionDrag.placeSlot() }
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

    /// The card's place in the list moved, as when the list scrolled: a lifted block or Window row keeps its place
    /// under the pointer.
    func placeMoved() {
        sessionDrag.placeMoved()
        for block in blocks { block.placeMoved() }
    }

    private func abandonDrags() {
        sessionDrag.abandon()
        for block in blocks { block.abandonDrag() }
    }

    /// The rows from the top, as the card lists them to accessibility.
    var accessibilityParts: [NSView] {
        blocks.flatMap { block in (block.line.map { [$0 as NSView] } ?? []) + block.rows.flatMap(\.accessibilityParts) }
            + (showsMore ? [more] : [])
    }
}

/// The drag of the Session blocks of an open Topic's card.
extension TopicCardRowsView: StackDragHost {
    var dragUnits: [DragUnitView] { blocks }

    var unitsWidth: CGFloat { bounds.width }

    var liftsUnits: Bool { movesSessions }

    var reducesMotion: Bool { environment.reduceMotion }

    func visibleTop(in clip: NSClipView) -> CGFloat { visibleListTop(clip) }

    func layOutUnits() { layOut() }

    /// The dividers stay with the blocks they top, so they hide while a block moves, as in the SwiftUI card.
    func dragWillPlaceUnits(lifted: DragUnitView?) {
        let shows = sessionDrag.draggedID == nil
        for case let layer? in dividers.map(\.layer) {
            LayerGlide.set("opacity", of: layer, to: Float(shows ? 1 : 0), motion: .easeOut(CardBlockDivider.fadeDuration))
        }
    }

    func drop(_ id: String, at placement: DropPlacement<String>) { onMoveSession(id, placement) }
}

/// The rows of one Session in an open card of the AppKit Topics list, as `CardList` lists a block in SwiftUI: its
/// Session line, when it has one, over its Window and Pane rows in their Window units (`WindowUnitView`), all
/// `CardSpacing.row` apart. A drag on its Session line lifts the whole block among the card's blocks, on the plate of
/// `CardBlockLift`. A drag on a Window row lifts the row with its Pane rows among the block's Window units, as the
/// Sessions list's card lifts them: in a Session with more than one Window row, while the store has not turned the drag
/// off. It takes no click of its own.
final class SessionBlockView: DragUnitView {
    /// A drag on a Window row let go: the Window moves, with its Pane rows, before or after another Window of the
    /// Session.
    var onMoveWindow: (TmuxWindow, DropPlacement<String>) -> Void = { _, _ in }
    /// The top of the visible part of the list for the rows, in a clip view: under the card's header while it sticks.
    var visibleListTop: (NSClipView) -> CGFloat = { $0.bounds.minY }
    private(set) var line: SessionLineView?
    /// The Window and Pane rows from the top, and in their units.
    private(set) var rows: [CardRowView] = []
    private var units: [WindowUnitView] = []
    /// The drag of the Window units, whose placeholder stands among them.
    private lazy var windowDrag = StackDrag(host: self, spacing: CardSpacing.row, cornerRadius: WindowRowMetrics.cornerRadius)
    private var movesWindows = false
    private(set) var reducesMotion = false

    init(sessionID: String) {
        super.init(id: sessionID, cornerRadius: CardBlockLift.cornerRadius)
    }

    /// Shows the Session line and the rows. A unit that already showed keeps its view, so a lifted unit keeps the row
    /// the pointer presses.
    func show(line: SessionLineView?, rows: [(content: CardRowContent, view: CardRowView)], movesWindows: Bool,
              environment: SidebarListEnvironment) {
        self.line = line
        self.rows = rows.map(\.view)
        self.movesWindows = movesWindows
        reducesMotion = environment.reduceMotion
        theme = environment.chromeTheme
        units = WindowUnitView.units(of: rows, keeping: units)
        for unit in units { unit.theme = environment.chromeTheme }
        let lifts = liftsUnits
        for case let row as WindowRowView in self.rows {
            row.drag = windowDrag.handle(row.windowID)
            row.isDraggable = lifts
        }
        parts = (line.map { [$0] } ?? []) + [windowDrag.slot] + units
        windowDrag.show()
    }

    /// The units of Window rows, from the top.
    private var windowUnits: [WindowUnitView] { units.filter { $0.tmuxWindow != nil } }

    /// A Window unit of the block is lifted, or glides to where it lands.
    var holdsDraggedUnit: Bool { windowDrag.draggedID != nil }

    /// The Session line and the units, `CardSpacing.row` apart.
    override func height(width: CGFloat) -> CGFloat {
        let heights = (line.map { [$0.height(width: width)] } ?? []) + units.map { $0.height(width: width) }
        return heights.reduce(0, +) + CardSpacing.row * CGFloat(max(0, heights.count - 1))
    }

    /// Stacks the Session line and the units from the top, each unit moved by its drag's offset.
    override func layOutParts() {
        let width = bounds.width
        var top: CGFloat = 0
        if let line {
            line.frame = NSRect(x: 0, y: 0, width: width, height: line.height(width: width))
            top = line.frame.maxY + CardSpacing.row
        }
        for unit in units { top = windowDrag.place(unit, at: top, width: width) + CardSpacing.row }
        windowDrag.placeSlot()
    }

    /// The block's place in the list moved: a lifted Window row keeps its place under the pointer.
    func placeMoved() { windowDrag.placeMoved() }

    /// The card closed, or the block went away: a lifted Window row goes back.
    func abandonDrag() { windowDrag.abandon() }
}

/// The drag of the Window units of a Session block.
extension SessionBlockView: StackDragHost {
    var dragUnits: [DragUnitView] { windowUnits }

    var unitsWidth: CGFloat { bounds.width }

    var liftsUnits: Bool { movesWindows && windowUnits.count > 1 }

    func visibleTop(in clip: NSClipView) -> CGFloat { visibleListTop(clip) }

    func layOutUnits() { layOutParts() }

    func drop(_ id: String, at placement: DropPlacement<String>) {
        guard let window = windowUnits.first(where: { $0.id == id })?.tmuxWindow else { return }
        onMoveWindow(window, placement)
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
/// the first click while Muxify is not the front app. In an open Topic's card the line is the handle of its block
/// (`SidebarPressView.drag`): a press that moves lifts the block, and a press let go in place goes to the Session.
final class SessionLineView: SidebarPressView {
    private let label = SidebarLabel()
    /// The line's context menu and its named accessibility actions, as the list reads them for the Session. A line with
    /// no menu passes a right-click to its card.
    var menuItems: () -> SidebarMenu? = { nil }
    var actions: () -> SidebarMenu? = { nil }

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

    /// A right-click or a Control-click on the line shows the line's menu, in place of the card's.
    override func menu(for event: NSEvent) -> NSMenu? { menuItems()?.contextMenu() }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { actions()?.accessibilityActions }

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
