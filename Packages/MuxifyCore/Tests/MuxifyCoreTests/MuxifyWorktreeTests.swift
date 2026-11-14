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
        let record = MuxifyWorktreeRecord(repository: work, name: "fix", path: made.path, branch: "fix", base: made.commit)
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
        let record = MuxifyWorktreeRecord(repository: work, name: "fix", path: made.path, branch: "fix", base: made.commit)
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
        let record = MuxifyWorktreeRecord(repository: work, name: "fix", path: made.path, branch: "fix", base: made.commit)
        let command = try worktrees.postCreateCommand(record, hooks: ["pwd > hook-ran", "false", "touch never"], setupFile: work + "/.worktree.json")
        XCTAssertThrowsError(try Shell.run("/bin/sh", ["-c", command]))
        XCTAssertEqual(try String(contentsOfFile: made.path + "/hook-ran", encoding: .utf8), made.path + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path + "/never"))
        // The script is in git's private folder, so the Worktree has no change apart from what the hooks made.
        XCTAssertEqual(try git(["status", "--porcelain"], in: made.path), "?? hook-ran")
    }

    private var paths: MuxifyPaths { MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent") }

    func testStoreKeepsOneRowForEachRecordAndLeavesTheDefaultRootsFolders() throws {
        let store = MuxifyWorktreeStore(paths: paths)
        XCTAssertEqual(try store.all(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path), "a read creates no state folder")
        let checkout = paths.worktrees.appendingPathComponent("app/fix")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let record = MuxifyWorktreeRecord(repository: "/src/app", name: "fix", path: "/src/trees/fix", branch: "fix", base: "abc",
                                          createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.write(record)
        XCTAssertEqual(try store.all(), [record])
        XCTAssertEqual(store.record(record.id), record)
        XCTAssertEqual(try MuxifyWorktreeStore(paths: paths).all(), [record], "another store reads the same row")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.worktrees.path), ["app"], "no record file")
        try store.remove(record.id)
        XCTAssertEqual(try store.all(), [])
        XCTAssertNil(store.record(record.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkout.path))
    }

    func testAWriteOfAnExistingIDUpdatesItsRecord() throws {
        let store = MuxifyWorktreeStore(paths: paths)
        var record = MuxifyWorktreeRecord(repository: "/src/app", name: "fix", path: "/src/trees/fix", branch: "fix", base: "abc",
                                          createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.write(record)
        record.branch = "fix-2"
        record.base = "def"
        try store.write(record)
        XCTAssertEqual(try store.all(), [record])
    }

    func testASecondRecordAtAPathThatHasOneFailsWithAnErrorNamingThePath() throws {
        let store = MuxifyWorktreeStore(paths: paths)
        let first = MuxifyWorktreeRecord(repository: "/src/app", name: "fix", path: "/src/trees/fix", branch: "fix", base: "abc",
                                         createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.write(first)
        let second = MuxifyWorktreeRecord(repository: "/src/app", name: "fix", path: "/src/trees/fix", branch: "other", base: "def")
        XCTAssertThrowsError(try MuxifyWorktreeStore(paths: paths).write(second)) { error in
            XCTAssertEqual(error as? MuxifyWorktreeError, .pathTaken("/src/trees/fix"))
            XCTAssertTrue(String(describing: error).contains("/src/trees/fix"), String(describing: error))
            XCTAssertEqual(EnvironmentService(paths: self.paths).failure(error, phase: .nothingChanged).kind, .worktreeExists)
        }
        XCTAssertEqual(try store.all(), [first], "the second record was not written")
    }

    // MARK: - A record lives on the machine that has it (ADR 0088)

    func testARecordNamesNoEnvironmentAndKeepsItsDateAsISO8601() throws {
        let record = MuxifyWorktreeRecord(id: "w", repository: "/src/app", name: "fix", path: "/src/trees/fix", branch: "fix", base: "abc",
                                          createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try encoder.encode(record), as: UTF8.self),
                       #"{"base":"abc","branch":"fix","created_at":"2023-11-14T22:13:20Z","id":"w","name":"fix","path":"/src/trees/fix","repository":"/src/app"}"#)
        let older = #"{"id":"w","environment":"box","repository":"/src/app","name":"fix","path":"/src/trees/fix","branch":"fix","base":"abc","created_at":"2023-11-14T22:13:20Z"}"#
        XCTAssertEqual(try JSONDecoder().decode(MuxifyWorktreeRecord.self, from: Data(older.utf8)), record,
                       "an older record's environment is not part of the record")
    }

    func testTheDefaultRootIsTheMachinesOwnStateHome() {
        let host = MuxifyPaths(environment: ["XDG_STATE_HOME": "/home/me/state"], home: "/home/me")
        XCTAssertEqual(EnvironmentService(paths: host).defaultWorktreesRoot, "/home/me/state/muxify/worktrees")
        XCTAssertEqual(EnvironmentService(paths: MuxifyPaths(environment: [:], home: "/home/me")).defaultWorktreesRoot,
                       "/home/me/.local/state/muxify/worktrees")
        let repository = WorktreeRepository(main: "/src/app", name: "app", stateHome: "/home/me/state", home: "/home/me", setupFolder: nil,
                                            setup: WorktreeSetup())
        let service = EnvironmentService(paths: host)
        XCTAssertEqual(repository.folder(for: "fix", root: service.worktreesRoot, defaultRoot: service.defaultWorktreesRoot),
                       "/home/me/state/muxify/worktrees/app/fix")
        XCTAssertEqual(repository.folder(for: "fix", root: "/trees", defaultRoot: service.defaultWorktreesRoot), "/trees/app/fix",
                       "the machine's own worktrees.root_path wins")
    }

    func testTheMacsReadsAndWritesIgnoreARowThatWaitsForAHost() throws {
        try FileManager.default.createDirectory(at: paths.worktrees, withIntermediateDirectories: true)
        let waiting = #"{"id":"remote","environment":"box","repository":"/home/me/app","name":"fix","path":"/home/me/trees/fix","branch":"fix","base":"abc","created_at":"2026-09-01T10:00:00Z"}"#
        try Data(waiting.utf8).write(to: paths.worktrees.appendingPathComponent("remote.json"))
        let store = MuxifyWorktreeStore(paths: paths)
        let local = MuxifyWorktreeRecord(id: "local", repository: "/src/app", name: "fix", path: "/src/trees/fix", branch: "fix", base: "abc",
                                         createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.write(local)

        XCTAssertEqual(try store.all(), [local], "the list leaves out the waiting row")
        XCTAssertNil(store.record("remote"), "a lookup by id does not find it")
        let service = EnvironmentService(paths: paths)
        XCTAssertEqual(try service.worktreeRecords().map(\.id), ["local"])
        XCTAssertThrowsError(try service.worktreeRecord(named: "/home/me/trees/fix"), "Remove Worktree cannot name it")
        try store.remove("remote")
        XCTAssertEqual(try store.waiting(for: "box").map(\.id), ["remote"], "a remove of this Mac's record leaves it")
        XCTAssertEqual(try store.waiting(for: "other"), [])

        try store.removeWaiting(["remote", "local"], for: "box")
        XCTAssertEqual(try store.waiting(for: "box"), [])
        XCTAssertEqual(try store.all(), [local], "removeWaiting deletes no record of this Mac")
    }
}
