import AppKit
import MuxifyCore

/// What a card of the AppKit Topics list shows, a Topic card or a Locked card, as the list reads it from the models.
struct TopicCardContent: Equatable {
    var header: CardHeaderContent
    /// The card holds the Location: it is the Active Topic's card.
    var holdsSelection = false
    /// The mark of the spine along the card's left edge. The open card of the Active Topic shows the marks on its rows
    /// instead.
    var spine: CardMark?
    /// The Unread mark's spine over the header, which the open card of an Unread Active Topic shows while its rows show
    /// the Agent marks.
    var unreadOverHeader = false
    /// The opacity of the card at rest, as `TopicCardOpacity` gives it. The Hint shows whole.
    var restingOpacity = 1.0
    /// The Topic's own action in the card's bottom-right corner. Nil for a Locked card.
    var corner: TopicCardCorner?
    /// The blocks of the Sessions that an open card lists, each cut at `CardRows.shownCount` of the card's rows. A
    /// closed card has none.
    var blocks: [TopicCardBlock] = []
    /// The rows an open card holds back, which its "N more…" counts. 0 for none.
    var moreCount = 0
    /// The strongest Agent mark of the rows held back, which "N more…" names.
    var moreMark: AgentMark?
    /// A press that moves on the Session line of an ordered block lifts the block, and one on a Window row lifts the
    /// row with its Pane rows: the store has not turned the drag off. Off, such a press is neither a click nor a drag.
    var movesSessions = true
    var movesWindows = true
    /// The Sessions that an open Settled card remembers, which it lists in place of `blocks`. Nil for a card that is not
    /// Settled.
    var remembered: [RememberedSessionContent]?
}

/// The Topic's own action in the bottom-right corner of its card, as a link: Settle in the Topics list, Reopen in the
/// Settled group.
struct TopicCardCorner: Equatable {
    let title: String
    let identifier: String
    var isEnabled = true
}

