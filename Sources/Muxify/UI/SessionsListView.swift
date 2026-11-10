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
        show(store.sessions.map { ($0.id, content(of: $0)) })
    }

    /// Shows a card for each of the Sessions, from the top of the list, with its content. When a card that already
    /// showed opens or closes, it glides to its new height and the cards below it move with it, with ease-out over
    /// `CardMotion.openDuration`, as the SwiftUI list animates them.
    func show(_ sessions: [(id: String, content: SessionCardContent)]) {
        var kept = Dictionary(cards.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        var opens = false
        let shown: [(card: SessionCardView, content: SessionCardContent)] = sessions.map { session in
            guard let card = kept.removeValue(forKey: session.id) else { return (card(of: session.id), session.content) }
            opens = opens || card.isOpen != session.content.isOpen
            return (card, session.content)
        }
        let change = { [self] in
            for (card, content) in shown { card.show(content, environment: environment) }
            let cards = shown.map(\.card)
            // The order of the subviews is the order of the accessibility rows.
            if self.cards != cards {
                self.cards = cards
                document.subviews = cards
            }
            layOut()
        }
        if opens, let layer = document.layer {
            LayerGlide.run(under: layer, duration: CardMotion.openDuration, timing: CAMediaTimingFunction(name: .easeOut), change: change)
        } else {
            change()
        }
    }

    private func card(of sessionID: String) -> SessionCardView {
        let card = SessionCardView(sessionID: sessionID)
        card.onPress = { [weak self] in self?.press(sessionID) }
        // As the tap of the SwiftUI row's drag handle.
        card.onSelectWindow = { [weak self] window in self?.store.windowRowDrag.select(window) }
        return card
    }

    /// What the card of the Session shows, read from the models as the SwiftUI card reads it.
    private func content(of session: SessionGroup) -> SessionCardContent {
        let model = store.topics
        let isOpen = store.openSessionCards.contains(session.name)
        let isLocked = model.lockedSessionIDs.contains(session.id)
        let formatted = store.sidebarText(.session, context: store.sidebarFormatContexts.sessions[session.id])
        return SessionCardContent(title: formatted.title, summary: formatted.summary, isOpen: isOpen,
                                  holdsSelection: SessionCardPress(store: store, session: session).holdsSelection,
                                  mark: model.sessionMarks[session.id].map(CardMark.agent), isLocked: isLocked,
                                  isGuest: isLocked && store.topicConfig.inPlay != nil,
                                  hasBell: session.windows.contains(where: \.hasBell),
                                  hint: CardHint(.session(session.id), in: environment.hints),
                                  rows: isOpen ? rows(of: session) : [])
    }

    /// The Window rows of the Session's open card, in tmux's order, read from the models as the SwiftUI list reads them.
    private func rows(of session: SessionGroup) -> [WindowRowContent] {
        (store.topics.sessionChildren[session.id]?.items ?? []).compactMap { item in
            guard case .window(let window) = item else { return nil }
            return WindowRowContent(
                window: window, formatted: store.sidebarWindowRow(window), isSelected: window.id == store.selectedWindowID,
                tabCount: store.tabCount(for: window), isGitViewOpen: store.isGitViewOpen(in: window.id),
                usesMainWorkingCopy: TopicsModel.usesMainWorkingCopy(
                    window, record: store.topicWatcher.records.first { $0.id == window.topicID }, sessionPaths: store.sessionPaths))
        }
    }

    /// A press on the header of the Session's card, as the Session is now.
    private func press(_ sessionID: String) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        SessionCardPress(store: store, session: session)()
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
