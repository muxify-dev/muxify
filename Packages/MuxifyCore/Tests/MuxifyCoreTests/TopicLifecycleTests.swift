import XCTest
@testable import MuxifyCore

final class TopicLifecycleTests: XCTestCase {
    private var topic: TopicRecord { TopicRecord(id: "topic", title: "Fix", slug: "fix") }
    private func window(_ n: Int = 1, name: String = "debug/fix") -> TmuxWindow {
        TmuxWindow(id: "@\(n)", sessionID: "$\(n)", sessionName: name, index: 0, name: "shell", paneTitle: "",
            path: "/work/game", command: "zsh", isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0,
            agent: "", storedBrowser: StoredBrowser(), openRequests: [], topicID: "topic", sessionPath: "/work/game")
    }
    private func snapshot(_ windows: [TmuxWindow], running: Bool = true) -> TmuxSnapshot {
        TmuxSnapshot(windows: windows, clients: [], panes: [], serverRunning: running)
    }
    private func remembered() throws -> TopicRecord {
        try XCTUnwrap(topic.remembering(snapshot([window(), window(2, name: "debug+2/fix")]), order: .oldestFirst))
    }

    func testSettleDefaultsEverySessionToKeepAndRestoresItsBaseName() throws {
        let live = snapshot([window(), window(2, name: "debug+2/fix")])
        let choices = TopicSettleSession.choices(topic: topic, snapshot: live, sessionPaths: [])
        XCTAssertEqual(choices.map(\.disposition), [.keep, .keep])
        XCTAssertTrue(choices.allSatisfy { !$0.removeWorktree })
        let edit = TopicSettlePlan(topic: topic, snapshot: live, sessionPaths: [], choices: [], outcome: "Done").edit
        XCTAssertNotNil(edit.record?.settledAt)
        XCTAssertEqual(edit.record?.sessions.count, 2)
        XCTAssertTrue(edit.commands.contains(.tmux(["rename-session", "-t", "$1", "debug"])))
        XCTAssertFalse(edit.commands.contains { if case .tmux(let args) = $0 { return args.first == "kill-session" }; return false })
    }

    func testExplicitKillSavesLayoutBeforeStoppingSessions() throws {
        let live = snapshot([window()])
        var choices = TopicSettleSession.choices(topic: topic, snapshot: live, sessionPaths: [])
        choices[0].disposition = .kill
        let edit = TopicSettlePlan(topic: topic, snapshot: live, sessionPaths: [], choices: choices, outcome: "").edit
        XCTAssertEqual(edit.commands, [.tmux(["kill-session", "-t", "$1"])])
        XCTAssertEqual(edit.record?.sessions.first?["name"], .string("debug/fix"))
    }

    func testConfirmedClosureRemovesOnlyObservedSessionAndFinalClosureMakesEmpty() throws {
        let saved = try remembered()
        let updated = try XCTUnwrap(saved.remembering(snapshot([window(2, name: "debug+2/fix")]), order: .oldestFirst,
            previously: [window(), window(2, name: "debug+2/fix")]))
        XCTAssertEqual(updated.sessions.count, 1)
        XCTAssertEqual(updated.sessions.first?["id"], .string("$2"))
        let empty = try XCTUnwrap(updated.remembering(snapshot([]), order: .oldestFirst, previously: [window(2, name: "debug+2/fix")]))
        XCTAssertTrue(empty.sessions.isEmpty)
        let reopened = try TopicReopenPlan(topic: empty, records: [empty], windows: [], sessionPaths: [], existingDirectories: []).edit
        XCTAssertTrue(reopened.commands.isEmpty)
        XCTAssertEqual(reopened.selection, .emptyTopic("topic"))
    }

    func testUnavailableServerAndInitialInventoryPreserveMissingLayouts() throws {
        let saved = try remembered()
        XCTAssertNil(saved.remembering(snapshot([], running: false), order: .oldestFirst, previously: [window()]))
        XCTAssertNil(saved.remembering(snapshot([]), order: .oldestFirst))
        let partial = saved.remembering(snapshot([window()]), order: .oldestFirst) ?? saved
        XCTAssertEqual(partial.sessions.count, 2)
        XCTAssertNil(partial.remembering(snapshot([window()]), order: .oldestFirst, previously: [window()]),
            "a later complete read must not silently erase a Session never seen on this connection")
    }

    func testReopenPreservesNamesAndDisambiguatesOnlyOccupiedSessionWithoutAdoption() throws {
        let saved = try remembered()
        var other = window(9)
        other.topicID = nil
        let edit = try TopicReopenPlan(topic: saved, records: [saved], windows: [other], sessionPaths: [], existingDirectories: ["/work/game"]).edit
        let names = edit.commands.compactMap { command -> String? in
            if case .reopenSession(let name, _, _) = command { return name }; return nil
        }
        XCTAssertEqual(names, ["debug+3/fix", "debug+2/fix"])
        XCTAssertEqual(edit.savedCompletionRecord?.slug, "fix")
        XCTAssertEqual(edit.savedCompletionRecord?.sessions.compactMap { $0["id"]?.string }, saved.sessions.compactMap { $0["id"]?.string })
        XCTAssertTrue(edit.commands.contains(.tmux(["set-option", "-t", "=debug+3/fix:", "@muxify_session_id", "$1"])))
    }

