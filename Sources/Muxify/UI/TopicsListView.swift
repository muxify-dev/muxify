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

/// The Sidebar's Topics list in AppKit (ADR 0075): a scroll view with a card for each Topic card and Locked card of the
/// Topics model's list, the No Topic card and the Guests line, in the model's order, with the gaps and insets of the
/// SwiftUI list. Its views lay out by frames, and it reads the store through `ObservedUpdate`. The header of an open
/// card sticks to the top while the card's rows scroll under it. The SwiftUI Sidebar shows the Settled group under it.
final class TopicsListView: NSView, SidebarList {
    private let store: WorkspaceStore
    /// The values from the SwiftUI Sidebar. The list draws again when one changes.
    var environment: SidebarListEnvironment {
        didSet {
            if environment != oldValue { update.run() }
        }
    }
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    /// The cards and lines from the top of the list.
    private var items: [NSView] = []
    /// The card of the No Topic Session the user opened, by Session ID.
    private var noTopicCard: SessionCardView?
    /// The cards whose "N more…" the user pressed: Topic and Locked cards by their ID, No Topic cards by Session ID.
    /// They show all their rows from then on.
    private var showingAllRows: Set<TopicGroupID> = []
    private var showingAllSessionRows: Set<String> = []
    private lazy var guestsLine = TopicsLineView(id: TopicsModel.ListItem.guestsLineID, word: "Guests", identifier: "topics-guests-line")
    private lazy var update = ObservedUpdate { [weak self] in self?.render() }

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
        addSubview(scrollView)
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

    /// Makes the items the Topic cards, Locked cards, the No Topic card and the Guests line of the model's list, each
    /// with what it shows now. When a card that already showed opens or closes, it glides to its new height and the
    /// items below it move with it, with ease-out over `CardMotion.openDuration`, as the SwiftUI list animates them.
    private func render() {
        let themed = environment.appearance
        if appearance?.name != themed?.name { appearance = themed }
        let model = store.topics
        var kept = Dictionary(items.compactMap { $0 as? TopicCardView }.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })
        var opens = false
        var shown: [(view: NSView, show: () -> Void)] = []
        for item in model.list {
            switch item {
            case .card(let row):
                let content = content(of: row, activeTopic: model.activeTopic)
                let card = kept.removeValue(forKey: row.id) ?? card(of: row.id)
                opens = opens || (card.superview != nil && card.isOpen != content.header.isOpen)
                shown.append((card, { [environment] in card.show(content, environment: environment) }))
            case .guestsLine:
                let line = guestsLine
                shown.append((line, { [environment] in line.show(environment: environment) }))
            case .noTopicSession(let opened):
                guard let session = store.sessions.first(where: { $0.id == opened.id.session }) else { continue }
                let content = SessionCardContent(session, store: store, hints: environment.hints,
                                                 showsAllRows: showingAllSessionRows.contains(session.id), inTopicsList: true)
                let card = noTopicCard?.sessionID == session.id ? noTopicCard! : makeNoTopicCard(of: session.id)
                opens = opens || (card.superview != nil && card.isOpen != content.isOpen)
                shown.append((card, { [environment] in card.show(content, environment: environment) }))
            // The Open Places and the Bench line come with a later task of the set remove-swiftui.
            case .openPlace, .benchLine:
                continue
            }
        }
        let change = { [self] in
            for item in shown { item.show() }
            let views = shown.map(\.view)
            // The order of the subviews is the order of the accessibility rows.
            if items != views {
                items = views
                document.subviews = views
            }
            layOut()
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

    private func layOut() {
        scrollView.frame = bounds
        let width = max(0, bounds.width - 2 * TopicsListMetrics.horizontalInset)
        var bottom = TopicsListMetrics.verticalInset
        for (index, item) in items.enumerated() {
            let top = bottom + (index == 0 ? 0 : TopicsListMetrics.itemSpacing)
            let height = switch item {
            case let card as TopicCardView: card.height(width: width)
            case let card as SessionCardView: card.height(width: width)
            case let line as TopicsLineView: line.height
            default: CGFloat(0)
            }
            item.frame = NSRect(x: TopicsListMetrics.horizontalInset, y: top, width: width, height: height)
            bottom = item.frame.maxY
        }
        // The clip view keeps its offset when the content changes height, inside the new scroll range.
        document.setFrameSize(NSSize(width: bounds.width, height: bottom + TopicsListMetrics.verticalInset))
        stickHeaders()
    }

    /// The list scrolled: by the user, or because its content got shorter than the offset it had.
    @objc private func clipDidMove() {
        stickHeaders()
    }

    /// Gives each card its top edge in the viewport, so the header of an open card sticks to the viewport's top.
    private func stickHeaders() {
        let top = scrollView.contentView.bounds.minY
        for item in items {
            switch item {
            case let card as TopicCardView: card.stick(cardTop: card.frame.minY - top)
            case let card as SessionCardView: card.stick(cardTop: card.frame.minY - top)
            default: break
            }
        }
    }
}