/// A card of the AppKit Topics list (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): a Topic card
/// or a Locked card, as `TopicCard` and `LockedCard` draw them in SwiftUI. Closed, it is flat, with only its border;
/// open, it is raised, and lists its Sessions' rows under its header (`TopicCardRowsView`), or a Settled card its
/// remembered Sessions (`RememberedSessionsView`), whose header sticks to the top of the list while the rows scroll
/// under it. A spine shows its mark, and the card that holds the Location has the many-coloured border. A Topic card
/// shows Settle in its corner, or in the Settled group Reopen, with how long ago it was Settled in its top-right corner.
/// A card rests at its opacity, and its Hint shows whole.
///
/// In the Topics list the card is a unit of the list's drag (`StackDrag`), whose handle is its header: a press that
/// moves on the header lifts the card, on its plate, and a press let go before that is a click.
///
/// To accessibility the view is no element: its rows are the corner's link, then the card, `card-<id>`, whose rows are
/// the rows of an open card, its header, `<id>`, its Tags, `tags-<id>`, the word in its top-right corner, and its Hint,
/// as SwiftUI gives them. `<id>` is the card's `accessibilityID`, such as `topic-<Topic ID>` or `locked-<Session ID>`.
final class TopicCardView: DragUnitView {
    let cardID: TopicGroupID
    /// A press on the header, or on the Tags over it.
    var onPress: () -> Void = {} {
        didSet {
            header.onPress = onPress
            tags.onPress = onPress
        }
    }
    /// The drag that a press that moves on the header starts; nil in the Settled group, where a card does not move.
    var drag: StackDragHandle? {
        get { header.drag }
        set { header.drag = newValue }
    }
    /// A press that moves on the header lifts the card: the open hand shows over it.
    var isDraggable: Bool {
        get { header.isDraggable }
        set { header.isDraggable = newValue }
    }
    /// A press on the action in the corner.
    var onCorner: () -> Void = {} {
        didSet { corner.onPress = onCorner }
    }
    /// A click on a Window row.
    var onSelectWindow: (TmuxWindow) -> Void {
        get { rows.rowViews.onSelectWindow }
        set { rows.rowViews.onSelectWindow = newValue }
    }
    /// A press on a Pane row, with the Pane's ID.
    var onSelectPane: (String) -> Void {
        get { rows.rowViews.onSelectPane }
        set { rows.rowViews.onSelectPane = newValue }
    }
    /// A press on a Session line, with the Session's ID.
    var onSession: (String) -> Void {
        get { rows.onSession }
        set { rows.onSession = newValue }
    }
    /// A drag on a Session line let go: the Session moves before or after another Session of the Topic.
    var onMoveSession: (String, DropPlacement<String>) -> Void {
        get { rows.onMoveSession }
        set { rows.onMoveSession = newValue }
    }
    /// A drag on a Window row let go: the Window moves, with its Pane rows, before or after another Window of its Session.
    var onMoveWindow: (TmuxWindow, DropPlacement<String>) -> Void {
        get { rows.onMoveWindow }
        set { rows.onMoveWindow = newValue }
    }
    /// A press on "N more…".
    var onShowAllRows: () -> Void {
        get { rows.onShowAllRows }
        set { rows.onShowAllRows = newValue }
    }
    /// The card's context menu, which is also its named accessibility actions, as the card is now.
    var menuItems: () -> SidebarMenu? {
        get { card.menuItems }
        set { card.menuItems = newValue }
    }
    /// The named accessibility actions of the header, as the card is now.
    var headerActions: () -> SidebarMenu? {
        get { header.actions }
        set { header.actions = newValue }
    }
    /// The context menu of a Window row and its named accessibility actions, as the list reads them for the Window.
    var windowMenu: (TmuxWindow) -> SidebarMenu? {
        get { rows.rowViews.windowMenu }
        set { rows.rowViews.windowMenu = newValue }
    }
    var windowActions: (TmuxWindow) -> SidebarMenu? {
        get { rows.rowViews.windowActions }
        set { rows.rowViews.windowActions = newValue }
    }
    /// The context menu of a Session line and its named accessibility actions, with the Session's ID.
    var sessionMenu: (String) -> SidebarMenu? {
        get { rows.sessionMenu }
        set { rows.sessionMenu = newValue }
    }
    var sessionActions: (String) -> SidebarMenu? {
        get { rows.sessionActions }
        set { rows.sessionActions = newValue }
    }
    /// The card, as one accessibility row.
    private let card = TopicCardGroupView()
    /// The parts of the card that rest at its opacity.
    private let dimmed = FlippedView()
    private let fill = CardFillView()
    private let header: CardHeaderView
    /// The Tags of a Topic card, over the place that the header keeps for them. They rest at the card's opacity part
    /// by part (`SidebarTagsView`), so they are no part of `dimmed`.
    private let tags = SidebarTagsView()
    /// The rows of an open card, or the remembered Sessions of an open Settled card. A card that closes keeps them, so
    /// they fade where they stand.
    private let rows: TopicCardRowsView
    private let remembered: RememberedSessionsView
    /// The word in the top-right corner, over the place the header keeps for it.
    private let cornerLabel = CardCornerLabelView()
    private let unread = CardSpineView()
    private let spine = CardSpineView()
    private let outline = CardOutlineView()
    private let selection = CardSelectionBorderView()
    private let hint = CardHintViews()
    /// The Hints of the Window rows of an open card, over the rows and the header, as SwiftUI's `cardHints` shows them.
    private let windowHints = WindowHintViews()
    private let corner = TopicCardCornerView()
    private var content: TopicCardContent?
    private var environment = SidebarListEnvironment()
    /// The card's top edge in the list's viewport, and where the header of an open card sticks there: the header
    /// sticks once the card's top has scrolled past it.
    private var viewportTop: CGFloat = 0
    private var stickInset: CGFloat = 0

