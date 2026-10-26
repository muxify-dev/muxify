import XCTest
@testable import MuxifyCore

final class AgentGuardTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: made + "/repo/src/deep", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/repo-feature", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: made + "/link", withDestinationPath: "repo")
        root = made
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func agent(_ id: String, at path: String, _ status: AgentStatus? = .working) -> Agent {
        Agent(paneID: id, kind: .claude, status: status, unread: false, windowID: "@1", sessionID: "$1", sessionName: "s",
              windowIndex: 0, windowTitle: "w", label: "", path: path)
    }

    private func guarded(_ agents: [Agent]) -> [String] {
        AgentGuard.agents(in: .local(root + "/repo"), among: agents).map(\.paneID)
    }

    func testAnAgentInTheWorktreeOrBelowItCounts() {
        XCTAssertEqual(guarded([agent("%1", at: root + "/repo"), agent("%2", at: root + "/repo/src/deep")]), ["%1", "%2"])
    }

    func testAnAgentThroughASymlinkedPathCounts() {
        XCTAssertEqual(guarded([agent("%1", at: root + "/link/src")]), ["%1"])
        XCTAssertEqual(AgentGuard.agents(in: .local(root + "/link"), among: [agent("%1", at: root + "/repo/src")]).map(\.paneID), ["%1"],
                       "the Worktree's own spelling may be the symlink")
    }

    func testAnAgentInAnotherWorktreeOfTheRepositoryDoesNotCount() {
        // A sibling folder that starts with the Worktree's name is not inside it.
        XCTAssertEqual(guarded([agent("%1", at: root + "/repo-feature"), agent("%2", at: root)]), [])
    }

    func testAnAgentOutsideTheRepositoryDoesNotCount() {
        XCTAssertEqual(guarded([agent("%1", at: root + "/elsewhere"), agent("%2", at: "/tmp"), agent("%3", at: "")]), [])
    }

    func testOnlyAWorkingOrBlockedAgentCounts() {
        let statuses: [AgentStatus?] = [.working, .blocked, .done, .failed, nil]
        let agents = statuses.enumerated().map { agent("%\($0.offset)", at: root + "/repo", $0.element) }
        XCTAssertEqual(guarded(agents), ["%0", "%1"])
    }
}
