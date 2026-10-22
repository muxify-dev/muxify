import XCTest
@testable import MuxifyCore

/// The rows of the New Topic list, which the app and `muxify sessionPath list` share. Real git in a temp folder.
final class SessionPathRowsTests: XCTestCase {
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

    /// The Config's SessionPaths in Config order: a bare repository with the Worktrees `main` and `release`, an aliased
    /// plain repository, and a plain directory.
    private func sessionPaths() throws -> [SessionPath] {
        let plain = path("app")
        try git(["init", "-q", "-b", "main", plain], in: root.path)
        try "a\n".write(toFile: plain + "/f", atomically: true, encoding: .utf8)
        try git(["add", "f"], in: plain)
        try git(["commit", "-q", "-m", "init"], in: plain)
        let bare = path("game_server")
        try git(["clone", "-q", "--bare", plain, bare], in: root.path)
        try git(["worktree", "add", "-q", bare + "/main", "main"], in: bare)
        try git(["worktree", "add", "-q", bare + "/release", "-b", "release-line"], in: bare)
        try FileManager.default.createDirectory(atPath: path("notes"), withIntermediateDirectories: true)
        return [SessionPath(path: bare, name: "game_server"), SessionPath(path: plain, name: "app", alias: "The App"), SessionPath(path: path("notes"), name: "notes")]
            .map { sessionPath in
                var detected = sessionPath
                detected.layout = RepositoryLayout.detect(at: sessionPath.folder.path)
                return detected
            }
    }

    func testRowsAreTheChoicesOfEachSessionPathInConfigOrderWithTheirLabels() throws {
        let sessionPaths = try sessionPaths()
        let rows = SessionPathRows.build(sessionPaths: sessionPaths, windows: [], records: [], titles: [:])
        XCTAssertEqual(rows.map(\.choice), sessionPaths.flatMap(SessionChoice.choices))
        XCTAssertEqual(rows.map { [$0.choice.directory.path, $0.choice.name, $0.choice.displayName] }, [
            [path("game_server/main"), "game_server/main", "game_server/main"],
            [path("game_server/release"), "game_server/release", "game_server/release"],
            [path("app"), "app", "The App"],
            [path("notes"), "notes", "notes"],
        ])
        XCTAssertEqual(rows.map(\.choice.worktree?.branch), ["main", "release-line", "main", nil])
        XCTAssertEqual(rows.map(\.alsoIn), [[], [], [], []])
    }

    func testARowNamesTheOtherOpenTopicsWhoseLiveSessionsUseItsFolderByIdAndLabel() throws {
        let sessionPaths = try sessionPaths()
        let release = path("game_server/release")
        var fix = TopicRecord(id: "fix", slug: "fix-drops")
        fix.sessions = [.object(["repository_path": .string(sessionPaths[0].folder.path), "worktree_path": .string(release), "branch": .string("release-line")])]
        var titled = TopicRecord(id: "ui", title: "Polish UI")
        titled.sessions = fix.sessions
        var settled = TopicRecord(id: "old", title: "Old")
        settled.sessions = fix.sessions
        settled.settledAt = "2026-10-01T00:00:00Z"
        let windows = [window("@1", session: "$1", topic: "fix", directory: release + "/src"),
                       window("@2", session: "$2", topic: "ui", directory: release),
                       window("@3", session: "$3", topic: "old", directory: release)]
        let rows = SessionPathRows.build(sessionPaths: sessionPaths, windows: windows, records: [fix, titled, settled], titles: [:])
        XCTAssertEqual(rows.map(\.alsoIn), [[], [TopicSummary(id: "fix", label: "fix-drops"), TopicSummary(id: "ui", label: "Polish UI")], [], []],
                       "a Topic with no title has the label topic list gives it; a Settled Topic is in no row")
    }

    private func window(_ id: String, session: String, topic: String, directory: String) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "s" + session, index: 0,
                   name: "shell", paneTitle: "", path: directory, command: "zsh",
                   isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: directory)
    }
}
