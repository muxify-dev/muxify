import XCTest
@testable import MuxifyCore

final class WorktreeWindowTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: made + "/repo-feature/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/repo", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: made + "/link", withDestinationPath: "repo-feature")
        root = made
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func window(_ id: String, session: String, index: Int = 0, active: Bool = true, activity: Int = 0) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$" + session, sessionName: session, index: index, name: "shell", paneTitle: "", path: "",
                   command: "zsh", isActive: active, paneCount: 1, hasBell: false, sessionActivity: activity, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [])
    }

    private func pane(_ id: String, in windowID: String, at path: String) -> TmuxPane {
        TmuxPane(id: id, windowID: windowID, path: path, command: "zsh", agent: "", agentStatus: "", unread: false)
    }

    private func choose(_ windows: [TmuxWindow], _ panes: [TmuxPane], visits: [String: Date] = [:]) -> String? {
        WorktreeWindow.mostRecent(in: .local(root + "/repo-feature"), windows: windows, panes: panes) { visits[$0.sessionName] }?.id
    }

    func testAWindowWithAPaneInTheWorktreeOrBelowItIsChosen() {
        let windows = [window("@1", session: "a"), window("@2", session: "b")]
        XCTAssertEqual(choose(windows, [pane("%1", in: "@1", at: root + "/repo"), pane("%2", in: "@2", at: root + "/repo-feature/src")]), "@2")
    }

    func testAPaneThroughASymlinkedPathCounts() {
        XCTAssertEqual(choose([window("@1", session: "a")], [pane("%1", in: "@1", at: root + "/link/src")]), "@1")
    }

    func testNoWindowIsChosenWhenNoPaneIsInTheWorktree() {
        let windows = [window("@1", session: "a"), window("@2", session: "b")]
        // The main Worktree, a folder that only starts with the Worktree's name, and a Pane with no folder.
        XCTAssertNil(choose(windows, [pane("%1", in: "@1", at: root + "/repo"), pane("%2", in: "@2", at: root + "/repo-feature2"),
                                      pane("%3", in: "@2", at: "")]))
        XCTAssertNil(choose([], []))
    }

    func testAnyPaneOfAWindowCountsNotOnlyTheActiveOne() {
        let windows = [window("@1", session: "a")]
        XCTAssertEqual(choose(windows, [pane("%1", in: "@1", at: root + "/repo"), pane("%2", in: "@1", at: root + "/repo-feature")]), "@1")
    }

    func testTheWindowVisitedLastWins() {
        let windows = [window("@1", session: "a"), window("@2", session: "b"), window("@3", session: "c")]
        let panes = windows.map { pane("%" + $0.id.dropFirst(), in: $0.id, at: root + "/repo-feature") }
        let visits = ["a": Date(timeIntervalSince1970: 100), "b": Date(timeIntervalSince1970: 300), "c": Date(timeIntervalSince1970: 200)]
        XCTAssertEqual(choose(windows, panes, visits: visits), "@2")
        // A Window with no visit comes after every one that has.
        XCTAssertEqual(choose(windows, panes, visits: ["c": Date(timeIntervalSince1970: 1)]), "@3")
    }

    func testWithNoVisitsTheActiveWindowThenTheLatestSessionActivityWins() {
        let panes = ["@1", "@2", "@3"].enumerated().map { pane("%\($0.offset)", in: $0.element, at: root + "/repo-feature") }
        let windows = [window("@1", session: "a", active: false, activity: 900), window("@2", session: "b", activity: 100),
                       window("@3", session: "c", activity: 200)]
        XCTAssertEqual(choose(windows, panes), "@3")
        XCTAssertEqual(choose([windows[0], windows[1]], panes), "@2", "an inactive Window loses to an active one")
    }

    func testInOneSessionTheActiveWindowWins() {
        let windows = [window("@1", session: "a", index: 0, active: false), window("@2", session: "a", index: 1)]
        let panes = [pane("%1", in: "@1", at: root + "/repo-feature"), pane("%2", in: "@2", at: root + "/repo-feature")]
        XCTAssertEqual(choose(windows, panes, visits: ["a": Date()]), "@2")
    }
}
