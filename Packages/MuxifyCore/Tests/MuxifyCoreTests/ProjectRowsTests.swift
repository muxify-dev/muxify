import XCTest
@testable import MuxifyCore

/// The rows of the New Topic list, which the app and `muxify project list` share. Real git in a temp folder.
final class ProjectRowsTests: XCTestCase {
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

    /// The Config's Projects in Config order: a bare repository with the Worktrees `main` and `release`, an aliased
    /// plain repository, and a plain directory.
    private func projects() throws -> [Project] {
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
        return [Project(path: bare, name: "game_server"), Project(path: plain, name: "app", alias: "The App"), Project(path: path("notes"), name: "notes")]
            .map { project in
                var detected = project
                detected.layout = ProjectLayout.detect(at: project.folder.path)
                return detected
            }
    }

    func testRowsAreTheChoicesOfEachProjectInConfigOrderWithTheirLabels() throws {
        let projects = try projects()
        let rows = ProjectRows.build(projects: projects, windows: [], records: [], titles: [:])
        XCTAssertEqual(rows.map(\.choice), projects.flatMap(ProjectChoice.choices))
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
        let projects = try projects()
        let release = path("game_server/release")
        var fix = TopicRecord(id: "fix", slug: "fix-drops", homeProject: projects[0].folder.path)
        fix.sessions = [.object(["project_path": .string(projects[0].folder.path), "worktree_path": .string(release), "branch": .string("release-line")])]
        var titled = TopicRecord(id: "ui", title: "Polish UI", homeProject: projects[0].folder.path)
        titled.sessions = fix.sessions
        var settled = TopicRecord(id: "old", title: "Old", homeProject: projects[0].folder.path)
        settled.sessions = fix.sessions
        settled.settledAt = "2026-10-01T00:00:00Z"
        let windows = [window("@1", session: "$1", topic: "fix", directory: release + "/src"),
                       window("@2", session: "$2", topic: "ui", directory: release),
                       window("@3", session: "$3", topic: "old", directory: release)]
        let rows = ProjectRows.build(projects: projects, windows: windows, records: [fix, titled, settled], titles: [:])
        XCTAssertEqual(rows.map(\.alsoIn), [[], [TopicSummary(id: "ui", label: "Polish UI"), TopicSummary(id: "fix", label: "fix-drops")], [], []],
                       "a Topic with no title has the label topic list gives it; a Settled Topic is in no row")
    }

    private func window(_ id: String, session: String, topic: String, directory: String) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: session, sessionName: "s" + session, index: 0,
                   name: "shell", paneTitle: "", path: directory, command: "zsh",
                   isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topic, sessionPath: directory)
    }
}
