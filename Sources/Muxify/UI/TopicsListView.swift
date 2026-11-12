import AppKit
import MuxifyCore

/// The two versions of the Sidebar's Topics list while the list moves from SwiftUI to AppKit
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).
enum TopicsListVersion: String {
    case swiftui, appkit

    /// The user default that chooses the version: true is the AppKit list; missing or false is the SwiftUI list. It is
    /// not a Config key, because it goes away with the SwiftUI list.
    static let defaultsKey = "topicsListAppKit"

    #if DEBUG
    /// The version in the App Window, for the verify driver: the AppKit list when the window holds one, also as the
    /// Sidebar page that does not show.
    static func shown(in window: NSWindow) -> TopicsListVersion {
        func holdsList(_ view: NSView?) -> Bool {
            guard let view else { return false }
            return view is TopicsListView || view.subviews.contains(where: holdsList)
        }
        return holdsList(window.contentView) ? .appkit : .swiftui
    }
    #endif
}

/// The Sidebar's Topics list in AppKit (ADR 0075): a scroll view with an item for each item of the Topics model's list,
/// in its order: the Topic cards and Locked cards, the Open Places, the Guests line, the Bench line and the No Topic
/// card, with the gaps and insets of the SwiftUI list. Its views lay out by frames, and it reads the store through
/// `ObservedUpdate`. The header of an open card sticks to the top while the card's rows scroll under it. Under the
/// scroll view stand the groups, the Settled group (`TopicGroupsView`), with the room around them of the SwiftUI
/// Sidebar's; an open group's cards scroll on their own, up to `TopicGroupMetrics.cardsShare` of the list's height.
///
/// With a Bench line, the items above the Bench (`TopicsModel.listParts`) are a block that sticks to the top on the
/// chrome's background while the Benched cards scroll under it, and the header of an open Benched card sticks under the
/// block, as `BenchGeometry` places them. When the Bench shows, the list moves its clip view so that the card of the
/// Location stays where it stood (`BenchedLocationPlace`).
///
/// The "N more below" pill over the bottom of the list, and with a Bench line the "N more above" pill over the top of
/// the Bench area, count the cards past their edges, as `TopicsListScroll` counts them from each card's `EdgePlace`. A
/// press on a pill, and a Jump To a Benched card out of view, glides the list's clip view to the card
/// (`TopicsListScroll.revealOffset`), which then comes to rest.
final class TopicsListView: NSView, SidebarList {
    private let store: WorkspaceStore
    /// The values from the SwiftUI Sidebar. The list draws again when one changes.
    var environment: SidebarListEnvironment {
        didSet {
            if environment != oldValue { update.run() }
        }
    }
    private let scrollView = NSScrollView()
    private let document = TopicsListDocumentView()
    /// The items of the list, in its order.
    private var items: [NSView] = []
    /// The frames of the items at rest, before the block sticks, in the document.
    private var places: [NSRect] = []
    /// How many of the items are the block that sticks; nil without a Bench line, when no item sticks.
    private var blockCount: Int?
    /// The chrome's background behind the block, over the Benched cards that scroll under it.
    private let backdrop = TopicsBlockBackdropView()
    /// Where the block and the Bench stand, from the last layout.
    private var geometry = BenchGeometry(topHeight: 0, viewportHeight: 0)
    /// The card of the Location while it is on the Bench, as the list last drew it: whether the Bench showed, and
    /// whether Benched cards came before the card.
    private var benchedLocation: (id: TopicGroupID, isBenchShown: Bool, hasCardsAbove: Bool)?
    /// Where the card of the Location stood on the Bench at the last layout or scroll; nil while it is not on the Bench.
    private var locationPlace: BenchedLocationPlace?
    /// Where each card stands against the visible part of the list, at the last layout or scroll.
    private var edgePlaces: [TopicGroupID: EdgePlace] = [:]
    /// Each card's top below the top of the list's first item, at the last layout.
    private var cardTops: [TopicGroupID: CGFloat] = [:]
    /// The cards that each pill counts, in list order, at the last layout or scroll.
    private var hiddenBelow: [TopicGroupID] = []
    private var hiddenAbove: [TopicGroupID] = []
    private let moreBelow = EdgePillView(edge: .bottom)
    private let moreAbove = EdgePillView(edge: .top)
    /// The card of the Location at the last update. When the Location moves to a Benched card out of view, the list
    /// glides to it.
    private var activeTopic: TopicGroupID?
    /// The card of the No Topic Session the user opened, by Session ID.
    private var noTopicCard: SessionCardView?
    /// The Open Places, by the ID of their records.
    private var openPlaces: [String: OpenPlaceView] = [:]
    /// The cards whose "N more…" the user pressed: Topic and Locked cards by their ID, No Topic cards by Session ID.
    /// They show all their rows from then on.
    private var showingAllRows: Set<TopicGroupID> = []
    private var showingAllSessionRows: Set<String> = []
    private lazy var guestsLine = TopicsLineView.guests()
    private lazy var benchLine: TopicsLineView = {
        let line = TopicsLineView.bench()
        line.onPress = { [weak self] in self?.store.toggleBench() }
        return line
    }()
    private lazy var update = ObservedUpdate { [weak self] in self?.render() }
    /// The groups under the list's scroll view.
    private lazy var groups: TopicGroupsView = {
        let groups = TopicGroupsView(store: store)
        groups.onMidnight = { [weak self] in self?.update.run() }
        return groups
    }()

