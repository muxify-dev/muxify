import AppKit
import XCTest
@testable import MuxifyCore

/// The drag of a Window row in the AppKit Sessions list (ADR 0074), where no dump of the end-to-end harness shows it:
/// the click, the lift, the units that make room, the bounds, the drop and the motion.
@MainActor final class SessionCardDragTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil }
        windows = []
        super.tearDown()
    }

    private func tmuxWindow(_ id: String, index: Int, panes: Int = 1) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$1", sessionName: "atlas", index: index, name: "w\(index)", paneTitle: "w\(index)",
                   path: "/work/app", command: "zsh", isActive: index == 0, paneCount: panes, hasBell: false,
                   sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])
    }

    private func windowRow(_ id: String, index: Int, panes: Int = 1) -> CardRowContent {
        let window = tmuxWindow(id, index: index, panes: panes)
        return .window(WindowRowContent(window: window, formatted: SidebarFormats.WindowRowContent(
            text: .init(title: window.name, summary: ""), left: nil, right: nil)))
    }

    private func paneRow(_ id: String, of window: String) -> CardRowContent {
        .pane(PaneRowContent(paneID: id, text: .init(title: "zsh", summary: ""), windowID: window))
    }

    /// @1 with its two Pane rows under it, then @2 and @3.
    private var threeWindows: [CardRowContent] {
        [windowRow("@1", index: 0, panes: 2), paneRow("%1", of: "@1"), paneRow("%2", of: "@1"),
         windowRow("@2", index: 1), windowRow("@3", index: 2)]
    }

    /// An open card with `rows`, in a window, as the list shows it.
    private func card(_ rows: [CardRowContent], movesWindows: Bool = true,
                      environment: SessionsListEnvironment = SessionsListEnvironment()) -> SessionCardView {
        let card = SessionCardView(sessionID: "$1")
        card.show(SessionCardContent(title: "atlas", isOpen: true, rows: rows, movesWindows: movesWindows), environment: environment)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        window.contentView = root
        root.wantsLayer = true
        root.addSubview(card)
        card.frame = NSRect(x: 6, y: 4, width: 248, height: card.height(width: 248))
        window.displayIfNeeded()
        windows.append(window)
        return card
    }

    private func row(_ id: String, of card: SessionCardView) throws -> WindowRowView {
        try XCTUnwrap(card.unit(id)?.rows.first as? WindowRowView, id)
    }

    /// A point on the row's title, in the window, where a press goes.
    private func point(on view: NSView) -> NSPoint { view.convert(NSPoint(x: 40, y: view.bounds.midY), to: nil) }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Where the last press went down, in the window.
    private var pressedAt = NSPoint.zero

    private func press(_ row: WindowRowView) {
        pressedAt = point(on: row)
        row.mouseDown(with: event(.leftMouseDown, at: pressedAt, in: row))
    }

    /// Moves the pointer down by each of `moves` from where the press went down.
    private func move(_ row: WindowRowView, by moves: CGFloat...) {
        for move in moves { row.mouseDragged(with: event(.leftMouseDragged, at: NSPoint(x: pressedAt.x, y: pressedAt.y - move), in: row)) }
    }

    private func release(_ row: WindowRowView, at move: CGFloat) {
        row.mouseUp(with: event(.leftMouseUp, at: NSPoint(x: pressedAt.x, y: pressedAt.y - move), in: row))
    }

    /// The frame of the view in the card.
    private func frame(_ view: NSView, in card: SessionCardView) -> NSRect { view.convert(view.bounds, to: card) }

    private func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func spring(_ animation: CAAnimation?) -> (duration: Double, bounce: Double)? {
        (animation as? CASpringAnimation).map { ($0.perceptualDuration, Double($0.bounce)) }
    }

    private func controlPoints(_ timing: CAMediaTimingFunction?) -> [Float] {
        (1...2).flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            timing?.getControlPoint(at: index, values: &point)
            return point
        }
    }

    // MARK: The click

    func testAPressThatLetsGoWithoutAMoveGoesToTheWindowAndLiftsNothing() throws {
        let card = card(threeWindows)
        var selected: [String] = []
        card.onSelectWindow = { selected.append($0.id) }
        card.onMoveWindow = { _, _ in XCTFail("a click moved a Window") }
        let row = try row("@2", of: card)
        let unit = try XCTUnwrap(card.unit("@2"))
        XCTAssertTrue(row.acceptsFirstMouse(for: nil), "the drag does not work on the first click")
        XCTAssertTrue(row.isDraggable, "no open hand over a row that a press can drag")

        press(row)
        XCTAssertEqual(card.windowDrag.phase, .pressing("@2"))
        XCTAssertEqual(unit.shownScale, ListLift.pressScale, accuracy: 0.0001, "a pressed row does not sink")
        let sinks = try XCTUnwrap(unit.scaleMotion as? CABasicAnimation)
        XCTAssertEqual(sinks.duration, 0.12)
        XCTAssertEqual(controlPoints(sinks.timingFunction), controlPoints(CAMediaTimingFunction(name: .easeOut)))
        XCTAssertEqual(unit.plateOpacity, 1, "a pressed row does not stand on its plate")
        XCTAssertEqual(unit.shadowOpacity, 0, "a pressed row has the shadow of a lifted one")

        // A move of a few points is still a click.
        move(row, by: 3)
        XCTAssertEqual(card.windowDrag.phase, .pressing("@2"))
        release(row, at: 3)

        XCTAssertEqual(selected, ["@2"])
        XCTAssertEqual(card.windowDrag.phase, .idle)
        XCTAssertEqual(unit.shownScale, 1, accuracy: 0.0001)
        XCTAssertEqual(unit.plateOpacity, 0)
    }

    func testARowInACardWithOneWindowOrWhileTheDragIsOffDoesNotLiftAndItsClickStillGoes() throws {
        let one = card([windowRow("@1", index: 0, panes: 2), paneRow("%1", of: "@1"), paneRow("%2", of: "@1")])
        let off = card(threeWindows, movesWindows: false)
        for (card, id) in [(one, "@1"), (off, "@2")] {
            var selected: [String] = []
            card.onSelectWindow = { selected.append($0.id) }
            let row = try row(id, of: card)
            let unit = try XCTUnwrap(card.unit(id))
            let before = frame(unit, in: card)
            XCTAssertFalse(row.isDraggable, "the open hand over a row that cannot move")

            press(row)
            move(row, by: 10, 30)
            XCTAssertEqual(card.windowDrag.phase, .idle, "a row that cannot move lifted")
            XCTAssertEqual(frame(unit, in: card), before, "a row that cannot move followed the pointer")
            XCTAssertEqual(unit.shownScale, 1, accuracy: 0.0001)
            XCTAssertEqual(spring(unit.scaleMotion)?.duration, 0.25, "the cancelled press does not end on the spring of 0.25 seconds")
            XCTAssertEqual(spring(unit.scaleMotion)?.bounce, 0)
            release(row, at: 30)
            XCTAssertEqual(selected, [], "a press that moved on a row that cannot move is a click")

            press(row)
            release(row, at: 0)
            XCTAssertEqual(selected, [id], "a click does not go to the Window")
        }
    }

    // MARK: The drag

    func testALiftedRowFollowsThePointerWithItsPaneRowsAndTheOthersMakeRoomWhereStackLayoutLandsIt() throws {
        let card = card(threeWindows)
        let row = try row("@1", of: card)
        let units = try ["@1", "@2", "@3"].map { try XCTUnwrap(card.unit($0)) }
        let panes = try XCTUnwrap(units[0].rows.last as? NSView)
        let tops = units.map { frame($0, in: card).minY }
        let paneTop = frame(panes, in: card).minY
        let heights = units.map(\.bounds.height)
        let order: [StackSlot<String>] = [.item("@1"), .item("@2"), .item("@3")]
        let layout = StackLayout(heights: Dictionary(uniqueKeysWithValues: zip(order, heights)), spacing: CardSpacing.row)
        let grab = row.convert(NSPoint(x: 0, y: row.bounds.midY), to: units[0]).y

        press(row)
        move(row, by: 10, 20)
        XCTAssertEqual(card.windowDrag.phase, .lifted("@1"))
        XCTAssertNil(card.windowDrag.placement)
        XCTAssertEqual(frame(units[0], in: card).minY, tops[0] + 20, accuracy: 0.001, "the lifted row does not follow the pointer")
        XCTAssertEqual(frame(panes, in: card).minY, paneTop + 20, accuracy: 0.001, "the Pane rows do not move with their Window row")

        // The pointer is 4 points above the middle of @2. The tall unit of @1 stops at the bottom of @3 on the way.
        let middle = heights[0] + CardSpacing.row + heights[1] / 2 - grab
        move(row, by: middle - 4)
        let short = layout.follow("@1", moved: middle - 4, grab: grab, in: order)
        XCTAssertNil(short.landing)
        XCTAssertNil(card.windowDrag.placement)
        XCTAssertEqual(card.windowDrag.translation, short.translation, "the bounds are not StackLayout's")
        XCTAssertEqual(frame(units[0], in: card).minY, tops[0] + short.translation, accuracy: 0.001)
        XCTAssertEqual(frame(panes, in: card).minY, paneTop + short.translation, accuracy: 0.001)
        XCTAssertEqual(frame(units[1], in: card).minY, tops[1], "a row made room before the pointer passed its middle")

        // Past the middle of @2, the lifted row lands after it, as StackLayout says, and @2 moves up into its place.
        let far = middle + 4
        move(row, by: far)
        let expected = layout.follow("@1", moved: far, grab: grab, in: order)
        XCTAssertEqual(expected.landing, .place(.after("@2")))
        XCTAssertEqual(card.windowDrag.placement, .after("@2"))
        XCTAssertEqual(card.windowDrag.translation, expected.translation)
        XCTAssertEqual(frame(units[1], in: card).minY, tops[0], accuracy: 0.001, "@2 did not move into @1's place")
        XCTAssertEqual(frame(units[2], in: card).minY, tops[2], "@3 moved")
        XCTAssertEqual(frame(card.dropSlot, in: card).minY, tops[0] + heights[1] + CardSpacing.row, accuracy: 0.001,
                       "the placeholder is not at @1's place after @2")
        XCTAssertEqual(card.dropSlot.frame.height, heights[0])
        XCTAssertTrue(card.dropSlot.shows)

        // Far down, it stops at the end of its Session's Windows.
        move(row, by: 1000)
        XCTAssertEqual(card.windowDrag.translation, layout.bounded(1000, of: "@1", in: order), "the bounds are not StackLayout's")
        XCTAssertEqual(card.windowDrag.placement, .after("@3"))
    }

    func testTheDropMovesTheWindowOnceTheRowGlidedAndTheRowStaysUntilTheCardShowsTheNewOrder() throws {
        let card = card(threeWindows)
        var moves: [(String, DropPlacement<String>)] = []
        card.onMoveWindow = { moves.append(($0.id, $1)) }
        card.onSelectWindow = { _ in XCTFail("a drag selected a Window") }
        let row = try row("@1", of: card)
        let units = try ["@1", "@2", "@3"].map { try XCTUnwrap(card.unit($0)) }
        let tops = units.map { frame($0, in: card).minY }
        let heights = units.map(\.bounds.height)
        let grab = row.convert(NSPoint(x: 0, y: row.bounds.midY), to: units[0]).y

        // The pointer passed the middle of @2, and @1 lands after it.
        let moved = heights[0] + CardSpacing.row + heights[1] / 2 + 4 - grab
        press(row)
        move(row, by: 10, moved)
        release(row, at: moved)
        XCTAssertEqual(card.windowDrag.phase, .settling("@1"))
        // Let go, it glides into the placeholder, after @2.
        let landed = tops[0] + heights[1] + CardSpacing.row
        XCTAssertEqual(frame(units[0], in: card).minY, landed, accuracy: 0.001)
        XCTAssertEqual(spring(units[0].layer?.animation(forKey: "glide-position"))?.duration, 0.3, "the landing is not the spring of 0.3 s")
        XCTAssertEqual(spring(units[0].layer?.animation(forKey: "glide-position"))?.bounce ?? 0, 0.15, accuracy: 0.0001)
        XCTAssertEqual(spring(units[0].scaleMotion)?.duration, 0.25, "the lift does not end on its spring")
        XCTAssertFalse(card.dropSlot.shows, "the placeholder stays after the drop")
        XCTAssertTrue(moves.isEmpty, "the Window moved before the row glided into its place")

        wait(0.4)
        XCTAssertEqual(moves.map(\.0), ["@1"])
        XCTAssertEqual(moves.map(\.1), [.after("@2")])
        XCTAssertEqual(card.windowDrag.phase, .settling("@1"), "the drag ended before the card showed the new order")
        XCTAssertEqual(frame(units[0], in: card).minY, landed, accuracy: 0.001, "the row left its place before the card showed the new order")

        // The card shows the new order: every row is where it already showed.
        let shown = units.map { frame($0, in: card) }
        let rows = threeWindows
        card.show(SessionCardContent(title: "atlas", isOpen: true, rows: [rows[3]] + Array(rows[..<3]) + [rows[4]]),
                  environment: SessionsListEnvironment())
        XCTAssertEqual(card.windowDrag.phase, .idle)
        for (unit, before) in zip(units, shown) {
            XCTAssertEqual(frame(unit, in: card).minY, before.minY, accuracy: 0.001, "\(unit.id) jumped when the card showed the new order")
        }
    }

    func testWhenTheCardDoesNotShowTheNewOrderInTimeTheRowsGoBack() throws {
        let card = card(threeWindows)
        let units = try ["@1", "@2", "@3"].map { try XCTUnwrap(card.unit($0)) }
        let tops = units.map { frame($0, in: card).minY }

        let row = try row("@1", of: card)
        press(row)
        move(row, by: 10, 1000)
        release(row, at: 1000)
        wait(0.4)
        XCTAssertEqual(card.windowDrag.phase, .settling("@1"))
        wait(3.1)
        XCTAssertEqual(card.windowDrag.phase, .idle, "the dropped row waits longer than the SwiftUI drag")
        XCTAssertEqual(units.map { frame($0, in: card).minY }, tops, "the rows did not go back")
        XCTAssertEqual(spring(units[0].layer?.animation(forKey: "glide-position"))?.duration, 0.3)
    }

    func testARowLetGoInItsOwnPlaceGlidesBackAndMovesNothing() throws {
        let card = card(threeWindows)
        card.onMoveWindow = { _, _ in XCTFail("a row let go in its place moved its Window") }
        let unit = try XCTUnwrap(card.unit("@2"))
        let top = frame(unit, in: card).minY

        let row = try row("@2", of: card)
        press(row)
        move(row, by: 10, 6)
        release(row, at: 6)
        XCTAssertEqual(frame(unit, in: card).minY, top, accuracy: 0.001)
        wait(0.4)
        XCTAssertEqual(card.windowDrag.phase, .idle)
    }

    // MARK: The bounds

    func testARowDraggedUpStopsAtTheBottomOfAHeaderThatSticks() throws {
        let list = SessionsListView(store: WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify/config.yaml")),
                                    environment: SessionsListEnvironment())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list
        windows.append(window)
        let scrollView = try XCTUnwrap(list.subviews.compactMap { $0 as? NSScrollView }.first)
        let rows = (1...20).map { windowRow("@\($0)", index: $0 - 1) }
        let closed = SessionCardContent(title: "atlas", summary: "1 Window")
        let open = SessionCardContent(title: "birch", isOpen: true, rows: rows)
        list.show([("$1", closed), ("$2", open), ("$3", closed)])
        window.displayIfNeeded()
        let card = try XCTUnwrap(scrollView.documentView?.subviews.compactMap { $0 as? SessionCardView }.first { $0.sessionID == "$2" })
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: card.frame.minY + 200))
        scrollView.reflectScrolledClipView(clip)
        let header = try XCTUnwrap(card.subviews.first { $0.accessibilityIdentifier() == "session-$2" })
        let headerBottom = header.convert(header.bounds, to: clip).maxY - clip.bounds.minY
        XCTAssertGreaterThan(header.frame.minY, 0, "the header does not stick")

        // The first row under the header.
        let unit = try XCTUnwrap(card.windowUnits.first { $0.convert($0.bounds, to: clip).minY - clip.bounds.minY > headerBottom + 40 })
        let row = try row(unit.id, of: card)
        press(row)
        move(row, by: 10, -1000)
        XCTAssertEqual(card.windowDrag.phase, .lifted(unit.id))
        // Grown by the lift around its point, the row's top stands that much above its frame.
        let top = unit.convert(unit.bounds, to: clip).minY - clip.bounds.minY - (ListLift.scale - 1) * ListLift.anchor.y * unit.bounds.height
        XCTAssertEqual(top, headerBottom, accuracy: 0.001, "the row did not stop at the bottom of the header that sticks")
        XCTAssertNotNil(card.windowDrag.placement, "the row passed no row on its way up")
    }

    // MARK: The motion

    func testTheLiftGrowsTheRowAroundItsPointOnTheSpringAndTheOthersMakeRoomOnTheLandingsSpring() throws {
        let card = card(threeWindows)
        let row = try row("@1", of: card)
        let unit = try XCTUnwrap(card.unit("@1"))

        press(row)
        move(row, by: 10)
        XCTAssertEqual(unit.shownScale, ListLift.scale, accuracy: 0.0001)
        let lift = try XCTUnwrap(spring(unit.scaleMotion))
        XCTAssertEqual(lift.duration, 0.25)
        XCTAssertEqual(lift.bounce, 0.3, accuracy: 0.0001)
        XCTAssertEqual(unit.shadowOpacity, Float(ListLift.shadowOpacity))
        XCTAssertEqual(unit.plateOpacity, 1)
        // The point at (0.5, 0.3) of the row's size stays where it is.
        let anchor = CGPoint(x: unit.bounds.width * 0.5, y: unit.bounds.height * 0.3)
        let transform = try XCTUnwrap(unit.layer?.sublayerTransform)
        XCTAssertEqual(anchor.x * transform.m11 + transform.m41, anchor.x, accuracy: 0.001)
        XCTAssertEqual(anchor.y * transform.m22 + transform.m42, anchor.y, accuracy: 0.001)
        XCTAssertEqual(unit.layer?.zPosition, 2, "the lifted row is not above the others")

        move(row, by: 200)
        let room = try XCTUnwrap(spring(card.unit("@2")?.layer?.animation(forKey: "glide-position")))
        XCTAssertEqual(room.duration, 0.3)
        XCTAssertEqual(room.bounce, 0.15, accuracy: 0.0001)
        XCTAssertNil(unit.layer?.animation(forKey: "glide-position"), "the lifted row glides after the pointer")
    }

    func testWithReduceMotionTheRowDoesNotSinkOrGrow() throws {
        var still = SessionsListEnvironment()
        still.reduceMotion = true
        let card = card(threeWindows, environment: still)
        let row = try row("@1", of: card)
        let unit = try XCTUnwrap(card.unit("@1"))

        press(row)
        XCTAssertEqual(unit.shownScale, 1, "with Reduce Motion a pressed row sinks")
        move(row, by: 10)
        XCTAssertEqual(card.windowDrag.phase, .lifted("@1"))
        XCTAssertEqual(unit.shownScale, 1, "with Reduce Motion a lifted row grows")
        XCTAssertNil(unit.scaleMotion)
    }
}
