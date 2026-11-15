import Foundation
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class TranscriptTests: XCTestCase {
    private struct Row: Equatable, CustomStringConvertible {
        let index: Int
        let role: Entry.Role
        let tool: String?
        let text: String

        init(_ index: Int, _ role: Entry.Role, _ text: String) { self.init(index, role, nil, text) }

        init(_ index: Int, _ role: Entry.Role, _ tool: String?, _ text: String) {
            self.index = index
            self.role = role
            self.tool = tool
            self.text = text
        }

        init(_ entry: Entry) { self.init(entry.index, entry.role, entry.tool, entry.text) }

        var description: String { "[\(index)] \(role.rawValue) \(tool ?? "-") \(text)" }
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"), name)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testClaudeGivesEachTextToolCallAndToolResultAndSkipsThinkingMetaAndOtherRecords() throws {
        let entries = try TranscriptReader.entries(inFile: fixture("claude-2.1.296.jsonl"), kind: .claude)
        XCTAssertEqual(entries.map(Row.init), [
            Row(0, .user, "scrubbed 21"),
            Row(1, .toolCall, "Bash", #"{"command":"scrubbed 48","description":"scrubbed 49"}"#),
            Row(2, .toolResult, "Bash", "scrubbed 67"),
            Row(3, .assistant, "scrubbed 79"),
        ])
        XCTAssertEqual(entries.first?.at, try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-12T09:03:55.038Z"))
    }

    func testCodexReadsMessagesFromEventsAndToolsFromResponseItemsOnce() throws {
        let entries = try TranscriptReader.entries(inFile: fixture("codex-0.162.1.jsonl"), kind: .codex)
        XCTAssertEqual(entries.map(Row.init), [
            Row(0, .user, "scrubbed 157"),
            Row(1, .assistant, "scrubbed 160"),
            Row(2, .toolCall, "exec", "scrubbed 167"),
            Row(3, .toolResult, "exec", "scrubbed 183\nscrubbed 184"),
            Row(4, .toolCall, "spawn_agent", #"{"message":"scrubbed 190","task_name":"scrubbed 189"}"#),
            Row(5, .toolResult, "spawn_agent", "scrubbed 198"),
        ])
    }

    func testCodexReadsTheOlderUserAndAgentMessageEvents() {
        let lines = """
        {"type":"event_msg","timestamp":"2026-01-01T10:00:00Z","payload":{"type":"user_message","message":"older user"}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"older agent"}}
        """
        XCTAssertEqual(TranscriptReader.entries(in: Data(lines.utf8), kind: .codex).map(Row.init),
                       [Row(0, .user, "older user"), Row(1, .assistant, "older agent")])
    }

    func testPiGivesTheToolCallAndItsResultAndSkipsThinking() throws {
        let entries = try TranscriptReader.entries(inFile: fixture("pi-v3.jsonl"), kind: .pi)
        XCTAssertEqual(entries.map(Row.init), [
            Row(0, .user, "scrubbed 5"),
            Row(1, .toolCall, "read", #"{"path":"scrubbed 8"}"#),
            Row(2, .toolResult, "read", "scrubbed 15"),
            Row(3, .assistant, "scrubbed 18"),
        ])
    }

    func testOpenCodeExportGivesTwoEntriesForAToolPartAndSkipsSteps() throws {
        let entries = try TranscriptReader.entries(in: Data(contentsOf: fixture("opencode-1.19.0-export.json")), kind: .opencode)
        XCTAssertEqual(entries.map(Row.init), [
            Row(0, .user, "scrubbed 18"),
            Row(1, .assistant, "scrubbed 32"),
            Row(2, .toolCall, "read", #"{"filePath":"scrubbed 36"}"#),
            Row(3, .toolResult, "read", "scrubbed 37"),
            Row(4, .assistant, "scrubbed 56"),
        ])
        XCTAssertEqual(entries.first?.at, Date(timeIntervalSince1970: 1_780_489_374.187))
    }

    func testAHalfWrittenLastLineGivesNoEntryAndACompleteOneWithoutNewlineDoes() throws {
        let file = try temporaryFolder().appendingPathComponent("t.jsonl")
        let first = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"first"}]}}"#
        let last = #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"last"}]}}"#
        try Data((first + "\n" + last.dropLast(10)).utf8).write(to: file)
        XCTAssertEqual(try TranscriptReader.entries(inFile: file, kind: .pi).map(Row.init), [Row(0, .user, "first")])
        try Data((first + "\n" + last).utf8).write(to: file)
        XCTAssertEqual(try TranscriptReader.entries(inFile: file, kind: .pi).map(Row.init),
                       [Row(0, .user, "first"), Row(1, .assistant, "last")])
    }

    func testRootsHonorTheVendorFoldersFromTheEnvironmentAndFindEachTranscript() throws {
        let home = try temporaryFolder()
        let claudeHome = home.appendingPathComponent("elsewhere/claude")
        let roots = TranscriptRoots(environment: ["CLAUDE_CONFIG_DIR": claudeHome.path, "CODEX_HOME": ""], home: home)
        XCTAssertEqual(roots.claude.path, claudeHome.appendingPathComponent("projects").path)
        XCTAssertEqual(roots.codex.path, home.appendingPathComponent(".codex/sessions").path)
        XCTAssertNil(roots.folder(for: .opencode))

        let files: [(AgentConversation, URL)] = [
            (AgentConversation(kind: .claude, id: "c-1"), roots.claude.appendingPathComponent("-work/c-1.jsonl")),
            (AgentConversation(kind: .codex, id: "x-1"), roots.codex.appendingPathComponent("2026/10/rollout-2026-10-18T09-00-00-x-1.jsonl")),
            (AgentConversation(kind: .pi, id: "p-1"), roots.pi.appendingPathComponent("--work--/2026-10-18T09-00-00Z_p-1.jsonl")),
        ]
        for (conversation, file) in files {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        for (conversation, file) in files {
            XCTAssertEqual(roots.transcript(of: conversation)?.resolvingSymlinksInPath(), file.resolvingSymlinksInPath(), "\(conversation)")
            XCTAssertEqual(roots.kind(ofTranscriptAt: file), conversation.kind)
            XCTAssertEqual(roots.kind(ofTranscriptAt: URL(fileURLWithPath: Folder.local(file.path).real)), conversation.kind,
                           "through the temporary folder's /private symlink")
        }
        XCTAssertNil(roots.transcript(of: AgentConversation(kind: .claude, id: "other")))
        XCTAssertNil(roots.transcript(of: AgentConversation(kind: .claude, id: "../c-1")), "an unsafe id reads nothing")
        XCTAssertNil(roots.kind(ofTranscriptAt: home.appendingPathComponent("notes.jsonl")))
    }

    func testATopicGivesTheConversationsOfItsLivePanesThenOfItsRememberedWindowsAndPanesOnce() {
        var topic = TopicRecord(id: "topic")
        topic.sessions = [.object(["windows": .array([
            .object(["agent": .string("claude"), "agent_conversation": .string("live"),
                     "panes": .array([.object(["agent": .string("pi"), "agent_conversation": .string("side")])])]),
            .object(["agent": .string("codex"), "agent_conversation": .string("old")]),
            .object(["agent": .string("nobody"), "agent_conversation": .string("unknown kind")]),
        ])])]
        let window = TmuxWindow.fixture(name: "", path: "/", command: "", topicID: "topic", sessionPath: "/", activePaneID: "%1")
        let pane = TmuxPane(id: "%1", windowID: "@1", command: "claude", agent: "claude", agentStatus: "working", unread: false,
                            agentConversation: "live")
        let snapshot = TmuxSnapshot(windows: [window], clients: [], panes: [pane], lastWindowID: nil, serverRunning: true)
        XCTAssertEqual(topic.agentConversations(in: snapshot), [
            AgentConversation(kind: .claude, id: "live"),
            AgentConversation(kind: .pi, id: "side"),
            AgentConversation(kind: .codex, id: "old"),
        ])
    }
}
