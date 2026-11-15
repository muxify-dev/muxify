import XCTest
@testable import MuxifyCore

final class WorktreeTests: XCTestCase {
    func testNewWorktreesGoToTheWorktreesFolderBesideTheTopicRecords() {
        func paths(_ environment: [String: String]) -> MuxifyPaths { MuxifyPaths(environment: environment, home: "/Users/me") }
        XCTAssertEqual(paths(["XDG_STATE_HOME": "/xdg state"]).worktrees.path, "/xdg state/muxify/worktrees")
        XCTAssertEqual(paths(["XDG_STATE_HOME": "/xdg state"]).stateDatabase.path, "/xdg state/muxify/muxify.db")
        XCTAssertEqual(paths([:]).worktrees.path, "/Users/me/.local/state/muxify/worktrees")
        XCTAssertEqual(paths(["XDG_STATE_HOME": ""]).worktrees.path, "/Users/me/.local/state/muxify/worktrees", "an empty value is unset")
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
