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

/// The Sidebar's Topics list in AppKit (ADR 0075): a scroll view with one card for each Topic card and Locked card of
/// the Topics model's list, in the model's order, with the gaps and insets of the SwiftUI list. Its views lay out by
/// frames, and it reads the store through `ObservedUpdate`. The SwiftUI Sidebar shows the Settled group under it.
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
    /// The cards from the top of the list.
    private var cards: [TopicCardView] = []
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

    /// Makes the cards the Topic cards and Locked cards of the model's list, each with what it shows now.
    private func render() {
        let themed = environment.appearance
        if appearance?.name != themed?.name { appearance = themed }
        var kept = Dictionary(cards.map { ($0.cardID, $0) }, uniquingKeysWith: { first, _ in first })
        let shown: [TopicCardView] = store.topics.list.compactMap { item in
            guard case .card(let row) = item else { return nil }
            let card = kept.removeValue(forKey: row.id) ?? TopicCardView(cardID: row.id)
            card.show(title: title(of: row), environment: environment)
            return card
        }
        // The order of the subviews is the order of the accessibility rows.
        if cards != shown {
            cards = shown
            document.subviews = shown
        }
        layOut()
    }

    /// The card's title, read as the SwiftUI card reads it: a Topic's from the Topic card Formats, a Locked Session's
    /// from the Session card Formats.
    private func title(of row: TopicsModel.Row) -> String {
        if case .locked(let sessionID) = row.id {
            return store.sidebarText(.session, context: store.sidebarFormatContexts.sessions[sessionID]).title
        }
        return store.sidebarText(.topic, context: store.sidebarFormatContexts.topics[row.id]).title
    }

    private func layOut() {
        scrollView.frame = bounds
        let cardWidth = max(0, bounds.width - 2 * TopicsListMetrics.horizontalInset)
        var bottom = TopicsListMetrics.verticalInset
        for (index, card) in cards.enumerated() {
            let top = bottom + (index == 0 ? 0 : TopicsListMetrics.itemSpacing)
            card.frame = NSRect(x: TopicsListMetrics.horizontalInset, y: top, width: cardWidth, height: card.height)
            bottom = card.frame.maxY
        }
        document.setFrameSize(NSSize(width: bounds.width, height: bottom + TopicsListMetrics.verticalInset))
    }
}
