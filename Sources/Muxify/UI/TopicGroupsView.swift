import AppKit
import MuxifyCore

/// The groups under the AppKit Topics list (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): the
/// Settled group, as `TopicGroupBlock` draws it in SwiftUI, one block under the other `TopicGroupMetrics.spacing` apart.
/// The Topics list puts them at its bottom and gives the room left above them to its cards.
///
/// While a group is open, the ages of its Settled cards are seen from the moment the list drew them, and the list draws
/// them again at the next midnight (`SettledAge.nextMidnight`), when the ages change, as SwiftUI's `TimelineView` does.
///
/// To accessibility it is one container, `topic-groups`, of each group's header and the scroll view of its cards.
final class TopicGroupsView: NSView {
    private let store: WorkspaceStore
    /// The blocks that show, in the order of the groups.
    private var blocks: [TopicGroupBlockView] = []
    /// The most height of an open group's cards before they scroll.
    var cardsLimit: CGFloat = 0 {
        didSet {
            if cardsLimit != oldValue { layOut() }
        }
    }
    /// Midnight came while a group was open: the ages of its Settled cards change.
    var onMidnight: () -> Void = {}
    private var midnight: Timer?

    init(store: WorkspaceStore) {
        self.store = store
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier(TopicGroupMetrics.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// Shows the groups, with the ages of the Settled cards seen from `now`.
    func show(_ groups: [TopicsModel.Group], activeTopic: TopicGroupID?, environment: SidebarListEnvironment, now: Date) {
        let kept = Dictionary(blocks.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        blocks = groups.map { group in
            let block = kept[group.kind] ?? TopicGroupBlockView(store: store, kind: group.kind)
            block.show(group, activeTopic: activeTopic, environment: environment, now: now)
            return block
        }
        if subviews != blocks { subviews = blocks }
        waitForMidnight(after: now, while: groups.contains(where: \.isExpanded))
        layOut()
    }

    /// The height of the groups, one under the other, `width` wide.
    func height(width: CGFloat) -> CGFloat {
        let heights = blocks.map { $0.height(width: width, cardsLimit: cardsLimit) }
        return heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * TopicGroupMetrics.spacing
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        var top: CGFloat = 0
        for block in blocks {
            let height = block.height(width: bounds.width, cardsLimit: cardsLimit)
            block.frame = NSRect(x: 0, y: top, width: bounds.width, height: height)
            top += height + TopicGroupMetrics.spacing
        }
    }

    /// Draws the cards again at the next midnight after `now`, while a group is open.
    private func waitForMidnight(after now: Date, while isOpen: Bool) {
        let next = isOpen ? SettledAge.nextMidnight(after: now, calendar: .autoupdatingCurrent) : nil
        guard midnight?.fireDate != next else { return }
        midnight?.invalidate()
        midnight = next.map { date in
            let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.midnight = nil
                    self?.onMidnight()
                }
            }
            // Also while the user scrolls or holds a menu open.
            RunLoop.main.add(timer, forMode: .common)
            return timer
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            midnight?.invalidate()
            midnight = nil
        }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { blocks.flatMap(\.accessibilityParts) }
}

/// One group under the Topics list, as `TopicGroupBlock` draws it in SwiftUI: its header, a button that opens and closes
/// the group, and while it is open a divider and its cards in a scroll view of their own, as high as the cards up to
/// `cardsLimit`, ending with "Show N more" while Settled Topics follow the pages it shows. A rounded border in the
/// separator colour goes around it. The header offers the group's action, Forget Settled Older Than…, as its menu and
/// its named action.
///
/// A card in the group is a `TopicCardView` as the SwiftUI group's `TopicCard` shows it: a Settled card has Reopen in
/// its corner, how long ago it was Settled in its top-right corner, rests dimmer while it is closed, and lists its
/// remembered Sessions while it is open. Its header sticks to the top of the group while its rows scroll under it.
private final class TopicGroupBlockView: NSView {
    let kind: TopicGroup
    private let store: WorkspaceStore
    private let header = TopicGroupHeaderView()
    private let divider = CardBlockDividerView()
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    private let showMore = TopicGroupShowMoreView()
    private let outline = TopicGroupOutlineView()
    private var cards: [TopicCardView] = []
    private var isExpanded = false
    private var showsMore = false
    private var environment = SidebarListEnvironment()

    init(store: WorkspaceStore, kind: TopicGroup) {
        self.store = store
        self.kind = kind
        super.init(frame: .zero)
        header.setAccessibilityIdentifier(kind.accessibilityID)
        header.onPress = { [store] in store.topicGroups.toggle(kind) }
        header.menuItems = { [weak self] in self?.actions }
        showMore.onPress = { [weak self] in self?.store.topicGroups.showMoreSettled() }
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidMove), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        subviews = [header, divider, scrollView, outline]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The group's action: Forget Settled Older Than…, off while a Topic change runs and in a Remote Environment.
    private var actions: SidebarMenu {
        SidebarMenu([[SidebarMenuItem(title: PaletteCommand.forgetSettledOlderThan.rawValue,
                                      isEnabled: !store.changingTopic && !store.isRemote,
                                      perform: { [store] in store.presentForgetSettled() })]])
    }

    /// Shows the group: its header, and while it is open its cards, with the ages of the Settled ones seen from `now`.
    /// When a card that already showed opens or closes, the cards glide to their new places with ease-out over
    /// `CardMotion.openDuration`, as the SwiftUI group animates them.
    func show(_ group: TopicsModel.Group, activeTopic: TopicGroupID?, environment: SidebarListEnvironment, now: Date) {
        self.environment = environment
        isExpanded = group.isExpanded
        header.show(group, environment: environment)
        divider.isHidden = !isExpanded
        scrollView.isHidden = !isExpanded
        guard isExpanded else {
            cards = []
            document.subviews = []
            return
        }
        var kept = Dictionary(cards.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })
        var opens = false
        let shown = group.topics.map { row -> (card: TopicCardView, content: TopicCardContent) in
            let content = content(of: row, activeTopic: activeTopic, now: now)
            let card = kept.removeValue(forKey: row.id) ?? card(of: row.id)
            opens = opens || (card.superview != nil && card.isOpen != content.header.isOpen)
            return (card, content)
        }
        showsMore = group.hiddenCount > 0
        if showsMore { showMore.show(TopicGroupMetrics.ShowMore.text(hiddenCount: group.hiddenCount), environment: environment) }
        let change = { [self] in
            for (card, content) in shown { card.show(content, environment: environment) }
            cards = shown.map(\.card)
            let views: [NSView] = cards + (showsMore ? [showMore] : [])
            if document.subviews != views { document.subviews = views }
            layOutCards()
        }
        if opens, let layer = document.layer {
            LayerGlide.run(under: layer, duration: CardMotion.openDuration, timing: CAMediaTimingFunction(name: .easeOut), change: change)
        } else {
            change()
        }
    }

    private func card(of id: TopicGroupID) -> TopicCardView {
        let card = TopicCardView(cardID: id)
        card.onPress = { [weak self] in self?.press(id) }
        card.onCorner = { [weak self] in
            if case .topic(let topicID) = id { self?.store.reopenTopic(topicID, .reopen) }
        }
        return card
    }

    /// A press on the header of a card in the group, as the card is now: on another Topic's card it goes to the Topic,
    /// which shows a Settled Topic's Reopen choice, and opens the card.
    private func press(_ id: TopicGroupID) {
        let model = store.topics
        guard let row = model.groups.lazy.flatMap(\.topics).first(where: { $0.id == id }) else { return }
        TopicCardPress(store: store, id: id, holdsSelection: id == model.activeTopic, isOpen: row.isExpanded)()
    }

    /// What a card in the group shows, as the SwiftUI group's `TopicCard` reads it: the title from the Topic card Formats
    /// with no Summary, no Hint, the outcome first in the details line of an open card, its Tags only while it is open,
    /// Reopen in the corner of a Settled card with the room of `CardCorner.designGroupWidth`, and how long ago it was
    /// Settled, seen from `now`.
    private func content(of row: TopicsModel.Row, activeTopic: TopicGroupID?, now: Date) -> TopicCardContent {
        let text = store.sidebarText(.topic, context: store.sidebarFormatContexts.topics[row.id])
        let topicID: String? = if case .topic(let id) = row.id { id } else { nil }
        var age: CardCornerLabel?
        var corner: TopicCardCorner?
        var remembered: [RememberedSessionContent]?
        if case .settled(_, let settledDate) = row.kind, let topicID {
            age = settledDate.map {
                CardCornerLabel(text: SettledAge.label(settled: $0, now: now, calendar: .autoupdatingCurrent), accessibilityID: "settled-age-" + topicID)
            }
            corner = TopicCardCorner(title: "Reopen", identifier: "reopen-topic-" + topicID, isEnabled: !store.changingTopic)
            remembered = rememberedSessions(of: row)
        }
        let header = CardHeaderContent(title: text.title, isOpen: row.isExpanded, mark: row.mark, isPinned: row.isPinned, isGuest: row.isGuest,
                                       details: TopicCardWords.details(of: row, inList: false), note: row.note,
                                       tags: row.isExpanded ? store.cardTags(row) : nil, notes: TopicCardWords.notes(of: row),
                                       cornerWidth: CardCorner.designGroupWidth, cornerLabel: age)
        return TopicCardContent(header: header, holdsSelection: row.id == activeTopic, spine: row.usesRowMarks ? nil : row.mark,
                                unreadOverHeader: row.usesRowMarks && row.isUnread,
                                restingOpacity: TopicCardOpacity.resting(row, inList: false), corner: corner, remembered: remembered)
    }

    /// The Sessions that a Settled card remembers, with the folder of each Window for its hover label.
    private func rememberedSessions(of row: TopicsModel.Row) -> [RememberedSessionContent] {
        let tooltips = store.config.sidebar.windowTooltips
        return row.sessions.compactMap { session in
            guard case .remembered(let windows) = session.contents else { return nil }
            return RememberedSessionContent(sessionID: session.id.session, line: session.baseName, windows: windows.map {
                RememberedRowContent(windowID: $0.id, name: $0.name, folder: Paths.tildify($0.directory), tooltips: tooltips)
            })
        }
    }

    /// The height of the group `width` wide: its header, and while it is open the divider and its cards up to the limit.
    func height(width: CGFloat, cardsLimit: CGFloat) -> CGFloat {
        header.height + (isExpanded ? TopicGroupMetrics.dividerWidth + scrollHeight(width: width, cardsLimit: cardsLimit) : 0)
    }

    /// As high as the cards, up to the limit, in whole pixels.
    private func scrollHeight(width: CGFloat, cardsLimit: CGFloat) -> CGFloat {
        min(placeCards(width: width, placing: false), cardsLimit).rounded(toPixelsOf: environment.displayScale)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: header.height)
        divider.frame = NSRect(x: 0, y: header.height, width: bounds.width, height: TopicGroupMetrics.dividerWidth)
        scrollView.frame = NSRect(x: 0, y: divider.frame.maxY, width: bounds.width, height: max(0, bounds.height - divider.frame.maxY))
        outline.frame = bounds
        layOutCards()
    }

