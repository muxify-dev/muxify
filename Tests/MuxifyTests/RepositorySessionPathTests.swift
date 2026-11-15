import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// A repository with several Worktrees is one SessionPath. Real git in a temp folder for the
/// layout detection, plain models for the rows and labels.
final class RepositorySessionPathTests: XCTestCase {
    private static let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    /// Built once for the class, on the first test that needs it, and only read.
    private static let repositories = Result { try makeRepositories() }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private static func git(_ arguments: [String], in directory: String) throws {
        _ = try Shell.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"] + arguments, directory: directory)
    }

    private static func path(_ name: String) -> String { (root.appendingPathComponent(name).path as NSString).standardizingPath }
    private func path(_ name: String) -> String { Self.path(name) }

    /// `plain` with one commit on main, a linked Worktree `plain-feat` and a prunable `plain-gone`; `game_server`, a bare
    /// clone with Worktrees `main` and `release`; `synced`, a `.bare` clone behind a `.git` pointer with Worktree `main`;
    /// the folders `plain/sub` and `notes`; and `link`, a symlink to the root.
    private static func makeRepositories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plain = path("plain")
        try git(["init", "-q", "-b", "main", plain], in: root.path)
        try "a\n".write(toFile: plain + "/f", atomically: true, encoding: .utf8)
        try git(["add", "f"], in: plain)
        try git(["commit", "-q", "-m", "init"], in: plain)
        try git(["worktree", "add", "-q", path("plain-feat"), "-b", "feat"], in: plain)
        try git(["worktree", "add", "-q", path("plain-gone"), "-b", "gone"], in: plain)
        try FileManager.default.removeItem(atPath: path("plain-gone"))
        let bare = path("game_server")
        try git(["clone", "-q", "--bare", plain, bare], in: root.path)
        try git(["worktree", "add", "-q", bare + "/main", "main"], in: bare)
        try git(["worktree", "add", "-q", bare + "/release", "-b", "release-line"], in: bare)
        let synced = path("synced")
        try FileManager.default.createDirectory(atPath: synced, withIntermediateDirectories: true)
        try git(["clone", "-q", "--bare", plain, synced + "/.bare"], in: root.path)
        try "gitdir: ./.bare\n".write(toFile: synced + "/.git", atomically: true, encoding: .utf8)
        try git(["worktree", "add", "-q", synced + "/main", "main"], in: synced)
        try FileManager.default.createDirectory(atPath: plain + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path("notes"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path("link"), withDestinationPath: root.path)
    }

    func testBareDotGitRepositoryIsOneSessionPathWhoseWorktreesLeaveOutTheBareEntry() throws {
        try Self.repositories.get()
        let bare = path("game_server")
        XCTAssertEqual(RepositoryLayout.detect(at: bare), .bareRepository([
            Worktree(path: bare + "/main", branch: "main"),
            Worktree(path: bare + "/release", branch: "release-line"),
        ]))
    }

    func testDotBareFolderWithGitPointerIsABareRepository() throws {
        try Self.repositories.get()
        let repository = path("synced")
        XCTAssertEqual(RepositoryLayout.detect(at: repository), .bareRepository([Worktree(path: repository + "/main", branch: "main")]))
    }

    func testPlainRepositoryListsItsMainCheckoutAndLinkedWorktreesWithoutPrunableOnes() throws {
        try Self.repositories.get()
        let plain = path("plain")
        XCTAssertEqual(RepositoryLayout.detect(at: plain), .plainRepository([
            Worktree(path: plain, branch: "main"),
            Worktree(path: path("plain-feat"), branch: "feat"),
        ]))
    }

    func testRepositoryReachedThroughASymlinkedFolderKeepsTheConfigSpellingForItsOwnCheckouts() throws {
        try Self.repositories.get()
        let link = path("link")
        XCTAssertEqual(RepositoryLayout.detect(at: link + "/plain"), .plainRepository([
            Worktree(path: link + "/plain", branch: "main"),
            Worktree(path: path("plain-feat"), branch: "feat"),
        ]))
        XCTAssertEqual(RepositoryLayout.detect(at: link + "/game_server"), .bareRepository([
            Worktree(path: link + "/game_server/main", branch: "main"),
            Worktree(path: link + "/game_server/release", branch: "release-line"),
        ]))
    }

    func testFolderThatIsNoRepositoryOrSitsInsideOneIsAPlainDirectory() throws {
        try Self.repositories.get()
        XCTAssertEqual(RepositoryLayout.detect(at: path("notes")), .directory)
        XCTAssertEqual(RepositoryLayout.detect(at: path("plain") + "/sub"), .directory)
        XCTAssertEqual(RepositoryLayout.detect(at: path("missing")), .directory)
    }

    func testDetachedWorktreeHasNoBranch() {
        let listed = """
        worktree /repo
        bare

        worktree /repo/main
        HEAD 0123
        branch refs/heads/main

        worktree /repo/pinned
        HEAD 4567
        detached

        """
        XCTAssertEqual(RepositoryLayout.parse(worktreeList: listed, resolver: .local),
                       [Worktree(path: "/repo/main", branch: "main"), Worktree(path: "/repo/pinned", branch: nil)])
    }

