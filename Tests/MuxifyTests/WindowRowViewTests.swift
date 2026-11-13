import AppKit
import XCTest
@testable import MuxifyCore

/// The Window row of the AppKit Sessions list (ADR 0074), where no dump of the end-to-end harness shows it: the clicks
/// it takes and the room it keeps for a Hint.
@MainActor final class WindowRowViewTests: XCTestCase {
    private let window = TmuxWindow(id: "@1", sessionID: "$1", sessionName: "atlas", index: 0, name: "editor", paneTitle: "editor",
                                    path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false,
                                    sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [])

    private func row(environment: SidebarListEnvironment = SidebarListEnvironment()) -> WindowRowView {
        let row = WindowRowView(windowID: window.id, identifier: "session-window-" + window.id)
        row.show(WindowRowContent(window: window, formatted: SidebarFormats.WindowRowContent(text: .init(title: "editor", summary: ""),
                                                                                            left: nil, right: nil)),
                 environment: environment)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: row.height(width: 240))
        return row
    }

    func testAWindowRowOfTheTopicsListListsTheSpineOfItsMarkAfterItsButton() throws {
        let row = WindowRowView(windowID: window.id, identifier: "topic-window-" + window.id, isButton: true)
        var content = WindowRowContent(window: window, formatted: SidebarFormats.WindowRowContent(text: .init(title: "editor", summary: ""),
                                                                                                 left: nil, right: nil), inTopicsList: true)
        content.spine = .working
        row.show(content, environment: SidebarListEnvironment())
        row.frame = NSRect(x: 0, y: 0, width: 240, height: row.height(width: 240))
        XCTAssertEqual(row.accessibilityParts.map { $0.accessibilityIdentifier() }, ["topic-window-@1", "topic-agent-mark-@1"])
        XCTAssertEqual(row.accessibilityParts.last?.accessibilityLabel(), "working")
        XCTAssertTrue(row.subviews.last is CardSpineView, "the spine stands over the row's fill and parts")
        content.spine = nil
        row.show(content, environment: SidebarListEnvironment())
        XCTAssertEqual(row.accessibilityParts.map { $0.accessibilityIdentifier() }, ["topic-window-@1"])
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
        var environment = SidebarListEnvironment()
        environment.hints = HintPresentation(modifiers: nil, keybinds: .defaults,
                                             targets: QuickSwitchTargets(cards: [], windows: [], topicWindows: [], tabs: [], sessions: [], topics: []),
                                             sidebar: true, browser: false, terminal: false, config: config)
        let plain = try XCTUnwrap(row().accessibilityParts.first)
        let hinted = try XCTUnwrap(row(environment: environment).accessibilityParts.first)

        XCTAssertEqual(plain.frame.minX, WindowRowMetrics.leading)
        XCTAssertEqual(hinted.frame.minX, WindowRowMetrics.leading + WindowRowMetrics.hintRoom + WindowRowMetrics.spacing)
        XCTAssertEqual(hinted.accessibilityRole(), .image, "the first part is the app icon")
    }
}
