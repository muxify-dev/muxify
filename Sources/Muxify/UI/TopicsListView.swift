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
/// While the list has no item and no group, it says "No Topics" in its middle (`TopicsListEmptyState`).
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
///
/// A press that moves on the header of a Topic card or a Locked card lifts the card (`StackDrag`, as the SwiftUI list's
/// `ListDrag`): it moves among the cards of its section, Pinned or not, and the lines, the Open Places and the No Topic
/// card slide with the cards it passes. Across the Guests line or the Bench line it trades with the card under the
/// pointer, which shows the trade mark, or fills the Open Place there; while an In Play card is across, the hidden Bench
/// shows (`WorkspaceStore.benchPeek`). While the pointer rests near an edge of the list, or of the Bench under the
/// block, the list scrolls its clip view (`EdgeAutoScrollLoop`), and the card stays under the pointer. No card lifts
/// while a Topic change runs.
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
    /// "No Topics" in the middle of the list while it lists nothing. It stands over the scroll view, after it among the
    /// accessibility rows, as the SwiftUI list's overlay does.
    private let emptyState = SidebarLabel()
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
    /// The drag of the Topic cards and Locked cards, whose placeholder stands among the items.
    private lazy var cardDrag = StackDrag<TopicListID>(host: self, spacing: TopicsListMetrics.itemSpacing,
                                                       cornerRadius: CardOutline.cornerRadius,
                                                       tradesAcross: [TopicsModel.ListItem.guestsLineID, TopicsModel.ListItem.benchLineID])
    /// The model of the list as it shows now, whose slots a drag reaches.
    private var shownModel: TopicsModel?
    /// The slot of each item in the drag, in the list's order.
    private var slots: [StackSlot<TopicListID>] = []
    /// The trade target of the lifted card, with its trade mark over it and its ghost where the lifted card stood.
    private var shownTrade: (target: TopicListID, mark: TradeMarkView, ghost: TradeGhostView)?
    /// The drag's phase, and whether the lifted card was across a line, when the list last heard of the drag.
    private var dragState: (phase: StackDrag<TopicListID>.Phase, across: Bool) = (.idle, false)
    /// Scrolls the list while a lifted card's pointer rests at an edge.
    private let edgeScroll = EdgeAutoScrollLoop()
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
        // Over the list, outside its scroll view, as SwiftUI's overlays: "No Topics" and the pills are no rows of
        // `topics-list`.
        subviews = [scrollView, emptyState, moreBelow, moreAbove, groups]
        emptyState.ink = .secondary
        // Wraps where it does not fit, as SwiftUI's `Text` does.
        emptyState.wraps = true
        emptyState.setAccessibilityRole(.staticText)
        emptyState.setAccessibilityIdentifier(TopicsListEmptyState.identifier)
        for pill in [moreBelow, moreAbove] { pill.scrollView = scrollView }
        edgeScroll.scrollView = scrollView
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
        // A card's header lifts it while no Topic change runs, as the SwiftUI card's handle.
        let lifts = !store.changingTopic
        var shown: [(view: NSView, slot: StackSlot<TopicListID>, show: () -> Void)] = []
        for item in model.list {
            switch item {
            case .card(let row):
                let content = content(of: row, activeTopic: model.activeTopic)
                let card = kept.removeValue(forKey: row.id) ?? card(of: row.id)
                opens = opens || (card.superview != nil && card.isOpen != content.header.isOpen)
                card.drag = row.id.listID.map(cardDrag.handle)
                card.isDraggable = lifts
                shown.append((card, item.dragSlot, { [environment] in card.show(content, environment: environment) }))
            case .openPlace(let id, let place):
                let view = keptPlaces.removeValue(forKey: id) ?? OpenPlaceView(recordID: id)
                view.onPress = { [weak self] in self?.store.presentFillOpenPlace(place) }
                shown.append((view, item.dragSlot, { [environment] in view.show(place: place, environment: environment) }))
            case .guestsLine:
                let line = guestsLine
                shown.append((line, item.dragSlot, { [environment] in line.show(environment: environment) }))
            case .benchLine(let isBenchShown):
                let line = benchLine
                shown.append((line, item.dragSlot, { [environment] in line.show(isBenchShown: isBenchShown, environment: environment) }))
            case .noTopicSession(let opened):
                guard let session = store.sessions.first(where: { $0.id == opened.id.session }) else { continue }
                let content = SessionCardContent(session, store: store, hints: environment.hints,
                                                 showsAllRows: showingAllSessionRows.contains(session.id), inTopicsList: true)
                let card = noTopicCard?.sessionID == session.id ? noTopicCard! : makeNoTopicCard(of: session.id)
                opens = opens || (card.superview != nil && card.isOpen != content.isOpen)
                shown.append((card, item.dragSlot, { [environment] in card.show(content, environment: environment) }))
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
        let empty = TopicsListEmptyState.text(model)
        let change = { [self] in
            benchedLocation = location
            emptyState.text = empty ?? ""
            emptyState.font = environment.typography.nsFont(for: TopicsListEmptyState.role)
            emptyState.scale = environment.displayScale
            emptyState.isHidden = empty == nil
            emptyState.setAccessibilityElement(empty != nil)
            emptyState.setAccessibilityValue(empty)
            groups.isHidden = shownGroups.isEmpty
            groups.show(shownGroups, activeTopic: model.activeTopic, environment: environment, now: Date())
            for item in shown { item.show() }
            let views = shown.map(\.view)
            shownModel = model
            slots = shown.map(\.slot)
            if items != views || self.blockCount != blockCount {
                items = views
                self.blockCount = blockCount
                // The order of the subviews is the order of the drawing: the block over the Bench that scrolls under it,
                // and the drag's placeholder behind the cards. The order of the items is the order of the accessibility
                // rows.
                let block = blockCount.map { Array(views.prefix($0)) } ?? []
                document.subviews = [cardDrag.slot] + (blockCount.map { Array(views.dropFirst($0)) + [backdrop] + block } ?? views)
                document.rows = views
            }
            layOut()
            keepLocationInPlace(after: before)
            // A lifted card finds its places among the items again, and a dropped one lands once they show it there.
            cardDrag.show()
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
        // As the drops of the SwiftUI card's `SessionHeading` and `CardList`.
        card.onMoveSession = { [weak self] sessionID, drop in
            if let placement = drop.sessionPlacement { self?.store.moveSession(sessionID, to: placement) }
        }
        card.onMoveWindow = { [weak self] window, placement in self?.store.windowRowDrag.move(window, placement) }
        card.onShowAllRows = { [weak self] in
            self?.showingAllRows.insert(id)
            self?.update.run()
        }
        card.menuItems = { [weak self] in self?.menu(of: id, header: false) }
        card.headerActions = { [weak self] in self?.menu(of: id, header: true) }
        card.sessionMenu = { [weak self] sessionID in self?.sessionLineMenu(sessionID, of: id, actions: false) }
        card.sessionActions = { [weak self] sessionID in self?.sessionLineMenu(sessionID, of: id, actions: true) }
        card.windowMenu = { [weak self] window in self.map { TopicsListMenus.window(window, store: $0.store) } }
        card.windowActions = { [weak self] window in self.map { TopicsListMenus.windowActions(window, store: $0.store) } }
        return card
    }

    /// The menu of a Topic card or a Locked card, or with `header` its header's named actions, as the card is now. Nil
    /// once the card has gone.
    private func menu(of id: TopicGroupID, header: Bool) -> SidebarMenu? {
        let model = store.topics
        guard let row = model.rows.first(where: { $0.id == id }) else { return nil }
        let steps = model.steps(of: id)
        if case .locked(let sessionID) = id {
            return header ? TopicsListMenus.lockedHeader(row, sessionID: sessionID, steps: steps, store: store)
                : TopicsListMenus.lockedCard(row, sessionID: sessionID, steps: steps, store: store)
        }
        return header ? TopicsListMenus.topicHeader(row, steps: steps, store: store) : TopicsListMenus.topicCard(row, steps: steps, store: store)
    }

    /// The menu of a Session line of the card, or with `actions` its named actions, as the card is now. Nil once the
    /// card has gone.
    private func sessionLineMenu(_ sessionID: String, of id: TopicGroupID, actions: Bool) -> SidebarMenu? {
        guard let row = store.topics.rows.first(where: { $0.id == id }) else { return nil }
        let order = SessionLineOrder(row, sessionID: sessionID, store: store)
        guard !actions else { return TopicsListMenus.sessionLineActions(order, store: store) }
        let window = row.sessions.first { $0.id.session == sessionID }?.windows.first
        return TopicsListMenus.sessionLine(order, window: window, store: store)
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
        // Its Window rows are the Topics list's, as in the SwiftUI list's No Topic card.
        card.windowMenu = { [weak self] window in self.map { TopicsListMenus.window(window, store: $0.store) } }
        card.windowActions = { [weak self] window in self.map { TopicsListMenus.windowActions(window, store: $0.store) } }
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
    /// A block whose line has a `SessionLineOrder` is ordered: a drag on its line moves it, as on the SwiftUI line.
    /// `spines` are the Agent marks beside the rows, by Window or Pane ID: a Topic card's `agentSpines`, and none on a
    /// Locked card, as the SwiftUI `LockedCard` gives its `CardList` none. Returns the blocks, the number of rows held
    /// back and the strongest Agent mark among them.
    private func blocks(of row: TopicsModel.Row, lines: Bool,
                        spines: [String: AgentMark]) -> (blocks: [TopicCardBlock], held: Int, mark: AgentMark?) {
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
            blocks.append(TopicCardBlock(sessionID: session.id, line: lines ? session.line : nil,
                                         isOrdered: lines && SessionLineOrder(row, sessionID: session.id, store: store) != nil, fades: fades,
                                         rows: session.items.prefix(shown - start).map { item in
                                             CardRowContent(item, store: store, inTopicsList: true, spine: spines[item.id])
                                         }))
        }
        return (blocks, items.count - shown, items.dropFirst(shown).compactMap { spines[$0.id] }.max())
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
            let rows = blocks(of: row, lines: false, spines: [:])
            return TopicCardContent(header: header, holdsSelection: holdsSelection, spine: row.mark, blocks: rows.blocks,
                                    moreCount: rows.held, moreMark: rows.mark, movesWindows: store.windowRowDrag.isEnabled)
        case .topic, .noTopic:
            let text = store.sidebarText(.topic, context: store.sidebarFormatContexts.topics[row.id])
            let topicID: String? = if case .topic(let id) = row.id { id } else { nil }
            let header = CardHeaderContent(title: text.title, summary: text.summary, isOpen: row.isExpanded, mark: row.mark,
                                           isPinned: row.isPinned, isGuest: row.isGuest,
                                           details: TopicCardWords.details(of: row, inList: true), note: row.note,
                                           tags: store.cardTags(row),
                                           hint: topicID.flatMap { CardHint(.topic($0), in: environment.hints) },
                                           notes: TopicCardWords.notes(of: row), cornerWidth: CardCorner.designWidth)
            let rows = blocks(of: row, lines: true, spines: row.agentSpines)
            return TopicCardContent(header: header, holdsSelection: holdsSelection, spine: row.usesRowMarks ? nil : row.mark,
                                    unreadOverHeader: row.usesRowMarks && row.isUnread,
                                    restingOpacity: TopicCardOpacity.resting(row, inList: true),
                                    corner: topicID.map { TopicCardCorner(title: "Settle", identifier: "settle-topic-" + $0,
                                                                          isEnabled: !store.changingTopic) },
                                    blocks: rows.blocks, moreCount: rows.held, moreMark: rows.mark,
                                    movesSessions: !store.changingTopic, movesWindows: store.windowRowDrag.isEnabled)
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
        // In the middle of the scroll view, on the nearest pixel, where SwiftUI draws the text of its overlay.
        let empty = emptyState.fit(width: scrollView.frame.width), area = scrollView.frame
        emptyState.frame = NSRect(origin: NSPoint(x: (area.minX + (area.width - empty.width) / 2).rounded(toPixelsOf: scale),
                                                  y: (area.minY + (area.height - empty.height) / 2).rounded(toPixelsOf: scale)),
                                  size: empty)
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
        // `placeItems` puts them at their places.
        for (item, place) in zip(items, places) { item.setFrameSize(place.size) }
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

    /// Moves the block down as far as the list scrolled past its slack, so it stays at the top, with its background
    /// (`placeItems`). A lifted card stays under the pointer, and finds where it lands among the cards that scrolled
    /// under it. Keeps where the Location's card now stands on the Bench.
    private func stick() {
        let offset = scrollView.contentView.bounds.minY
        let shift = blockCount == nil ? 0 : geometry.stick(at: offset)
        let blockItems = blockCount ?? 0
        placeItems()
        // As the SwiftUI list's drag hears the scroll: the Bench scrolled under the block, and the lifted card's place
        // moved in the viewport.
        cardDrag.scrollArea(by: shift)
        cardDrag.placeMoved()
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

    /// Puts each item at its place: the block moved down as far as the list scrolled past its slack, so it stays at the
    /// top, and each item moved by the drag's offset, the dragged card above the others. Gives each card its top edge
    /// in the viewport, so the header of an open card sticks: to the viewport's top in the block or in a list without a
    /// Bench line, and under the block on the Bench. Puts the drag's placeholder, and the marks of a trade.
    private func placeItems() {
        let offset = scrollView.contentView.bounds.minY
        let shift = blockCount == nil ? 0 : geometry.stick(at: offset)
        // Under the block on the Bench, and at the viewport's top elsewhere.
        let benchInset = blockCount == nil ? 0 : geometry.areaTop
        let blockItems = blockCount ?? 0
        for (index, (item, place)) in zip(items, places).enumerated() {
            let isBlock = index < blockItems
            let top = place.minY + (isBlock ? shift : 0)
            let slot = index < slots.count ? slots[index] : nil
            (item as? DragUnitView)?.place = top
            let origin = NSPoint(x: place.minX, y: top + (slot.map { cardDrag.offset(of: $0) } ?? 0))
            if item.frame.origin != origin { item.setFrameOrigin(origin) }
            // Above every other item, also above the block, as the SwiftUI list raises a card that the drag moves.
            let z: CGFloat = slot.map(cardDrag.raises) == true ? 2 : 0
            if let layer = item.layer, layer.zPosition != z { layer.zPosition = z }
            let cardTop = item.frame.minY - offset
            switch item {
            case let card as TopicCardView: card.stick(cardTop: cardTop, inset: isBlock ? 0 : benchInset)
            case let card as SessionCardView: card.stick(cardTop: cardTop)
            default: break
            }
        }
        cardDrag.placeSlot()
        placeTrade()
    }

    /// The item of a card or an Open Place by its place in the drag.
    private func item(of id: TopicListID) -> NSView? {
        slots.firstIndex(of: .item(id)).flatMap { $0 < items.count ? items[$0] : nil }
    }

    /// Shows the trade mark over the card or the Open Place that the lifted card would trade with, and the target's
    /// ghost where the lifted card stood, as the SwiftUI list's `TradeMark` and `TradeGhost` show them. Each target
    /// has its own mark and ghost, which fade in at its place, and fade out there when the lifted card leaves it. The
    /// mark draws just above its target, so the block covers it as it covers the target.
    private func placeTrade() {
        let id = cardDrag.tradeTarget
        if shownTrade?.target != id {
            if let old = shownTrade {
                old.mark.show(false, environment: environment)
                old.ghost.show(nil, environment: environment)
                Task { [weak mark = old.mark, weak ghost = old.ghost] in
                    try? await Task.sleep(for: .seconds(TradeLook.shows.duration * 2))
                    mark?.removeFromSuperview()
                    ghost?.removeFromSuperview()
                }
            }
            shownTrade = id.flatMap { id in
                item(of: id).map { target in
                    let mark = TradeMarkView(cornerRadius: CardOutline.cornerRadius)
                    let ghost = TradeGhostView(cornerRadius: CardOutline.cornerRadius)
                    ghost.show(target, environment: environment)
                    mark.show(true, environment: environment)
                    return (id, mark, ghost)
                }
            }
            document.tradeMark = shownTrade?.mark
        }
        guard let trade = shownTrade, let target = item(of: trade.target) else { return }
        // A change to the items, such as the Bench that shows, gives the document its subviews anew.
        if trade.mark.superview !== document { document.addSubview(trade.mark, positioned: .above, relativeTo: target) }
        if trade.ghost.superview !== document { document.addSubview(trade.ghost) }
        trade.mark.frame = target.frame
        if let ghost = cardDrag.tradeGhostOffset(of: trade.target) { trade.ghost.frame = target.frame.offsetBy(dx: 0, dy: ghost) }
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

/// The drag of the Topic cards and Locked cards, as the SwiftUI list's `ListDrag`: the slots come from the model's
/// `dragSlots`, so a card moves among the cards with its Pin, and passes the lines and the No Topic card.
extension TopicsListView: StackDragList {
    func dragSlots(around id: TopicListID) -> [StackSlot<TopicListID>] {
        guard let model = shownModel, let item = model.list.first(where: { $0.dragSlot == .item(id) }) else { return [] }
        let shown = Set(slots)
        return model.dragSlots(around: item.id).filter(shown.contains)
    }

    func dragHeight(of slot: StackSlot<TopicListID>) -> CGFloat {
        slots.firstIndex(of: slot).flatMap { $0 < places.count ? places[$0].height : nil } ?? 0
    }

    func dragView(_ id: TopicListID) -> DragUnitView? { item(of: id) as? DragUnitView }

    var liftsUnits: Bool { !store.changingTopic }

    var reducesMotion: Bool { environment.reduceMotion }

    /// A lifted card stops at the top of the list's viewport, also on the Bench, as in the SwiftUI list.
    func visibleTop(in clip: NSClipView) -> CGFloat { clip.bounds.minY }

    func layOutUnits() { placeItems() }

    /// As the SwiftUI card's handle drops it.
    func drop(_ id: TopicListID, at placement: DropPlacement<TopicListID>) {
        store.moveTopic(id, to: placement.topicPlacement)
    }

    /// As the SwiftUI card's handle trades it: with a card, or into an Open Place.
    func trade(_ id: TopicListID, with other: TopicListID) {
        store.tradeCard(id, with: other)
    }

    /// An In Play card that crosses a line opens the hidden Bench, so the user sees what it can trade with; when it goes
    /// back above the line, the Bench hides again. What a drag showed of the hidden Bench folds into the line as soon as
    /// the cards no longer need it: at the drop, while a card glides back, or once two traded cards are in their new
    /// places. As the SwiftUI list's handlers of `isAcross` and `phase`. While a card is lifted, its pointer scrolls the
    /// list at the edges of the Bench under the block, or of the whole list without a Bench line, as the SwiftUI list's
    /// `EdgeAutoScroller` hands it to `ScrollDriver`.
    func dragDidChange() {
        let phase = cardDrag.phase, across = cardDrag.isAcross
        let before = dragState
        dragState = (phase, across)
        if across != before.across {
            if !across {
                if case .lifted = phase, store.benchPeek == .all { store.benchPeek = nil }
            } else if !store.benchShown, store.benchPeek != .all, let dragged = cardDrag.draggedID,
                      shownModel?.split?.inPlay.contains(where: { $0.id.listID == dragged }) == true {
                store.benchPeek = .all
            }
        }
        if phase != before.phase {
            switch phase {
            case .lifted, .trading: break
            default: if store.benchPeek != nil { store.benchPeek = nil }
            }
        }
        let clip = scrollView.contentView
        edgeScroll.follow(pointer: cardDrag.pointer.map { clip.convert($0, from: nil).y - clip.bounds.minY }) { [weak self] offset in
            guard let self else { return 0...0 }
            return blockCount == nil ? 0...scrollView.contentView.bounds.height : geometry.autoScrollRange(at: offset)
        }
    }
}

/// The content of the AppKit Topics list. Its subviews are in the order they draw, the block over the Bench; its
/// accessibility rows are the items in the list's order, as SwiftUI gives them.
private final class TopicsListDocumentView: NSView {
    /// The items in the list's order.
    var rows: [NSView] = []
    /// The trade mark over the trade target of a lifted card, after the items.
    weak var tradeMark: TradeMarkView?

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: rows + (tradeMark.map { [$0] } ?? []))
    }
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
