import XCTest
@testable import MuxifyCore

final class WorktreeTests: XCTestCase {
    private func config(_ text: String) throws -> Config {
        try Config.load(path: "/cfg/muxify/config.yaml") { _ in text }.get()
    }

    func testConfigHasNoWorktreeDirectoryAndReportsTheRemovedKeysAsUnknown() throws {
        XCTAssertEqual(try config("").topics, Config.Topics())
        let removed = try config("topics:\n  worktree: true\n  worktree_dir: /trees")
        XCTAssertEqual(removed.problems, [ConfigProblem(path: "/cfg/muxify/config.yaml", line: 2, message: "unknown key \"topics.worktree\""),
                                          ConfigProblem(path: "/cfg/muxify/config.yaml", line: 3, message: "unknown key \"topics.worktree_dir\"")])
        XCTAssertFalse(Config.template.contains("worktree_dir"))
        XCTAssertFalse(Config.template.contains("#   worktree: false"))
        XCTAssertEqual(try config("topics: []").problems.count, 1)
        XCTAssertEqual(try config("topics: {other: true}").problems.count, 1)
    }

    func testNewWorktreesGoToTheWorktreesFolderBesideTheTopicRecords() {
        func paths(_ environment: [String: String]) -> MuxifyPaths { MuxifyPaths(environment: environment, home: "/Users/me") }
        XCTAssertEqual(paths(["XDG_STATE_HOME": "/xdg state"]).worktrees.path, "/xdg state/muxify/worktrees")
        XCTAssertEqual(paths(["XDG_STATE_HOME": "/xdg state"]).topics.path, "/xdg state/muxify/topics")
        XCTAssertEqual(paths(["XDG_STATE_HOME": "/xdg state"]).zenFile.path, "/xdg state/muxify/zen.json")
        XCTAssertEqual(paths([:]).worktrees.path, "/Users/me/.local/state/muxify/worktrees")
        XCTAssertEqual(paths(["XDG_STATE_HOME": ""]).worktrees.path, "/Users/me/.local/state/muxify/worktrees", "an empty value is unset")
    }

    func testPlanMakesTheWorktreeFromTheBaseApartFromTheTmuxCommandsAndRecordsItAsCreated() throws {
        var sessionPath = SessionPath(path: "/work/game source", name: "team/game")
        sessionPath.alias = "My Game"
        sessionPath.layout = .plainRepository([Worktree(path: "/work/game source", branch: "main")])
        let plan = try TopicSessionPlan(topic: TopicRecord(id: "topic", title: "Fix links", slug: "fix-links"), sessionPath: sessionPath,
                                        workingCopy: .newWorktree(at: "c0ffee", root: "/work trees"), windows: [], sessionPaths: [sessionPath]).edit
        let worktree = TopicPlan.WorktreeSpec(repositoryPath: sessionPath.folder.path, path: "/work trees/team/game/fix-links", branch: "fix-links")
        XCTAssertEqual(worktree.arguments, ["worktree", "add", "-b", "fix-links", "/work trees/team/game/fix-links"])
        XCTAssertEqual(plan.newWorktree, TopicPlan.NewWorktree(worktree: worktree, commit: "c0ffee"))
        XCTAssertEqual(Array(plan.commands.prefix(2)), [
            .tmuxMaking(["new-session", "-d", "-s", "team/game/fix-links", "-c", worktree.path]),
            .tmux(["set-option", "-t", "=team/game/fix-links:", "@muxify_topic", "topic"]),
        ])
        var record = try XCTUnwrap(plan.record)
        record.title = "New title"
        record.slug = "new-title"
        let decoded = try JSONDecoder().decode(TopicRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.sessions, [.object([
            "id": try XCTUnwrap(plan.record?.sessions.first?["id"]),
            "name": .string("team/game/fix-links"),
            "base_name": .string("team/game"),
            "directory": .string(worktree.path),
            "repository_path": .string(sessionPath.folder.path),
            "worktree_path": .string(worktree.path),
            "branch": .string("fix-links"),
            "worktree_created": .bool(true),
            "base": .string("c0ffee"),
        ])])
    }

    func testNewWorktreeOfABareRepositoryGoesToTheWorktreesFolderAsForAPlainOne() throws {
        var sessionPath = SessionPath(path: "/work/game_server", name: "game_server")
        let release = Worktree(path: "/work/game_server/release", branch: "release-line")
        sessionPath.layout = .bareRepository([release])
        let plan = try TopicSessionPlan(topic: TopicRecord(id: "topic", title: "Fix links", slug: "fix-links"), sessionPath: sessionPath,
                                        workingCopy: .newWorktree(at: "c0ffee", root: "/state/muxify/worktrees"), windows: [], sessionPaths: [sessionPath]).edit
        let path = "/state/muxify/worktrees/game_server/fix-links"
        XCTAssertEqual(plan.newWorktree, TopicPlan.NewWorktree(worktree: .init(repositoryPath: sessionPath.folder.path, path: path, branch: "fix-links"), commit: "c0ffee"))
        XCTAssertEqual(plan.commands.first, .tmuxMaking(["new-session", "-d", "-s", "game_server/fix-links", "-c", path]))
    }

    func testShellRunsInRequestedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try Shell.run("/bin/pwd", [], directory: directory.path)
        XCTAssertEqual(URL(fileURLWithPath: result.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath(),
                       directory.resolvingSymlinksInPath())
    }

    /// The branch read for the Worktree at /trees/fix, which a Topic record remembers unless `remembered` is false.
    private func worktreeBranch(head: String?, pointer: String = "gitdir: /repo/.git/worktrees/fix\n", remembered: Bool = true) -> String? {
        var record = TopicRecord(id: "topic", title: "Fix")
        if remembered {
            record.sessions = [.object(["repository_path": .string("/repo"), "worktree_path": .string("/trees/fix")])]
        }
        var files = ["/trees/fix/.git": pointer]
        files["/repo/.git/worktrees/fix/HEAD"] = head
        return TopicBranches(records: [record]) { files[$0] }[.local("/trees/fix")]
    }

    func testBranchReadsHeadNamesAndRelativeGitdir() {
        for branch in ["fix", "feature/long-branch-name"] {
            XCTAssertEqual(worktreeBranch(head: "ref: refs/heads/\(branch)\n"), branch)
        }
        XCTAssertEqual(worktreeBranch(head: "ref: refs/heads/feature/fix\n", pointer: "gitdir: ../../repo/.git/worktrees/fix\n"), "feature/fix")
    }

    func testBranchIsAbsentForDetachedMissingMalformedAndUnrememberedWorktrees() {
        for head in [nil, "", "123456789abcdef\n", "ref: refs/tags/v1\n", "ref: refs/heads/\n",
                     "ref: refs/heads/fix\nref: refs/heads/other", "ref: refs/heads/bad name"] {
            XCTAssertNil(worktreeBranch(head: head), head ?? "missing")
        }
        for pointer in ["", "gitdir: ", "garbage", "gitdir: /missing", "gitdir: /repo\nother"] {
            XCTAssertNil(worktreeBranch(head: "ref: refs/heads/feature/fix", pointer: pointer), pointer)
        }
        XCTAssertNil(worktreeBranch(head: "ref: refs/heads/feature/fix", remembered: false))
    }

    func testGitFailureNamesGit() {
        XCTAssertThrowsError(try Shell.run("/usr/bin/git", ["not-a-command"])) { error in
            XCTAssertTrue(String(describing: error).hasPrefix("git exited with "))
        }
    }
}
