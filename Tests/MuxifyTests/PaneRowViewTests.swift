import AppKit
import XCTest
@testable import MuxifyCore

/// The Pane rows, the Agent marks and "N more…" of the AppKit Sessions list (ADR 0074), where no dump of the end-to-end
/// harness shows them: the steps of the Working mark on the shared clock, its pixels on device pixels, the colour of a
/// Notification's dot, and the press and the accessibility rows of the rows.
@MainActor final class PaneRowViewTests: XCTestCase {
    private func mark(_ mark: AgentMark?, colors: AgentColors = AgentColors(), moves: Bool = true, fontSize: Double = 12,
                      scale: CGFloat = 2) -> SidebarAgentMark {
        let view = SidebarAgentMark()
        let side = InterfaceFontSize(fontSize)(PaneRowMetrics.markPlace)
        view.frame = NSRect(x: 0, y: 0, width: side, height: side)
        view.show(mark, colors: colors, moves: moves, fontSize: InterfaceFontSize(fontSize), scale: scale)
        return view
    }

    private func paneRow(_ content: PaneRowContent, environment: SessionsListEnvironment = SessionsListEnvironment()) -> PaneRowView {
        let row = PaneRowView(paneID: content.paneID)
        row.show(content, environment: environment)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: row.height(width: 240))
        return row
    }

    private func content(active: Bool = false, underWindow: Bool = true, showsLocation: Bool = false, mark: AgentMark? = nil,
                         summary: String = "") -> PaneRowContent {
        PaneRowContent(paneID: "%3", text: SidebarFormats.Text(title: "claude", summary: summary), isActive: active,
                       isUnderWindowRow: underWindow, showsLocation: showsLocation, mark: mark,
                       accessibilityValue: [active ? "active" : nil, mark?.rawValue].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: The Working mark

    func testTheWorkingMarkStepsEightTimesInAPeriodOnTheSharedClock() throws {
        let view = mark(.working)
        let steps = view.stepAnimations.compactMap { $0 as? CAKeyframeAnimation }
        XCTAssertEqual(steps.count, 8, "each of the eight pixels steps")
        for (pixel, step) in steps.enumerated() {
            XCTAssertEqual(step.keyPath, "opacity")
            XCTAssertEqual(step.duration, 1.2)
            XCTAssertEqual(step.repeatCount, .infinity)
            XCTAssertEqual(step.calculationMode, .discrete, "a pixel does not fade between two steps")
            XCTAssertEqual(step.keyTimes?.map(\.doubleValue), (0...8).map { Double($0) / 8 })
            // At each step the head moves one pixel clockwise, and the pixels behind it dim.
            let values = try XCTUnwrap(step.values as? [Float])
            XCTAssertEqual(values, (0..<8).map { Float(WorkingGlyph.opacity(behind: ($0 - pixel + 8) % 8)) })
            // Where the steps stand in their period now is where the time since the reference date stands in it.
            let place = (CACurrentMediaTime() - step.beginTime + step.timeOffset).truncatingRemainder(dividingBy: 1.2)
            let clock = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2)
            XCTAssertLessThan(min(abs(place - clock), 1.2 - abs(place - clock)), 0.05)
        }
    }

    func testEveryWorkingMarkStepsOnOneClockWithTheSpines() throws {
        let first = try XCTUnwrap(mark(.working).stepAnimations.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let second = try XCTUnwrap(mark(.working).stepAnimations.first)
        let card = SessionCardView(sessionID: "$1")
        card.show(SessionCardContent(title: "atlas", mark: .agent(.working)), environment: SessionsListEnvironment())
        let spine = try XCTUnwrap(card.spineFade)

        XCTAssertEqual(first.beginTime, second.beginTime)
        XCTAssertEqual(first.timeOffset, second.timeOffset)
        XCTAssertEqual(first.beginTime, spine.beginTime, "the marks and the spines begin at one moment of the clock")
    }

    func testWithoutPulseOrWithReduceMotionTheWorkingMarkStandsStillAtItsFirstStep() {
        let still = mark(.working, moves: false)
        XCTAssertTrue(still.stepAnimations.isEmpty)
        let first = WorkingGlyph.pixels(in: CGSize(width: 10, height: 10), phase: 0, fontSize: InterfaceFontSize(), displayScale: 2)
        XCTAssertEqual(still.pixelOpacities, first.map { Float($0.opacity) })
        XCTAssertEqual(still.pixelOpacities.first, 0.85, "the head is the top left pixel")

        var noPulse = SessionsListEnvironment()
        noPulse.pulses = false
        var reduced = SessionsListEnvironment()
        reduced.reduceMotion = true
        for environment in [noPulse, reduced] {
            XCTAssertTrue(paneRow(content(mark: .working), environment: environment).agentMark.stepAnimations.isEmpty)
        }
        XCTAssertEqual(paneRow(content(mark: .working)).agentMark.stepAnimations.count, 8)

        let moving = mark(.working)
        moving.show(.working, colors: AgentColors(), moves: false, fontSize: InterfaceFontSize(), scale: 2)
        XCTAssertTrue(moving.stepAnimations.isEmpty, "the steps stop when pulse goes off")
        moving.show(.done, colors: AgentColors(), moves: true, fontSize: InterfaceFontSize(), scale: 2)
        XCTAssertTrue(moving.stepAnimations.isEmpty, "a Notification does not step")
    }

    func testTheGlyphsPixelsAreSeparateOnWholeDevicePixelsAtOneAndTwoTimes() throws {
        for scale in [CGFloat(1), 2] {
            let view = mark(.working, moves: false, scale: scale)
            for frame in view.pixelFrames {
                for edge in [frame.minX, frame.minY, frame.width, frame.height] {
                    XCTAssertEqual(edge * scale, (edge * scale).rounded(), "a pixel of the glyph is not on device pixels at \(scale)×")
                }
            }
            let blocks = try blocks(of: view, scale: scale)
            XCTAssertEqual(blocks.count, 8, "the pixels touch at \(scale)×")
            for block in blocks {
                XCTAssertEqual(block.width, block.height, "a pixel is not square at \(scale)×")
                // 2 points at 1×, so the gaps fit in the footprint; 3 points at 2×.
                XCTAssertEqual(CGFloat(block.width) / scale, scale == 1 ? 2 : 3)
            }
        }
    }

    func testTheGlyphAndTheDotGrowWithTheInterfaceFontSize() {
        let glyph = mark(.working, moves: false, fontSize: 18)
        XCTAssertEqual(glyph.pixelFrames.first?.width, 4.5)
        let dot = mark(.done, fontSize: 18)
        XCTAssertEqual(dot.dotFrame.width, 10.5)
        XCTAssertEqual(mark(.done).dotFrame, NSRect(x: 1.5, y: 1.5, width: 7, height: 7), "the dot stands in the middle of its place")
    }

    // MARK: The Notification dot

    func testANotificationIsADotInTheColourOfTheConfigForTheLightAndTheDarkAppearance() throws {
        var colors = AgentColors()
        colors[.done] = .pair(light: .rgb(red: 0, green: 255, blue: 0), dark: .rgb(red: 255, green: 0, blue: 0))
        let view = mark(.done, colors: colors)
        view.appearance = NSAppearance(named: .aqua)
        XCTAssertEqual(try rgb(view.dotColor), [0, 1, 0], "the light appearance draws the light colour")
        view.appearance = NSAppearance(named: .darkAqua)
        XCTAssertEqual(try rgb(view.dotColor), [1, 0, 0], "the dark appearance draws the dark colour")
        XCTAssertNil(mark(.working).dotColor, "the Working mark has no dot")
        XCTAssertNil(mark(nil).dotColor)
    }

    func testTheNotificationsAreBlueForDoneRedForFailedAndOrangeForBlocked() throws {
        let view = mark(.done)
        view.appearance = NSAppearance(named: .darkAqua)
        let done = try rgb(view.dotColor)
        view.show(.failed, colors: AgentColors(), moves: true, fontSize: InterfaceFontSize(), scale: 2)
        let failed = try rgb(view.dotColor)
        view.show(.blocked, colors: AgentColors(), moves: true, fontSize: InterfaceFontSize(), scale: 2)
        let blocked = try rgb(view.dotColor)
        XCTAssertGreaterThan(done[2], done[0] + 0.3, "done is blue")
        XCTAssertGreaterThan(failed[0], failed[1] + 0.4, "failed is red")
        XCTAssertGreaterThan(blocked[0], blocked[2] + 0.3, "blocked is orange")
        XCTAssertGreaterThan(blocked[1], failed[1] + 0.15, "blocked is not the red of failed")
    }

    // MARK: The Pane row

    func testAPaneRowIsAButtonWithTheIdentifierAndTheValueOfTheSwiftUIRow() {
        let row = paneRow(content(active: true, mark: .working))
        XCTAssertTrue(row.isAccessibilityElement())
        XCTAssertEqual(row.accessibilityRole(), .button)
        XCTAssertEqual(row.accessibilityIdentifier(), "pane-%3")
        XCTAssertEqual(row.accessibilityLabel(), "claude")
        XCTAssertEqual(row.accessibilityValue() as? String, "active, working")
        XCTAssertEqual(row.accessibilityChildren()?.count, 0, "the row hides its parts")
        XCTAssertEqual(paneRow(content(summary: "Pane Summary")).accessibilityLabel(), "claude, Pane Summary")
        XCTAssertEqual(paneRow(content()).accessibilityValue() as? String, "")
    }

    func testAPaneRowUnderItsWindowRowIsIndentedAndOneInItsPlaceIsNot() {
        XCTAssertEqual(paneRow(content(underWindow: true)).agentMark.frame.minX, PaneRowMetrics.leadingUnderWindow)
        XCTAssertEqual(paneRow(content(underWindow: false)).agentMark.frame.minX, PaneRowMetrics.leading)
        // The title's line at 12 with the room above and below it, as the SwiftUI row in the dump of `pane-rows`.
        XCTAssertEqual(paneRow(content()).frame.height, 21)
        XCTAssertGreaterThan(paneRow(content(summary: "Pane Summary")).frame.height, 21, "the Summary is a line under the title")
    }

    func testOnlyAPaneRowThatShowsTheLocationHasTheTintAndTheAccentIcon() {
        let location = paneRow(content(active: true, underWindow: false, showsLocation: true))
        XCTAssertEqual(location.fillColor?.alpha ?? 0, SelectedRow.tintOpacity, accuracy: 0.001)
        XCTAssertEqual(location.iconInk, .accent)
        XCTAssertEqual(location.titleInk, .primary)
        let other = paneRow(content(active: true))
        XCTAssertNil(other.fillColor)
        XCTAssertEqual(other.iconInk, .secondary)
        XCTAssertEqual(other.titleInk, .secondary, "another Pane row is in the softer text colour")

        location.show(content(active: true, underWindow: false), environment: SessionsListEnvironment())
        XCTAssertEqual((location.tintFade as? CABasicAnimation)?.duration, SelectedRow.fade, "the tint fades as a Window row's does")
    }

    func testAPressOnAPaneRowAndOnNMoreWorksByClickAndByAccessibility() {
        let row = paneRow(content())
        var presses = 0
        row.onPress = { presses += 1 }
        XCTAssertTrue(row.hitTest(NSPoint(x: 100, y: 10)) === row, "the row takes the clicks on its parts")
        XCTAssertTrue(row.acceptsFirstMouse(for: nil))
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(presses, 1)

        let more = MoreRowView(identifier: "session-$1")
        more.show(count: 3, environment: SessionsListEnvironment())
        more.frame = NSRect(x: 0, y: 0, width: 240, height: more.height(width: 240))
        more.onPress = { presses += 1 }
        XCTAssertTrue(more.hitTest(NSPoint(x: 10, y: 10)) === more)
        XCTAssertTrue(more.acceptsFirstMouse(for: nil))
        XCTAssertTrue(more.accessibilityPerformPress())
        XCTAssertEqual(presses, 2)
    }

    // MARK: "N more…"

    func testNMoreIsAButtonWithTheIdentifierOfTheHeaderAndTheCountOfTheRowsHeldBack() {
        let more = MoreRowView(identifier: "session-$1")
        more.show(count: 3, environment: SessionsListEnvironment())
        XCTAssertEqual(more.accessibilityRole(), .button)
        XCTAssertEqual(more.accessibilityIdentifier(), "session-$1-more")
        XCTAssertEqual(more.accessibilityLabel(), "3 more…")
        XCTAssertEqual(more.accessibilityValue() as? String, "")
        XCTAssertEqual(more.height(width: 240), 20)
    }

    func testAnOpenCardListsItsRowsThenNMoreThenItsHeader() throws {
        let window = TmuxWindow(id: "@1", sessionID: "$1", sessionName: "atlas", index: 0, name: "editor", paneTitle: "editor",
                                path: "/work/app", command: "zsh", isActive: true, paneCount: 2, hasBell: false,
                                sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])
        let windowRow = WindowRowContent(window: window, formatted: SidebarFormats.WindowRowContent(text: .init(title: "editor", summary: ""),
                                                                                                    left: nil, right: nil))
        let card = SessionCardView(sessionID: "$1")
        var shown = false
        card.onShowAllRows = { shown = true }
        card.show(SessionCardContent(title: "atlas", isOpen: true, rows: [.window(windowRow), .pane(content())], moreCount: 4),
                  environment: SessionsListEnvironment())
        card.frame = NSRect(x: 0, y: 0, width: 248, height: card.height(width: 248))

        let identifiers = try XCTUnwrap(card.accessibilityChildren() as? [NSView]).map { $0.accessibilityIdentifier() }
        XCTAssertEqual(identifiers.filter { $0 != "session-window-@1" }, ["pane-%3", "session-$1-more", "session-$1"])
        XCTAssertEqual(identifiers.first, "session-window-@1")
        let more = try XCTUnwrap((card.accessibilityChildren() as? [NSView])?.first { $0.accessibilityIdentifier() == "session-$1-more" })
        XCTAssertEqual(more.accessibilityLabel(), "4 more…")
        XCTAssertTrue(more.accessibilityPerformPress())
        XCTAssertTrue(shown, "a press on N more does not show all rows")
    }

    // MARK: Helpers

    /// The sides of the separate blocks of pixels that the view's layers cover, drawn as the driver's `snapshot` draws.
    private func blocks(of view: SidebarAgentMark, scale: CGFloat) throws -> [(width: Int, height: Int)] {
        let side = Int((view.bounds.width * scale).rounded())
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        try XCTUnwrap(view.layer).render(in: context)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var remaining = Set((0..<side * side).filter { data[$0 * 4 + 3] > 10 })
        var blocks: [(width: Int, height: Int)] = []
        while let first = remaining.first {
            remaining.remove(first)
            var pending = [first], xs: [Int] = [], ys: [Int] = []
            while let pixel = pending.popLast() {
                let x = pixel % side, y = pixel / side
                xs.append(x)
                ys.append(y)
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] where (0..<side).contains(x + dx) && (0..<side).contains(y + dy) {
                    if remaining.remove((y + dy) * side + x + dx) != nil { pending.append((y + dy) * side + x + dx) }
                }
            }
            blocks.append((xs.max()! - xs.min()! + 1, ys.max()! - ys.min()! + 1))
        }
        return blocks
    }

    private func rgb(_ color: CGColor?) throws -> [Double] {
        let color = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(color))?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent].map { (Double($0) * 1000).rounded() / 1000 }
    }
}
