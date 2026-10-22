import XCTest
@testable import MuxifyCore

final class TopicEditTests: XCTestCase {
    private let path = SessionPath(path: "/work/game", name: "game")
    private let topic = TopicRecord(id: "topic", title: "Fix", slug: "fix")

    private func window(_ session: String = "$1", name: String = "debug/fix", topicID: String? = "topic", panes: Int = 1) -> TmuxWindow {
        TmuxWindow(id: "@" + session.dropFirst(), sessionID: session, sessionName: name, index: 0,
            name: "shell", paneTitle: "", path: "/work/game/api", command: "zsh", isActive: true,
            paneCount: panes, hasBell: false, sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(),
            openRequests: [], topicID: topicID, sessionPath: path.folder.path, activePaneID: "%1")
    }

    func testRenameUsesActualNamesAndAllowsSeveralSessionsInOneDirectory() throws {
        let members = [window(), window("$2", name: "custom")]
        let edit = try TopicRenamePlan(topic: topic, title: "Next", records: [topic], windows: members, sessionPaths: [path]).edit
        XCTAssertEqual(edit.record?.slug, "next")
        XCTAssertEqual(edit.commands, [.tmux(["rename-session", "-t", "$1", "debug/next"]),
            .tmux(["rename-session", "-t", "$2", "custom/next"])])
    }

    func testCollisionChangesOnlyTheSessionBaseNotTopicSlug() throws {
        let edit = try TopicRenamePlan(topic: topic, title: "Next", records: [topic],
            windows: [window(), window("$2", name: "debug/next", topicID: nil)], sessionPaths: []).edit
        XCTAssertEqual(edit.record?.slug, "next")
        XCTAssertEqual(edit.commands, [.tmux(["rename-session", "-t", "$1", "debug+2/next"])])
    }

    func testRenameReservesSettledSlugsAndUpdatesRememberedNamesNotGitProvenance() throws {
        var saved = topic
        saved.sessions = [.object(["id": .string("s"), "name": .string("debug+2/fix"), "base_name": .string("debug+2"),
            "directory": .string("/trees/fix"), "branch": .string("fix"), "worktree_path": .string("/trees/fix")])]
        var other = TopicRecord(id: "old", slug: "next")
        other.settledAt = "yesterday"
        let edit = try TopicRenamePlan(topic: saved, title: "Next", records: [saved, other], windows: [], sessionPaths: []).edit
        XCTAssertEqual(edit.record?.slug, "next-2")
        XCTAssertEqual(edit.record?.sessions.first?["name"], .string("debug+2/next-2"))
        XCTAssertEqual(edit.record?.sessions.first?["branch"], .string("fix"))
        XCTAssertEqual(edit.record?.sessions.first?["worktree_path"], .string("/trees/fix"))
    }

    func testAddPathAlwaysCreatesNewMemberWithIndependentIdentity() throws {
        let first = try TopicSessionPlan(topic: topic, sessionPath: path, workingCopy: .directory,
            windows: [window(name: "game/fix")], sessionPaths: [path]).edit
        XCTAssertEqual(first.selection, .sessionName("game+2/fix"))
        XCTAssertEqual(first.record?.sessions.first?["directory"], .string(path.folder.path))
        XCTAssertNotNil(first.record?.sessions.first?["id"]?.string)
        XCTAssertEqual(first.commands.first, .tmuxMaking(["new-session", "-d", "-s", "game+2/fix", "-c", path.folder.path]))
        let second = try TopicSessionPlan(topic: topic, sessionPath: path, workingCopy: .directory, windows: [], sessionPaths: []).edit
        XCTAssertNotEqual(first.record?.sessions.first?["id"], second.record?.sessions.first?["id"])
    }

    func testMoveSessionReplacesSuffixAndCarriesProvenance() throws {
        let source = window()
        var old = topic
        old.sessions = [.object(["id": .string(source.sessionRecordID), "name": .string(source.sessionName),
            "base_name": .string("debug"), "directory": .string(path.folder.path), "base": .string("abc"),
            "repository_path": .string(path.folder.path), "worktree_path": .string("/trees/fix"), "worktree_created": .bool(true)])]
        let next = TopicRecord(id: "next", slug: "next")
        let plan = try TopicMembershipPlan(source: .session(source), destination: next, records: [old, next], windows: [source], sessionPaths: [])
        XCTAssertEqual(plan.commands.first, .tmux(["rename-session", "-t", "$1", "debug/next"]))
        XCTAssertEqual(plan.record?.sessions.first?["base"], .string("abc"))
        XCTAssertEqual(plan.record?.sessions.first?["worktree_created"], .bool(true))
        XCTAssertEqual(plan.leftTopic?.sessions, [])
    }

    func testWindowMoveRequiresChoiceAmongMultipleSessionsNotFolderMatching() throws {
        let source = window("$1", name: "source", topicID: nil)
        let targets = [window("$2"), window("$3", name: "debug+2/fix")]
        XCTAssertThrowsError(try TopicMembershipPlan(source: .window(source), destination: topic, records: [topic],
            windows: [source] + targets, sessionPaths: []))
        let plan = try TopicMembershipPlan(source: .window(source), destination: topic, records: [topic],
            windows: [source] + targets, sessionPaths: [], destinationSession: "$3")
        XCTAssertTrue(plan.commands.contains(.tmux(["move-window", "-d", "-s", "$1:@1", "-t", "$3:"])))
        XCTAssertFalse(plan.commands.contains { if case .newTopicSession = $0 { return true }; return false })
    }

    func testNewDestinationUsesCurrentPaneDirectoryAndBaseName() throws {
        let source = window(panes: 2)
        let plan = try TopicMembershipPlan(source: .pane(PaneID(rawValue: "%1")!, source), destination: nil,
            records: [topic], windows: [source], sessionPaths: [], createSession: true)
        XCTAssertEqual(plan.commands.first, .newTopicSession(name: "debug", directory: "/work/game/api"))
        XCTAssertTrue(plan.commands.contains(.tmux(["break-pane", "-d", "-s", "%1", "-t", "=debug:"])))
        XCTAssertNil(plan.leftTopic)
    }

    func testNamesAllocateFirstAvailableNumberAndStripOnlyManagedSuffix() {
        XCTAssertEqual(SessionNaming.available("debug", topic: "fix", taken: ["debug/fix", "debug+3/fix"]), "debug+2/fix")
        XCTAssertEqual(SessionNaming.available("debug+2", taken: ["debug+2", "debug+3"]), "debug+4")
        XCTAssertEqual(SessionNaming.base(of: "repo/worktree/fix", topic: topic), "repo/worktree")
        XCTAssertEqual(SessionNaming.base(of: "external/rename", topic: topic), "external/rename")
    }
}
