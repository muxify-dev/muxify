import XCTest
@testable import MuxifyCore

/// The Worktree setup file, and real git in a temp folder for the scripts that make, sync and remove a Muxify Worktree.
final class MuxifyWorktreeTests: XCTestCase {
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

    /// Real paths, as git and `pwd -P` print them: the temp folder is under a symlink on macOS.
    private func path(_ name: String) -> String {
        Folder.local(root.path).real + "/" + name
    }

    private func repository(_ name: String = "app") throws -> String {
        let work = path(name)
        _ = try git(["init", "-q", "-b", "main", work], in: root.path)
        try "ignored.env\n.envrc\nshared\n".write(toFile: work + "/.gitignore", atomically: true, encoding: .utf8)
        _ = try git(["add", ".gitignore"], in: work)
        _ = try git(["commit", "-q", "-m", "init"], in: work)
        return work
    }

    private let worktrees = MuxifyWorktrees(scripts: LocalScripts())

    // MARK: - The setup file

    func testSetupReadsTheScriptsFormatWithCommentsAndTrailingCommas() throws {
        let setup = try WorktreeSetup.parse("""
        // .worktree.json
        {
          "worktreePath": "~/trees", /* per project */
          "sync": {
            "copyFiles": [".envrc", "docker-compose.override.yml",],
            "symlinkDirs": ["node_modules"],
            "exclude": ["node_modules"],
          },
          "hooks": {
            "postCreate": ["direnv allow", "open http://app.local // not a comment"],
            "preDelete": ["docker compose down -v"],
          },
          "unknown": true,
        }
        """, file: ".worktree.json")
        XCTAssertEqual(setup.worktreePath, "~/trees")
        XCTAssertEqual(setup.copyFiles, [".envrc", "docker-compose.override.yml"])
        XCTAssertEqual(setup.postCreate, ["direnv allow", "open http://app.local // not a comment"])
        XCTAssertEqual(setup.preDelete, ["docker compose down -v"])
        XCTAssertEqual(setup.syncItems, [.copy(".envrc"), .copy("docker-compose.override.yml")])
    }

    func testSetupWithAKeyOfTheWrongTypeFailsAsAWhole() {
        XCTAssertThrowsError(try WorktreeSetup.parse(#"{"hooks": {"postCreate": "make"}}"#, file: "/r/.worktree.json")) { error in
            XCTAssertEqual(String(describing: error), "/r/.worktree.json is not a valid Worktree setup: hooks.postCreate: expected a list of strings. Muxify made no Worktree.")
        }
        XCTAssertThrowsError(try WorktreeSetup.parse("{", file: "x"))
    }

    func testRepositoryNameComesFromGitsCommonFolder() {
        XCTAssertEqual(WorktreeRepository.name(commonDirectory: "/src/app/.git"), "app")
        XCTAssertEqual(WorktreeRepository.name(commonDirectory: "/src/app.git"), "app")
        XCTAssertEqual(WorktreeRepository.name(commonDirectory: "/src/app/.bare"), "app")
    }

    func testWorktreePathReplacesTheRootAndTheRepositoryFolder() {
        func repository(_ setup: WorktreeSetup) -> WorktreeRepository {
            WorktreeRepository(main: "/src/app", name: "app", stateHome: "/home/me/.local/state", home: "/home/me", setupFolder: "/src/app", setup: setup)
        }
        XCTAssertEqual(repository(WorktreeSetup()).folder(for: "fix", root: nil, defaultRoot: nil), "/home/me/.local/state/muxify/worktrees/app/fix")
        XCTAssertEqual(repository(WorktreeSetup()).folder(for: "fix", root: "~/worktrees", defaultRoot: nil), "/home/me/worktrees/app/fix")
        XCTAssertEqual(repository(WorktreeSetup(worktreePath: "~/trees/app")).folder(for: "fix", root: "~/worktrees", defaultRoot: nil), "/home/me/trees/app/fix")
        XCTAssertEqual(repository(WorktreeSetup(worktreePath: "../trees")).folder(for: "fix", root: nil, defaultRoot: nil), "/src/trees/fix")
    }

    // MARK: - The scripts

    func testRepositoryReadsTheSetupOfTheMainWorkingTreeFromAnotherWorktree() throws {
        let work = try repository()
        try #"{"sync": {"copyFiles": [".envrc"]}}"#.write(toFile: work + "/.worktree.json", atomically: true, encoding: .utf8)
        _ = try git(["worktree", "add", "-q", "-b", "other", path("other")], in: work)
        let found = try worktrees.repository(at: path("other"))
        XCTAssertEqual(found.main, work)
        XCTAssertEqual(found.name, "app")
        XCTAssertEqual(found.setupFolder, work)
        XCTAssertEqual(found.setup.copyFiles, [".envrc"])
    }

    func testAddMakesTheBranchOrChecksOutTheOneThatExists() throws {
        let work = try repository()
        let made = try worktrees.add(name: "fix", from: work, at: path("trees/app/fix"), start: .head)
        XCTAssertEqual(made.path, path("trees/app/fix"))
        XCTAssertEqual(made.commit, try git(["rev-parse", "HEAD"], in: work))
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: made.path), "fix")

