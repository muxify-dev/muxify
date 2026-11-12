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
/// Topics model's list, and the Guests line, in the model's order, with the gaps and insets of the SwiftUI list. Its
/// views lay out by frames, and it reads the store through `ObservedUpdate`. The SwiftUI Sidebar shows the Settled
/// group under it.
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
        update.run()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// Makes the items the Topic cards, Locked cards and the Guests line of the model's list, each with what it shows
    /// now. When a card that already showed opens or closes, it glides to its new height and the items below it move
    /// with it, with ease-out over `CardMotion.openDuration`, as the SwiftUI list animates them.
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
            // The Open Places, the Bench line and the No Topic card come with later tasks of the set remove-swiftui.
            case .openPlace, .benchLine, .noTopicSession:
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
        return card
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
            return TopicCardContent(header: header, holdsSelection: holdsSelection, spine: row.mark)
        case .topic, .noTopic:
            let text = store.sidebarText(.topic, context: store.sidebarFormatContexts.topics[row.id])
            let topicID: String? = if case .topic(let id) = row.id { id } else { nil }
            let header = CardHeaderContent(title: text.title, summary: text.summary, isOpen: row.isExpanded, mark: row.mark,
                                           isPinned: row.isPinned, isGuest: row.isGuest,
                                           details: TopicCardWords.details(of: row, inList: true), note: row.note,
                                           hint: topicID.flatMap { CardHint(.topic($0), in: environment.hints) },
                                           notes: TopicCardWords.notes(of: row), cornerWidth: CardCorner.designWidth)
            return TopicCardContent(header: header, holdsSelection: holdsSelection, spine: row.usesRowMarks ? nil : row.mark,
                                    unreadOverHeader: row.usesRowMarks && row.isUnread,
                                    restingOpacity: TopicCardOpacity.resting(row, inList: true),
                                    corner: topicID.map { TopicCardCorner(title: "Settle", identifier: "settle-topic-" + $0,
                                                                          isEnabled: !store.changingTopic) })
        }
    }

    private func layOut() {
        scrollView.frame = bounds
        let width = max(0, bounds.width - 2 * TopicsListMetrics.horizontalInset)
        var bottom = TopicsListMetrics.verticalInset
        for (index, item) in items.enumerated() {
            let top = bottom + (index == 0 ? 0 : TopicsListMetrics.itemSpacing)
            let height = (item as? TopicCardView)?.height(width: width) ?? (item as? TopicsLineView)?.height ?? 0
            item.frame = NSRect(x: TopicsListMetrics.horizontalInset, y: top, width: width, height: height)
            bottom = item.frame.maxY
        }
        // The clip view keeps its offset when the content changes height, inside the new scroll range.
        document.setFrameSize(NSSize(width: bounds.width, height: bottom + TopicsListMetrics.verticalInset))
    }
}