    private func layOutCards() {
        let height = placeCards(width: bounds.width, placing: true)
        // The clip view keeps its offset when the content changes height, inside the new scroll range.
        document.setFrameSize(NSSize(width: bounds.width, height: height))
        stick()
    }

    /// Stacks the cards from the top, `TopicGroupMetrics.cardSpacing` apart, then "Show N more" in its line, all inside
    /// the room of `TopicGroupMetrics.cardsPadding`. Returns the height; with `placing`, it also puts the views there.
    private func placeCards(width: CGFloat, placing: Bool) -> CGFloat {
        let padding = TopicGroupMetrics.cardsPadding
        let cardWidth = max(0, width - 2 * padding)
        var top = padding
        for (index, card) in cards.enumerated() {
            if index > 0 { top += TopicGroupMetrics.cardSpacing }
            let height = card.height(width: cardWidth)
            if placing { card.frame = NSRect(x: padding, y: top, width: cardWidth, height: height) }
            top += height
        }
        if showsMore {
            if !cards.isEmpty { top += TopicGroupMetrics.cardSpacing }
            let line = environment.fontSize(TopicGroupMetrics.ShowMore.designHeight)
            if placing {
                let size = showMore.size
                showMore.frame = NSRect(x: padding + TopicGroupMetrics.ShowMore.leading,
                                        y: (top + (line - size.height) / 2).rounded(toPixelsOf: environment.displayScale),
                                        width: size.width, height: size.height)
            }
            top += line
        }
        return top + padding
    }

