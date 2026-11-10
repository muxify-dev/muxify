import AppKit
import MuxifyCore

/// The Sidebar's Sessions list in AppKit (ADR 0074): a scroll view with one card for each Session, in the order of
/// the SwiftUI list. Its views lay out by frames, and it reads the store through `ObservedUpdate`.
final class SessionsListView: NSView {
    private let store: WorkspaceStore
    /// The values from the SwiftUI Sidebar. The list draws again when one changes.
    var environment: SessionsListEnvironment {
        didSet {
            if environment != oldValue { update.run() }
        }
    }
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    /// The cards from the top of the list.
    private var cards: [SessionCardView] = []
    private lazy var update = ObservedUpdate { [weak self] in self?.render() }

    init(store: WorkspaceStore, environment: SessionsListEnvironment) {
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
        scrollView.setAccessibilityIdentifier("sessions-list")
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

    /// Makes the cards the Sessions of the store, each with what it shows now.
    private func render() {
        // Text follows the lightness of the Ghostty theme, as the SwiftUI Sidebar's colour scheme does.
        let themed = environment.chromeTheme.flatMap { NSAppearance(named: $0.isDark ? .darkAqua : .aqua) }
        if appearance?.name != themed?.name { appearance = themed }
        var kept = Dictionary(cards.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        cards = store.sessions.map { session in
            let card = kept.removeValue(forKey: session.id) ?? SessionCardView(sessionID: session.id)
            card.show(title: store.sidebarText(.session, context: store.sidebarFormatContexts.sessions[session.id]).title,
                      environment: environment)
            return card
        }
        // The order of the subviews is the order of the accessibility rows.
        document.subviews = cards
        layOut()
    }

    private func layOut() {
        scrollView.frame = bounds
        let cardWidth = max(0, bounds.width - 2 * SessionsListMetrics.horizontalInset)
        var bottom = SessionsListMetrics.verticalInset
        for (index, card) in cards.enumerated() {
            let top = bottom + (index == 0 ? 0 : SessionsListMetrics.cardSpacing)
            card.frame = NSRect(x: SessionsListMetrics.horizontalInset, y: top, width: cardWidth, height: card.height(width: cardWidth))
            bottom = card.frame.maxY
        }
        document.setFrameSize(NSSize(width: bounds.width, height: bottom + SessionsListMetrics.verticalInset))
    }
}

/// A view that counts its subviews' frames from its top left corner, as the lists and cards of the Sidebar do.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
