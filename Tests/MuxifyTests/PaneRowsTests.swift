import XCTest
@testable import MuxifyCore

final class PaneRowsTests: XCTestCase {
    private func window(_ id: String, session: String, topic: String? = "t") -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "app-" + session, index: 0, name: "editor",
                   paneTitle: "editor", path: "/work/app", command: "zsh", isActive: true, paneCount: 1, hasBell: false,
                   sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [], topicID: topic,
                   sessionPath: "/work/app")
    }

    private func pane(_ id: String, window: String, index: Int, active: Bool = false, agent: String = "") -> TmuxPane {
        TmuxPane(id: id, windowID: window, index: index, isActive: active, title: id + " title", path: "/work/app",
                 command: agent.isEmpty ? "zsh" : "2.1.289", agent: agent, agentStatus: agent.isEmpty ? "" : "blocked",
                 unread: false)
    }

    private func model(_ windows: [TmuxWindow], panes: [TmuxPane]?, mode: SidebarMode = .topics) -> TopicsModel {
        var selection = TopicSelection()
        selection.select(windowID: windows[0].id, activeTopic: .topic("t"))
        return TopicsModel(records: [TopicRecord(id: "t", title: "T")], windows: windows, config: Config(),
                           selection: selection, location: selection.windowID.flatMap(WindowID.init(rawValue:)).map(Location.window), mode: mode,
                           agents: Agent.list(panes: panes ?? [], windows: windows, ordered: false), panes: panes)
    }

    private func items(_ children: TopicsModel.SessionChildren?) -> [String] {
        (children?.items ?? []).map { item in
            switch item {
            case .window(let window): return "window " + window.id
            case .pane(let row): return (row.isUnderWindowRow ? "  pane " : "pane ") + row.pane.id
            }
        }
    }

    private func liveChildren(_ topics: TopicsModel) -> TopicsModel.SessionChildren? {
        guard case .live(let children) = topics.rows.first?.sessions.first?.contents else { return nil }
        return children
    }

    func testOnlyWindowsWithTwoOrMorePanesGetPaneRowsInPaneIndexOrder() {
        let windows = [window("@1", session: "$1"), window("@2", session: "$1")]
        let panes = [pane("%3", window: "@1", index: 1), pane("%1", window: "@1", index: 0, active: true),
                     pane("%9", window: "@2", index: 0, active: true)]
        let children = liveChildren(model(windows, panes: panes))
        XCTAssertEqual(items(children), ["window @1", "  pane %1", "  pane %3", "window @2"])
        XCTAssertNil(children?.replacedWindow)
    }

    func testPaneRowsTakeThePlaceOfTheOnlyWindowRowOfASession() {
        let windows = [window("@1", session: "$1")]
        let panes = [pane("%1", window: "@1", index: 0), pane("%2", window: "@1", index: 1, active: true, agent: "claude")]
        let children = liveChildren(model(windows, panes: panes))
        XCTAssertEqual(items(children), ["pane %1", "pane %2"])
        XCTAssertEqual(children?.replacedWindow?.id, "@1", "a click on the Session row selects the replaced Window")
        XCTAssertEqual(children?.windows.map(\.id), ["@1"])
        guard case .pane(let agentRow) = children?.items.last else { return XCTFail("Pane row expected") }
        XCTAssertEqual(agentRow.agent?.status, .blocked, "an Agent's Pane row has its Status")
        XCTAssertTrue(agentRow.pane.isActive)
    }

    func testOnePaneInTheOnlyWindowKeepsTheWindowRow() {
        let windows = [window("@1", session: "$1")]
        let children = liveChildren(model(windows, panes: [pane("%1", window: "@1", index: 0, active: true)]))
        XCTAssertEqual(items(children), ["window @1"])
        XCTAssertNil(children?.replacedWindow)
    }

    func testShowPanesOffListsOnlyWindows() {
        let windows = [window("@1", session: "$1")]
        let children = liveChildren(model(windows, panes: nil))
        XCTAssertEqual(items(children), ["window @1"])
        XCTAssertNil(children?.replacedWindow)
    }

    func testSessionsModeHasTheSamePaneRowsPerSession() {
        let windows = [window("@1", session: "$1", topic: nil), window("@2", session: "$2", topic: nil),
                       window("@3", session: "$2", topic: nil)]
        let panes = [pane("%1", window: "@1", index: 0), pane("%2", window: "@1", index: 1, active: true),
                     pane("%3", window: "@2", index: 0), pane("%4", window: "@3", index: 1), pane("%5", window: "@3", index: 0)]
        let topics = model(windows, panes: panes, mode: .sessions)
        XCTAssertEqual(items(topics.sessionChildren["$1"]), ["pane %1", "pane %2"])
        XCTAssertEqual(topics.sessionChildren["$1"]?.replacedWindow?.id, "@1")
        XCTAssertEqual(items(topics.sessionChildren["$2"]), ["window @2", "window @3", "  pane %5", "  pane %4"])
    }

    func testACardListsFiveRowsUnlessTheUserAsksOrTheSelectedWindowIsFurtherDown() throws {
        let windows = ["@1", "@2", "@3", "@4"].map { window($0, session: "$1") }
        let panes = [pane("%1", window: "@1", index: 0, active: true)]
            + (0..<3).map { pane("%2\($0)", window: "@2", index: $0, active: $0 == 0) }
            + [pane("%3", window: "@3", index: 0, active: true), pane("%4", window: "@4", index: 0, active: true)]
        let rows = try XCTUnwrap(liveChildren(model(windows, panes: panes))).items
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(CardRows.shownCount(rows, selectedWindowID: nil, showsAll: false), 5)
        XCTAssertEqual(CardRows.shownCount(rows, selectedWindowID: "@2", showsAll: false), 5, "the selected Window and its Panes are in the first five")
        XCTAssertEqual(CardRows.shownCount(rows, selectedWindowID: "@3", showsAll: false), 7, "the selected Window would hide")
        XCTAssertEqual(CardRows.shownCount(rows, selectedWindowID: "@1", showsAll: true), 7)
        XCTAssertEqual(CardRows.shownCount(Array(rows.prefix(3)), selectedWindowID: nil, showsAll: false), 3)
    }
}