    @objc private func clipDidMove() {
        stick()
    }

    /// Gives each card its top edge in the group's viewport, so the header of an open card sticks to its top.
    private func stick() {
        let offset = scrollView.contentView.bounds.minY
        for card in cards { card.stick(cardTop: card.frame.minY - offset) }
    }

    /// The header, then while the group is open the scroll view of its cards.
    var accessibilityParts: [NSView] { [header] + (isExpanded ? [scrollView] : []) }
}

/// The header of a group under the Topics list, as `GroupHeader` draws it in SwiftUI: a chevron in its box, the group's
/// symbol and its title with its count, such as "Settled (17)", in the secondary text colour, each with its middle on
/// the header's middle. A press on it opens or closes the group. To accessibility it is one button named by its title,
/// with the value `expanded` or `collapsed`, whose named actions are the items of its menu.
private final class TopicGroupHeaderView: SidebarPressView {
    private let title = SidebarLabel()
    private var symbol: SidebarSymbol?
    /// The chevron, which comes again when its symbol changes.
    private var chevron: SidebarSymbol?
    private var isExpanded = false
    private var environment = SidebarListEnvironment()
    /// The header's menu.
    var menuItems: () -> SidebarMenu? = { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.ink = .secondary
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ group: TopicsModel.Group, environment: SidebarListEnvironment) {
        self.environment = environment
        isExpanded = group.isExpanded
        let size = environment.fontSize, scale = environment.displayScale
        chevron = replaced(chevron, by: TopicGroupMetrics.Header.chevron(isExpanded: group.isExpanded))
        chevron?.pointSize = size(TopicGroupMetrics.Header.chevronFontSize)
        chevron?.weight = .bold
        symbol = replaced(symbol, by: TopicGroupMetrics.symbol(group.kind))
        symbol?.pointSize = size(TopicGroupMetrics.Header.symbolFontSize)
        for part in [chevron, symbol] { part?.scale = scale }
        title.text = TopicGroupMetrics.Header.title(group.kind, count: group.count)
        title.font = .systemFont(ofSize: size(TopicGroupMetrics.Header.fontSize), weight: .semibold)
        title.scale = scale
        setAccessibilityLabel(title.text)
        setAccessibilityValue(group.isExpanded ? "expanded" : "collapsed")
        layOut()
    }

