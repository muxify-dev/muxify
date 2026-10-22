import XCTest
@testable import MuxifyCore

/// A repository with several Worktrees is one SessionPath. Real git in a temp folder for the
/// layout detection, plain models for the rows and labels.
final class RepositorySessionPathTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func git(_ arguments: [String], in directory: String) throws {
        _ = try Shell.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"] + arguments, directory: directory)
    }

    private func path(_ name: String) -> String { (root.appendingPathComponent(name).path as NSString).standardizingPath }

    /// `plain` with one commit on main, a linked Worktree `plain-feat` and a prunable `plain-gone`.
    private func makePlainRepository() throws -> String {
        let plain = path("plain")
        try git(["init", "-q", "-b", "main", plain], in: root.path)
        try "a\n".write(toFile: plain + "/f", atomically: true, encoding: .utf8)
        try git(["add", "f"], in: plain)
        try git(["commit", "-q", "-m", "init"], in: plain)
        try git(["worktree", "add", "-q", path("plain-feat"), "-b", "feat"], in: plain)
        try git(["worktree", "add", "-q", path("plain-gone"), "-b", "gone"], in: plain)
        try FileManager.default.removeItem(atPath: path("plain-gone"))
        return plain
    }

    func testBareDotGitRepositoryIsOneSessionPathWhoseWorktreesLeaveOutTheBareEntry() throws {
        let plain = try makePlainRepository()
        let bare = path("game_server")
        try git(["clone", "-q", "--bare", plain, bare], in: root.path)
        try git(["worktree", "add", "-q", bare + "/main", "main"], in: bare)
        try git(["worktree", "add", "-q", bare + "/release", "-b", "release-line"], in: bare)
        XCTAssertEqual(RepositoryLayout.detect(at: bare), .bareRepository([
            Worktree(path: bare + "/main", branch: "main"),
            Worktree(path: bare + "/release", branch: "release-line"),
        ]))
    }

    func testDotBareFolderWithGitPointerIsABareRepository() throws {
        let plain = try makePlainRepository()
        let repository = path("synced")
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try git(["clone", "-q", "--bare", plain, repository + "/.bare"], in: root.path)
        try "gitdir: ./.bare\n".write(toFile: repository + "/.git", atomically: true, encoding: .utf8)
        try git(["worktree", "add", "-q", repository + "/main", "main"], in: repository)
        XCTAssertEqual(RepositoryLayout.detect(at: repository), .bareRepository([Worktree(path: repository + "/main", branch: "main")]))
    }

    func testPlainRepositoryListsItsMainCheckoutAndLinkedWorktreesWithoutPrunableOnes() throws {
        let plain = try makePlainRepository()
        XCTAssertEqual(RepositoryLayout.detect(at: plain), .plainRepository([
            Worktree(path: plain, branch: "main"),
            Worktree(path: path("plain-feat"), branch: "feat"),
        ]))
    }

    func testRepositoryReachedThroughASymlinkedFolderKeepsTheConfigSpellingForItsOwnCheckouts() throws {
        let plain = try makePlainRepository()
        let bare = path("game_server")
        try git(["clone", "-q", "--bare", plain, bare], in: root.path)
        try git(["worktree", "add", "-q", bare + "/main", "main"], in: bare)
        let link = path("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root.path)
        XCTAssertEqual(RepositoryLayout.detect(at: link + "/plain"), .plainRepository([
            Worktree(path: link + "/plain", branch: "main"),
            Worktree(path: path("plain-feat"), branch: "feat"),
        ]))
        XCTAssertEqual(RepositoryLayout.detect(at: link + "/game_server"),
                       .bareRepository([Worktree(path: link + "/game_server/main", branch: "main")]))
    }

    func testFolderThatIsNoRepositoryOrSitsInsideOneIsAPlainDirectory() throws {
        let plain = try makePlainRepository()
        try FileManager.default.createDirectory(atPath: plain + "/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path("notes"), withIntermediateDirectories: true)
        XCTAssertEqual(RepositoryLayout.detect(at: path("notes")), .directory)
        XCTAssertEqual(RepositoryLayout.detect(at: plain + "/sub"), .directory)
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
        TmuxWindow(id: id, sessionID: session, sessionName: "s" + session, index: 0,
                   name: "shell", paneTitle: "", path: path ?? directory, command: "zsh",
                   isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: directory)
    }

    func testListShowsOneRowPerWorktreeNamedRepoSlashFolderAndNoRowForTheBareFolder() {
        let rows = SessionPathRows.build(sessionPaths: [gameServer, notes], windows: [], records: [], titles: [:])
        XCTAssertEqual(rows.map(\.choice.name), ["game_server/main", "game_server/release", "notes"])
        XCTAssertEqual(rows.map(\.choice.directory.path), [main.folder.path, release.folder.path, notes.folder.path])
        XCTAssertEqual(SessionPathRows.list(rows, query: "game_server/rel", visits: VisitLog()).rows.map(\.title.text), ["game_server/release"])
    }

    private func shown(_ rows: [SessionPathRow]) -> [String] {
        SessionPathRows.list(rows, query: "", visits: VisitLog()).rows.map { "\($0.title.text) | \($0.detail.text) | \($0.pick.payload?.id ?? "blocked")" }
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
        let rows = SessionPathRows.build(sessionPaths: [gameServer], windows: windows, records: [other, third, settled],
                                     titles: ["other": "Fix drops", "third": "Polish UI"])
        XCTAssertEqual(shown(rows), ["game_server/main | /work/game_server/main · Also in Fix drops, Polish UI | /work/game_server/main",
                                     "game_server/release | /work/game_server/release | /work/game_server/release"])
        XCTAssertEqual(SessionPathRows.build(sessionPaths: [gameServer], windows: windows, records: [other], titles: [:], addingTo: other).count, 2,
                       "Add a Session keeps paths available even when the Topic uses them")
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
        let rows = SessionPathRows.build(sessionPaths: [app], windows: [], records: [], titles: [:])
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
        ], records: [legacy, noteTaker], titles: [:])
        XCTAssertEqual(shown(legacyRows), ["app | /work/app · Also in Legacy owner | /work/app", "app/feat | /trees/app/feat | /trees/app/feat",
                                           "notes | /work/notes · Also in Note taker | /work/notes"])

        var current = TopicRecord(id: "current", title: "Main owner")
        current.sessions = [.object(["repository_path": .string(app.folder.path), "worktree_path": .string(app.folder.path), "branch": .string("main")])]
        let currentRows = SessionPathRows.build(sessionPaths: [app], windows: [window("@1", session: "$1", topic: "current", directory: app.folder.path)],
                                            records: [current], titles: [:])
        XCTAssertEqual(shown(currentRows), ["app | /work/app · Also in Main owner | /work/app", "app/feat | /trees/app/feat | /trees/app/feat"])
    }

    func testSessionInTheMainCheckoutAndALegacyOneAreLabelledAsTheSessionPath() {
        var topic = TopicRecord(id: "a", title: "Fix")
        topic.sessions = [.object(["repository_path": .string(app.folder.path), "worktree_path": .string(app.folder.path), "branch": .string("main")])]
        var legacy = TopicRecord(id: "b", title: "Old")
        legacy.sessions = [.object(["repository_path": .string(app.folder.path)])]
        var config = Config()
        config.sessionPaths = [app]
        func session(of record: TopicRecord) -> TopicsModel.Session? {
            let model = TopicsModel(records: [record], windows: [window("@1", session: "$1", topic: record.id, directory: app.folder.path)],
                                    config: config, selection: TopicSelection(), groups: TopicGroupsState())
            return model.rows.first?.sessions.first
        }
        XCTAssertEqual(session(of: topic)?.baseName, "s$1")
        XCTAssertEqual(session(of: legacy)?.baseName, "s$1")
        XCTAssertFalse(TopicsModel.usesMainWorkingCopy(window("@1", session: "$1", topic: "a", directory: app.folder.path, path: app.folder.path + "/src"),
                                                       record: topic, sessionPaths: [app]))
    }

    func testAddSessionWithANewWorktreeCreatesItFromThePickedBaseAndRemembersItAsCreated() throws {
        let topic = TopicRecord(id: "t", title: "T", slug: "t")
        let added = try TopicSessionPlan(topic: topic, sessionPath: gameServer, workingCopy: .newWorktree(at: "c0ffee", root: "/trees"),
                                         windows: [], sessionPaths: [gameServer, notes]).edit
        let tree = TopicPlan.WorktreeSpec(repositoryPath: gameServer.folder.path, path: "/trees/game_server/t", branch: "t")
        XCTAssertEqual(added.newWorktree, TopicPlan.NewWorktree(worktree: tree, commit: "c0ffee"))
        XCTAssertEqual(Array(added.commands.prefix(2)), [.tmuxMaking(["new-session", "-d", "-s", "game_server/t", "-c", "/trees/game_server/t"]),
                                        .tmux(["set-option", "-t", "=game_server/t:", "@muxify_topic", "t"])])
        XCTAssertEqual(added.record?.sessions.last?["base"], .string("c0ffee"))
        XCTAssertEqual(added.record?.sessions.last?["worktree_created"], .bool(true))
        let plain = try TopicSessionPlan(topic: topic, sessionPath: app, workingCopy: .newWorktree(at: "c0ffee", root: "/trees"),
                                         windows: [], sessionPaths: [app, notes]).edit
        XCTAssertEqual(plain.newWorktree, TopicPlan.NewWorktree(worktree: .init(repositoryPath: app.folder.path, path: "/trees/app/t", branch: "t"),
                                                                commit: "c0ffee"))
        XCTAssertEqual(plain.record?.sessions.last?["worktree_path"]?.string, "/trees/app/t")
    }

    func testSessionInAWorktreeIsLabelledRepoSlashFolder() {
        var topic = TopicRecord(id: "a", title: "Fix")
        topic.sessions = [.object(["id": .string("$1"), "name": .string("s$1"), "base_name": .string("s$1"), "directory": .string(main.folder.path)]),
                          .object(["id": .string("$2"), "name": .string("s$2"), "base_name": .string("s$2"), "directory": .string(notes.folder.path)])]
        var settled = TopicRecord(id: "b", title: "Done")
        settled.sessions = [.object(["id": .string("remembered"), "name": .string("debug"), "base_name": .string("debug"), "directory": .string(release.folder.path)])]
        settled.settledAt = "2026-10-01T00:00:00Z"
        var config = Config()
        config.sessionPaths = [gameServer, notes]
        let windows = [window("@1", session: "$1", topic: "a", directory: main.folder.path),
                       window("@2", session: "$2", topic: "a", directory: notes.folder.path)]
        let model = TopicsModel(records: [topic, settled], windows: windows, config: config, selection: TopicSelection(),
                                groups: TopicGroupsState())
        XCTAssertEqual(model.rows[0].sessions.map(\.baseName), ["s$1", "s$2"])
        let remembered = model.groups.first { $0.kind == .settled }?.topics.first?.sessions.first
        XCTAssertEqual(remembered?.baseName, "debug")
    }

    func testWindowInItsOwnWorktreeOfABareLayoutIsNotFlaggedAsMainWorkingCopy() {
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
    }
}