    func testExternalRenameRemainsAuthoritativeAndIdentityKeepsProvenance() throws {
        var saved = try remembered()
        var fields = try XCTUnwrap(saved.sessions[0].object)
        fields["worktree_created"] = .bool(true)
        fields["base"] = .string("abc")
        saved.sessions[0] = .object(fields)
        let next = try XCTUnwrap(saved.remembering(snapshot([window(name: "custom")]), order: .oldestFirst))
        XCTAssertEqual(next.sessions.first?["name"], .string("custom"))
        XCTAssertEqual(next.sessions.first?["base_name"], .string("custom"))
        XCTAssertEqual(next.sessions.first?["base"], .string("abc"))
    }

    func testConfirmedKillDoesNotEraseAnotherSessionNeverSeenOnThisConnection() throws {
        let saved = try remembered()
        let remaining = try XCTUnwrap(saved.remembering(snapshot([]), order: .oldestFirst, previously: [window()]))
        XCTAssertEqual(remaining.sessions.compactMap { $0["name"]?.string }, ["debug+2/fix"])
    }

    func testReopenAfterKeepCreatesNewIdentityInsteadOfAliasingTheStillRunningOriginal() throws {
        let live = snapshot([window()])
        let settled = try XCTUnwrap(TopicSettlePlan(topic: topic, snapshot: live, sessionPaths: [], choices: [], outcome: "").edit.record)
        var kept = window(name: "debug")
        kept.topicID = nil
        let edit = try TopicReopenPlan(topic: settled, records: [settled], windows: [kept], sessionPaths: [], existingDirectories: ["/work/game"]).edit
        let saved = try XCTUnwrap(edit.savedCompletionRecord?.sessions.first)
        XCTAssertNotEqual(saved["id"], .string(kept.sessionRecordID))
        XCTAssertEqual(saved["name"], .string("debug/fix"))
        XCTAssertTrue(edit.commands.contains(.tmux(["set-option", "-t", "=debug/fix:", "@muxify_session_id", try XCTUnwrap(saved["id"]?.string)])))
    }

    func testSplitWindowRestoresLayoutAgentBrowserAndTypesProgramWithoutExecuting() throws {
        var source = window()
        source.activePaneID = "%3"
        source.layout = "5e2c,160x40,0,0{80x40,0,0,1,79x40,81,0[79x20,81,0,2,79x19,81,21,3]}"
        source.storedBrowser = StoredBrowser(tabURLs: ["https://example.com"], layout: PanelLayout(shown: .browser))
        var live = snapshot([source])
        live.panes = [TmuxPane(id: "%1", windowID: "@1", index: 0, path: "/work/game", command: "claude", agent: "claude", agentStatus: "done", unread: false, agentConversation: "abc"),
            TmuxPane(id: "%2", windowID: "@1", index: 1, path: "/work/game/web", command: "node", agent: "", agentStatus: "", unread: false, tty: "/dev/ttys011"),
            TmuxPane(id: "%3", windowID: "@1", index: 2, isActive: true, path: "/work/game", command: "zsh", agent: "", agentStatus: "", unread: false)]
        live.commandLines = PaneCommandLines().updating(for: live) { "710 710 ttys011 node server.js\n" }
        let saved = try XCTUnwrap(topic.remembering(live, order: .oldestFirst))
        let edit = try TopicReopenPlan(topic: saved, records: [saved], windows: [], sessionPaths: [], existingDirectories: ["/work/game"]).edit
        XCTAssertTrue(edit.commands.contains(.tmux(["select-layout", "-t", "=debug/fix:$", source.layout])))
        XCTAssertTrue(edit.commands.contains(.sendKeys(target: "=debug/fix:$.+1", keys: ["claude --resume 'abc'"], literal: true)))
        XCTAssertTrue(edit.commands.contains(.sendKeys(target: "=debug/fix:$.+2", keys: ["node server.js"], literal: true)))
        XCTAssertFalse(edit.commands.contains(.sendKeys(target: "=debug/fix:$.+2", keys: ["Enter"], literal: false)))
        XCTAssertTrue(edit.commands.contains(.tmux(source.storedBrowser.setOptionArgs(windowID: "=debug/fix:$"))))
        let fresh = try TopicReopenPlan(topic: saved, records: [saved], windows: [], sessionPaths: [], existingDirectories: ["/work/game"], choice: .startFresh).edit
        XCTAssertFalse(fresh.commands.contains { if case .sendKeys = $0 { return true }; return false })
    }
}

extension TopicEdit {
    var savedCompletionRecord: TopicRecord? {
        if case .save(let record) = completion { return record }; return nil
    }
}
