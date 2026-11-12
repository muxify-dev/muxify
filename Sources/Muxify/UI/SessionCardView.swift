import AppKit
import MuxifyCore

/// What a Session card shows, as the Sessions list reads it from the models.
struct SessionCardContent: Equatable {
    var title: String
    /// The Summary, which a closed card shows under its title. Empty for none.
    var summary = ""
    var isOpen = false
    /// The card holds the Location's Window.
    var holdsSelection = false
    var mark: CardMark?
    var isLocked = false
    /// The Session is Locked and the Config sets In Play, so the Lock is a Guest.
    var isGuest = false
    /// A Window of the Session has a bell.
    var hasBell = false
    var hint: CardHint?
    /// The rows an open card lists, in tmux's order: `CardRows.shownCount` of its Window and Pane rows. A closed card
    /// has none.
    var rows: [CardRowContent] = []
    /// The rows an open card holds back, which its "N more…" counts. 0 for none.
    var moreCount = 0
    /// A drag on a Window row can move its Window: the store has not turned the drag off. A card with one Window row
    /// lifts none in any case.
    var movesWindows = true

    /// What the card's header shows: the Guest mark or the lock after the title, and the bell of a closed card.
    var header: CardHeaderContent {
        CardHeaderContent(title: title, summary: summary, isOpen: isOpen, mark: mark, isLocked: isLocked, isGuest: isGuest,
                          hasBell: hasBell, hint: hint, notes: isGuest ? ["Guest"] : isLocked ? ["Locked"] : [])
    }
}

extension SessionCardContent {
    /// What the card of the Session shows, read from the models as the SwiftUI Session card reads it: in the Sessions
    /// list, and as the No Topic card of the Topics list with `inTopicsList`. An open card lists `CardRows.shownCount`
    /// of its rows, or all of them with `showsAllRows`, in tmux's order.
    @MainActor init(_ session: SessionGroup, store: WorkspaceStore, hints: HintPresentation, showsAllRows: Bool, inTopicsList: Bool = false) {
        let model = store.topics
        let isOpen = store.openSessionCards.contains(session.name)
        let isLocked = model.lockedSessionIDs.contains(session.id)
        let formatted = store.sidebarText(.session, context: store.sidebarFormatContexts.sessions[session.id])
        let items = isOpen ? model.sessionChildren[session.id]?.items ?? [] : []
        let shown = CardRows.shownCount(items, selectedWindowID: store.selectedWindowID, showsAll: showsAllRows)
        self.init(title: formatted.title, summary: formatted.summary, isOpen: isOpen,
                  holdsSelection: SessionCardPress(store: store, session: session).holdsSelection,
                  mark: model.sessionMarks[session.id].map(CardMark.agent), isLocked: isLocked,
                  isGuest: isLocked && store.topicConfig.inPlay != nil, hasBell: session.windows.contains(where: \.hasBell),
                  hint: CardHint(.session(session.id), in: hints),
                  rows: items.prefix(shown).map { CardRowContent($0, store: store, inTopicsList: inTopicsList) },
                  moreCount: items.count - shown, movesWindows: store.windowRowDrag.isEnabled)
    }
}

/// A row of an open card: a Window row, or a Pane row under its Window row or in its place.
enum CardRowContent: Equatable {
    case window(WindowRowContent)
    case pane(PaneRowContent)

    /// What the row of the item shows, read from the models as the SwiftUI rows read them. `inTopicsList` gives a
    /// Window row the look of the Topics list.
    @MainActor init(_ item: TopicsModel.SessionChildren.Item, store: WorkspaceStore, inTopicsList: Bool = false) {
        switch item {
        case .window(let window):
            self = .window(WindowRowContent(
                window: window, formatted: store.sidebarWindowRow(window), isSelected: window.id == store.selectedWindowID,
                tabCount: store.tabCount(for: window), isGitViewOpen: store.isGitViewOpen(in: window.id),
                usesMainWorkingCopy: TopicsModel.usesMainWorkingCopy(
                    window, record: store.topicWatcher.records.first { $0.id == window.topicID }, sessionPaths: store.sessionPaths),
                tooltips: store.config.sidebar.windowTooltips, inTopicsList: inTopicsList))
        case .pane(let row):
            let mark = store.topics.agentMarks[row.pane.id]
            self = .pane(PaneRowContent(paneID: row.pane.id, text: store.sidebarText(.pane, context: store.sidebarFormatContexts.panes[row.pane.id]),
                                        isActive: row.pane.isActive, isUnderWindowRow: row.isUnderWindowRow,
                                        showsLocation: row.showsLocation(selectedWindowID: store.selectedWindowID), mark: mark,
                                        accessibilityValue: row.accessibilityValue(mark: mark), hoverDetail: row.hoverDetail,
                                        windowID: row.window.id))
        }
    }
}

