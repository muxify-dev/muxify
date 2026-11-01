import XCTest
@testable import MuxifyCore

final class TopicBranchHoldersTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: made + "/repo", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: made + "/other", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: made + "/link", withDestinationPath: "repo")
        root = made
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func record(_ id: String, settled: Bool = false, sessions: [[String: JSONValue]]) -> TopicRecord {
        var record = TopicRecord(id: id, title: id)
        record.settledAt = settled ? "2026-01-01T00:00:00Z" : nil
        record.sessions = sessions.map(JSONValue.object)
        return record
    }

    private func session(repository: String? = nil, worktree: String? = nil, branch: String?) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["id": .string("s"), "directory": .string(root + "/repo")]
        fields["repository_path"] = repository.map(JSONValue.string)
        fields["worktree_path"] = worktree.map(JSONValue.string)
        fields["branch"] = branch.map(JSONValue.string)
        return fields
    }

    private func holders(_ records: [TopicRecord], branch: String = "fix") -> [String] {
        TopicBranchHolders.records(remembering: branch, in: [.local(root + "/repo")], among: records).map(\.id)
    }

    func testATopicThatRemembersTheBranchInTheRepositoryIsFound() {
        let records = [record("a", sessions: [session(repository: root + "/repo", worktree: root + "/wt", branch: "fix")]),
                       record("b", sessions: [session(repository: root + "/repo", worktree: root + "/wt2", branch: "other")])]
        XCTAssertEqual(holders(records), ["a"])
    }

    func testDormantAndSettledTopicsCountAsOpenOnesDo() {
        let kept = session(repository: root + "/repo", branch: "fix")
        XCTAssertEqual(holders([record("open", sessions: [kept]), record("done", settled: true, sessions: [kept]),
                                record("empty", sessions: [])]), ["open", "done"])
    }

    func testABranchOfTheSameNameInAnotherRepositoryIsNotRemembered() {
        XCTAssertEqual(holders([record("a", sessions: [session(repository: root + "/other", branch: "fix")])]), [])
    }

    func testTheWorktreeFolderAloneIdentifiesTheRepositoryAndSymlinksAreTheSameFolder() {
        XCTAssertEqual(holders([record("a", sessions: [session(worktree: root + "/link", branch: "fix")])]), ["a"])
        XCTAssertEqual(holders([record("b", sessions: [session(repository: root + "/link", branch: "fix")])]), ["b"])
    }

    func testASessionWithoutAWorktreeRemembersNoBranch() {
        XCTAssertEqual(holders([record("a", sessions: [session(repository: root + "/repo", branch: nil)])]), [])
    }
}