        _ = try git(["branch", "feature"], in: work)
        let checkedOut = try worktrees.add(name: "feature", from: work, at: path("trees/app/feature"), start: .head)
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: checkedOut.path), "feature")

        XCTAssertThrowsError(try worktrees.add(name: "again", from: work, at: path("trees/app/again"), start: .branch("fix"))) { error in
            XCTAssertTrue(String(describing: error).contains("The branch fix is checked out in the Worktree"), String(describing: error))
        }
        XCTAssertThrowsError(try worktrees.add(name: "x", from: work, at: path("trees/app/fix"), start: .head)) { error in
            XCTAssertTrue(String(describing: error).contains("exists. Muxify made no Worktree."), String(describing: error))
        }
    }

    func testSyncCopiesAndLinksAndSkipsWhatIsMissing() throws {
        let work = try repository()
        try "secret".write(toFile: work + "/.envrc", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: work + "/shared", withIntermediateDirectories: true)
        let made = try worktrees.add(name: "fix", from: work, at: path("trees/fix"), start: .head)
        let lines = try worktrees.sync(WorktreeSetup(copyFiles: [".envrc", "missing.env"], symlinkDirs: ["shared"]), from: work, to: made.path)
        XCTAssertEqual(lines, ["copy .envrc", "skip copy (missing): missing.env", "symlink shared"])
        XCTAssertEqual(try String(contentsOfFile: made.path + "/.envrc", encoding: .utf8), "secret")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: made.path + "/shared"), work + "/shared")
        XCTAssertEqual(try worktrees.states([made.path, path("gone")]), [.clean, .missing])
    }

    func testPreDeleteStopsAtTheFirstFailedHookAndKeepsItsOutput() throws {
        let work = try repository()
        let made = try worktrees.add(name: "fix", from: work, at: path("trees/fix"), start: .head)
        let record = MuxifyWorktreeRecord(environment: nil, repository: work, name: "fix", path: made.path, branch: "fix", base: made.commit)
        XCTAssertEqual(try worktrees.runPreDelete(record, hooks: [#"echo "$MUXIFY_WORKTREE_NAME""#]), "$ echo \"$MUXIFY_WORKTREE_NAME\"\nfix\n")
        XCTAssertThrowsError(try worktrees.runPreDelete(record, hooks: ["echo one", "exit 3", "echo never"])) { error in
            guard case MuxifyWorktreeError.hookFailed(let output, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(output, "$ echo one\none\n$ exit 3\n")
            XCTAssertEqual(reason, "exit 3 exited with 3.")
        }
    }

    func testRemoveRefusesChangesUnlessForced() throws {
        let work = try repository()
        let made = try worktrees.add(name: "fix", from: work, at: path("trees/fix"), start: .head)
        let record = MuxifyWorktreeRecord(environment: nil, repository: work, name: "fix", path: made.path, branch: "fix", base: made.commit)
        try "change".write(toFile: made.path + "/new.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(try worktrees.states([made.path]), [.dirty])
        XCTAssertThrowsError(try worktrees.remove(record, force: false))
        try worktrees.remove(record, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
        XCTAssertEqual(try git(["branch", "--list", "fix"], in: work), "fix")
    }

    func testPostCreateScriptRunsEachHookInTheWorktreeAndStopsAtAFailure() throws {
        let work = try repository()
        let made = try worktrees.add(name: "fix", from: work, at: path("trees/fix"), start: .head)
        let record = MuxifyWorktreeRecord(environment: nil, repository: work, name: "fix", path: made.path, branch: "fix", base: made.commit)
        let command = try worktrees.postCreateCommand(record, hooks: ["pwd > hook-ran", "false", "touch never"], setupFile: work + "/.worktree.json")
        XCTAssertThrowsError(try Shell.run("/bin/sh", ["-c", command]))
        XCTAssertEqual(try String(contentsOfFile: made.path + "/hook-ran", encoding: .utf8), made.path + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path + "/never"))
        // The script is in git's private folder, so the Worktree has no change apart from what the hooks made.
        XCTAssertEqual(try git(["status", "--porcelain"], in: made.path), "?? hook-ran")
    }

    func testStoreKeepsOneFileForEachRecordBesideTheDefaultRootsFolders() throws {
        let store = MuxifyWorktreeStore(folder: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app/fix"), withIntermediateDirectories: true)
        let record = MuxifyWorktreeRecord(environment: "box", repository: "/src/app", name: "fix", path: "/src/trees/fix", branch: "fix", base: "abc",
                                          createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.write(record)
        XCTAssertEqual(try store.all(), [record])
        try store.remove(record.id)
        XCTAssertEqual(try store.all(), [])
    }
}