/// The Hint of a card, in the place the header keeps for it after the title.
struct CardHint: Equatable {
    let target: QuickSwitchTarget
    /// The key that shows at rest. Empty when the card only keeps the place, for the Hint of a held modifier.
    let restKey: String
    /// The keys of the modifier the user holds, which the badge shows in place of the key at rest. Empty for none.
    let triggers: [KeyTrigger]

    /// Nil when the card has no Hint: its header then keeps no place for one.
    init?(_ target: QuickSwitchTarget, in hints: HintPresentation) {
        guard hints.restKey(for: target) != nil || !hints[target].isEmpty else { return nil }
        self.target = target
        restKey = hints.restKey(for: target) ?? ""
        triggers = hints[target]
    }

    /// The badge shows: the user holds the modifier of the Hint.
    var showsBadge: Bool { !triggers.isEmpty }
}

/// A Session card of the AppKit Sessions list (ADR 0074), and the No Topic card of the AppKit Topics list
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md). Closed, it is flat, with only its border;
/// open, it is raised, with its Window and Pane rows under its header, and "N more…" after them when it holds rows
/// back. A spine shows its mark, and the card that holds the Location's Window has the many-coloured border. It gives
/// the accessibility rows of the SwiftUI card: `card-<id>` for the card, its Window rows, its Pane rows and "N more…",
/// `<id>` for its header, and a row for each Hint: the card's and its Window rows'. `<id>` is `session-<Session ID>` in
/// the Sessions list and `no-topic-session-<Session ID>` in the Topics list.
final class SessionCardView: NSView {
    let sessionID: String
    /// A press on the header.
    var onPress: () -> Void = {} {
        didSet { header.onPress = onPress }
    }
    /// A click on a Window row.
    var onSelectWindow: (TmuxWindow) -> Void = { _ in }
    /// A drag on a Window row let go: the Window moves, with its Pane rows, before or after another Window.
    var onMoveWindow: (TmuxWindow, DropPlacement<String>) -> Void = { _, _ in }
    /// A press on a Pane row, with the Pane's ID.
    var onSelectPane: (String) -> Void = { _ in }
    /// A press on "N more…".
    var onShowAllRows: () -> Void = {} {
        didSet { more.onPress = onShowAllRows }
    }
    /// The card's context menu, which is also its named accessibility actions, as the Session is now.
    var menuItems: () -> SidebarMenu? = { nil }
    /// The named accessibility actions of the header, as the Session is now.
    var headerActions: () -> SidebarMenu? = { nil } {
        didSet { header.actions = headerActions }
    }
    /// The context menu of a Window row, as the list reads it for the Window.
    var windowMenu: (TmuxWindow) -> SidebarMenu? = { _ in nil }
    private let fill = CardFillView()
    private let header: CardHeaderView
    /// The rows of an open card. A card that closes keeps them, so they fade where they stand.
    private let rows = CardRowsView()
    /// The views of the Window and Pane rows.
    private let rowViews: CardRowViews
    /// The Window and Pane rows from the top, and "N more…" after them when it shows.
    private var listed: [CardRowView] = []
    /// The Window and Pane rows from the top in their units: each Window row with the Pane rows under it, which a drag
    /// moves as one, and each Pane row in place of the only Window row.
    private var units: [WindowUnitView] = []
    /// The place where a lifted unit would land.
    private let slot = DropSlotView()
    private lazy var drag = SessionCardDrag(card: self)
    private let more: MoreRowView
    private let spine = CardSpineView()
    private let outline = CardOutlineView()
    private let selection = CardSelectionBorderView()
    /// The card's Hint: its key at rest, or the badge while the user holds the Hint's modifier.
    private let hint = CardHintViews()
    /// The Hints of the Window rows of an open card, by Window ID.
    private var windowHints: [String: SidebarHintView] = [:]
    private var content: SessionCardContent?
    private var environment = SidebarListEnvironment()
    /// The card's top edge in the list's viewport. The header of an open card sticks to the viewport's top once the
    /// card's top has scrolled past it.
    private var viewportTop: CGFloat = 0

