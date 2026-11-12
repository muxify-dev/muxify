import AppKit
import MuxifyCore

/// The Sidebar's Sessions list in AppKit (ADR 0074): a scroll view with one card for each Session, in the order of
/// the SwiftUI list. Its views lay out by frames, and it reads the store through `ObservedUpdate`. It owns its scroll
/// view: it glides to the card of the Location's Session by moving its own clip view, and the header of an open card
/// sticks to the top while the card's rows scroll under it.
final class SessionsListView: NSView, SidebarList {
    private let store: WorkspaceStore
    /// The values from the SwiftUI Sidebar. The list draws again when one changes.
    var environment: SidebarListEnvironment {
        didSet {
            if environment != oldValue { update.run() }
        }
    }
    private let scrollView = NSScrollView()
    private let document = FlippedView()
    /// "No windows" or "No tmux server" in the middle of the list while tmux has no Window. It stands over the scroll
    /// view, after it among the accessibility rows, as the SwiftUI list's overlay does.
    private let emptyState = SidebarLabel()
    /// The cards from the top of the list.
    private var cards: [SessionCardView] = []
    /// The cards whose "N more…" the user pressed, by Session ID. They show all their rows from then on.
    private var showingAllRows: Set<String> = []
    /// The Session of the Location's Window at the last update. When it changes, the list glides to its card.
    private var locationSessionID: String?
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
        scrollView.setAccessibilityIdentifier("sessions-list")
        addSubview(scrollView)
        emptyState.ink = .secondary
        // Wraps where it does not fit, as SwiftUI's `Text` does.
        emptyState.wraps = true
        emptyState.setAccessibilityRole(.staticText)
        addSubview(emptyState)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidMove), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        // As SwiftUI's `onChange`, the Location the list starts with is no move.
        locationSessionID = store.selectedWindow?.sessionID
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
        let themed = environment.appearance
        if appearance?.name != themed?.name { appearance = themed }
        let empty = SessionsListEmptyState.text(store)
        emptyState.text = empty ?? ""
        emptyState.font = environment.typography.nsFont(for: SessionsListEmptyState.role)
        emptyState.scale = environment.displayScale
        emptyState.isHidden = empty == nil
        emptyState.setAccessibilityElement(empty != nil)
        emptyState.setAccessibilityValue(empty)
        show(store.sessions.map { ($0.id, content(of: $0)) })
        let location = store.selectedWindow?.sessionID
        if location != locationSessionID {
            locationSessionID = location
            if let location { glide(to: location) }
        }
    }

    /// Glides the list so that the card of the Session shows whole, by the least move inside the scroll range, with
    /// ease-out over `SessionsListScroll.glideDuration`. A card that shows whole does not move the list. The glide
    /// moves the list's own clip view to a place it can stand at, so nothing moves after it, also while the pager
    /// scales the list's page.
    private func glide(to sessionID: String) {
        guard let card = cards.first(where: { $0.sessionID == sessionID }) else { return }
        let clip = scrollView.contentView
        guard clip.bounds.height > 0, let y = SessionsListScroll.offset(
            showing: card.frame.minY, to: card.frame.maxY, from: clip.bounds.minY, height: clip.bounds.height,
            end: document.frame.height - clip.bounds.height) else { return }
        let from = clip.bounds.origin, to = NSPoint(x: from.x, y: y)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = SessionsListScroll.glideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(to)
        }
        scrollView.reflectScrolledClipView(clip)
        // The animator starts no NSAnimation, so Diagnostics counts the glide from here (the `sidebar_pager_scroll` suite).
        DisplayLinkProbe.didStart(glide: "SessionsListGlide", in: window, duration: SessionsListScroll.glideDuration, from: from, to: to)
    }

    /// The list scrolled: by the user, by a glide, or because its content got shorter than the offset it had.
    @objc private func clipDidMove() {
        stickHeaders()
    }

    /// Gives each card its top edge in the viewport, so the header of an open card sticks to the viewport's top.
    private func stickHeaders() {
        let top = scrollView.contentView.bounds.minY
        for card in cards { card.stick(cardTop: card.frame.minY - top) }
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
        // As the drop of the SwiftUI row's drag handle.
        card.onMoveWindow = { [weak self] window, placement in self?.store.windowRowDrag.move(window, placement) }
        card.onSelectPane = { [weak self] paneID in self?.selectPane(paneID, of: sessionID) }
        card.onShowAllRows = { [weak self] in self?.showAllRows(of: sessionID) }
        card.menuItems = { [weak self] in self?.menu(of: sessionID, SessionsListMenus.card) }
        card.headerActions = { [weak self] in self?.menu(of: sessionID, SessionsListMenus.header) }
        card.windowMenu = { [weak self] window in self.map { SessionsListMenus.window(window, store: $0.store) } }
        return card
    }

    /// A menu of the Session's card, as the Session is now. Nil once the Session has gone.
    private func menu(of sessionID: String, _ menu: (SessionGroup, WorkspaceStore) -> SidebarMenu) -> SidebarMenu? {
        store.sessions.first { $0.id == sessionID }.map { menu($0, store) }
    }

    /// What the card of the Session shows, read from the models as the SwiftUI card reads it.
    private func content(of session: SessionGroup) -> SessionCardContent {
        SessionCardContent(session, store: store, hints: environment.hints, showsAllRows: showingAllRows.contains(session.id))
    }

    /// A press on a Pane row of the Session's card goes to that Pane, as the Session is now.
    private func selectPane(_ paneID: String, of sessionID: String) {
        for case .pane(let row) in store.topics.sessionChildren[sessionID]?.items ?? [] where row.id == paneID {
            return store.select(row)
        }
    }

    /// A press on "N more…" of the Session's card shows all its rows from then on.
    private func showAllRows(of sessionID: String) {
        showingAllRows.insert(sessionID)
        update.run()
    }

    /// A press on the header of the Session's card, as the Session is now.
    private func press(_ sessionID: String) {
        guard let session = store.sessions.first(where: { $0.id == sessionID }) else { return }
        SessionCardPress(store: store, session: session)()
    }

    private func layOut() {
        scrollView.frame = bounds
        // In the middle, on the nearest pixel, where SwiftUI draws the text of its overlay.
        let empty = emptyState.fit(width: bounds.width), scale = environment.displayScale
        emptyState.frame = NSRect(origin: NSPoint(x: ((bounds.width - empty.width) / 2).rounded(toPixelsOf: scale),
                                                  y: ((bounds.height - empty.height) / 2).rounded(toPixelsOf: scale)), size: empty)
        let cardWidth = max(0, bounds.width - 2 * SessionsListMetrics.horizontalInset)
        var bottom = SessionsListMetrics.verticalInset
        for (index, card) in cards.enumerated() {
            let top = bottom + (index == 0 ? 0 : SessionsListMetrics.cardSpacing)
            card.frame = NSRect(x: SessionsListMetrics.horizontalInset, y: top, width: cardWidth, height: card.height(width: cardWidth))
            bottom = card.frame.maxY
        }
        // The clip view keeps its offset when the content changes height, inside the new scroll range, as the SwiftUI
        // list does.
        document.setFrameSize(NSSize(width: bounds.width, height: bottom + SessionsListMetrics.verticalInset))
        stickHeaders()
    }
}

/// A view that counts its subviews' frames from its top left corner, as the lists and cards of the Sidebar do.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