    private let main = Worktree(path: "/work/game_server/main", branch: "main")
    private let release = Worktree(path: "/work/game_server/release", branch: "release-line")
    private var gameServer: SessionPath {
        var sessionPath = SessionPath(path: "/work/game_server", name: "game_server")
        sessionPath.layout = .bareRepository([main, release])
        return sessionPath
    }
    private var notes: SessionPath { SessionPath(path: "/work/notes", name: "notes") }

    private func window(_ id: String, session: String, topic: String?, directory: String, path: String? = nil) -> TmuxWindow {
        .fixture(id: id, sessionID: session, sessionName: "s" + session, path: path ?? directory, topicID: topic, sessionPath: directory)
    }

    private func shown(_ rows: [SessionPathRow]) -> [String] {
        PaletteCatalog(windows: [], agents: []).addSessionList(topic: "target", query: "", rows: rows, rules: .standard).rows.map { "\($0.title.text) | \($0.detail.text) | \($0.id)" }
    }

    func testWorktreeOfLiveSessionsInOtherOpenTopicsCanBePickedAndSaysAlsoInThoseTopics() {
        var other = TopicRecord(id: "other", title: "Fix drops")
        other.sessions = [.object(["repository_path": .string(gameServer.folder.path), "worktree_path": .string(main.folder.path), "branch": .string("main")])]
        var third = TopicRecord(id: "third", title: "Polish UI")
        third.sessions = other.sessions
        var settled = TopicRecord(id: "settled", title: "Old")
        settled.sessions = other.sessions
        settled.settledAt = "2026-10-01T00:00:00Z"
        let windows = [window("@1", session: "$1", topic: "third", directory: main.folder.path),
                       window("@2", session: "$2", topic: "other", directory: main.folder.path, path: main.folder.path + "/src"),
                       window("@3", session: "$3", topic: "settled", directory: release.folder.path)]
        let rows = SessionPathRows.build(sessionPaths: [gameServer], windows: windows, records: [other, third, settled])
        XCTAssertEqual(shown(rows), ["game_server/main | /work/game_server/main · Also in Fix drops, Polish UI | /work/game_server/main",
                                     "game_server/release | /work/game_server/release | /work/game_server/release"])
        XCTAssertEqual(SessionPathRows.build(sessionPaths: [gameServer], windows: windows, records: [other], addingTo: other).count, 2,
                       "Add a Session keeps paths available even when the Topic uses them")
        XCTAssertEqual(PaletteCatalog(windows: [], agents: []).addSessionList(topic: "target", query: "game_server/rel", rows: rows, rules: .standard).rows.map(\.title.text),
                       ["game_server/release"], "typing repo/folder finds the Worktree's row")
    }

    func testPickedWorktreeOpensTheSessionThereAndIsRememberedWithItsBranchAsNotCreated() {
        let choice = SessionChoice(sessionPath: gameServer, worktree: release)
        XCTAssertEqual(choice.workingCopy(newWorktree: false), .worktree(path: release.folder.path))
        let added = try? TopicSessionPlan(topic: TopicRecord(id: "t", title: "T", slug: "t"),
                                          sessionPath: gameServer, workingCopy: .worktree(release), windows: [], sessionPaths: [gameServer, notes]).edit
        XCTAssertEqual(added?.commands.first, .tmuxMaking(["new-session", "-d", "-s", "game_server/t", "-c", release.folder.path]))
        XCTAssertEqual(added?.record?.sessions.last?["worktree_path"], .string(release.folder.path))
        XCTAssertEqual(added?.record?.sessions.last?["worktree_created"], .bool(false))
    }

    private var app: SessionPath {
        var sessionPath = SessionPath(path: "/work/app", name: "app")
        sessionPath.layout = .plainRepository([Worktree(path: "/work/app", branch: "main"), Worktree(path: "/trees/app/feat", branch: "feat")])
        return sessionPath
    }

    func testMainCheckoutOfAPlainRepositoryIsAWorktreeTheTopicPicksAndNeverCreated() throws {
        let rows = SessionPathRows.build(sessionPaths: [app], windows: [], records: [])
        XCTAssertEqual(rows.map(\.choice.name), ["app", "app/feat"], "the main checkout is the SessionPath folder, so it keeps the SessionPath name")
        XCTAssertEqual(rows[0].choice.workingCopy(newWorktree: false), .worktree(path: "/work/app"))
        let plan = try TopicSessionPlan(topic: TopicRecord(id: "fix", title: "Fix", slug: "fix"), sessionPath: app,
                                        workingCopy: .worktree(Worktree(path: "/work/app", branch: "main")), windows: [], sessionPaths: [app]).edit
        XCTAssertEqual(plan.commands.first, .tmuxMaking(["new-session", "-d", "-s", "app/fix", "-c", "/work/app"]))
        XCTAssertEqual(plan.record?.sessions.first?["directory"], .string("/work/app"))
        XCTAssertEqual(plan.record?.sessions.first?["worktree_created"], .bool(false))
    }