    /// The symbol view, kept while it shows `name`, or a new one in its place.
    private func replaced(_ view: SidebarSymbol?, by name: String) -> SidebarSymbol {
        if let view, view.name == name { return view }
        view?.removeFromSuperview()
        let symbol = SidebarSymbol(name)
        addSubview(symbol)
        return symbol
    }

    var height: CGFloat { environment.fontSize(TopicGroupMetrics.Header.designHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Lays the header out as SwiftUI lays out its `HStack`: the chevron in the middle of its box, the symbol, then the
    /// title in the room that the space after it leaves.
    private func layOut() {
        let scale = environment.displayScale
        let spacing = TopicGroupMetrics.Header.spacing
        let box = environment.fontSize(TopicGroupMetrics.Header.designChevronWidth)
        func middled(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(x: x.rounded(toPixelsOf: scale), y: ((bounds.height - size.height) / 2).rounded(toPixelsOf: scale),
                   width: size.width, height: size.height)
        }
        var x = TopicGroupMetrics.Header.horizontalPadding
        if let chevron { chevron.frame = middled(chevron.symbolSize, x: x + (box - chevron.symbolSize.width) / 2) }
        x += box + spacing
        let symbolSize = symbol?.symbolSize ?? .zero
        symbol?.frame = middled(symbolSize, x: x)
        x += symbolSize.width + spacing
        let room = bounds.width - x - spacing - TopicGroupMetrics.Header.endGap - TopicGroupMetrics.Header.horizontalPadding
        title.frame = middled(title.fit(width: max(0, room)), x: x)
    }

    /// A right-click, or a Control-click, shows the header's menu.
    override func menu(for event: NSEvent) -> NSMenu? { menuItems()?.contextMenu() }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { menuItems()?.accessibilityActions }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

/// "Show N more" after the shown pages of the Settled group: its words in the secondary text colour, as SwiftUI's plain
/// button draws them. A press shows the next page. To accessibility it is one button named by its words, as large as
/// they are.
private final class TopicGroupShowMoreView: SidebarPressView {
    private let label = SidebarLabel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.ink = .secondary
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(TopicGroupMetrics.ShowMore.identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String, environment: SidebarListEnvironment) {
        label.text = text
        label.font = .systemFont(ofSize: environment.fontSize(TopicGroupMetrics.ShowMore.fontSize))
        label.scale = environment.displayScale
        setAccessibilityLabel(text)
    }

    /// The room the words take.
    var size: NSSize { label.fit() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        label.frame = bounds
    }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

/// The rounded border around a group under the Topics list: the separator colour in a ring of
/// `TopicGroupMetrics.borderWidth` inside the group's rounded shape, as SwiftUI's `strokeBorder` draws it.
private final class TopicGroupOutlineView: LayerColoredView {
    private let ring = CardRing(width: TopicGroupMetrics.borderWidth, cornerRadius: TopicGroupMetrics.cornerRadius)

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.mask = ring
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions { ring.frame = bounds }
    }

    override func colorLayers() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
