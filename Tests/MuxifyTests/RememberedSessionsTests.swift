import XCTest
@testable import MuxifyCore

final class RememberedSessionsTests: XCTestCase {
    private func snapshot(_ sessions: [String] = ["a", "b"], conversation: String = "conversation-1") -> TmuxSnapshot {
        let windows = sessions.enumerated().map { index, session in
            TmuxWindow(id: "@\(session)", sessionID: "$\(session)", sessionName: session, index: index,
                       name: "editor", paneTitle: "editor", path: "/work/\(session)/src", command: "codex",
                       isActive: true, paneCount: 2, hasBell: false, sessionActivity: 0, agent: "codex",
                       storedBrowser: StoredBrowser(tabURLs: ["https://example.com/issue"]), openRequests: [],
                       topicID: "topic", sessionPath: "/work/\(session)", activePaneID: "%\(session)", startCommand: "codex")
        }
        let panes = sessions.map { session in
            TmuxPane(id: "%\(session)", windowID: "@\(session)", command: "codex", agent: "codex",
                     agentStatus: "working", unread: false, agentConversation: conversation)
        }
        return TmuxSnapshot(windows: windows, clients: [], panes: panes, lastWindowID: nil, serverRunning: !sessions.isEmpty)
    }

    private func windowFields(_ record: TopicRecord) throws -> JSONValue {
        let session = try XCTUnwrap(record.sessions.first)
        guard case .array(let windows) = session["windows"] else { throw CocoaError(.coderInvalidValue) }
        return try XCTUnwrap(windows.first)
    }

    func testSnapshotRecordsWindowAndConversationChanges() throws {
        let record = TopicRecord(id: "topic")
        let first = try XCTUnwrap(record.remembering(snapshot(), order: .oldestFirst))
        XCTAssertEqual(first.sessions.count, 2)
        let fields = try windowFields(first)
        XCTAssertEqual(fields["directory"], .string("/work/a/src"))
        XCTAssertEqual(fields["name"], .string("editor"))
        XCTAssertEqual(fields["panes"], .array([.object(["index": .integer(0), "directory": .string("/work/a/src"), "active": .bool(false),
                                                         "agent": .string("codex"), "agent_conversation": .string("conversation-1")])]))
        XCTAssertEqual(fields["start_command"], .string("codex"))
        XCTAssertEqual(fields["agent"], .string("codex"))
        XCTAssertEqual(fields["agent_conversation"], .string("conversation-1"))
        XCTAssertEqual(fields["browser_tabs"], .array([.string("https://example.com/issue")]))
        let changed = try XCTUnwrap(first.remembering(snapshot(conversation: "conversation-2"), order: .oldestFirst))
        XCTAssertEqual(try windowFields(changed)["agent_conversation"], .string("conversation-2"))
    }

    func testUnchangedSnapshotDoesNotWrite() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: state) }
        let writes = WriteCount()
        let store = TopicStore(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": state.path], home: "/nonexistent")) { data, url in
            writes.add()
            try data.write(to: url, options: .atomic)
        }
        let record = try XCTUnwrap(TopicRecord(id: "topic").remembering(snapshot(), order: .oldestFirst))
        try store.write { try $0.create(record) }
        let loaded = try XCTUnwrap(store.read().records.first)
        let change = loaded.remembering(snapshot(), order: .oldestFirst)
        XCTAssertNil(change)
        if let change { try store.write { try $0.update(change.id) { $0 = change } } }
        XCTAssertEqual(writes.count, 1)
    }

    func testKilledSessionIsForgottenWhileAnotherLivesAndLastRemovalKeepsSet() throws {
        let both = try XCTUnwrap(TopicRecord(id: "topic").remembering(snapshot(), order: .oldestFirst))
        let remaining = try XCTUnwrap(both.remembering(snapshot(["b"]), order: .oldestFirst, previously: snapshot().windows))
        XCTAssertEqual(remaining.sessions.map { $0["directory"]?.string }, ["/work/b"])
        XCTAssertNil(remaining.remembering(snapshot([]), order: .oldestFirst))
        XCTAssertEqual(remaining.sessions.count, 1)
        XCTAssertNil(both.remembering(snapshot([]), order: .oldestFirst))
    }

    func testUnknownFieldsAndWorktreeBranchSurviveSnapshotUpdates() throws {
        let data = Data(#"{"id":"topic","future_topic":true,"sessions":[{"id":"$a","name":"a","directory":"/work/a","repository_path":"/main","worktree_path":"/work/a","branch":"fix","future_session":42,"windows":[{"window_id":"@a","future_window":{"large":18446744073709551615}}]}]}"#.utf8)
        let original = try JSONDecoder().decode(TopicRecord.self, from: data)
        let updated = try XCTUnwrap(original.remembering(snapshot(["a"]), order: .oldestFirst))
        XCTAssertEqual(updated.unknownFields, original.unknownFields)
        XCTAssertEqual(updated.sessions[0]["repository_path"], .string("/main"))
        XCTAssertEqual(updated.sessions[0]["worktree_path"], .string("/work/a"))
        XCTAssertEqual(updated.sessions[0]["branch"], .string("fix"))
        XCTAssertEqual(updated.sessions[0]["future_session"], .integer(42))
        XCTAssertEqual(try windowFields(updated)["future_window"]?["large"], .unsignedInteger(UInt64.max))
        XCTAssertNil(updated.remembering(snapshot(["a"]), order: .oldestFirst))
    }

    func testActivePaneOwnsConversationAndShellClearsOldAgentFields() throws {
        var live = snapshot(["a"])
        live.panes.insert(TmuxPane(id: "%other", windowID: "@a", command: "claude", agent: "claude",
                                  agentStatus: "done", unread: true, agentConversation: "wrong-conversation"), at: 0)
        let active = try XCTUnwrap(TopicRecord(id: "topic").remembering(live, order: .oldestFirst))
        XCTAssertEqual(try windowFields(active)["agent_conversation"], .string("conversation-1"))
        live.panes[1] = TmuxPane(id: "%a", windowID: "@a", command: "zsh", agent: "codex",
                                 agentStatus: "done", unread: false, agentConversation: "stale")
        let shell = try XCTUnwrap(active.remembering(live, order: .oldestFirst))
        XCTAssertNil(try windowFields(shell)["agent"])
        XCTAssertNil(try windowFields(shell)["agent_conversation"])
    }
}

private final class WriteCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func add() { lock.lock(); value += 1; lock.unlock() }
}
