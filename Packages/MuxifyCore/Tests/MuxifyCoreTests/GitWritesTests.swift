#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest
@testable import MuxifyCore

/// Each of the Git View's writes that need no network, run by `GitWriter` against temporary repositories: what the
/// Git View's scripts did on the Mac, now on whichever machine has the repository.
final class GitWritesTests: XCTestCase {
    private var fixture: GitTestRepository!
    private var repository: String { fixture.path }
    private var directory: URL { fixture.directory }

    override func setUpWithError() throws {
        fixture = try GitTestRepository()
        try run("cd \"$1\" && git worktree add -q -b other ../linked", repository)
    }

    override func tearDown() {
        fixture?.remove()
    }

    /// Runs a script, its first argument as `$1`, with the repository's private HOME.
    @discardableResult
    private func run(_ script: String, _ arguments: String...) throws -> String {
        try GitTestRepository.Scripts(environment: fixture.environment).runScript(script, arguments: arguments, timeout: 30)
    }

    /// Runs a write as the Git View runs it, and answers what git printed.
    @discardableResult
    private func write(_ write: GitWrite) throws -> String {
        try fixture.writer.run(write)
    }

    private func status() throws -> [String] {
        try run("cd \"$1\" && git status --porcelain --untracked-files=all", repository).split(separator: "\n").map(String.init)
    }

    func testSpaceStagesAndUnstages() throws {
        try write(.stage(root: repository, paths: ["c.txt", "a.swift"]))
        XCTAssertEqual(try status(), ["M  a.swift", "A  c.txt"])
        try write(.unstage(root: repository, paths: ["."]))
        XCTAssertEqual(try status(), [" M a.swift", "?? c.txt"])
        // A deleted file in a folder is staged with it.
        try run("cd \"$1\" && mkdir sub && printf 'x\\n' > sub/x && git add sub && git commit -qm x && rm sub/x", repository)
        try write(.stage(root: repository, paths: ["sub"]))
        XCTAssertEqual(try status(), [" M a.swift", "D  sub/x", "?? c.txt"])
    }

    func testCommitTakesWhatsStaged() throws {
        let hash = try write(.commit(root: repository, message: "Stage a\n\nThe body."))
        XCTAssertEqual(try run("cd \"$1\" && git log -1 --format='%h %s|%b'", repository).trimmingCharacters(in: .whitespacesAndNewlines),
                       "\(hash.trimmingCharacters(in: .whitespacesAndNewlines)) Stage a|The body.")
        XCTAssertEqual(try status(), [" M a.swift", "?? c.txt"])
        // Nothing staged: git refuses, and nothing is staged for it.
        XCTAssertThrowsError(try write(.commit(root: repository, message: "Again")))
        XCTAssertEqual(try status(), [" M a.swift", "?? c.txt"])
    }

    func testAmendTakesWhatsStagedAndKeepsTheMessage() throws {
        try write(.commit(root: repository, message: "Stage a\n\nThe body."))
        let before = try run("cd \"$1\" && git rev-list --count HEAD", repository)
        try run("cd \"$1\" && git add c.txt", repository)
        try write(.amend(root: repository))
        XCTAssertEqual(try run("cd \"$1\" && git rev-list --count HEAD", repository), before)
        XCTAssertEqual(try run("cd \"$1\" && git log -1 --format='%s|%b'", repository).trimmingCharacters(in: .whitespacesAndNewlines), "Stage a|The body.")
        XCTAssertTrue(try run("cd \"$1\" && git show --name-only --format= HEAD", repository).contains("c.txt"))
        // A failing hook's words come back.
        try run("cd \"$1\" && printf '#!/bin/sh\\necho no amend today >&2\\nexit 1\\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit && printf 'z\\n' > z.txt && git add z.txt", repository)
        XCTAssertThrowsError(try write(.amend(root: repository))) { XCTAssertTrue(self.stderr(of: $0).contains("no amend today")) }
    }

    func testDiscardTakesEverythingOrOnlyWhatsUnstaged() throws {
        // a.swift is staged and changed again: only the change goes.
        try write(.discardUnstaged(root: repository, paths: ["a.swift"]))
        XCTAssertEqual(try status(), ["M  a.swift", "?? c.txt"])
        // Everything: back to the last commit, and the untracked file deleted.
        try write(.discard(root: repository, paths: ["a.swift", "c.txt"]))
        XCTAssertEqual(try status(), [])
        XCTAssertEqual(try run("cat \"$1/a.swift\"", repository), "let a = 1\n")
        // A rename goes back to its old path, and a new file is deleted.
        try run("cd \"$1\" && git mv a.swift moved.swift && printf 'n\\n' > n.txt && git add n.txt", repository)
        try write(.discard(root: repository, paths: ["moved.swift", "a.swift"]))
        try write(.discard(root: repository, paths: ["n.txt"]))
        XCTAssertEqual(try status(), [])
        // Paths are literal: app/[id] isn't a pattern that takes app/i too.
        try run("""
        cd "$1" && mkdir -p 'app/[id]' app/i && printf 'r\\n' > 'app/[id]/p' && printf 'i\\n' > app/i/p
        git add app && git commit -qm app && printf 'x\\n' >> 'app/[id]/p' && printf 'x\\n' >> app/i/p
        """, repository)
        try write(.discard(root: repository, paths: ["app/[id]/p"]))
        XCTAssertEqual(try status(), [" M app/i/p"])
    }

    /// A clean master with a staged new file, an unstaged change and an untracked file.
    private func prepareStash() throws {
        try run("""
        cd "$1" && git reset -q --hard && git stash clear && rm -f c.txt
        printf 'staged\\n' > s.txt && git add s.txt && printf 'let a = 3\\n' > a.swift && printf 'u\\n' > u.txt
        """, repository)
        XCTAssertEqual(try status(), [" M a.swift", "A  s.txt", "?? u.txt"])
    }