    init(store: WorkspaceStore, environment: SidebarListEnvironment) {
        self.store = store
        self.environment = environment
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        // The Sidebar puts the list under the header. AppKit adds no room of its own for the title bar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        scrollView.setAccessibilityIdentifier("topics-list")
        // Over the list, outside its scroll view, as SwiftUI's overlays: the pills are no rows of `topics-list`.
        subviews = [scrollView, moreBelow, moreAbove, groups]
        for pill in [moreBelow, moreAbove] { pill.scrollView = scrollView }
        moreBelow.onPress = { [weak self] in
            if let card = self?.hiddenBelow.first { self?.reveal(card) }
        }
        moreAbove.onPress = { [weak self] in
            if let card = self?.hiddenAbove.last { self?.reveal(card) }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidMove), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        update.run()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Makes the items the items of the model's list, each with what it shows now. When a card that already showed
    /// opens or closes, it glides to its new height and the items below it move with it, with ease-out over
    /// `CardMotion.openDuration`, as the SwiftUI list animates them. When the Bench shows, the list keeps the card of the
    /// Location in its place.
    private func render() {
        let themed = environment.appearance
        if appearance?.name != themed?.name { appearance = themed }
        let model = store.topics
        var kept = Dictionary(items.compactMap { $0 as? TopicCardView }.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })
        var keptPlaces = openPlaces
        var opens = false
        var shown: [(view: NSView, show: () -> Void)] = []
        for item in model.list {
            switch item {
            case .card(let row):
                let content = content(of: row, activeTopic: model.activeTopic)
                let card = kept.removeValue(forKey: row.id) ?? card(of: row.id)
                opens = opens || (card.superview != nil && card.isOpen != content.header.isOpen)
                shown.append((card, { [environment] in card.show(content, environment: environment) }))
            case .openPlace(let id, let place):
                let view = keptPlaces.removeValue(forKey: id) ?? OpenPlaceView(recordID: id)
                view.onPress = { [weak self] in self?.store.presentFillOpenPlace(place) }
                shown.append((view, { [environment] in view.show(place: place, environment: environment) }))
            case .guestsLine:
                let line = guestsLine
                shown.append((line, { [environment] in line.show(environment: environment) }))
            case .benchLine(let isBenchShown):
                let line = benchLine
                shown.append((line, { [environment] in line.show(isBenchShown: isBenchShown, environment: environment) }))
            case .noTopicSession(let opened):
                guard let session = store.sessions.first(where: { $0.id == opened.id.session }) else { continue }
                let content = SessionCardContent(session, store: store, hints: environment.hints,
                                                 showsAllRows: showingAllSessionRows.contains(session.id), inTopicsList: true)
                let card = noTopicCard?.sessionID == session.id ? noTopicCard! : makeNoTopicCard(of: session.id)
                opens = opens || (card.superview != nil && card.isOpen != content.isOpen)
                shown.append((card, { [environment] in card.show(content, environment: environment) }))
            }
        }
        openPlaces = Dictionary(shown.compactMap { $0.view as? OpenPlaceView }.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
        let parts = model.listParts
        let blockCount = parts.bench == nil ? nil : parts.top.count
        let location = model.benchedLocation.map { id in (id: id, isBenchShown: model.isBenchShown == true, hasCardsAbove: model.benchCardIDs.first != id) }
        let before = locationPlace
        // Where the card stood before this change, as the SwiftUI list asks when the Location changes.
        let jumpedTo = model.activeTopic.flatMap { card in
            card != activeTopic && TopicsListScroll.revealsLocation(card, isBenched: model.isBenched(card), places: edgePlaces) ? card : nil
        }
        activeTopic = model.activeTopic
        let shownGroups = model.groups
        let change = { [self] in
            benchedLocation = location
            groups.isHidden = shownGroups.isEmpty
            groups.show(shownGroups, activeTopic: model.activeTopic, environment: environment, now: Date())
            for item in shown { item.show() }
            let views = shown.map(\.view)
            if items != views || self.blockCount != blockCount {
                items = views
                self.blockCount = blockCount
                // The order of the subviews is the order of the drawing: the block over the Bench that scrolls under it.
                // The order of the items is the order of the accessibility rows.
                let block = blockCount.map { Array(views.prefix($0)) } ?? []
                document.subviews = blockCount.map { Array(views.dropFirst($0)) + [backdrop] + block } ?? views
                document.rows = views
            }
            layOut()
            keepLocationInPlace(after: before)
        }
        if opens, let layer = document.layer {
            LayerGlide.run(under: layer, duration: CardMotion.openDuration, timing: CAMediaTimingFunction(name: .easeOut), change: change)
        } else {
            change()
        }
        // After the layout of the change, in which the card the user leaves closed and the block got shorter with it.
        if let jumpedTo { reveal(jumpedTo) }
    }

    private func card(of id: TopicGroupID) -> TopicCardView {
        let card = TopicCardView(cardID: id)
        card.onPress = { [weak self] in self?.press(id) }
        card.onCorner = { [weak self] in
            if case .topic(let topicID) = id { self?.store.presentSettleTopic(topicID) }
        }
        // As the tap of the SwiftUI row's drag handle.
        card.onSelectWindow = { [weak self] window in self?.store.windowRowDrag.select(window) }
        card.onSelectPane = { [weak self] paneID in self?.selectPane(paneID) }
        card.onSession = { [weak self] sessionID in self?.goToSession(sessionID, of: id) }
        card.onShowAllRows = { [weak self] in
            self?.showingAllRows.insert(id)
            self?.update.run()
        }
        return card
    }

    /// The card of the No Topic Session, as the SwiftUI list's `SessionCard` with Topic rows.
    private func makeNoTopicCard(of sessionID: String) -> SessionCardView {
        let card = SessionCardView(sessionID: sessionID, identifier: TopicGroupID.noTopic.accessibilityID + "-session-" + sessionID,
                                   inTopicsList: true)
        card.onPress = { [weak self] in
            guard let self, let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
            SessionCardPress(store: store, session: session)()
        }
        card.onSelectWindow = { [weak self] window in self?.store.windowRowDrag.select(window) }
        card.onMoveWindow = { [weak self] window, placement in self?.store.windowRowDrag.move(window, placement) }
        card.onSelectPane = { [weak self] paneID in self?.selectPane(paneID) }
        card.onShowAllRows = { [weak self] in
            self?.showingAllSessionRows.insert(sessionID)
            self?.update.run()
        }
        card.menuItems = { [weak self] in self?.sessionMenu(sessionID, SessionsListMenus.card) }
        card.headerActions = { [weak self] in self?.sessionMenu(sessionID, SessionsListMenus.header) }
        noTopicCard = card
        return card
    }

    /// A menu of the No Topic card's Session, as the Session is now. Nil once the Session has gone.
    private func sessionMenu(_ sessionID: String, _ menu: (SessionGroup, WorkspaceStore) -> SidebarMenu) -> SidebarMenu? {
        store.sessions.first { $0.id == sessionID }.map { menu($0, store) }
    }

    /// A press on a Session line goes to the Session, while it is live, as the card is now.
    private func goToSession(_ sessionID: String, of card: TopicGroupID) {
        let session = store.topics.rows.first { $0.id == card }?.sessions.first { $0.id.session == sessionID }
        if case .live = session?.contents { store.goToSession(sessionID) }
    }

    /// A press on a Pane row of a card goes to that Pane, as the list is now.
    private func selectPane(_ paneID: String) {
        let model = store.topics
        let sessions = model.rows.flatMap(\.sessions).compactMap { session -> [TopicsModel.SessionChildren.Item]? in
            if case .live(let children) = session.contents { return children.items }
            return nil
        }
        let noTopic = model.openedNoTopicSession.flatMap { model.sessionChildren[$0.id.session]?.items } ?? []
        for case .pane(let row) in sessions.flatMap({ $0 }) + noTopic where row.id == paneID {
            return store.select(row)
        }
    }

    /// The blocks that an open card lists, as the SwiftUI list's `CardList` cuts them: each live Session's rows, the
    /// first `CardRows.shownCount` of the card's rows, and a block whose rows are all cut loses its Session line too.
    /// Returns the blocks, the number of rows held back and the strongest Agent mark among them.
    private func blocks(of row: TopicsModel.Row, lines: Bool) -> (blocks: [TopicCardBlock], held: Int, mark: AgentMark?) {
        guard row.isExpanded else { return ([], 0, nil) }
        let live = row.sessions.compactMap { session -> (id: String, line: String, items: [TopicsModel.SessionChildren.Item])? in
            guard case .live(let children) = session.contents else { return nil }
            return (session.id.session, session.baseName, children.items)
        }
        let items = live.flatMap(\.items)
        let shown = CardRows.shownCount(items, selectedWindowID: store.selectedWindowID, showsAll: showingAllRows.contains(row.id))
        let fades = row.kind != .open
        var start = 0
        var blocks: [TopicCardBlock] = []
        for session in live {
            defer { start += session.items.count }
            guard start < shown else { break }
            blocks.append(TopicCardBlock(sessionID: session.id, line: lines ? session.line : nil, fades: fades,
                                         rows: session.items.prefix(shown - start).map { CardRowContent($0, store: store, inTopicsList: true) }))
        }
        return (blocks, items.count - shown, items.dropFirst(shown).compactMap { row.agentSpines[$0.id] }.max())
    }

    /// A press on the header of the card, as the card is now.
    private func press(_ id: TopicGroupID) {
        let model = store.topics
        guard let row = model.rows.first(where: { $0.id == id }) else { return }
        TopicCardPress(store: store, id: id, holdsSelection: id == model.activeTopic, isOpen: row.isExpanded)()
    }

    /// What the card shows, read from the models as the SwiftUI card reads them: a Topic's title and Summary from the
    /// Topic card Formats, a Locked Session's from the Session card Formats.
    private func content(of row: TopicsModel.Row, activeTopic: TopicGroupID?) -> TopicCardContent {
        let holdsSelection = row.id == activeTopic
        switch row.id {
        case .locked(let sessionID):
            let text = store.sidebarText(.session, context: store.sidebarFormatContexts.sessions[sessionID])
            let header = CardHeaderContent(title: text.title, summary: text.summary, isOpen: row.isExpanded, mark: row.mark,
                                           isLocked: true, isGuest: row.isGuest,
                                           hasBell: row.sessions.flatMap(\.windows).contains(where: \.hasBell),
                                           hint: CardHint(.locked(sessionID), in: environment.hints),
                                           notes: [row.isGuest ? "Guest" : "Locked"])
            let rows = blocks(of: row, lines: false)
            return TopicCardContent(header: header, holdsSelection: holdsSelection, spine: row.mark, blocks: rows.blocks,
                                    moreCount: rows.held, moreMark: rows.mark)
        case .topic, .noTopic:
            let text = store.sidebarText(.topic, context: store.sidebarFormatContexts.topics[row.id])
            let topicID: String? = if case .topic(let id) = row.id { id } else { nil }
            let header = CardHeaderContent(title: text.title, summary: text.summary, isOpen: row.isExpanded, mark: row.mark,
                                           isPinned: row.isPinned, isGuest: row.isGuest,
                                           details: TopicCardWords.details(of: row, inList: true), note: row.note,
                                           tags: store.cardTags(row),
                                           hint: topicID.flatMap { CardHint(.topic($0), in: environment.hints) },
                                           notes: TopicCardWords.notes(of: row), cornerWidth: CardCorner.designWidth)
            let rows = blocks(of: row, lines: true)
            return TopicCardContent(header: header, holdsSelection: holdsSelection, spine: row.usesRowMarks ? nil : row.mark,
                                    unreadOverHeader: row.usesRowMarks && row.isUnread,
                                    restingOpacity: TopicCardOpacity.resting(row, inList: true),
                                    corner: topicID.map { TopicCardCorner(title: "Settle", identifier: "settle-topic-" + $0,
                                                                          isEnabled: !store.changingTopic) },
                                    blocks: rows.blocks, moreCount: rows.held, moreMark: rows.mark)
        }
    }

    /// Lays the items out one under the other, from the top of the list, as the SwiftUI list's stack does. With a Bench
    /// line, empty room after the last Benched card lets it scroll up to right under the block
    /// (`BenchGeometry.tail`).
    private func layOut() {
        // The groups at the bottom, with their room around them, and the list in the room above them.
        let scale = environment.displayScale
        groups.cardsLimit = (bounds.height * TopicGroupMetrics.cardsShare).rounded(toPixelsOf: scale)
        let groupsWidth = max(0, bounds.width - 2 * TopicGroupMetrics.horizontalInset)
        let groupsHeight = groups.isHidden ? 0 : groups.height(width: groupsWidth)
        let groupsRoom = groups.isHidden ? 0 : groupsHeight + 2 * TopicGroupMetrics.verticalInset
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - groupsRoom))
        groups.frame = NSRect(x: TopicGroupMetrics.horizontalInset, y: scrollView.frame.maxY + TopicGroupMetrics.verticalInset,
                              width: groupsWidth, height: groupsHeight)
        let width = max(0, bounds.width - 2 * TopicsListMetrics.horizontalInset)
        var bottom = TopicsListMetrics.verticalInset
        places = items.enumerated().map { index, item in
            let top = bottom + (index == 0 ? 0 : TopicsListMetrics.itemSpacing)
            let height = switch item {
            case let card as TopicCardView: card.height(width: width)
            case let card as SessionCardView: card.height(width: width)
            case let line as TopicsLineView: line.height
            case let place as OpenPlaceView: place.height
            default: CGFloat(0)
            }
            bottom = top + height
            return NSRect(x: TopicsListMetrics.horizontalInset, y: top, width: width, height: height)
        }
        for (item, place) in zip(items, places) { item.frame = place }
        cardTops = Dictionary(zip(items, places).compactMap { item, place in Self.cardID(of: item).map { ($0, place.minY - TopicsListMetrics.verticalInset) } },
                              uniquingKeysWith: { first, _ in first })
        let blockBottom = blockCount.flatMap { $0 > 0 ? places[$0 - 1].maxY : nil } ?? TopicsListMetrics.verticalInset
        geometry = BenchGeometry(topHeight: blockBottom - TopicsListMetrics.verticalInset, viewportHeight: scrollView.frame.height,
                                 spacing: TopicsListMetrics.itemSpacing, inset: TopicsListMetrics.verticalInset,
                                 fontSize: environment.fontSize)
        if let blockCount, let last = places.last, places.count > blockCount {
            // The SwiftUI list's stack has the empty room as one more item, after a gap.
            bottom += TopicsListMetrics.itemSpacing + geometry.tail(afterCardOfHeight: last.height)
        }
        // The clip view keeps its offset when the content changes height, inside the new scroll range.
        document.setFrameSize(NSSize(width: bounds.width, height: bottom + TopicsListMetrics.verticalInset))
        stick()
    }

    /// The list scrolled: by the user, by the list itself, or because its content got shorter than the offset it had.
    @objc private func clipDidMove() {
        stick()
    }

    /// Moves the block down as far as the list scrolled past its slack, so it stays at the top, with its background,
    /// and gives each card its top edge in the viewport, so the header of an open card sticks: to the viewport's top in
    /// the block or in a list without a Bench line, and under the block on the Bench. Keeps where the Location's card
    /// now stands on the Bench.
    private func stick() {
        let offset = scrollView.contentView.bounds.minY
        let shift = blockCount == nil ? 0 : geometry.stick(at: offset)
        // Under the block on the Bench, and at the viewport's top elsewhere.
        let benchInset = blockCount == nil ? 0 : geometry.areaTop
        let blockItems = blockCount ?? 0
        for (index, (item, place)) in zip(items, places).enumerated() {
            let isBlock = index < blockItems
            if isBlock { item.setFrameOrigin(NSPoint(x: place.minX, y: place.minY + shift)) }
            let top = item.frame.minY - offset
            switch item {
            case let card as TopicCardView: card.stick(cardTop: top, inset: isBlock ? 0 : benchInset)
            case let card as SessionCardView: card.stick(cardTop: top)
            default: break
            }
        }
        // As the SwiftUI list draws the chrome behind each item of the block: from the list's top to a gap under the
        // block's last item, across the list's whole width.
        backdrop.isHidden = blockItems == 0
        if blockItems > 0 {
            backdrop.frame = NSRect(x: 0, y: shift, width: bounds.width, height: places[blockItems - 1].maxY + TopicsListMetrics.itemSpacing)
        }
        backdrop.theme = environment.chromeTheme
        locationPlace = currentLocationPlace()
        showPills(offset: offset)
    }

    /// The card that the item shows: a Topic card or a Locked card by its ID, the No Topic card as No Topic; nil for a
    /// line or an Open Place.
    private static func cardID(of item: NSView) -> TopicGroupID? {
        switch item {
        case let card as TopicCardView: card.cardID
        case is SessionCardView: .noTopic
        default: nil
        }
    }

    /// The Benched cards, in list order: the cards after the block. Empty without a Bench line.
    private var benchCards: [TopicGroupID] { blockCount.map { items.dropFirst($0).compactMap(Self.cardID(of:)) } ?? [] }

    /// Keeps where each card stands against the visible part of the list at the scroll offset `offset`, from the
    /// bottom of the block on the Bench and from the list's top elsewhere, and shows the pills that count the cards
    /// past the edges, as the SwiftUI list's `MoreBelowPill` and `MoreAbovePill` do. The "more below" pill slides
    /// out with the end of the list, or of the Bench; the "more above" pill slides in as the Bench scrolls under the
    /// block.
    private func showPills(offset: CGFloat) {
        let viewport = scrollView.contentView.bounds.height, band = geometry.indicatorHeight
        let blockItems = blockCount ?? 0
        var places: [TopicGroupID: EdgePlace] = [:]
        for (index, item) in items.enumerated() {
            guard let id = Self.cardID(of: item) else { continue }
            let top = item.frame.minY - offset
            places[id] = EdgePlace(top: top, bottom: top + item.frame.height,
                                   visibleTop: blockCount == nil || index < blockItems ? 0 : geometry.areaTop,
                                   visibleBottom: viewport, indicatorHeight: band)
        }
        edgePlaces = places
        hiddenBelow = TopicsListScroll.moreBelow(items.compactMap(Self.cardID(of:)), places: places)
        hiddenAbove = blockCount == nil ? [] : TopicsListScroll.moreAbove(benchCards, places: places)
        // With a Bench line, the end is the last Benched card's bottom, not the empty room after it.
        let last = blockCount == nil ? items.last : items.count > blockItems ? items.last : nil
        let end = last.map { min(max(0, $0.frame.maxY - offset - viewport), band) } ?? 0
        moreBelow.frame = NSRect(x: 0, y: scrollView.frame.maxY - band, width: bounds.width, height: band)
        moreBelow.show(count: hiddenBelow.count, slide: end, environment: environment)
        moreAbove.frame = NSRect(x: 0, y: geometry.areaTop, width: bounds.width, height: band)
        moreAbove.show(count: hiddenAbove.count, slide: geometry.stick(at: offset), environment: environment)
    }

    /// Glides the list to the card, as the SwiftUI list's `reveal` scrolls: a Benched card to directly under the line,
    /// or under the "more above" pill when the Benched cards before it are then above the area, and any other card to
    /// the top of the list. The glide has the SwiftUI list's duration and curve, and it stays inside the scroll range.
    private func reveal(_ card: TopicGroupID) {
        guard let top = cardTops[card] else { return }
        let bench = benchCards
        let offset = TopicsListScroll.revealOffset(cardTop: top, isBenched: bench.contains(card), hasCardsAbove: bench.first != card,
                                                   geometry: geometry)
        scrollView.glide(to: offset, duration: TopicsListScroll.revealDuration, timing: TopicsListScroll.revealTiming,
                         name: "TopicsListGlide")
    }

    /// Where the card of the Location stands on the Bench now, in the viewport; nil while it is not on the Bench.
    private func currentLocationPlace() -> BenchedLocationPlace? {
        guard let location = benchedLocation,
              let card = items.first(where: { ($0 as? TopicCardView)?.cardID == location.id }) else { return nil }
        return BenchedLocationPlace(top: card.frame.minY - scrollView.contentView.bounds.minY, isBenchShown: location.isBenchShown,
                                    hasCardsAbove: location.hasCardsAbove)
    }

    /// Keeps the Location's card on the Bench where it stood on the screen when the Bench shows, as the SwiftUI list's
    /// `KeepsPlaceWhenBenchShows` does: the list moves at once by the distance the cards shown before it pushed it down,
    /// less the band of the "more above" pill that those cards bring. Without a Benched Location nothing moves, and the
    /// Bench opens at its top. `before` is where the card stood before the change.
    private func keepLocationInPlace(after before: BenchedLocationPlace?) {
        if let distance = currentLocationPlace()?.openingScroll(after: before, indicatorHeight: geometry.indicatorHeight) {
            scrollView.move(by: distance)
        }
        locationPlace = currentLocationPlace()
    }
}

/// The content of the AppKit Topics list. Its subviews are in the order they draw, the block over the Bench; its
/// accessibility rows are the items in the list's order, as SwiftUI gives them.
private final class TopicsListDocumentView: NSView {
    /// The items in the list's order.
    var rows: [NSView] = []

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { NSAccessibility.unignoredChildren(from: rows) }
}

/// The chrome's background behind the block of the Topics list that sticks, so the Benched cards that scroll under the
/// block do not show through. As SwiftUI's background of the block, it takes the clicks that land on it, and does
/// nothing with them.
private final class TopicsBlockBackdropView: SidebarChromeView {
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    override func rightMouseDown(with event: NSEvent) {}
}