    /// `identifier` is the header's; nil for the Sessions list's `session-<Session ID>`. In the Topics list the Window
    /// rows are its own (`CardRowViews`).
    init(sessionID: String, identifier: String? = nil, inTopicsList: Bool = false) {
        self.sessionID = sessionID
        let identifier = identifier ?? "session-" + sessionID
        header = CardHeaderView(identifier: identifier)
        more = MoreRowView(identifier: identifier)
        rowViews = CardRowViews(inTopicsList: inTopicsList)
        super.init(frame: .zero)
        wantsLayer = true
        // The SwiftUI card cuts nothing off.
        clipsToBounds = false
        // From the back: the fill, the rows, the header, which stays above the rows that scroll under it, the spine,
        // the border and the Hints.
        subviews = chrome
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("card-" + identifier)
        rowViews.onSelectWindow = { [weak self] in self?.onSelectWindow($0) }
        rowViews.onSelectPane = { [weak self] in self?.onSelectPane($0) }
        rowViews.windowMenu = { [weak self] in self?.windowMenu($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The card's views from the back, without the Hints of its Window rows, which come after them.
    private var chrome: [NSView] { [fill, rows, header, spine, outline, selection] + hint.views }

    var isOpen: Bool { content?.isOpen ?? false }

    /// Shows the content. The colours of the border turn once when the Location comes to a card that already showed.
    func show(_ content: SessionCardContent, environment: SidebarListEnvironment) {
        guard content != self.content || environment != self.environment else { return }
        let came = self.content.map { !$0.holdsSelection && content.holdsSelection } ?? false
        let wasOpen = isOpen
        self.content = content
        self.environment = environment
        header.show(content.header, environment: environment)
        if content.isOpen {
            showRows(content.rows, more: content.moreCount, fades: wasOpen)
            drag.show(windowUnits.map(\.id))
        } else {
            drag.abandon()
        }
        fill.alphaValue = content.isOpen ? 1 : 0
        rows.alphaValue = content.isOpen ? 1 : 0
        rows.isOpen = content.isOpen
        spine.show(content.mark, colors: environment.agentColors, moves: environment.pulses && !environment.reduceMotion)
        // The card that holds the Location's Window gives up its plain border for the coloured one.
        outline.isHidden = content.holdsSelection
        selection.isHidden = !content.holdsSelection
        hint.show(content.hint, environment: environment)
        showWindowHints()
        layOut()
        if came, !environment.reduceMotion { selection.turn() }
    }

    /// Shows a row for each Window and Pane, from the top, and "N more…" after them for `more` rows held back. A row
    /// that already showed keeps its view, so its tint fades when the Location moves, unless `fades` is false.
    private func showRows(_ contents: [CardRowContent], more count: Int, fades: Bool) {
        listed = rowViews.show(contents, environment: environment, fades: fades)
        units = units(of: zip(contents, listed).map { ($0, $1) })
        for unit in units { unit.theme = environment.chromeTheme }
        let moves = movesWindows
        for case let row as WindowRowView in listed {
            row.drag = drag
            row.isDraggable = moves
        }
        let views = [slot] + units + (count > 0 ? [more] : [])
        if count > 0 {
            more.show(count: count, environment: environment)
            listed.append(more)
        }
        if rows.subviews != views { rows.subviews = views }
    }

    /// The rows in their units, as `WindowUnit` groups them in the SwiftUI list. A unit that already showed keeps its
    /// view, so a lifted unit keeps the row the pointer presses.
    private func units(of rows: [(content: CardRowContent, view: CardRowView)]) -> [WindowUnitView] {
        var kept = Dictionary(units.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [(id: String, window: TmuxWindow?, rows: [CardRowView])] = []
        for (content, view) in rows {
            switch content {
            case .window(let content):
                grouped.append((content.window.id, content.window, [view]))
            case .pane(let content) where content.isUnderWindowRow && grouped.last?.window?.id == content.windowID:
                grouped[grouped.count - 1].rows.append(view)
            case .pane(let content):
                grouped.append((content.paneID, nil, [view]))
            }
        }
        return grouped.map { group in
            let unit = kept.removeValue(forKey: group.id) ?? WindowUnitView(id: group.id)
            unit.tmuxWindow = group.window
            unit.rows = group.rows
            return unit
        }
    }

    /// Shows the Hint of each Window row of an open card: the badge while the user holds its modifier, else its key at
    /// rest when the Config shows Window Hints at all times. A closed card shows none.
    private func showWindowHints() {
        var kept = windowHints
        windowHints = [:]
        if isOpen {
            for case let row as WindowRowView in listed {
                let target = QuickSwitchTarget.window(row.windowID)
                let look: SidebarHintView.Look
                if !environment.hints[target].isEmpty { look = .badge(environment.hints[target]) }
                else if let key = environment.hints.restKey(for: target) { look = .key(key) }
                else { continue }
                let view = kept.removeValue(forKey: row.windowID) ?? SidebarHintView()
                view.show(look, target: target, fontSize: environment.fontSize, scale: environment.displayScale)
                windowHints[row.windowID] = view
            }
        }
        let views = chrome + windowHints.keys.sorted().compactMap { windowHints[$0] }
        if subviews != views { subviews = views }
    }

    /// The card's height at `width`: its header, and under the header of an open card its rows.
    func height(width: CGFloat) -> CGFloat {
        header.height(width: width) + (isOpen ? CardRowsPadding.top + rowsHeight(width: width) + CardRowsPadding.bottom : 0)
    }

    /// The height of the rows in a card `width` wide, with `CardSpacing.row` between two rows.
    private func rowsHeight(width: CGFloat) -> CGFloat {
        let rowWidth = max(0, width - 2 * CardRowsPadding.horizontal)
        return listed.map { $0.height(width: rowWidth) }.reduce(0, +) + CardSpacing.row * CGFloat(max(0, listed.count - 1))
    }

    /// The width of the rows.
    var rowsWidth: CGFloat { max(0, bounds.width - 2 * CardRowsPadding.horizontal) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Moves the header of an open card to the top of the list's viewport while the card's rows scroll under it.
    /// `top` is the card's top edge in the viewport.
    func stick(cardTop top: CGFloat) {
        guard top != viewportTop else { return }
        viewportTop = top
        placeHeader()
        drag.placeMoved()
    }

    /// Puts the header at the top of the card, or as far down as it sticks, and the card's Hint on it.
    private func placeHeader() {
        let height = header.height(width: bounds.width)
        let stuck = isOpen ? StuckHeader.offset(cardTop: viewportTop, cardHeight: bounds.height, headerHeight: height) : 0
        header.frame = NSRect(x: 0, y: stuck, width: bounds.width, height: height)
        header.sticks = stuck > 0
        // The header keeps the Hint's place, and the card draws the Hint over it.
        hint.place(header.hintPlace(width: bounds.width)?.offsetBy(dx: 0, dy: stuck))
    }

    private func layOut() {
        fill.frame = bounds
        outline.frame = bounds
        selection.frame = bounds
        placeHeader()
        rows.frame = NSRect(x: CardRowsPadding.horizontal, y: header.height(width: bounds.width) + CardRowsPadding.top,
                            width: rowsWidth, height: rowsHeight(width: bounds.width))
        layOutRows()
        spine.frame = NSRect(x: CardSpine.leading, y: CardSpine.verticalInset, width: CardSpine.width,
                             height: max(0, bounds.height - 2 * CardSpine.verticalInset))
    }

    /// Stacks the units from the top of the rows, each moved by the drag's offset, then "N more…", and puts the
    /// Hints on their Window rows and the placeholder where the lifted unit would land.
    private func layOutRows() {
        let width = rows.bounds.width
        var top: CGFloat = 0
        for unit in units {
            unit.place = top
            unit.frame = NSRect(x: 0, y: top + drag.offset(of: unit.id), width: width, height: unit.height(width: width))
            unit.layOut()
            // Above the others while it is lifted and while it glides to where it lands, and above the placeholder.
            unit.layer?.zPosition = drag.draggedID == unit.id ? 2 : 0
            top += unit.frame.height + CardSpacing.row
        }
        if listed.last === more { more.frame = NSRect(x: 0, y: top, width: width, height: more.height(width: width)) }
        placeSlot()
        units.forEach(placeHints(of:))
    }

    /// A Window row's Hint stands in the room the row keeps before its icon, from the row's top left corner.
    private func placeHints(of unit: WindowUnitView) {
        for case let row as WindowRowView in unit.rows {
            guard let view = windowHints[row.windowID] else { continue }
            let corner = row.convert(NSPoint.zero, to: self)
            view.frame = NSRect(origin: NSPoint(x: corner.x + WindowHintMetrics.inset, y: corner.y + WindowHintMetrics.inset), size: view.size)
        }
    }

    private func placeSlot() {
        slot.layer?.zPosition = 1
        guard let id = drag.liftedID, let offset = drag.slotOffset, let unit = unit(id) else { return }
        slot.frame = NSRect(x: 0, y: unit.place + offset, width: unit.bounds.width, height: unit.bounds.height)
    }

    // MARK: The drag

    /// The units of Window rows, from the top.
    var windowUnits: [WindowUnitView] { units.filter { $0.tmuxWindow != nil } }

    func unit(_ id: String) -> WindowUnitView? { units.first { $0.id == id } }

    /// A press that moves on a Window row lifts it: the store has not turned the drag off, and the card has more than
    /// one Window row.
    var movesWindows: Bool { (content?.movesWindows ?? false) && windowUnits.count > 1 }

    var reducesMotion: Bool { environment.reduceMotion }

    func showLook(_ look: WindowUnitView.Look, of id: String, motion: LayerMotion) {
        unit(id)?.show(look, reducesMotion: environment.reduceMotion, motion: motion)
    }

    /// How far the unit's top stands below the visible top of the list, or below the bottom of the card's header that
    /// sticks there, and its bottom above the visible bottom, without the drag's offset. Nil outside a list.
    func visiblePlace(of unit: WindowUnitView) -> (visibleTop: CGFloat, footroom: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView else { return nil }
        let frame = rows.convert(NSRect(x: 0, y: unit.place, width: unit.bounds.width, height: unit.bounds.height), to: clip)
        // A unit dragged up stops at the bottom of the header that sticks to the top, not under it.
        let top = header.sticks ? convert(header.frame, to: clip).maxY : clip.bounds.minY
        return (frame.minY - top, clip.bounds.maxY - frame.maxY)
    }

    /// Puts the units at their places and the drag's offsets. With `motion`, the units that move glide there, with
    /// their Hints and the placeholder; the lifted unit and its Hints follow the pointer at once.
    func placeUnits(motion: LayerMotion?) {
        let appears = drag.liftedID != nil && !slot.shows
        LayerGlide.withoutActions {
            if let id = drag.liftedID, let unit = unit(id) {
                unit.setFrameOrigin(NSPoint(x: 0, y: unit.place + drag.offset(of: id)))
                placeHints(of: unit)
            }
            if appears { placeSlot() }
        }
        if let motion, let layer {
            LayerGlide.run(under: layer, motion: motion, change: layOutRows)
        } else {
            LayerGlide.withoutActions(layOutRows)
        }
        slot.show(drag.liftedID != nil, motion: appears ? ListLift.lift.motion : motion)
    }

    func moveWindow(_ id: String, _ placement: DropPlacement<String>) {
        guard let window = unit(id)?.tmuxWindow else { return }
        onMoveWindow(window, placement)
    }

    // MARK: The menu

    /// A right-click anywhere on the card shows the card's menu: on the header, the paddings and the gaps between the
    /// rows, which have no menu of their own and pass the click up to the card. A Window row shows its own menu. A
    /// Control-click shows the same menu: AppKit asks the view under it for a menu, and a header or a row with none
    /// passes the click up as a right-click (`SidebarPressView`).
    override func menu(for event: NSEvent) -> NSMenu? { menuItems()?.contextMenu() }

    // MARK: Accessibility

    /// The card's menu, as named actions: a check never opens a menu.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { menuItems()?.accessibilityActions }

    /// The rows of an open card, each Window row by its parts, then the header and the Hints, each a row of its own
    /// because the header hides its children. SwiftUI lists the header after the rows, which it draws above them, and
    /// the Hints by their identifiers.
    override func accessibilityChildren() -> [Any]? {
        let hints = (hint.views + Array(windowHints.values)).filter { !$0.isHidden }
            .sorted { $0.accessibilityIdentifier() < $1.accessibilityIdentifier() }
        return (isOpen ? listed.flatMap(\.accessibilityParts) : []) + [header] + hints
    }

    /// VoiceOver reads the header first, then the rows and the Hint, as SwiftUI's sort priority orders the header.
    override func accessibilityChildrenInNavigationOrder() -> [NSAccessibilityElementProtocol]? {
        let children = (accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElementProtocol }
        return [header] + children.filter { $0 !== header }
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

extension NSRect {
    var centre: NSPoint { NSPoint(x: midX, y: midY) }
}

/// The rows of a card. A closed card's rows take no click and no pointer. The view takes no click of its own: a click
/// between two rows goes to the card, so a Control-click there opens the card's menu, as a right-click does.
private final class CardRowsView: NSView {
    var isOpen = false {
        didSet {
            for case let unit as WindowUnitView in subviews {
                for case let row as SidebarRowView in unit.rows.map({ $0 as NSView }) { row.isShown = isOpen }
            }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isOpen else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A card's key at rest, on a faint capsule of the text colour: `CardRestKey` in SwiftUI. It is a row of its own to
/// accessibility, with the identifier of its target and the key as its value.
final class CardRestKeyView: NSView {
    private var layout: SidebarTextLayout?
    private var scale: CGFloat = 2

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func font(_ fontSize: InterfaceFontSize) -> NSFont {
        let font = NSFont.systemFont(ofSize: fontSize(CardRestKeyMetrics.fontSize), weight: .semibold)
        return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
    }

    private static func layout(_ key: String, fontSize: InterfaceFontSize, scale: CGFloat) -> SidebarTextLayout {
        SidebarTextLayout(key, font: font(fontSize), scale: scale)
    }

    /// The room the key takes: the key with its padding, and not less than the capsule's least side.
    static func size(key: String, fontSize: InterfaceFontSize, scale: CGFloat) -> NSSize {
        let text = layout(key, fontSize: fontSize, scale: scale).size
        let side = fontSize(CardRestKeyMetrics.minSide)
        return NSSize(width: max(side, (key.isEmpty ? 0 : text.width) + 2 * CardRestKeyMetrics.horizontalPadding),
                      height: max(side, key.isEmpty ? 0 : text.height))
    }

    /// Shows the key of the Hint at rest, or nothing when the card has no key at rest.
    func show(_ hint: CardHint?, fontSize: InterfaceFontSize, scale: CGFloat) {
        let key = hint?.restKey ?? ""
        isHidden = key.isEmpty
        layout = key.isEmpty ? nil : Self.layout(key, fontSize: fontSize, scale: scale)
        self.scale = scale
        setAccessibilityElement(!key.isEmpty)
        setAccessibilityIdentifier(hint?.target.accessibilityID)
        setAccessibilityValue(key)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout else { return }
        NSColor.labelColor.faded(CardRestKeyMetrics.fillOpacity).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        layout.draw(at: NSPoint(x: ((bounds.width - layout.size.width) / 2).rounded(toPixelsOf: scale),
                                y: ((bounds.height - layout.size.height) / 2).rounded(toPixelsOf: scale)),
                    ink: NSColor.labelColor.faded(CardRestKeyMetrics.textOpacity))
    }
}