    init(cardID: TopicGroupID) {
        self.cardID = cardID
        header = CardHeaderView(identifier: cardID.accessibilityID)
        rows = TopicCardRowsView(identifier: cardID.accessibilityID)
        remembered = RememberedSessionsView(identifier: cardID.accessibilityID)
        super.init(id: cardID.accessibilityID, cornerRadius: CardOutline.cornerRadius)
        dimmed.wantsLayer = true
        // The SwiftUI card cuts nothing off.
        for view in [self, card, dimmed] { view.clipsToBounds = false }
        // From the back: the fill, the rows, the header, which stays above the rows that scroll under it, the word in
        // its corner, the spines, the border, then the Tags over the header, the Hints and the corner's action.
        dimmed.subviews = [fill, rows, remembered, header, cornerLabel, unread, spine, outline, selection]
        card.subviews = [dimmed, tags] + hint.views
        parts = [card, corner]
        card.setAccessibilityIdentifier("card-" + cardID.accessibilityID)
        card.header = header
        rows.didPlaceRows = { [weak self] rows in
            guard let self else { return }
            windowHints.place(in: card, rows: rows)
        }
        // A row dragged up stops at the bottom of the header that sticks to the top, not under it.
        rows.visibleListTop = { [weak self] clip in
            guard let self, header.sticks else { return clip.bounds.minY }
            return dimmed.convert(header.frame, to: clip).maxY
        }
        card.rows = { [weak self] in
            self.map {
                ($0.isOpen ? $0.body.accessibilityParts : []) + [$0.header] + ($0.tags.isHidden ? [] : [$0.tags])
                    + ($0.cornerLabel.isHidden ? [] : [$0.cornerLabel]) + $0.hints
            } ?? []
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var isOpen: Bool { content?.header.isOpen ?? false }

    /// What the card lists under its header while it is open: its rows, or a Settled card's remembered Sessions.
    private var body: any TopicCardBody { content?.remembered == nil ? rows : remembered }

    /// Shows the content. The colours of the border turn once when the Location comes to a card that already showed.
    func show(_ content: TopicCardContent, environment: SidebarListEnvironment) {
        guard content != self.content || environment != self.environment else { return }
        let came = self.content.map { !$0.holdsSelection && content.holdsSelection } ?? false
        let wasOpen = isOpen
        self.content = content
        self.environment = environment
        theme = environment.chromeTheme
        header.show(content.header, environment: environment)
        tags.show(content.header.tags, fontSize: environment.fontSize, scale: environment.displayScale, opacity: content.restingOpacity)
        cornerLabel.show(content.header.cornerLabel, environment: environment)
        if content.header.isOpen {
            if let remembered = content.remembered {
                self.remembered.show(remembered, environment: environment)
            } else {
                rows.show(content.blocks, moreCount: content.moreCount, moreMark: content.moreMark, reservesCorner: content.corner != nil,
                          movesSessions: content.movesSessions, movesWindows: content.movesWindows, environment: environment,
                          fades: wasOpen)
            }
        }
        for view in [rows, remembered] as [any TopicCardBody] {
            let shows = content.header.isOpen && view === body
            view.alphaValue = shows ? 1 : 0
            view.isOpen = shows
        }
        fill.alphaValue = content.header.isOpen ? 1 : 0
        let moves = environment.pulses && !environment.reduceMotion
        spine.show(content.spine, colors: environment.agentColors, moves: moves)
        unread.show(content.unreadOverHeader ? .unread : nil, colors: environment.agentColors, moves: moves)
        // The card that holds the Location gives up its plain border for the coloured one.
        outline.isHidden = content.holdsSelection
        selection.isHidden = !content.holdsSelection
        dimmed.alphaValue = content.restingOpacity
        hint.show(content.header.hint, environment: environment)
        windowHints.show(content.header.isOpen && content.remembered == nil ? rows.windowRows : [], environment: environment)
        let views = [dimmed, tags] + hint.views + windowHints.views
        if card.subviews != views { card.subviews = views }
        corner.show(content.corner, environment: environment)
        corner.alphaValue = content.restingOpacity
        layOut()
        if came, !environment.reduceMotion { selection.turn() }
    }

    /// The card's height at `width`: its header, and under the header of an open card its rows, which a Topic card's
    /// end with the room of its action.
    override func height(width: CGFloat) -> CGFloat {
        header.height(width: width) + (isOpen ? CardRowsPadding.top + body.height(width: rowsWidth(width)) + CardRowsPadding.bottom : 0)
    }

    /// The Hints that show, the card's and those of its Window rows, by their identifiers, as SwiftUI lists them.
    private var hints: [NSView] {
        (hint.shown + windowHints.views).sorted { $0.accessibilityIdentifier() < $1.accessibilityIdentifier() }
    }

    private func rowsWidth(_ width: CGFloat) -> CGFloat { max(0, width - 2 * CardRowsPadding.horizontal) }

    /// Moves the header of an open card to where it sticks in the list's viewport while the card's rows scroll under it.
    /// `top` is the card's top edge in the viewport, and `inset` where the header sticks: 0 for the viewport's top.
    func stick(cardTop top: CGFloat, inset: CGFloat = 0) {
        guard top != viewportTop || inset != stickInset else { return }
        viewportTop = top
        stickInset = inset
        placeHeader()
        rows.placeMoved()
    }

    /// Puts the header at the top of the card, or as far down as it sticks, with the Unread spine over it and the
    /// card's Tags and Hint on it.
    private func placeHeader() {
        let height = header.height(width: bounds.width)
        let stuck = isOpen ? StuckHeader.offset(cardTop: viewportTop, cardHeight: bounds.height, headerHeight: height, inset: stickInset) : 0
        header.frame = NSRect(x: 0, y: stuck, width: bounds.width, height: height)
        header.sticks = stuck > 0
        unread.frame = NSRect(x: CardSpine.leading, y: stuck + CardSpine.verticalInset, width: CardSpine.width,
                              height: max(0, height - 2 * CardSpine.verticalInset))
        // The header keeps the places of the Tags, the word in the corner and the Hint, and the card draws them over it.
        tags.frame = header.tagsPlace(width: bounds.width)?.offsetBy(dx: 0, dy: stuck) ?? .zero
        cornerLabel.frame = header.cornerLabelPlace(width: bounds.width)?.offsetBy(dx: 0, dy: stuck) ?? .zero
        hint.place(header.hintPlace(width: bounds.width)?.offsetBy(dx: 0, dy: stuck))
    }

    override func layOutParts() {
        card.frame = bounds
        dimmed.frame = bounds
        fill.frame = bounds
        outline.frame = bounds
        selection.frame = bounds
        let headerHeight = header.height(width: bounds.width)
        let rowsWidth = rowsWidth(bounds.width)
        for view in [rows, remembered] as [any TopicCardBody] {
            view.frame = NSRect(x: CardRowsPadding.horizontal, y: headerHeight + CardRowsPadding.top, width: rowsWidth,
                                height: view.height(width: rowsWidth))
        }
        placeHeader()
        windowHints.place(in: card)
        spine.frame = NSRect(x: CardSpine.leading, y: CardSpine.verticalInset, width: CardSpine.width,
                             height: max(0, bounds.height - 2 * CardSpine.verticalInset))
        // In the bottom-right corner, at the same offsets whether the card is open or closed.
        let size = corner.size
        corner.frame = NSRect(x: bounds.width - CardCorner.trailing - size.width, y: bounds.height - CardCorner.bottom - size.height,
                              width: size.width, height: size.height)
    }

    // MARK: Accessibility

    /// The corner's link, then the card, as SwiftUI lists the overlay of the card's corner.
    override func accessibilityChildren() -> [Any]? { (corner.isHidden ? [] : [corner]) + [card] }
}

/// The card as one accessibility row: a group of its header and its Hint, though the Hint is no part of what rests at
/// the card's opacity. It holds the card's menu, which is also its named actions.
private final class TopicCardGroupView: NSView {
    /// The rows of the card: the rows of an open card, its header, its Tags, then the Hint.
    var rows: () -> [NSView] = { [] }
    /// The card's menu.
    var menuItems: () -> SidebarMenu? = { nil }
    /// The card's header, which VoiceOver reads first.
    weak var header: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { rows() }

    /// VoiceOver reads the header first, then the rows and the Hint, as SwiftUI's sort priority orders the header.
    override func accessibilityChildrenInNavigationOrder() -> [NSAccessibilityElementProtocol]? {
        let children = rows().compactMap { $0 as NSAccessibilityElementProtocol }
        return (header.map { [$0] } ?? []) + children.filter { $0 !== header }
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    /// A right-click anywhere on the card shows the card's menu: on the header, its Tags, the paddings and the gaps
    /// between the rows, which have no menu of their own and pass the click up to the card. A Session line and a Window
    /// row show their own menus. A Control-click shows the same menu (`SidebarPressView`).
    override func menu(for event: NSEvent) -> NSMenu? { menuItems()?.contextMenu() }

    /// The card's menu, as named actions: a check never opens a menu.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { menuItems()?.accessibilityActions }
}

/// The word in a card's top-right corner, such as how long ago a Topic was Settled, as SwiftUI's `cardCornerLabel`
/// shows it: in the secondary text colour, over the header, and a click goes through it to the header. To accessibility
/// it is one static text with the word as its value.
private final class CardCornerLabelView: NSView {
    private let label = SidebarLabel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.ink = .secondary
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Shows the word, or nothing for none.
    func show(_ content: CardCornerLabel?, environment: SidebarListEnvironment) {
        isHidden = content == nil
        label.text = content?.text ?? ""
        label.font = CardHeaderView.cornerLabelFont(environment)
        label.scale = environment.displayScale
        setAccessibilityIdentifier(content?.accessibilityID)
        setAccessibilityValue(content?.text)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        label.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func accessibilityChildren() -> [Any]? { [] }
}

/// The Topic's own action in its card's corner: a link in the text size of `CardCorner`, as SwiftUI's link button
/// draws it, and a link to accessibility. A disabled link does nothing.
private final class TopicCardCornerView: SidebarPressView {
    private let label = SidebarLabel()
    private var isEnabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the action, or nothing for none.
    func show(_ corner: TopicCardCorner?, environment: SidebarListEnvironment) {
        isHidden = corner == nil
        isEnabled = corner?.isEnabled ?? false
        label.text = corner?.title ?? ""
        label.font = .systemFont(ofSize: environment.fontSize(CardCorner.fontSize))
        label.ink = isEnabled ? .link : .disabledLink
        label.scale = environment.displayScale
        setAccessibilityIdentifier(corner?.identifier)
        setAccessibilityLabel(corner?.title)
        setAccessibilityEnabled(isEnabled)
    }

    /// The room the action's text takes.
    var size: NSSize { label.fit() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        label.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : super.hitTest(point) }

    override func pressUp(at point: NSPoint) {
        if isEnabled { super.pressUp(at: point) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        return super.accessibilityPerformPress()
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}
