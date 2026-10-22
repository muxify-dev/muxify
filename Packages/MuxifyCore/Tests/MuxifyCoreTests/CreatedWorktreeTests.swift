import XCTest
@testable import MuxifyCore

/// Real git in a temp folder: the Worktree a Topic creates, and which Worktrees Settle may remove.
final class CreatedWorktreeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func git(_ arguments: [String], in directory: String) throws -> String {
        try Shell.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"] + arguments, directory: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func path(_ name: String) -> String { (root.appendingPathComponent(name).path as NSString).standardizingPath }

    private func commit(_ message: String, in directory: String) throws {
        try message.write(toFile: directory + "/" + message, atomically: true, encoding: .utf8)
        _ = try git(["add", message], in: directory)
        _ = try git(["commit", "-q", "-m", message], in: directory)
    }

    func testNewWorktreeStartsAtTheBaseWorktreesHeadIncludingItsUnpushedCommit() throws {
        let origin = path("origin.git"), work = path("work")
        _ = try git(["init", "-q", "--bare", "-b", "main", origin], in: root.path)
        _ = try git(["clone", "-q", origin, work], in: root.path)
        try commit("pushed", in: work)
        _ = try git(["push", "-q", "-u", "origin", "main"], in: work)
        try commit("local", in: work)
        let base = Worktree(path: work, branch: "main")
        let spec = TopicPlan.WorktreeSpec(repositoryPath: work, path: path("trees/work/fix-links"), branch: "fix-links")
        try TopicWorktrees.add(spec, at: try TopicWorktrees.commit(nil, in: base))
        XCTAssertEqual(try git(["rev-parse", "HEAD"], in: spec.path), try git(["rev-parse", "HEAD"], in: work))
        XCTAssertNotEqual(try git(["rev-parse", "HEAD"], in: spec.path), try git(["rev-parse", "origin/main"], in: work))
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: spec.path), "fix-links")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spec.path + "/local"))
    }

    func testFailedWorktreeAddReportsGitsMessage() throws {
        let work = path("work")
        _ = try git(["init", "-q", "-b", "main", work], in: root.path)
        try commit("init", in: work)
        _ = try git(["branch", "clash"], in: work)
        let spec = TopicPlan.WorktreeSpec(repositoryPath: work, path: path("trees/clash"), branch: "clash")
        XCTAssertThrowsError(try TopicWorktrees.add(spec, at: try git(["rev-parse", "HEAD"], in: work))) { error in
            XCTAssertTrue(String(describing: error).contains("a branch named 'clash' already exists"), String(describing: error))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spec.path))
    }

    func testSettleMayRemoveOnlyWorktreesInMuxifysFolderThatTheTopicCreated() throws {
        let work = path("work")
        _ = try git(["init", "-q", "-b", "main", work], in: root.path)
        try commit("init", in: work)
        let inside = { (branch: String) in self.path("worktrees/work/" + branch) }
        for (branch, folder) in [("created", inside("created")), ("picked", inside("picked")), ("legacy", inside("legacy")),
                                 ("outside", path("outside"))] {
            _ = try git(["worktree", "add", "-q", "-b", branch, folder], in: work)
        }
        func session(_ branch: String, _ folder: String, created: JSONValue?) -> JSONValue {
            var fields: [String: JSONValue] = ["repository_path": .string(work), "worktree_path": .string(folder), "branch": .string(branch)]
            fields["worktree_created"] = created
            return .object(fields)
        }
        var topic = TopicRecord(id: "topic")
        topic.sessions = [session("created", inside("created"), created: .bool(true)), session("picked", inside("picked"), created: .bool(false)),
                          session("legacy", inside("legacy"), created: nil), session("outside", path("outside"), created: .bool(true))]
        XCTAssertEqual(Set(TopicWorktrees.merged(in: topic, root: path("worktrees")).map(\.path)), [inside("created")],
                       "a picked Worktree and one outside Muxify's folder are never removed")
    }
}
