import AppKit
import XCTest
@testable import MuxifyCore

/// The Window row of the AppKit Sessions list (ADR 0074), where no dump of the end-to-end harness shows it: the fade
/// of the Location's tint, the fill of a row under the pointer and the room it keeps for a Hint.
@MainActor final class WindowRowViewTests: XCTestCase {
    private let window = TmuxWindow(id: "@1", sessionID: "$1", sessionName: "atlas", index: 0, name: "editor", paneTitle: "editor",
                                    path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false,
                                    sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])

    private func content(selected: Bool, tooltips: Config.Sidebar.WindowTooltips = .always) -> WindowRowContent {
        WindowRowContent(window: window, formatted: SidebarFormats.WindowRowContent(text: .init(title: "editor", summary: ""), left: nil, right: nil),
                         isSelected: selected, tooltips: tooltips)
    }

    private func row(selected: Bool = false, environment: SessionsListEnvironment = SessionsListEnvironment()) -> WindowRowView {
        let row = WindowRowView(windowID: window.id, identifier: "session-window-" + window.id)
        row.show(content(selected: selected), environment: environment)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: row.height(width: 240))
        return row
    }

    private func alpha(_ color: CGColor?) -> CGFloat { color?.alpha ?? 0 }

    private var crossing: NSEvent {
        NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                               eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    private func controlPoints(_ timing: CAMediaTimingFunction?) -> [Float] {
        (1...2).flatMap { index -> [Float] in
            var point: [Float] = [0, 0]
            timing?.getControlPoint(at: index, values: &point)
            return point
        }
    }

    func testTheTintFadesInWhenTheLocationComesToTheRowAndOutWhenItLeaves() throws {
        let row = row()
        XCTAssertNil(row.fillColor)
        XCTAssertNil(row.tintFade, "a row that shows for the first time has no fade")

        row.show(content(selected: true), environment: SessionsListEnvironment())

        XCTAssertEqual(alpha(row.fillColor), SelectedRow.tintOpacity, accuracy: 0.001)
        let fadeIn = try XCTUnwrap(row.tintFade as? CABasicAnimation)
        XCTAssertEqual(fadeIn.keyPath, "backgroundColor")
        XCTAssertEqual(fadeIn.duration, 0.14)
        XCTAssertEqual(controlPoints(fadeIn.timingFunction), controlPoints(CAMediaTimingFunction(name: .easeOut)))
        XCTAssertNil(fadeIn.fromValue, "the tint fades in from no fill")
        XCTAssertNil(fadeIn.toValue, "the fade ends where the fill now is")

        row.show(content(selected: false), environment: SessionsListEnvironment())

        XCTAssertNil(row.fillColor)
        let fadeOut = try XCTUnwrap(row.tintFade as? CABasicAnimation)
        XCTAssertEqual(fadeOut.duration, 0.14)
        XCTAssertEqual(alpha(fadeOut.fromValue.map { $0 as! CGColor }), SelectedRow.tintOpacity, accuracy: 0.001)
    }

    func testARowThatShowsWithTheLocationHasItsTintAtOnce() {
        let row = row(selected: true)
        XCTAssertEqual(alpha(row.fillColor), SelectedRow.tintOpacity, accuracy: 0.001)
        XCTAssertNil(row.tintFade)
    }

    func testARowUnderThePointerHasTheFaintFillAtOnce() {
        let row = row()
        row.mouseEntered(with: crossing)

        XCTAssertEqual(alpha(row.fillColor), NSColor.labelColor.alphaComponent * SelectedRow.hoverOpacity, accuracy: 0.001)
        XCTAssertNil(row.tintFade, "the fill of the pointer does not fade")

        row.mouseExited(with: crossing)
        XCTAssertNil(row.fillColor)
    }

    func testTheHoverOfTheTestDriverGivesTheRowItsFill() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Flipped, as the content view of a SwiftUI window is, and the row far from the window's middle, so a point in
        // the wrong coordinates misses it.
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        window.contentView = content
        defer { window.contentView = nil }
        let row = row()
        row.frame.origin = NSPoint(x: 10, y: 10)
        content.addSubview(row)
        // AppKit asks a view for its tracking areas once its window shows, and this window never shows.
        row.updateTrackingAreas()

        // As `TestDriver.hover`: each tracking area of the view under the point and of its ancestors gets an entered event.
        let point = content.convert(NSPoint(x: row.frame.midX, y: row.frame.midY), to: nil)
        let areas = TestDriver.trackingAreas(at: point, in: window)
        XCTAssertEqual(areas.count, 1)
        XCTAssertTrue(areas.first?.owner === row, "the row is not the view under the point")
        for area in areas { area.owner.mouseEntered(with: crossing) }

        XCTAssertEqual(alpha(row.fillColor), NSColor.labelColor.alphaComponent * SelectedRow.hoverOpacity, accuracy: 0.001)
        row.mouseExited(with: crossing)
    }

    func testTheTintOfTheLocationWinsOverTheFillOfThePointer() {
        let row = row(selected: true)
        row.mouseEntered(with: crossing)
        XCTAssertEqual(alpha(row.fillColor), SelectedRow.tintOpacity, accuracy: 0.001)
    }

    func testTheRowTakesTheClicksOnItsPartsAndTheFirstClick() {
        let row = row()
        XCTAssertTrue(row.hitTest(NSPoint(x: 15, y: 10)) === row)
        XCTAssertNil(row.hitTest(NSPoint(x: 15, y: row.frame.maxY + 1)))
        XCTAssertTrue(row.acceptsFirstMouse(for: nil))
    }

    func testWithWindowHintsAtAllTimesTheRowKeepsRoomBeforeItsIcon() throws {
        var config = Config.Hints()
        config.windows.always = true
        var environment = SessionsListEnvironment()
        environment.hints = HintPresentation(modifiers: nil, keybinds: .defaults,
                                             targets: QuickSwitchTargets(cards: [], windows: [], topicWindows: [], tabs: [], sessions: [], topics: []),
                                             sidebar: true, browser: false, terminal: false, config: config)
        let plain = try XCTUnwrap(row().accessibilityParts.first)
        let hinted = try XCTUnwrap(row(environment: environment).accessibilityParts.first)

        XCTAssertEqual(plain.frame.minX, WindowRowMetrics.leading)
        XCTAssertEqual(hinted.frame.minX, WindowRowMetrics.leading + WindowRowMetrics.hintRoom + WindowRowMetrics.spacing)
        XCTAssertEqual(hinted.accessibilityRole(), .image, "the first part is the app icon")
    }

    // MARK: The hover label

    /// The row whose hover label shows, or waits out its rest.
    private var labelled: HoverAnchor? { HoverLabels.shared.anchorInPlay }

    func testTheHoverLabelFollowsTheWindowTooltipsOfTheConfig() {
        let row = row()
        defer { row.mouseExited(with: crossing) }
        for tooltips in [Config.Sidebar.WindowTooltips.always, .truncated] {
            row.show(content(selected: false, tooltips: tooltips), environment: SessionsListEnvironment())
            row.mouseEntered(with: crossing)
            XCTAssertTrue(labelled === row.hoverLabel.anchor, "no label for \(tooltips)")
            XCTAssertEqual(row.hoverLabel.request.onlyWhenCutOff, tooltips == .truncated)
            row.mouseExited(with: crossing)
            XCTAssertNil(labelled, "the label stays after the pointer left the row")
        }

        row.show(content(selected: false, tooltips: .off), environment: SessionsListEnvironment())
        row.mouseEntered(with: crossing)
        XCTAssertNil(labelled, "a label opens with window_tooltips off")
        row.show(content(selected: false, tooltips: .always), environment: SessionsListEnvironment())
        XCTAssertTrue(labelled === row.hoverLabel.anchor, "the label does not open on the hovered row when the Config turns it on")
        XCTAssertEqual(row.hoverLabel.request.detail, "atlas:0 — /work/app")
    }

    func testTheHoverLabelClosesWhenTheRowGoesAway() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        window.contentView = content
        defer { window.contentView = nil }
        let row = row()
        content.addSubview(row)
        row.mouseEntered(with: crossing)
        XCTAssertTrue(labelled === row.hoverLabel.anchor)

        row.removeFromSuperview()
        XCTAssertNil(labelled, "the label stays after its row went away")
    }

    func testTheRowsOfAClosedCardTakeNoPointer() throws {
        let card = SessionCardView(sessionID: "$1")
        let rows = [CardRowContent.window(content(selected: false))]
        card.show(SessionCardContent(title: "atlas", isOpen: true, rows: rows), environment: SessionsListEnvironment())
        let row = try XCTUnwrap((card.accessibilityChildren() as? [NSView])?.first { $0.accessibilityIdentifier() == "session-window-@1" }?.superview
                                    as? WindowRowView)
        row.mouseEntered(with: crossing)
        XCTAssertTrue(labelled === row.hoverLabel.anchor)

        card.show(SessionCardContent(title: "atlas", rows: rows), environment: SessionsListEnvironment())
        XCTAssertNil(labelled, "the label stays after the card closed")
        row.mouseEntered(with: crossing)
        XCTAssertNil(labelled, "a row of a closed card opens a label")
        XCTAssertNil(row.fillColor, "a row of a closed card takes the fill of the pointer")
    }
}
