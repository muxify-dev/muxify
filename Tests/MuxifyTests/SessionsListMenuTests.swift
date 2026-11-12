import AppKit
import XCTest
@testable import MuxifyCore

/// The context menus of the AppKit Sessions list (ADR 0074), which no check of the end-to-end harness opens: what a
/// right-click shows on a card and on a Window row, in order, which items are enabled, the named accessibility actions
/// that the same menu gives, and a Control-click, which is a right-click and no press.
@MainActor final class SessionsListMenuTests: XCTestCase {
    /// A store of a local App Window in which no Topic change runs. It reads no tmux server.
    private let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml"))

    private func window(_ id: String, topicID: String? = nil) -> TmuxWindow {
        var window = TmuxWindow(id: id, sessionID: "$1", sessionName: "atlas", index: 0, name: "editor", paneTitle: "editor",
                                path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false,
                                sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])
        window.topicID = topicID
        return window
    }

    private func row(_ window: TmuxWindow) -> CardRowContent {
        .window(WindowRowContent(window: window, formatted: SidebarFormats.WindowRowContent(text: .init(title: window.name, summary: ""),
                                                                                              left: nil, right: nil)))
    }

    /// The titles of a menu from the top, with "-" for a divider.
    private func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
    }

    private let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!

    /// The menu that a right-click at `point` in the card shows: the menu of the view that the click hits, or of the
    /// first view above it that has one, as AppKit passes a right-click up the responder chain.
    private func menu(at point: NSPoint, on card: SessionCardView) -> NSMenu? {
        var view = card.hitTest(point)
        while let shown = view, shown !== card.superview {
            if let menu = shown.menu(for: rightClick) { return menu }
            view = shown.superview
        }
        return nil
    }

    /// An open card of a Session in a Topic with two Window rows, laid out in a flipped view.
    private func openCard() -> (card: SessionCardView, rows: [NSRect]) {
        let windows = [window("@1", topicID: "t1"), window("@2", topicID: "t1")]
        let session = SessionGroup(id: "$1", name: "atlas", windows: windows)
        let card = SessionCardView(sessionID: "$1")
        card.menuItems = { [store] in SessionsListMenus.card(session, store: store) }
        card.headerActions = { [store] in SessionsListMenus.header(session, store: store) }
        card.windowMenu = { [store] in SessionsListMenus.window($0, store: store) }
        card.show(SessionCardContent(title: "atlas", isOpen: true, rows: windows.map(row)), environment: SessionsListEnvironment())
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 248, height: 400))
        root.addSubview(card)
        card.frame = NSRect(x: 0, y: 0, width: 248, height: card.height(width: 248))
        let rows = (card.accessibilityChildren() as? [NSView] ?? []).compactMap { $0.superview as? WindowRowView }
        var frames: [NSRect] = []
        for row in rows where !frames.contains(row.convert(row.bounds, to: card)) { frames.append(row.convert(row.bounds, to: card)) }
        return (card, frames)
    }

    private let cardMenu = ["Go to Session", "-", "Move to Topic…", "New Topic from this Session", "Remove from Topic", "Remove from Topic and Kill…"]
    private let windowMenu = ["Move Window to Topic…", "New Topic from this Window", "New Topic from this Pane", "-",
                              "Rename Window…", "New Window in atlas", "-", "Copy Path", "Reveal in Finder", "-", "Kill Window…"]

    func testARightClickOnTheHeaderThePaddingsAndTheGapsBetweenRowsShowsTheCardsMenu() throws {
        let (card, rows) = openCard()
        XCTAssertEqual(rows.count, 2)
        let places = [
            "the header": NSPoint(x: 20, y: 8),
            "the padding beside the rows": NSPoint(x: card.bounds.maxX - 1, y: rows[0].midY),
            "the gap between the rows": NSPoint(x: rows[0].midX, y: (rows[0].maxY + rows[1].minY) / 2),
            "the padding under the rows": NSPoint(x: rows[1].midX, y: card.bounds.maxY - 1),
        ]
        for (place, point) in places {
            XCTAssertEqual(titles(menu(at: point, on: card)), cardMenu, place)
        }
    }

    func testARightClickOnAWindowRowShowsTheRowsMenu() throws {
        let (card, rows) = openCard()
        for frame in rows {
            XCTAssertEqual(titles(menu(at: NSPoint(x: frame.midX, y: frame.midY), on: card)), windowMenu)
        }
    }

    func testTheCardOfASessionInNoTopicOffersNoRemove() {
        let session = SessionGroup(id: "$1", name: "atlas", windows: [window("@1")])
        XCTAssertEqual(titles(SessionsListMenus.card(session, store: store).contextMenu()),
                       ["Go to Session", "-", "Move to Topic…", "New Topic from this Session"])
    }

    func testInALocalAppWindowWithNoTopicChangeEveryItemIsEnabled() {
        let session = SessionGroup(id: "$1", name: "atlas", windows: [window("@1", topicID: "t1")])
        for menu in [SessionsListMenus.card(session, store: store), SessionsListMenus.window(window("@1"), store: store)] {
            let items = menu.contextMenu().items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(items.filter { !$0.isEnabled }.map(\.title), [])
        }
    }

    func testAnItemThatIsOffShowsGreyAndItsNamedActionStartsNothing() throws {
        var started: [String] = []
        let menu = SidebarMenu([[SidebarMenuItem(title: "On") { started.append("On") }],
                                [SidebarMenuItem(title: "Off", isEnabled: false) { started.append("Off") }]])

        let shown = menu.contextMenu()
        XCTAssertEqual(titles(shown), ["On", "-", "Off"])
        XCTAssertFalse(shown.autoenablesItems)
        XCTAssertEqual(shown.items.map(\.isEnabled), [true, false, false])
        shown.performActionForItem(at: 0)
        XCTAssertEqual(started, ["On"])

        let actions = menu.accessibilityActions
        XCTAssertEqual(actions.map(\.name), ["Off", "On"], "the named actions are not in the order SwiftUI gives them")
        XCTAssertEqual(actions.first?.handler?(), false)
        XCTAssertEqual(actions.last?.handler?(), true)
        XCTAssertEqual(started, ["On", "On"])
    }

    func testTheCardAndItsHeaderGiveTheirMenusAsNamedActionsAndAWindowRowGivesNone() throws {
        let (card, _) = openCard()
        XCTAssertEqual(card.accessibilityCustomActions()?.map(\.name), cardMenu.filter { $0 != "-" }.reversed())
        let children = card.accessibilityChildren() as? [NSView] ?? []
        let header = try XCTUnwrap(children.first { $0.accessibilityIdentifier() == "session-$1" })
        XCTAssertEqual(header.accessibilityCustomActions()?.map(\.name), ["Go to Session"])
        let parts = children.filter { $0.accessibilityIdentifier().hasPrefix("session-window-") }
        XCTAssertFalse(parts.isEmpty)
        XCTAssertEqual(parts.flatMap { $0.accessibilityCustomActions() ?? [] }.map(\.name), [])
    }

    // MARK: Control-click

    /// A Control-press on the header, a Window row, a Pane row and "N more…" of an open card with two Window rows,
    /// the first with a Pane row under it, presses nothing and starts no drag, and the same press without Control
    /// presses each. The card has no menus, so a Control-click here opens none.
    func testAControlPressOnTheHeaderAWindowRowAPaneRowOrNMorePressesNothingAndStartsNoDrag() throws {
        let card = SessionCardView(sessionID: "$1")
        var pressed: [String] = []
        card.onPress = { pressed.append("header") }
        card.onSelectWindow = { pressed.append($0.id) }
        card.onMoveWindow = { window, _ in pressed.append("moved " + window.id) }
        card.onSelectPane = { pressed.append($0) }
        card.onShowAllRows = { pressed.append("more") }
        card.show(SessionCardContent(title: "atlas", isOpen: true,
                                     rows: [row(window("@1")), .pane(PaneRowContent(paneID: "%1", text: .init(title: "zsh", summary: ""), windowID: "@1")),
                                            row(window("@2"))],
                                     moreCount: 2),
                  environment: SessionsListEnvironment())
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        host.contentView = root
        defer { host.contentView = nil }
        root.addSubview(card)
        card.frame = NSRect(x: 6, y: 4, width: 248, height: card.height(width: 248))

        let children = card.accessibilityChildren() as? [NSView] ?? []
        func part(_ identifier: String) throws -> NSView {
            let part = try XCTUnwrap(children.first { $0.accessibilityIdentifier() == identifier }, identifier)
            // A Window row's parts are its accessibility rows: the row is their superview.
            return identifier.hasPrefix("session-window-") ? try XCTUnwrap(part.superview, identifier) : part
        }
        let parts = try [("header", part("session-$1")), ("@1", part("session-window-@1")), ("%1", part("pane-%1")),
                         ("more", part("session-$1-more"))]
        let rows = try ["session-window-@1", "pane-%1", "session-window-@2"].map(part)
        func frames() -> [NSRect] { rows.map { $0.convert($0.bounds, to: card) } }
        let before = frames()

        func click(_ view: NSView, with flags: NSEvent.ModifierFlags, moving move: CGFloat = 0) {
            let point = view.convert(NSPoint(x: 40, y: view.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, down: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: point.y - down), modifierFlags: flags, timestamp: 0,
                                   windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, down: 0))
            if move != 0 {
                for step in [10, move] { view.mouseDragged(with: event(.leftMouseDragged, down: step)) }
            }
            view.mouseUp(with: event(.leftMouseUp, down: move))
        }

        for (name, view) in parts {
            click(view, with: .control)
            click(view, with: .control, moving: 30)
            XCTAssertEqual(pressed, [], "a Control-press on \(name) pressed it")
            XCTAssertEqual(frames(), before, "a Control-press that moved on \(name) dragged a row")
        }
        for (name, view) in parts {
            click(view, with: [])
            XCTAssertEqual(pressed.last, name, "a click on \(name) did not press it")
        }
    }
}