    private func git(_ arguments: String) throws -> String {
        try run("cd \"$1\" && git \(arguments)", repository)
    }

    func testStashTakesAllChangesAndLeavesUntrackedFilesAsGitDoes() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .all, message: "my note"))
        XCTAssertEqual(try status(), ["?? u.txt"])
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: my note\n")
        XCTAssertEqual(try git("show stash@{0}:a.swift"), "let a = 3\n")
        XCTAssertEqual(try git("show stash@{0}:s.txt"), "staged\n")
        // No message: git's own.
        try run("cd \"$1\" && printf 'let a = 4\\n' > a.swift", repository)
        try write(.stash(root: repository, kind: .all, message: ""))
        XCTAssertTrue(try git("stash list --format=%gs").hasPrefix("WIP on master: "))
    }

    func testStashCanIncludeUntrackedFiles() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .untracked, message: "everything"))
        XCTAssertEqual(try status(), [])
        XCTAssertEqual(try git("show stash@{0}^3:u.txt"), "u\n")
    }

    func testStashCanTakeOnlyWhatIsStagedOrOnlyWhatIsNot() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .staged, message: "s"))
        XCTAssertEqual(try status(), [" M a.swift", "?? u.txt"])
        XCTAssertEqual(try git("diff --name-only stash@{0}^ stash@{0}"), "s.txt\n")
        // Only what isn't staged: what's staged stays staged, and no commit is left behind.
        try prepareStash()
        let commits = try git("rev-list --count HEAD")
        try write(.stash(root: repository, kind: .unstaged, message: "u"))
        XCTAssertEqual(try status(), ["A  s.txt", "?? u.txt"])
        XCTAssertEqual(try git("diff --name-only stash@{0}^ stash@{0}"), "a.swift\n")
        XCTAssertEqual(try git("show stash@{0}:a.swift"), "let a = 3\n")
        XCTAssertEqual(try git("rev-list --count HEAD"), commits)
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: u\n")
        // With nothing staged, it is a plain stash.
        try run("cd \"$1\" && git reset -q --hard && printf 'let a = 5\\n' > a.swift", repository)
        try write(.stash(root: repository, kind: .unstaged, message: ""))
        XCTAssertEqual(try status(), ["?? u.txt"])
    }

    func testTheResetOptionsDoWhatLazygitsDo() throws {
        let cases: [(String, [String])] = [
            ("nuke", []),
            ("unstaged", ["A  s.txt", "?? u.txt"]),
            ("untracked", [" M a.swift", "A  s.txt"]),
            ("staged", [" M a.swift", "?? u.txt"]),
            ("soft", [" M a.swift", "A  s.txt", "?? u.txt"]),
            ("mixed", [" M a.swift", "?? s.txt", "?? u.txt"]),
            ("hard", ["?? u.txt"]),
        ]
        for (reset, left) in cases {
            try prepareStash()
            try run("cd \"$1\" && git stash push -q -m kept -- a.swift && printf 'let a = 3\\n' > a.swift", repository)
            try write(.resetWorkingTree(root: repository, option: GitWrite.WorkingTreeReset(rawValue: reset)!))
            XCTAssertEqual(try status(), left, reset)
            // Discarding what's staged drops only the stash it made.
            XCTAssertEqual(try git("stash list --format=%gs"), "On master: kept\n", reset)
        }
        XCTAssertEqual(try git("show HEAD:a.swift"), try run("cat \"$1/a.swift\"", repository), "a hard reset left a.swift changed")
        // With nothing staged, git makes no stash, and the one on top stays.
        XCTAssertThrowsError(try write(.resetWorkingTree(root: repository, option: .staged))) {
            XCTAssertTrue(self.stderr(of: $0).contains("Nothing is staged."), self.stderr(of: $0))
        }
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: kept\n")
    }

    // MARK: Continuing, skipping and aborting

    /// A repository where `side` and `master` both changed f.txt, so merging, rebasing, cherry-picking and reverting
    /// conflict; `master` has a second commit that a revert of the first conflicts with.
    private func conflictedRepository() throws -> String {
        let path = directory.appendingPathComponent("ops").path
        try run("""
        cd "$1"
        git init -q -b master ops && cd ops
        printf 'base\\n' > f.txt && git add f.txt && git commit -q -m Base
        git checkout -q -b side
        printf 'side\\n' > f.txt && git commit -q -am 'Side one'
        printf 'side\\nmore\\n' > f.txt && git commit -q -am 'Side two'
        git checkout -q master
        printf 'master\\n' > f.txt && git commit -q -am 'Master one'
        printf 'master\\ntwo\\n' > f.txt && git commit -q -am 'Master two'
        """, directory.path)
        return path
    }

    private func git(_ arguments: String, in path: String) throws -> String {
        try run("cd \"$1\" && git \(arguments)", path)
    }

    private func resolve(_ path: String, _ text: String = "resolved") throws {
        try run("cd \"$1\" && printf '\(text)\\n' > f.txt && git add f.txt", path)
    }

    private func step(_ command: String, _ verb: String, in path: String) throws {
        try write(.operation(root: path, command: GitWrite.OperationCommand(rawValue: command)!, step: GitWrite.OperationStep(rawValue: verb)!))
    }

    /// Whether git is in the middle of something, by the state it keeps.
    private func inProgress(_ path: String) throws -> Bool {
        try run("cd \"$1\" && ls \"$(git rev-parse --git-dir)\"", path).split(separator: "\n").contains {
            ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD"].contains(String($0))
        }
    }

    func testContinueConcludesAMergeWithGitsMessageAndRefusesWhileConflictsRemain() throws {
        let path = try conflictedRepository()
        _ = try? git("merge side", in: path)
        XCTAssertThrowsError(try step("merge", "continue", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Conflicts remain"), self.stderr(of: $0))
        }
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("merge", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Merge branch 'side'\n")
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 3)
    }

    func testAbortGoesBackToBeforeTheMergeAndAMergeCannotBeSkipped() throws {
        let path = try conflictedRepository()
        let before = try git("rev-parse HEAD", in: path)
        _ = try? git("merge side", in: path)
        XCTAssertFalse(GitOperation.merge(["x"]).canSkip)
        try step("merge", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        XCTAssertEqual(try git("status --porcelain", in: path), "")
    }

    func testContinueGoesOnWithARebaseAndLeavesNewConflictsInChanges() throws {
        let path = try conflictedRepository()
        _ = try? git("checkout -q side && git rebase master", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path, "r1")
        // The second commit conflicts too: the continue says so and the rebase goes on.
        XCTAssertThrowsError(try step("rebase", "continue", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Conflicts remain"), self.stderr(of: $0))
        }
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        try resolve(path, "r2")
        try step("rebase", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log --format=%s", in: path), "Side two\nSide one\nMaster two\nMaster one\nBase\n")
        XCTAssertEqual(try git("symbolic-ref --short HEAD", in: path), "side\n")
    }

    func testSkipLeavesOutTheStepAndAbortRestoresTheBranchOfARebase() throws {
        let path = try conflictedRepository()
        let original = try git("rev-parse side", in: path)
        _ = try? git("checkout -q side && git rebase master", in: path)
        try step("rebase", "abort", in: path)
        XCTAssertEqual(try git("rev-parse HEAD", in: path), original)
        XCTAssertEqual(try git("symbolic-ref --short HEAD", in: path), "side\n")
        _ = try? git("rebase master", in: path)
        // Skipping the first commit; the second applies on its own, or conflicts again.
        _ = try? step("rebase", "skip", in: path)
        _ = try? git("checkout --theirs f.txt && git add f.txt", in: path)
        _ = try? step("rebase", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertFalse(try git("log --format=%s", in: path).contains("Side one"))
    }

    /// master (Base, Master one) and side (Base, Side one, Side two) touching other files, so they merge cleanly; `ahead`
    /// is a branch of one commit that master can fast-forward to.
    private func mergeableRepository() throws -> String {
        let path = directory.appendingPathComponent("merges").path
        try run("""
        cd "$1"
        git init -q -b master merges && cd merges
        printf 'base\\n' > f.txt && git add f.txt && git commit -q -m Base
        git checkout -q -b ahead
        printf 'a\\n' > a.txt && git add a.txt && git commit -q -m 'Ahead one'
        git checkout -q -b side master
        printf 's\\n' > s.txt && git add s.txt && git commit -q -m 'Side one'
        printf 's2\\n' > s.txt && git commit -q -am 'Side two'
        git checkout -q master
        """, directory.path)
        return path
    }

    private func merge(_ kind: String, _ branch: String, in path: String) throws {
        try write(.merge(root: path, branch: branch, kind: GitWrite.MergeKind(rawValue: kind)!, into: "master"))
    }

    func testAFastForwardMergeMovesTheBranchWhenItCanAndMakesAMergeCommitWhenItCannot() throws {
        let path = try mergeableRepository()
        try merge("ff", "ahead", in: path)
        XCTAssertEqual(try git("rev-parse HEAD", in: path), try git("rev-parse ahead", in: path))
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 2)
        // Master has moved on from side: git makes a merge commit, with its own message and no editor.
        try merge("ff", "side", in: path)
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 3)
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Merge branch 'side'\n")
    }

    func testAMergeWithMergeCommitIsNeverAFastForward() throws {
        let path = try mergeableRepository()
        let before = try git("rev-parse HEAD", in: path)
        try merge("no-ff", "ahead", in: path)
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 3)
        XCTAssertEqual(try git("rev-parse HEAD^1", in: path), before)
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Merge branch 'ahead'\n")
    }

    func testASquashMergeCommitsOneCommitWithGitsMessageAndCanLeaveItStaged() throws {
        let path = try mergeableRepository()
        let before = try git("rev-parse HEAD", in: path)
        try merge("squash", "side", in: path)
        XCTAssertEqual(try git("rev-parse HEAD^", in: path), before)
        XCTAssertEqual(try git("rev-list --parents -1 HEAD", in: path).split(separator: " ").count, 2, "a squash has one parent")
        XCTAssertTrue(try git("log -1 --format=%B", in: path).hasPrefix("Squashed commit of the following:"))
        XCTAssertTrue(try git("log -1 --format=%B", in: path).contains("Side two"))
        XCTAssertEqual(try git("status --porcelain", in: path), "")
        try run("cd \"$1\" && git reset -q --hard \(before)", path)
        try merge("squash-leave", "side", in: path)
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        XCTAssertEqual(try git("status --porcelain", in: path), "A  s.txt\n")
        XCTAssertFalse(try inProgress(path))
    }

    func testAMergeThatConflictsStaysInProgressAndIsToldApartFromOtherFailures() throws {
        let path = try conflictedRepository()
        XCTAssertThrowsError(try merge("no-ff", "side", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Merging 'side' into 'master' conflicted"), self.stderr(of: $0))
        }
        XCTAssertTrue(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        // c concludes it once the conflict is resolved and staged, and git's message is kept.
        try resolve(path)
        try write(.commit(root: path, message: "Merge branch 'side'"))
        XCTAssertFalse(try inProgress(path))
        // m aborts it.
        try run("cd \"$1\" && git reset -q --hard HEAD^", path)
        XCTAssertThrowsError(try merge("ff", "side", in: path))
        XCTAssertTrue(try inProgress(path))
        try step("merge", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        // Any other failure prints what git said.
        XCTAssertThrowsError(try merge("ff", "nowhere", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("nowhere"), self.stderr(of: $0))
        }
    }

    func testASquashMergeThatConflictsLeavesTheConflictsInChanges() throws {
        let path = try conflictedRepository()
        XCTAssertThrowsError(try merge("squash", "side", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("Squashing 'side' into 'master' conflicted"), self.stderr(of: $0))
        }
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        XCTAssertEqual(try git("rev-parse HEAD", in: path), try git("rev-parse master", in: path))
    }

    func testAnUncommittedChangeThatTheMergeWouldOverwriteStopsItWithGitsWords() throws {
        let path = try mergeableRepository()
        try run("cd \"$1\" && git checkout -q side && printf 'x\\n' > a.txt && git add a.txt && git commit -q -m 'Side a' && git checkout -q master && printf 'mine\\n' > a.txt", path)
        XCTAssertThrowsError(try merge("ff", "side", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("a.txt"), self.stderr(of: $0))
        }
        XCTAssertEqual(try git("status --porcelain", in: path), "?? a.txt\n")
    }

    private func resetRepository() throws -> String {
        let path = try mergeableRepository()
        // master is at Base; side is two commits ahead of it. Check side out, with a staged and an unstaged change and an untracked file.
        try run("cd \"$1\" && git checkout -q side && printf 'staged\\n' > a.txt && git add a.txt && printf 'unstaged\\n' > s.txt && printf 'u\\n' > untracked.txt", path)
        return path
    }

    func testASoftResetKeepsTheChangesBetweenTheCommitsStaged() throws {
        let path = try resetRepository()
        try write(.reset(root: path, kind: .soft, target: try git("rev-parse master", in: path).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), try git("rev-parse master", in: path))
        XCTAssertEqual(try git("rev-parse --abbrev-ref HEAD", in: path), "side\n")
        XCTAssertEqual(try git("status --porcelain", in: path), "A  a.txt\nAM s.txt\n?? untracked.txt\n")
    }

    func testAMixedResetKeepsThemUnstaged() throws {
        let path = try resetRepository()
        try write(.reset(root: path, kind: .mixed, target: try git("rev-parse master", in: path).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), try git("rev-parse master", in: path))
        XCTAssertEqual(try git("status --porcelain", in: path), "?? a.txt\n?? s.txt\n?? untracked.txt\n")
        XCTAssertEqual(try git("diff --cached --name-only", in: path), "")
    }

    func testAHardResetDiscardsTheChangesAndLeavesUntrackedFiles() throws {
        let path = try resetRepository()
        try write(.reset(root: path, kind: .hard, target: try git("rev-parse master", in: path).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), try git("rev-parse master", in: path))
        XCTAssertEqual(try git("status --porcelain", in: path), "?? untracked.txt\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + "/s.txt"))
    }

    func testAResetThatGitRefusesPrintsItsMessage() throws {
        let path = try resetRepository()
        XCTAssertThrowsError(try write(.reset(root: path, kind: .hard, target: "nowhere"))) {
            XCTAssertTrue(self.stderr(of: $0).contains("nowhere"), self.stderr(of: $0))
        }
    }

    private func sha(_ revision: String, in path: String) throws -> String {
        try git("rev-parse \(revision)", in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testTheSnapshotNamesTheCommonGitDirectoryTheSameFromEveryWorktree() throws {
        let path = try mergeableRepository()
        let linked = directory.appendingPathComponent("merges-linked").path
        try git("worktree add -q -b linked \"\(linked)\"", in: path)
        let main = try GitReads.parseSnapshot(run(GitReads.snapshotScript, path)).get()
        let other = try GitReads.parseSnapshot(run(GitReads.snapshotScript, linked)).get()
        XCTAssertFalse(main.commonDirectory.isEmpty)
        XCTAssertEqual(main.commonDirectory, other.commonDirectory)
        XCTAssertNotEqual(main.root, other.root)
        let unrelated = try GitReads.parseSnapshot(run(GitReads.snapshotScript, try conflictedRepository())).get()
        XCTAssertNotEqual(unrelated.commonDirectory, main.commonDirectory)
    }

    func testCherryPickingPutsTheCopiesOnTheBranchOldestFirstWhateverTheCopyOrder() throws {
        let path = try mergeableRepository()
        let newest = try sha("side", in: path), oldest = try sha("side~1", in: path)
        // Copied newest first, as a user may; the pick still goes oldest first, or "Side two" would not apply.
        try write(.cherryPick(root: path, commits: [newest, oldest]))
        XCTAssertEqual(try git("log --format=%s master~0 -2", in: path), "Side two\nSide one\n")
        XCTAssertEqual(try git("rev-parse --abbrev-ref HEAD", in: path), "master\n")
        XCTAssertFalse(try inProgress(path))
        // One commit alone, and commits of unrelated branches in any order.
        try git("reset -q --hard HEAD~2", in: path)
        try write(.cherryPick(root: path, commits: [try sha("ahead", in: path)]))
        XCTAssertEqual(try git("log --format=%s -1", in: path), "Ahead one\n")
        try git("reset -q --hard HEAD~1", in: path)
        try write(.cherryPick(root: path, commits: [try sha("ahead", in: path), newest, oldest]))
        XCTAssertEqual(try git("log --format=%s -3", in: path).split(separator: "\n").sorted(), ["Ahead one", "Side one", "Side two"])
        XCTAssertLessThan(try git("log --format=%s", in: path).range(of: "Side two")!.lowerBound,
                          try git("log --format=%s", in: path).range(of: "Side one")!.lowerBound)
    }

    func testACherryPickThatConflictsStopsWithTheConflictsAndMContinuesSkipsOrAbortsIt() throws {
        let path = try conflictedRepository()
        let one = try sha("side~1", in: path), two = try sha("side", in: path)
        XCTAssertThrowsError(try write(.cherryPick(root: path, commits: [two, one]))) {
            XCTAssertTrue(self.stderr(of: $0).contains("The cherry-pick conflicted"), self.stderr(of: $0))
        }
        XCTAssertTrue(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        try resolve(path)
        // The first pick is continued; the second conflicts with what was resolved, and stops again.
        XCTAssertThrowsError(try step("cherry-pick", "continue", in: path))
        XCTAssertEqual(try git("log --format=%s -1", in: path), "Side one\n")
        XCTAssertTrue(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        // m aborts the rest, back to where the paste began; another failure prints git's message.
        try step("cherry-pick", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log --format=%s -1", in: path), "Master two\n")
        XCTAssertThrowsError(try write(.cherryPick(root: path, commits: ["nowhere"]))) {
            XCTAssertTrue(self.stderr(of: $0).contains("nowhere"), self.stderr(of: $0))
        }
    }

    private func rebase(onto branch: String, in path: String) throws {
        try write(.rebase(root: path, onto: branch, head: "side"))
    }

    func testASimpleRebaseReplaysTheCommitsOnTopOfTheBranchWithNoEditor() throws {
        let path = try mergeableRepository()
        try run("cd \"$1\" && git checkout -q side", path)
        try rebase(onto: "ahead", in: path)
        XCTAssertEqual(try git("rev-parse --abbrev-ref HEAD", in: path), "side\n")
        XCTAssertEqual(try git("rev-parse ahead", in: path), try git("merge-base ahead side", in: path))
        XCTAssertEqual(try git("log --format=%s ahead..side", in: path), "Side two\nSide one\n")
        XCTAssertFalse(try inProgress(path))
    }

    func testARebaseThatConflictsStaysInProgressAndIsToldApartFromOtherFailures() throws {
        let path = try conflictedRepository()
        try run("cd \"$1\" && git checkout -q side", path)
        XCTAssertThrowsError(try write(.rebase(root: path, onto: "master", head: "side"))) {
            XCTAssertTrue(self.stderr(of: $0).contains("Rebasing 'side' onto 'master' conflicted"), self.stderr(of: $0))
        }
        XCTAssertTrue(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "UU f.txt\n")
        // m continues it once the conflict is resolved and staged; the next commit conflicts too.
        try resolve(path)
        XCTAssertThrowsError(try step("rebase", "continue", in: path))
        try resolve(path, "again")
        try step("rebase", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        // m aborts it, and skips it.
        try run("cd \"$1\" && git reset -q --hard ORIG_HEAD", path)
        XCTAssertThrowsError(try write(.rebase(root: path, onto: "master", head: "side")))
        try step("rebase", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log --format=%s master..side", in: path), "Side two\nSide one\n")
        // Any other failure prints what git said.
        XCTAssertThrowsError(try write(.rebase(root: path, onto: "nowhere", head: "side"))) {
            XCTAssertTrue(self.stderr(of: $0).contains("nowhere"), self.stderr(of: $0))
        }
    }

    func testAnUncommittedChangeStopsTheRebaseWithGitsWords() throws {
        let path = try mergeableRepository()
        try run("cd \"$1\" && git checkout -q side && printf 'dirty\\n' > s.txt", path)
        XCTAssertThrowsError(try rebase(onto: "ahead", in: path)) {
            XCTAssertTrue(self.stderr(of: $0).contains("unstaged changes"), self.stderr(of: $0))
        }
        XCTAssertFalse(try inProgress(path))
    }

    func testCherryPickAndRevertContinueSkipAndAbort() throws {
        let path = try conflictedRepository()
        let before = try git("rev-parse HEAD", in: path)
        _ = try? git("cherry-pick side", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("cherry-pick", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Side two\n")
        _ = try git("reset -q --hard \(before)", in: path)
        _ = try? git("cherry-pick side", in: path)
        try step("cherry-pick", "skip", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        _ = try? git("cherry-pick side", in: path)
        try step("cherry-pick", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("status --porcelain", in: path), "")
        // A revert of the first commit conflicts with the second.
        _ = try? git("revert HEAD~1", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("revert", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertTrue(try git("log -1 --format=%s", in: path).hasPrefix("Revert \"Master one\""))
        _ = try? git("revert HEAD~2", in: path)
        try step("revert", "skip", in: path)
        XCTAssertFalse(try inProgress(path))
        _ = try? git("revert HEAD~2", in: path)
        try step("revert", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
    }

    func testGitAmContinuesSkipsAndAborts() throws {
        let path = try conflictedRepository()
        let before = try git("rev-parse HEAD", in: path)
        try run("cd \"$1\" && git format-patch -1 side --stdout > ../side.patch", path)
        let patch = directory.appendingPathComponent("side.patch").path
        _ = try? git("am -3 \(patch)", in: path)
        XCTAssertTrue(try inProgress(path))
        try resolve(path)
        try step("am", "continue", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("log -1 --format=%s", in: path), "Side two\n")
        _ = try git("reset -q --hard \(before)", in: path)
        _ = try? git("am -3 \(patch)", in: path)
        try step("am", "skip", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
        _ = try? git("am -3 \(patch)", in: path)
        try step("am", "abort", in: path)
        XCTAssertFalse(try inProgress(path))
        XCTAssertEqual(try git("rev-parse HEAD", in: path), before)
    }

    /// What a failed script said.
    private func stderr(of error: Error) -> String {
        if case TmuxError.failed(_, let stderr) = error { return stderr }
        return String(describing: error)
    }

    private func stashSha(_ ref: String = "stash@{0}") throws -> String {
        try git("rev-parse \(ref)").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAStashIsAppliedAndStaysInTheList() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .all, message: "w"))
        XCTAssertEqual(try status(), ["?? u.txt"])
        try write(.stashEntry(root: repository, action: .apply, ref: "stash@{0}", sha: try stashSha()))
        XCTAssertEqual(try status(), [" M a.swift", "A  s.txt", "?? u.txt"])
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: w\n")
    }

    func testAStashIsPoppedAndDropped() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .all, message: "w"))
        try write(.stashEntry(root: repository, action: .pop, ref: "stash@{0}", sha: try stashSha()))
        XCTAssertEqual(try git("show :s.txt"), "staged\n", "the stash's new file is staged again, as git does")
        XCTAssertEqual(try git("stash list"), "")
        try write(.stash(root: repository, kind: .all, message: "second"))
        try write(.stashEntry(root: repository, action: .drop, ref: "stash@{0}", sha: try stashSha()))
        XCTAssertEqual(try git("stash list"), "")
        XCTAssertEqual(try status(), ["?? u.txt"], "dropping leaves the working tree as it is")
    }

    func testAStashEntryRefusesWhenTheListMovedUnderIt() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .all, message: "w"))
        let sha = try stashSha()
        try run("cd \"$1\" && printf 'again\\n' >> a.swift && git stash push -q -m newer", repository)
        // stash@{0} is now the newer one: nothing changes.
        XCTAssertThrowsError(try write(.stashEntry(root: repository, action: .drop, ref: "stash@{0}", sha: sha)))
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: newer\nOn master: w\n")
    }

    func testAConflictingPopKeepsTheStashAndLeavesTheConflictedFiles() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .all, message: "w"))
        try run("cd \"$1\" && printf 'let a = 4\\n' > a.swift && git commit -q -am other", repository)
        XCTAssertThrowsError(try write(.stashEntry(root: repository, action: .pop, ref: "stash@{0}", sha: try stashSha()))) { error in
            XCTAssertTrue(stderr(of: error).contains("conflicted"), stderr(of: error))
        }
        XCTAssertTrue(try status().contains("UU a.swift"))
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: w\n")
    }

    func testAnApplyThatGitRefusesSaysWhatGitSaid() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .all, message: "w"))
        try run("cd \"$1\" && printf 'let a = 5\\n' > a.swift", repository)
        XCTAssertThrowsError(try write(.stashEntry(root: repository, action: .apply, ref: "stash@{0}", sha: try stashSha()))) { error in
            XCTAssertTrue(stderr(of: error).contains("overwritten"), stderr(of: error))
        }
        XCTAssertEqual(try git("stash list --format=%gs"), "On master: w\n")
    }

    /// A clean master, and `diverged`, a branch whose a.swift differs from it.
    private func prepareCheckout() throws {
        try run("""
        cd "$1" && git reset -q --hard && git stash clear && rm -f c.txt
        git checkout -q -b diverged && printf 'let a = 9\\n' > a.swift && git commit -q -am diverge && git checkout -q master
        """, repository)
    }

    func testACheckoutSwitchesBranchAndCarriesChangesThatDontClash() throws {
        try prepareCheckout()
        try run("cd \"$1\" && printf 'u\\n' > u.txt", repository)
        try write(.checkout(root: repository, kind: .branch, target: "feature", autostash: false, base: nil))
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "feature")
        XCTAssertEqual(try status(), ["?? u.txt"])
    }

    func testACheckoutOfACommitLeavesADetachedHead() throws {
        try prepareCheckout()
        let sha = try git("rev-parse feature").trimmingCharacters(in: .whitespacesAndNewlines)
        try write(.checkout(root: repository, kind: .commit, target: sha, autostash: false, base: nil))
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(try git("rev-parse HEAD").trimmingCharacters(in: .whitespacesAndNewlines), sha)
    }

    func testAChangeThatWouldBeOverwrittenBlocksTheCheckoutAndIsToldApart() throws {
        try prepareCheckout()
        try run("cd \"$1\" && printf 'mine\\n' > a.swift", repository)
        XCTAssertThrowsError(try write(.checkout(root: repository, kind: .branch, target: "diverged", autostash: false, base: nil))) { error in
            XCTAssertTrue(stderr(of: error).hasPrefix(GitWrites.checkoutBlockedMarker), stderr(of: error))
            XCTAssertTrue(stderr(of: error).contains("overwritten"), stderr(of: error))
        }
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "master")
        XCTAssertEqual(try status(), [" M a.swift"])
    }

    func testAnAutostashCheckoutStashesChecksOutAndPops() throws {
        try prepareCheckout()
        try run("""
        cd "$1" && git checkout -q -b clash && printf 'let a = 1\\nline\\n' > a.swift && git commit -q -am clash && git checkout -q master
        printf 'top\\nlet a = 1\\n' > a.swift && printf 'u\\n' > u.txt
        """, repository)
        XCTAssertThrowsError(try write(.checkout(root: repository, kind: .branch, target: "clash", autostash: false, base: nil)))
        try write(.checkout(root: repository, kind: .branch, target: "clash", autostash: true, base: nil))
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "clash")
        XCTAssertEqual(try git("stash list"), "")
        XCTAssertEqual(try status(), [" M a.swift", "?? u.txt"])
        XCTAssertEqual(try run("cat \"$1/a.swift\"", repository), "top\nlet a = 1\nline\n")
    }

    func testAnAutostashCheckoutWithNothingToStashJustChecksOut() throws {
        try prepareCheckout()
        try write(.checkout(root: repository, kind: .branch, target: "diverged", autostash: true, base: nil))
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "diverged")
        XCTAssertEqual(try git("stash list"), "")
    }

    func testAnAutostashPopThatConflictsKeepsTheStash() throws {
        try prepareCheckout()
        try run("cd \"$1\" && printf 'mine\\n' > a.swift", repository)
        XCTAssertThrowsError(try write(.checkout(root: repository, kind: .branch, target: "diverged", autostash: true, base: nil))) { error in
            XCTAssertTrue(stderr(of: error).contains("conflicted"), stderr(of: error))
        }
        XCTAssertEqual(try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines), "diverged")
        XCTAssertTrue(try status().contains("UU a.swift"))
        XCTAssertEqual(try git("stash list --format=%gs").hasPrefix("On master: Autostash"), true)
    }

    private func currentBranch() throws -> String {
        try git("branch --show-current").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testANewBranchIsMadeOffAnotherBranchAndCheckedOut() throws {
        try prepareCheckout()
        try write(.checkout(root: repository, kind: .new, target: "topic", autostash: false, base: "diverged"))
        XCTAssertEqual(try currentBranch(), "topic")
        XCTAssertEqual(try git("rev-parse topic"), try git("rev-parse diverged"))
        // A name that is taken is git's to refuse.
        XCTAssertThrowsError(try write(.checkout(root: repository, kind: .new, target: "topic", autostash: false, base: "master"))) { error in
            XCTAssertTrue(stderr(of: error).contains("already exists"), stderr(of: error))
        }
    }

    func testThePreviousBranchIsWhatCheckoutDashGoesBackTo() throws {
        try prepareCheckout()
        let before = try GitReads.parseSnapshot(run(GitReads.snapshotScript, repository)).get()
        XCTAssertEqual(before.previousBranch, "diverged", "prepareCheckout moved from diverged to master")
        try write(.checkout(root: repository, kind: .previous, target: "-", autostash: false, base: nil))
        XCTAssertEqual(try currentBranch(), "diverged")
        let after = try GitReads.parseSnapshot(run(GitReads.snapshotScript, repository)).get()
        XCTAssertEqual(after.previousBranch, "master")
        // A repository that never switched has none, and says so.
        try run("git init -q -b main \"$1/fresh\" && cd \"$1/fresh\" && git -c user.email=a@b -c user.name=a commit -q --allow-empty -m x", directory.path)
        let fresh = directory.appendingPathComponent("fresh").path
        XCTAssertNil(try GitReads.parseSnapshot(run(GitReads.snapshotScript, fresh)).get().previousBranch)
        XCTAssertThrowsError(try write(.checkout(root: fresh, kind: .previous, target: "-", autostash: false, base: nil))) { error in
            XCTAssertTrue(stderr(of: error).contains("no previous branch"), stderr(of: error))
        }
    }

    func testARemoteBranchMakesALocalBranchThatTracksIt() throws {
        try prepareCheckout()
        try run("""
        cd "$1" && git init -q --bare ../origin.git && git remote add origin ../origin.git
        git push -q origin feature:remote-only && git fetch -q origin
        """, repository)
        let snapshot = try GitReads.parseSnapshot(run(GitReads.snapshotScript, repository)).get()
        XCTAssertEqual(snapshot.remoteBranches, ["origin/remote-only"])
        try write(.checkout(root: repository, kind: .remote, target: "origin/remote-only", autostash: false, base: nil))
        XCTAssertEqual(try currentBranch(), "remote-only")
        XCTAssertEqual(try git("rev-parse --abbrev-ref remote-only@{upstream}").trimmingCharacters(in: .whitespacesAndNewlines),
                       "origin/remote-only")
    }

    func testARenameChangesTheNameAndKeepsTheBranch() throws {
        try prepareCheckout()
        let sha = try git("rev-parse feature")
        try write(.renameBranch(root: repository, branch: "feature", name: "renamed"))
        XCTAssertEqual(try git("rev-parse renamed"), sha)
        XCTAssertFalse(try git("branch --format='%(refname:short)'").split(separator: "\n").contains("feature"))
        XCTAssertThrowsError(try write(.renameBranch(root: repository, branch: "renamed", name: "master"))) { error in
            XCTAssertTrue(stderr(of: error).contains("already exists"), stderr(of: error))
        }
    }

    private func branchNames() throws -> [String] {
        try git("branch --format='%(refname:short)'").split(separator: "\n").map(String.init)
    }

    func testDeletingAMergedBranchNeedsNoForceAndAnUnmergedOneAsksFirst() throws {
        try run("cd \"$1\" && git branch merged master", repository)
        try write(.deleteBranch(root: repository, branch: "merged", force: false))
        XCTAssertFalse(try branchNames().contains("merged"))
        // git refuses an unmerged branch, and the script says so apart from any other failure.
        XCTAssertThrowsError(try write(.deleteBranch(root: repository, branch: "feature", force: false))) { error in
            XCTAssertEqual(stderr(of: error).trimmingCharacters(in: .whitespacesAndNewlines), GitWrites.branchNotMergedMarker)
        }
        XCTAssertTrue(try branchNames().contains("feature"))
        try write(.deleteBranch(root: repository, branch: "feature", force: true))
        XCTAssertFalse(try branchNames().contains("feature"))
    }

    func testTheCurrentBranchAndAnotherWorktreesBranchAreNotDeletedEvenWithForce() throws {
        for (branch, force) in [("master", "0"), ("master", "1"), ("other", "0"), ("other", "1")] {
            XCTAssertThrowsError(try write(.deleteBranch(root: repository, branch: branch, force: force == "1"))) { error in
                // git's wording differs by version: "checked out at" or "used by worktree at".
                XCTAssertTrue(stderr(of: error).contains("checked out") || stderr(of: error).contains("worktree"), stderr(of: error))
                XCTAssertFalse(stderr(of: error).hasPrefix(GitWrites.branchNotMergedMarker))
            }
        }
        XCTAssertTrue(try branchNames().contains("master"))
        XCTAssertTrue(try branchNames().contains("other"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("linked").path), "no Worktree is removed")
    }

    func testTheSnapshotNamesTheRepositoryFolderFromAnyWorktree() throws {
        let real = (repository as NSString).resolvingSymlinksInPath
        for path in [repository, directory.appendingPathComponent("linked").path] {
            let snapshot = try GitReads.parseSnapshot(run(GitReads.snapshotScript, path)).get()
            XCTAssertEqual((snapshot.repositoryFolder as NSString).resolvingSymlinksInPath, real)
        }
    }

    func testStashCanKeepTheIndex() throws {
        try prepareStash()
        try write(.stash(root: repository, kind: .keepIndex, message: "k"))
        XCTAssertEqual(try status(), ["A  s.txt", "?? u.txt"])
        XCTAssertEqual(try git("show stash@{0}:a.swift"), "let a = 3\n")
        XCTAssertEqual(try git("show stash@{0}:s.txt"), "staged\n")
    }

    func testAMergeInProgressIsReadAndItsConflictsStagedOnceResolved() throws {
        let merging = directory.appendingPathComponent("merging").path
        try run("""
        cd "$1" && git init -q -b master merging && cd merging
        printf 'one\\n' > f && git add f && git commit -qm base
        git checkout -q -b theirs && printf 'theirs\\n' > f && git commit -qam theirs
        git checkout -q master && printf 'ours\\n' > f && git commit -qam ours
        git merge theirs >/dev/null 2>&1 || true
        """, directory.path)
        let snapshot = try GitReads.parseSnapshot(run(GitReads.snapshotScript, merging)).get()
        let theirs = try XCTUnwrap(snapshot.branches.first { $0.name == "theirs" })
        XCTAssertEqual(snapshot.operation, .merge([theirs.sha]))
        XCTAssertEqual(snapshot.operationTitle, "Merging theirs")
        XCTAssertEqual(snapshot.mergeMessage, "Merge branch 'theirs'")
        XCTAssertEqual(snapshot.changes.map(\.status), ["UU"])
        // Its conflict markers are still there: nothing is staged.
        XCTAssertThrowsError(try write(.stage(root: merging, paths: ["."]))) { error in
            guard case TmuxError.failed(_, let stderr) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(stderr.hasPrefix("Still has conflict markers, so nothing was staged:\nf\n"), stderr)
        }
        try run("printf 'resolved\\n' > \"$1/f\"", merging)
        try write(.stage(root: merging, paths: ["."]))
        XCTAssertEqual(try run("cd \"$1\" && git status --porcelain", merging), "M  f\n")
    }

    func testARebaseCherryPickOrBisectInProgressIsRead() throws {
        let path = directory.appendingPathComponent("busy").path
        try run("""
        cd "$1" && git init -q -b master busy && cd busy
        printf 'one\\n' > f && git add f && git commit -qm base
        git checkout -q -b theirs && printf 'theirs\\n' > f && git commit -qam theirs
        git checkout -q master && printf 'ours\\n' > f && git commit -qam ours
        git cherry-pick theirs >/dev/null 2>&1 || true
        """, directory.path)
        func operation() throws -> GitOperation? {
            try GitReads.parseSnapshot(run(GitReads.snapshotScript, path)).get().operation
        }
        let theirs = try run("cd \"$1\" && git rev-parse theirs", path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(try operation(), .cherryPick(theirs))
        try run("cd \"$1\" && git cherry-pick --abort && { git rebase theirs >/dev/null 2>&1 || true; }", path)
        XCTAssertEqual(try operation(), .rebase(branch: "master", step: 1, steps: 1))
        XCTAssertNotNil(try operation()?.commitBlock)
        try run("cd \"$1\" && git rebase --abort && git bisect start", path)
        XCTAssertEqual(try operation(), .bisect)
        try run("cd \"$1\" && git bisect reset >/dev/null 2>&1", path)
        XCTAssertNil(try operation())
    }

    func testTheWritesArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        XCTAssertEqual(text(try ProtocolLine.request(id: 2, HostRequest.gitWrite(.commit(root: "/r", message: "m")))),
                       #"{"id":2,"kind":"request","request":{"git_write":{"commit":{"message":"m","root":"/r"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 3, HostRequest.gitWrite(.merge(root: "/r", branch: "b", kind: .squashAndLeave, into: "m")))),
                       #"{"id":3,"kind":"request","request":{"git_write":{"merge":{"branch":"b","into":"m","kind":"squash-leave","root":"/r"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 4, HostRequest.gitWrite(.operation(root: "/r", command: .cherryPick, step: .continue)))),
                       #"{"id":4,"kind":"request","request":{"git_write":{"operation":{"command":"cherry-pick","root":"/r","step":"continue"}}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 2, GitWritten(output: "abc1234\n"))), #"{"end":{"ok":{"output":"abc1234\n"}},"id":2,"kind":"end"}"# + "\n")
        let checkout = GitWrite.checkout(root: "/r", kind: .new, target: "t", autostash: true, base: "main")
        XCTAssertEqual(try JSONDecoder().decode(GitWrite.self, from: JSONEncoder().encode(checkout)), checkout)
        XCTAssertEqual(checkout.action, "Checkout")
        XCTAssertEqual(GitWrite.stashEntry(root: "/r", action: .pop, ref: "stash@{0}", sha: "s").action, "Pop Stash")
    }
}
