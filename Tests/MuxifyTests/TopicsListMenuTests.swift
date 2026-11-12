import AppKit
import XCTest
@testable import MuxifyCore

/// The context menus of the Topics list and their named accessibility actions (ADR 0075), which both versions of the
/// list read from `TopicsListMenus` and which no check of the end-to-end harness opens: what a right-click shows on a
/// Topic card, a Locked card, a Session line and a Topic row, in order, which items are enabled, the named actions of
/// each card, header, Session line and Topic row, and which view's menu a right-click on an AppKit card reaches.
@MainActor final class TopicsListMenuTests: XCTestCase {
    /// A store of a local App Window in which no Topic change runs and the Config sets no `topics.in_play`. It reads no
    /// tmux server and no Topic record.
    private let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml"))

    private func window(_ id: String, session: String = "$1", topicID: String? = "menustest") -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "api/menustest", index: 0, name: "editor", paneTitle: "editor",
                   path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topicID)
    }

    private func session(_ id: String, topic: TopicGroupID = .topic("menustest"), windows: [TmuxWindow]) -> TopicsModel.Session {
        TopicsModel.Session(id: TopicSessionID(topic: topic, session: id), baseName: "api",
                            contents: .live(TopicsModel.SessionChildren(windows: windows, panes: nil, agents: [:])))
    }

    private func topic(state: TopicState = .live, kind: TopicsModel.Row.Kind = .open, isPinned: Bool = false, note: String? = nil,
                       sessions: [TopicsModel.Session] = []) -> TopicsModel.Row {
        TopicsModel.Row(id: .topic("menustest"), title: "Menus", kind: kind, mark: nil, isPinned: isPinned, sessions: sessions,
                        isExpanded: !sessions.isEmpty, state: state, note: note)
    }

    private func locked(isGuest: Bool = false) -> TopicsModel.Row {
        TopicsModel.Row(id: .locked("$9"), title: "dune", kind: .open, mark: nil, isGuest: isGuest, isPinned: false,
                        sessions: [session("$9", topic: .noTopic, windows: [window("@9", session: "$9", topicID: nil)])],
                        isExpanded: false, state: nil)
    }

    /// Move Up moves the card, and Move Down finds it at the end.
    private let steps = CardSteps(up: .takePlace, down: .atEnd)

    /// The titles of a menu from the top, with "-" for a divider.
    private func titles(_ menu: SidebarMenu) -> [String] {
        menu.contextMenu().items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// The titles of the items that are off.
    private func off(_ menu: SidebarMenu) -> [String] {
        menu.contextMenu().items.filter { !$0.isSeparatorItem && !$0.isEnabled }.map(\.title)
    }

    /// The names of the named actions, in the order SwiftUI gives them: from the last item to the first.
    private func names(_ menu: SidebarMenu) -> [String] { menu.accessibilityActions.map(\.name) }

    // MARK: Topic cards

    func testATopicCardsMenuListsItsItemsInTheirGroupsAndOrder() {
        XCTAssertEqual(titles(TopicsListMenus.topicCard(topic(), steps: steps, store: store)),
                       ["Go to Topic", "-", "Forget Topic…", "Settle Topic…", "-", "Rename Topic…", "Set Topic Note…", "Add a Session…",
                        "-", "Pin Topic", "Move Up", "Move Down"])
    }

    func testADormantPinnedTopicWithANoteOffersReopenStartFreshUnpinAndClearTopicNote() {
        let row = topic(state: .dormant, isPinned: true, note: "Repro with seed 4411")
        XCTAssertEqual(titles(TopicsListMenus.topicCard(row, steps: steps, store: store)),
                       ["Go to Topic", "-", "Reopen", "Start Fresh", "Forget Topic…", "Settle Topic…", "-", "Rename Topic…",
                        "Set Topic Note…", "Clear Topic Note", "Add a Session…", "-", "Unpin Topic", "Move Up", "Move Down"])
    }

    func testTheCardOfNoTopicOffersGoToTopicOnly() {
        let row = TopicsModel.Row(id: .noTopic, title: "No Topic", kind: .open, mark: nil, isPinned: false, sessions: [],
                                  isExpanded: false, state: nil)
        XCTAssertEqual(titles(TopicsListMenus.topicCard(row, steps: steps, store: store)), ["Go to Topic"])
        XCTAssertEqual(names(TopicsListMenus.topicHeader(row, steps: steps, store: store)), ["Go to Topic"])
    }

    /// The header's list is not the card's menu: it has no Settle Topic…, no Reopen and no Start Fresh, and another
    /// order, as the SwiftUI header gives it.
    func testATopicCardsHeaderGivesAnotherListThanTheMenu() {
        let row = topic(state: .dormant, isPinned: true, note: "Repro with seed 4411")
        XCTAssertEqual(names(TopicsListMenus.topicHeader(row, steps: steps, store: store)),
                       ["Add a Session…", "Clear Topic Note", "Set Topic Note…", "Rename Topic…", "Move Down", "Move Up", "Unpin Topic",
                        "Forget Topic…", "Go to Topic"])
        XCTAssertEqual(names(TopicsListMenus.topicCard(row, steps: steps, store: store)),
                       ["Move Down", "Move Up", "Unpin Topic", "Add a Session…", "Clear Topic Note", "Set Topic Note…", "Rename Topic…",
                        "Settle Topic…", "Forget Topic…", "Start Fresh", "Reopen", "Go to Topic"])
    }

    func testInALocalAppWindowWithNoTopicChangeOnlyAMoveTheCardCannotMakeIsOff() {
        let row = topic(state: .dormant, note: "Repro")
        XCTAssertEqual(off(TopicsListMenus.topicCard(row, steps: steps, store: store)), ["Move Down"])
        XCTAssertEqual(off(TopicsListMenus.topicCard(row, steps: CardSteps(up: .hidden, down: .bench), store: store)), ["Move Up"])
        XCTAssertEqual(off(TopicsListMenus.topicCard(row, steps: CardSteps(up: .bench, down: .makeGuest), store: store)), [])
        let header = TopicsListMenus.topicHeader(row, steps: steps, store: store)
        XCTAssertEqual(header.items.filter { !$0.isEnabled }.map(\.title), ["Move Down"])
    }

    func testAnItemThatIsOffStartsNothingAsANamedAction() throws {
        let actions = TopicsListMenus.topicCard(topic(), steps: steps, store: store).accessibilityActions
        let moveDown = try XCTUnwrap(actions.first { $0.name == "Move Down" })
        XCTAssertEqual(moveDown.handler?(), false)
    }

    func testASettledCardOffersForgetTopicAsItsMenuAndItsHeadersList() {
        let row = topic(kind: .settled(outcome: "", settledDate: nil))
        XCTAssertEqual(titles(TopicsListMenus.settledCard(row, store: store)), ["Forget Topic…"])
        XCTAssertEqual(off(TopicsListMenus.settledCard(row, store: store)), [])
    }

    // MARK: Locked cards

    func testALockedCardsMenuAndItsHeadersList() {
        XCTAssertEqual(titles(TopicsListMenus.lockedCard(locked(), sessionID: "$9", steps: steps, store: store)),
                       ["Go to Session", "-", "Unlock Session", "Rename Session…", "Move to Topic…", "New Topic from this Session",
                        "Kill Session…", "Move Up", "Move Down"])
        XCTAssertEqual(names(TopicsListMenus.lockedHeader(locked(), sessionID: "$9", steps: steps, store: store)),
                       ["Move Down", "Move Up", "Kill Session…", "New Topic from this Session", "Move to Topic…", "Rename Session…",
                        "Unlock Session", "Go to Session"])
        XCTAssertEqual(off(TopicsListMenus.lockedCard(locked(), sessionID: "$9", steps: steps, store: store)), ["Move Down"])
    }

    func testALockedGuestOffersBenchInPlaceOfUnlock() {
        let menu = TopicsListMenus.lockedCard(locked(isGuest: true), sessionID: "$9", steps: steps, store: store)
        XCTAssertEqual(Array(titles(menu).prefix(3)), ["Go to Session", "-", "Bench"])
        XCTAssertFalse(titles(menu).contains("Unlock Session"))
    }

    // MARK: Session lines

    func testASessionLinesMenuIsItsOrderItemsThenTheTopicMembershipItems() throws {
        let first = window("@1")
        let row = topic(sessions: [session("$1", windows: [first]), session("$2", windows: [window("@2", session: "$2")])])
        let order = try XCTUnwrap(SessionLineOrder(row, sessionID: "$1", store: store))
        XCTAssertEqual(titles(TopicsListMenus.sessionLine(order, window: first, store: store)),
                       ["Move Up", "Move Down", "-", "Move to Topic…", "New Topic from this Session", "Remove from Topic",
                        "Remove from Topic and Kill…"])
        // The first Session cannot move up, the last cannot move down.
        XCTAssertEqual(off(TopicsListMenus.sessionLine(order, window: first, store: store)), ["Move Up"])
        let last = try XCTUnwrap(SessionLineOrder(row, sessionID: "$2", store: store))
        XCTAssertEqual(off(TopicsListMenus.sessionLine(last, window: first, store: store)), ["Move Down"])
        XCTAssertEqual(names(TopicsListMenus.sessionLineActions(order, store: store)), ["Move Down", "Move Up"])
    }

    func testATopicWithAnOrderTheUserGaveOffersSortSessionsByCreation() {
        let order = SessionLineOrder(topicID: "menustest", sessionID: "$1", above: nil, below: "$2", isManual: true)
        XCTAssertEqual(titles(TopicsListMenus.sessionLine(order, window: window("@1"), store: store)).prefix(4),
                       ["Move Up", "Move Down", "Sort Sessions by Creation", "-"])
        XCTAssertEqual(names(TopicsListMenus.sessionLineActions(order, store: store)),
                       ["Sort Sessions by Creation", "Move Down", "Move Up"])
    }

    func testASessionLineOfASettledTopicDoesNotMoveAndOffersOnlyTheTopicMembershipItems() {
        let row = topic(kind: .settled(outcome: "", settledDate: nil), sessions: [session("$1", windows: [window("@1")])])
        XCTAssertNil(SessionLineOrder(row, sessionID: "$1", store: store))
        XCTAssertEqual(titles(TopicsListMenus.sessionLine(nil, window: window("@1"), store: store)).first, "Move to Topic…")
        XCTAssertEqual(names(TopicsListMenus.sessionLineActions(nil, store: store)), [])
    }

    // MARK: Topic rows

    func testATopicRowsMenuIsTheTopicMembershipItemsAndItsNamedActionIsMoveWindowToTopic() {
        XCTAssertEqual(titles(TopicsListMenus.window(window("@1"), store: store)),
                       ["Move Window to Topic…", "New Topic from this Window", "New Topic from this Pane"])
        XCTAssertEqual(off(TopicsListMenus.window(window("@1"), store: store)), [])
        XCTAssertEqual(names(TopicsListMenus.windowActions(window("@1"), store: store)), ["Move Window to Topic…"])
    }

    // MARK: The AppKit card

    private let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!

    /// The menu that a right-click at `point` in the card shows: the menu of the view that the click hits, or of the
    /// first view above it that has one, as AppKit passes a right-click up the responder chain. Nil when none has one.
    private func menu(at point: NSPoint, on card: TopicCardView) -> [String]? {
        // A view's hit test takes the point in its superview's coordinates.
        var view = card.hitTest(card.convert(point, to: card.superview))
        while let shown = view, shown !== card.superview {
            if let menu = shown.menu(for: rightClick) { return menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }
            view = shown.superview
        }
        return nil
    }

    /// The open card of a Topic with one Session of two Window rows, with Settle in its corner, laid out in a flipped
    /// view and wired as the Topics list wires it.
    private func openCard() throws -> (card: TopicCardView, row: TopicsModel.Row, parts: [String: NSView]) {
        let windows = [window("@1"), window("@2")]
        let row = topic(sessions: [session("$1", windows: windows)])
        let card = TopicCardView(cardID: row.id)
        card.menuItems = { [store, steps] in TopicsListMenus.topicCard(row, steps: steps, store: store) }
        card.headerActions = { [store, steps] in TopicsListMenus.topicHeader(row, steps: steps, store: store) }
        card.sessionMenu = { [store] in TopicsListMenus.sessionLine(SessionLineOrder(row, sessionID: $0, store: store), window: windows[0], store: store) }
        card.sessionActions = { [store] in TopicsListMenus.sessionLineActions(SessionLineOrder(row, sessionID: $0, store: store), store: store) }
        card.windowMenu = { [store] in TopicsListMenus.window($0, store: store) }
        card.windowActions = { [store] in TopicsListMenus.windowActions($0, store: store) }
        let rows = windows.map { CardRowContent.window(WindowRowContent(window: $0, formatted: .init(text: .init(title: $0.name, summary: ""),
                                                                                                  left: nil, right: nil),
                                                                        inTopicsList: true)) }
        card.show(TopicCardContent(header: CardHeaderContent(title: "Menus", isOpen: true), corner: TopicCardCorner(title: "Settle", identifier: "settle-topic-menustest"),
                                   blocks: [TopicCardBlock(sessionID: "$1", line: "api", rows: rows)]),
                  environment: SidebarListEnvironment())
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 248, height: 400))
        root.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 248, height: card.height(width: 248))
        var parts: [String: NSView] = [:]
        func collect(_ element: Any) {
            guard let view = element as? NSView else { return }
            if !view.accessibilityIdentifier().isEmpty { parts[view.accessibilityIdentifier()] = view }
            for child in view.accessibilityChildren() ?? [] { collect(child) }
        }
        for child in card.accessibilityChildren() ?? [] { collect(child) }
        return (card, row, parts)
    }

    private func centre(of view: NSView, in card: TopicCardView) -> NSPoint {
        let frame = view.convert(view.bounds, to: card)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    func testARightClickOnTheHeaderShowsTheCardsMenuAndOnASessionLineOrAWindowRowItsOwn() throws {
        let (card, row, parts) = try openCard()
        let cardMenu = titles(TopicsListMenus.topicCard(row, steps: steps, store: store))
        let header = try XCTUnwrap(parts["topic-menustest"])
        XCTAssertEqual(menu(at: NSPoint(x: 20, y: 8), on: card), cardMenu, "the header")
        XCTAssertEqual(menu(at: NSPoint(x: card.bounds.maxX - 2, y: header.frame.maxY + 20), on: card), cardMenu, "the padding")
        XCTAssertEqual(menu(at: centre(of: try XCTUnwrap(parts["topic-menustest-session-$1"]), in: card), on: card),
                       ["Move Up", "Move Down", "-", "Move to Topic…", "New Topic from this Session", "Remove from Topic",
                        "Remove from Topic and Kill…"], "the Session line")
        for id in ["topic-window-@1", "topic-window-@2"] {
            XCTAssertEqual(menu(at: centre(of: try XCTUnwrap(parts[id]), in: card), on: card),
                           ["Move Window to Topic…", "New Topic from this Window", "New Topic from this Pane"], id)
        }
    }

    func testTheCardItsHeaderASessionLineAndATopicRowGiveTheirNamedActions() throws {
        let (_, row, parts) = try openCard()
        let card = try XCTUnwrap(parts["card-topic-menustest"])
        XCTAssertEqual(card.accessibilityCustomActions()?.map(\.name), names(TopicsListMenus.topicCard(row, steps: steps, store: store)))
        XCTAssertEqual(try XCTUnwrap(parts["topic-menustest"]).accessibilityCustomActions()?.map(\.name),
                       names(TopicsListMenus.topicHeader(row, steps: steps, store: store)))
        XCTAssertEqual(try XCTUnwrap(parts["topic-menustest-session-$1"]).accessibilityCustomActions()?.map(\.name), ["Move Down", "Move Up"])
        XCTAssertEqual(try XCTUnwrap(parts["topic-window-@1"]).accessibilityCustomActions()?.map(\.name), ["Move Window to Topic…"])
    }
}