    func testALiveSessionInTheSessionPathFolderIsAlsoInItsTopicForTheMainCheckoutAndForAPlainDirectory() {
        var legacy = TopicRecord(id: "legacy", title: "Legacy owner")
        legacy.sessions = [.object(["repository_path": .string(app.folder.path)])]
        var noteTaker = TopicRecord(id: "notes", title: "Note taker")
        noteTaker.sessions = [.object(["repository_path": .string(notes.folder.path)])]
        let legacyRows = SessionPathRows.build(sessionPaths: [app, notes], windows: [
            window("@1", session: "$1", topic: "legacy", directory: app.folder.path + "/src"),
            window("@2", session: "$2", topic: "notes", directory: notes.folder.path),
        ], records: [legacy, noteTaker])
        XCTAssertEqual(shown(legacyRows), ["app | /work/app · Also in Legacy owner | /work/app", "app/feat | /trees/app/feat | /trees/app/feat",
                                           "notes | /work/notes · Also in Note taker | /work/notes"])

        var current = TopicRecord(id: "current", title: "Main owner")
        current.sessions = [.object(["repository_path": .string(app.folder.path), "worktree_path": .string(app.folder.path), "branch": .string("main")])]
        let currentRows = SessionPathRows.build(sessionPaths: [app], windows: [window("@1", session: "$1", topic: "current", directory: app.folder.path)],
                                            records: [current])
        XCTAssertEqual(shown(currentRows), ["app | /work/app · Also in Main owner | /work/app", "app/feat | /trees/app/feat | /trees/app/feat"])
    }

    func testAddSessionWithANewWorktreeCreatesItFromThePickedBaseAndRemembersItAsCreated() throws {
        let topic = TopicRecord(id: "t", title: "T", slug: "t")
        let added = try TopicSessionPlan(topic: topic, sessionPath: gameServer, workingCopy: .newWorktree(at: "c0ffee", parent: "/trees/game_server"),
                                         windows: [], sessionPaths: [gameServer, notes]).edit
        let tree = TopicPlan.WorktreeSpec(repositoryPath: gameServer.folder.path, path: "/trees/game_server/t", branch: "t")
        XCTAssertEqual(tree.arguments, ["worktree", "add", "-b", "t", "/trees/game_server/t"])
        XCTAssertEqual(added.newWorktree?.worktree, tree)
        XCTAssertEqual(added.newWorktree?.commit, "c0ffee")
        XCTAssertEqual(Array(added.commands.prefix(2)), [.tmuxMaking(["new-session", "-d", "-s", "game_server/t", "-c", "/trees/game_server/t"]),
                                        .tmux(["set-option", "-t", "=game_server/t:", "@muxify_topic", "t"])])
        XCTAssertEqual(added.record?.sessions, [.object([
            "id": try XCTUnwrap(added.record?.sessions.first?["id"]),
            "name": .string("game_server/t"),
            "base_name": .string("game_server"),
            "directory": .string(tree.path),
            "repository_path": .string(gameServer.folder.path),
            "worktree_path": .string(tree.path),
            "branch": .string("t"),
            "worktree_created": .bool(true),
            "base": .string("c0ffee"),
            "worktree_id": .string(try XCTUnwrap(added.newWorktree?.id)),
        ])], "the Session names the Worktree's record")
        let plain = try TopicSessionPlan(topic: topic, sessionPath: app, workingCopy: .newWorktree(at: "c0ffee", parent: "/work trees/app"),
                                         windows: [], sessionPaths: [app, notes]).edit
        XCTAssertEqual(plain.newWorktree?.worktree, .init(repositoryPath: app.folder.path, path: "/work trees/app/t", branch: "t"))
        XCTAssertEqual(plain.record?.sessions.last?["worktree_path"]?.string, "/work trees/app/t")
    }

    func testWindowInItsOwnWorktreeOrInTheMainCheckoutIsNotFlaggedAsMainWorkingCopy() {
        var topic = TopicRecord(id: "a", title: "Fix")
        topic.sessions = [.object(["id": .string("$1"), "repository_path": .string(gameServer.folder.path), "worktree_path": .string(release.folder.path), "branch": .string("release-line")])]
        func flagged(_ path: String) -> Bool {
            TopicsModel.usesMainWorkingCopy(window("@1", session: "$1", topic: "a", directory: release.folder.path, path: path),
                                            record: topic, sessionPaths: [gameServer])
        }
        XCTAssertFalse(flagged(release.folder.path))
        XCTAssertFalse(flagged(release.folder.path + "/src"))
        XCTAssertTrue(flagged(main.folder.path + "/src"), "a Window that moved into another Worktree of the repository")
        XCTAssertFalse(flagged("/elsewhere"))
        var mainCheckout = TopicRecord(id: "a", title: "Fix")
        mainCheckout.sessions = [.object(["repository_path": .string(app.folder.path), "worktree_path": .string(app.folder.path), "branch": .string("main")])]
        XCTAssertFalse(TopicsModel.usesMainWorkingCopy(window("@1", session: "$1", topic: "a", directory: app.folder.path, path: app.folder.path + "/src"),
                                                       record: mainCheckout, sessionPaths: [app]), "a Window in the main checkout its Session remembers")
    }
}
