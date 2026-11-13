import AppKit
import XCTest
@testable import MuxifyCore

/// The Pane rows, the Agent marks and "N more…" of the AppKit Sessions list (ADR 0074), where no dump of the end-to-end
/// harness shows them: the Working mark's pixels on device pixels and the colours of a Notification, as the mark
/// takes them from the shared definitions, and the press and the accessibility rows of the rows.
@MainActor final class PaneRowViewTests: XCTestCase {
    private func paneRow(_ content: PaneRowContent, environment: SidebarListEnvironment = SidebarListEnvironment()) -> PaneRowView {
        let row = PaneRowView(paneID: content.paneID)
        row.show(content, environment: environment)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: row.height(width: 240))
        return row
    }

    private func content(active: Bool = false, mark: AgentMark? = nil, summary: String = "") -> PaneRowContent {
        PaneRowContent(paneID: "%3", text: SidebarFormats.Text(title: "claude", summary: summary), isActive: active, mark: mark,
                       accessibilityValue: [active ? "active" : nil, mark?.rawValue].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: The Working mark

    /// The frames of the Working mark's pixels in its footprint at `fontSize` on a display of `scale`, as the mark lays
    /// them out.
    private func pixels(fontSize: Double = 12, scale: CGFloat) -> [CGRect] {
        let size = InterfaceFontSize(fontSize)
        let side = size(WorkingGlyph.footprint)
        return WorkingGlyph.pixels(in: CGSize(width: side, height: side), phase: 0, fontSize: size, displayScale: scale).map(\.frame)
    }

    func testTheGlyphsPixelsAreSeparateSquaresOnWholeDevicePixelsAtOneAndTwoTimes() {
        for scale in [CGFloat(1), 2] {
            let pixels = pixels(scale: scale)
            XCTAssertEqual(pixels.count, 8)
            for frame in pixels {
                for edge in [frame.minX, frame.minY, frame.width, frame.height] {
                    XCTAssertEqual(edge * scale, (edge * scale).rounded(), "a pixel of the glyph is not on device pixels at \(scale)×")
                }
                XCTAssertEqual(frame.width, frame.height, "a pixel is not square at \(scale)×")
                // 2 points at 1×, so the gaps fit in the footprint; 3 points at 2×.
                XCTAssertEqual(frame.width, scale == 1 ? 2 : 3)
            }
            for (index, frame) in pixels.enumerated() {
                for other in pixels[(index + 1)...] {
                    let gap = max(other.minX - frame.maxX, frame.minX - other.maxX, other.minY - frame.maxY, frame.minY - other.maxY)
                    XCTAssertGreaterThanOrEqual(gap, 1 / scale, "two pixels of the glyph touch at \(scale)×")
                }
            }
        }
    }

    func testTheGlyphAndTheDotGrowWithTheInterfaceFontSize() {
        XCTAssertEqual(pixels(fontSize: 18, scale: 2).first?.width, 4.5)
        XCTAssertEqual(InterfaceFontSize(18)(AgentMarkMetrics.dotSize), 10.5)
    }

    // MARK: The Notification dot

    /// The colour of the mark in the appearance, as the mark takes it from the Config's colours, in sRGB.
    private func rgb(_ mark: AgentMark, _ colors: AgentColors = AgentColors(), in name: NSAppearance.Name) throws -> [Double] {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var shown: CGColor?
        appearance.performAsCurrentDrawingAppearance { shown = colors[mark].nsColor(in: appearance).cgColor }
        let color = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(shown))?.usingColorSpace(.sRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent].map { (Double($0) * 1000).rounded() / 1000 }
    }

    func testANotificationIsInTheColourOfTheConfigForTheLightAndTheDarkAppearance() throws {
        var colors = AgentColors()
        colors[.done] = .pair(light: .rgb(red: 0, green: 255, blue: 0), dark: .rgb(red: 255, green: 0, blue: 0))
        XCTAssertEqual(try rgb(.done, colors, in: .aqua), [0, 1, 0], "the light appearance draws the light colour")
        XCTAssertEqual(try rgb(.done, colors, in: .darkAqua), [1, 0, 0], "the dark appearance draws the dark colour")
    }

    func testTheNotificationsAreBlueForDoneRedForFailedAndOrangeForBlocked() throws {
        let done = try rgb(.done, in: .darkAqua)
        let failed = try rgb(.failed, in: .darkAqua)
        let blocked = try rgb(.blocked, in: .darkAqua)
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

    func testAPressOnAPaneRowAndOnNMoreWorksByClickAndByAccessibility() {
        let row = paneRow(content())
        var presses = 0
        row.onPress = { presses += 1 }
        XCTAssertTrue(row.hitTest(NSPoint(x: 100, y: 10)) === row, "the row takes the clicks on its parts")
        XCTAssertTrue(row.acceptsFirstMouse(for: nil))
        XCTAssertTrue(row.accessibilityPerformPress())
        XCTAssertEqual(presses, 1)

        let more = MoreRowView(identifier: "session-$1")
        more.show(count: 3, environment: SidebarListEnvironment())
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
        more.show(count: 3, environment: SidebarListEnvironment())
        XCTAssertEqual(more.accessibilityRole(), .button)
        XCTAssertEqual(more.accessibilityIdentifier(), "session-$1-more")
        XCTAssertEqual(more.accessibilityLabel(), "3 more…")
        XCTAssertEqual(more.accessibilityValue() as? String, "")
        XCTAssertEqual(more.height(width: 240), 20)
    }

    func testNMoreInTheTopicsListShowsTheStrongestMarkOfTheRowsHeldBackAsItsSpineAndItsValue() throws {
        let more = MoreRowView(identifier: "topic-atlas")
        more.show(count: 2, mark: .blocked, environment: SidebarListEnvironment())
        more.frame = NSRect(x: 0, y: 0, width: 240, height: more.height(width: 240))
        XCTAssertEqual(more.accessibilityValue() as? String, "blocked")
        XCTAssertEqual(more.accessibilityChildren()?.count, 0, "the spine is no accessibility row, as SwiftUI hides it")
        let spine = try XCTUnwrap(more.subviews.first { $0 is CardSpineView })
        XCTAssertFalse(spine.isHidden)
        XCTAssertEqual(spine.frame, NSRect(x: 0, y: RowSpine.verticalInset, width: RowSpine.width, height: 20 - 2 * RowSpine.verticalInset))
        more.show(count: 2, environment: SidebarListEnvironment())
        XCTAssertTrue(spine.isHidden, "\"N more…\" with no mark shows no spine")
        XCTAssertEqual(more.accessibilityValue() as? String, "")
    }

    // MARK: The spine of a row

    func testARowOfTheActiveTopicsOpenCardListsTheSpineOfItsMarkAfterItselfAlongItsLeftEdge() throws {
        var marked = content(mark: .done)
        marked.spine = .done
        let row = paneRow(marked)
        XCTAssertEqual(row.accessibilityParts.map { $0.accessibilityIdentifier() }, ["pane-%3", "topic-agent-mark-%3"])
        let spine = try XCTUnwrap(row.accessibilityParts.last)
        XCTAssertTrue(spine.isAccessibilityElement())
        XCTAssertEqual(spine.accessibilityLabel(), "done")
        XCTAssertEqual(spine.frame, NSRect(x: 0, y: RowSpine.verticalInset, width: RowSpine.width,
                                           height: row.bounds.height - 2 * RowSpine.verticalInset))
        XCTAssertTrue(row.hitTest(NSPoint(x: 1, y: 10)) === row, "a click on the spine presses the row")
        XCTAssertEqual(paneRow(content(mark: .done)).accessibilityParts.count, 1, "a row with no spine lists only itself")
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
                  environment: SidebarListEnvironment())
        card.frame = NSRect(x: 0, y: 0, width: 248, height: card.height(width: 248))

        let identifiers = try XCTUnwrap(card.accessibilityChildren() as? [NSView]).map { $0.accessibilityIdentifier() }
        XCTAssertEqual(identifiers.filter { $0 != "session-window-@1" }, ["pane-%3", "session-$1-more", "session-$1"])
        XCTAssertEqual(identifiers.first, "session-window-@1")
        let more = try XCTUnwrap((card.accessibilityChildren() as? [NSView])?.first { $0.accessibilityIdentifier() == "session-$1-more" })
        XCTAssertEqual(more.accessibilityLabel(), "4 more…")
        XCTAssertTrue(more.accessibilityPerformPress())
        XCTAssertTrue(shown, "a press on N more does not show all rows")
    }
}
