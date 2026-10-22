import Foundation
import XCTest
@testable import MuxifyCore

final class TitleSuggestionTests: XCTestCase {
    private let sessionPath = SessionPath(path: "/work/game", name: "game")

    private func pane(kind: AgentKind = .codex, id: String = "conversation-1", command: String = "codex") -> TmuxPane {
        TmuxPane(id: "%1", windowID: "@1", command: command, agent: kind.rawValue,
                 agentStatus: "working", unread: false, agentConversation: id)
    }

    private func window(topicID: String = "topic") -> TmuxWindow {
        TmuxWindow(id: "@1", sessionID: "$1", sessionName: "game/topic", index: 0,
                   name: "codex", paneTitle: "", path: "/work/game", command: "codex",
                   isActive: true, paneCount: 1, hasBell: false, sessionActivity: 0, agent: "codex",
                   storedBrowser: StoredBrowser(), openRequests: [], topicID: topicID,
                   sessionPath: "/work/game", activePaneID: "%1", startCommand: "codex")
    }

    func testBuildsTheCompleteRequestFromLiveAndRememberedConversationIDs() throws {
        var topic = TopicRecord(id: "topic")
        topic.sessions = [.object([
            "repository_path": .string(sessionPath.folder.path),
            "windows": .array([
                .object(["agent": .string("codex"), "agent_conversation": .string("conversation-1")]),
                .object(["agent": .string("claude"), "agent_conversation": .string("conversation-2")]),
                .object(["agent": .string("pi"), "agent_conversation": .string("conversation-1")]),
            ]),
        ])]
        let snapshot = TmuxSnapshot(windows: [window()], clients: [], panes: [pane()], lastWindowID: nil, serverRunning: true)
        var loaded: [TopicTitleSuggester.Conversation] = []
        var request: (command: String, prompt: String, timeout: TimeInterval)?
        let suggester = TopicTitleSuggester(commands: ["model"], transcriptLoader: { conversation in
            loaded.append(conversation)
            return conversation.kind == .codex ? ["First request", "Second request"] : ["Remembered request"]
        }, modelCall: { command, prompt, timeout in
            request = (command, prompt, timeout)
            return .completed(status: 0, stdout: "  Suggested title  \nignored", stderr: "")
        })

        XCTAssertEqual(try suggester.suggest(for: .topic(topic, snapshot, [sessionPath])), "Suggested title")
        XCTAssertEqual(loaded, [
            TopicTitleSuggester.Conversation(kind: .codex, id: "conversation-1"),
            TopicTitleSuggester.Conversation(kind: .claude, id: "conversation-2"),
        ])
        XCTAssertEqual(request?.command, "model")
        XCTAssertEqual(request?.timeout, 30)
        XCTAssertEqual(request?.prompt, """
        Give a short title for this work, at most 5 words. Return plain text on one line.

        Sessions:
        - game/topic

        Conversation excerpts:
        [Codex 1]
        - First request
        - Second request
        [Claude Code 2]
        - Remembered request
        """)
    }

    func testKeepsFirstThreeAndLastThreeMessagesAndLimitsEachToFiveHundredCharacters() throws {
        let messages = (1...8).map { "message-\($0)" }
        let long = String(repeating: "x", count: 600)
        var prompt = ""
        let suggester = TopicTitleSuggester(commands: ["model"], transcriptLoader: { _ in messages + [long] },
                                            modelCall: { _, value, _ in
            prompt = value
            return .completed(status: 0, stdout: "Title", stderr: "")
        })
        _ = try suggester.suggest(for: .newTopic(pane(), sessionPath))
        for kept in [1, 2, 3, 7, 8] { XCTAssertTrue(prompt.contains("message-\(kept)")) }
        for removed in [4, 5, 6] { XCTAssertFalse(prompt.contains("message-\(removed)")) }
        XCTAssertTrue(prompt.contains(String(repeating: "x", count: 500)))
        XCTAssertFalse(prompt.contains(String(repeating: "x", count: 501)))
    }

    func testPromptLimitDropsTheLastMessageFromTheLargestConversationWithStableTies() throws {
        let a = String(repeating: "a", count: 500)
        let b = String(repeating: "b", count: 500)
        let c = String(repeating: "c", count: 500)
        var prompt = ""
        let suggester = TopicTitleSuggester(commands: ["model"], transcriptLoader: { conversation in
            Array(repeating: conversation.kind == .codex ? a : conversation.kind == .claude ? b : c, count: 6)
        }, modelCall: { _, value, _ in
            prompt = value
            return .completed(status: 0, stdout: "Title", stderr: "")
        })
        var topic = TopicRecord(id: "topic")
        topic.sessions = [.object(["windows": .array([
            .object(["agent": .string("codex"), "agent_conversation": .string("one")]),
            .object(["agent": .string("claude"), "agent_conversation": .string("two")]),
            .object(["agent": .string("pi"), "agent_conversation": .string("three")]),
        ])])]
        _ = try suggester.suggest(for: .topic(topic,
            TmuxSnapshot(windows: [], clients: [], panes: [], lastWindowID: nil, serverRunning: true), []))
        XCTAssertLessThanOrEqual(prompt.count, 8_000)
        let lines = prompt.components(separatedBy: "\n")
        XCTAssertLessThanOrEqual(lines.filter { $0 == "- " + a }.count, lines.filter { $0 == "- " + b }.count)
        XCTAssertLessThanOrEqual(lines.filter { $0 == "- " + b }.count, lines.filter { $0 == "- " + c }.count)
    }

    func testTriesCommandsInOrderNormalizesQuotesAndReportsEveryFailure() throws {
        var calls: [String] = []
        let success = TopicTitleSuggester(commands: ["first", "second", "third"], transcriptLoader: { _ in ["request"] },
                                          modelCall: { command, _, _ in
            calls.append(command)
            if command == "first" { return .completed(status: 2, stdout: "", stderr: "bad input") }
            if command == "second" { return .completed(status: 0, stdout: "\n  \"  Good title  \"\n", stderr: "") }
            return .completed(status: 0, stdout: "wrong", stderr: "")
        })
        XCTAssertEqual(try success.suggest(for: .newTopic(pane(), nil)), "Good title")
        XCTAssertEqual(calls, ["first", "second"])

        let failed = TopicTitleSuggester(commands: ["exit", "empty", "slow", "missing"], transcriptLoader: { _ in ["request"] },
                                         modelCall: { command, _, _ in
            switch command {
            case "exit": return .completed(status: 7, stdout: "", stderr: "denied")
            case "empty": return .completed(status: 0, stdout: " \n", stderr: "")
            case "slow": return .timedOut(stderr: "still working")
            default: return .launchFailed("not found")
            }
        })
        XCTAssertThrowsError(try failed.suggest(for: .newTopic(pane(), nil))) { error in
            XCTAssertEqual(String(describing: error), """
            exit: exited with 7: denied
            empty: returned no title
            slow: timed out: still working
            missing: could not start: not found
            """)
        }
        XCTAssertEqual(TopicTitleSuggester.normalizedTitle(String(repeating: "z", count: 70))?.count, 60)
    }

    func testProductionModelCallUsesTheLoginShellAndWritesThePromptToStandardInput() throws {
        let suggester = TopicTitleSuggester(
            commands: ["read first; test \"$first\" = \"Give a short title for this work, at most 5 words. Return plain text on one line.\" && printf '\"Shell title\"\\n'"],
            transcriptLoader: { _ in ["request"] }
        )
        XCTAssertEqual(try suggester.suggest(for: .newTopic(pane(), nil)), "Shell title")
    }

    func testTimeoutStopsDescendantsThatKeepOutputOpenAndTriesTheNextCommand() throws {
        let started = Date()
        let suggester = TopicTitleSuggester(
            commands: ["(trap '' TERM; sleep 10) & exit 0", "printf 'Fallback title\\n'"],
            commandTimeout: 0.1,
            transcriptLoader: { _ in ["request"] }
        )

        XCTAssertEqual(try suggester.suggest(for: .newTopic(pane(), nil)), "Fallback title")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testSessionPathMetadataCannotExceedTheCompletePromptLimit() {
        let huge = SessionPath(path: "/work", name: String(repeating: "p", count: 8_000))
        var calls = 0
        let suggester = TopicTitleSuggester(commands: ["model"], transcriptLoader: { _ in ["request"] },
                                            modelCall: { _, _, _ in
            calls += 1
            return .completed(status: 0, stdout: "Title", stderr: "")
        })
        XCTAssertThrowsError(try suggester.suggest(for: .newTopic(pane(), huge))) { error in
            XCTAssertEqual(error as? TopicTitleSuggester.Failure, .promptMetadataTooLong)
        }
        XCTAssertEqual(calls, 0)
    }

    func testDoesNotCallAModelWithoutMessagesAndRejectsUnsafeIDsBeforeLoading() {
        var loads = 0, calls = 0
        let empty = TopicTitleSuggester(commands: ["model"], transcriptLoader: { _ in loads += 1; return [] },
                                        modelCall: { _, _, _ in calls += 1; return .completed(status: 0, stdout: "Title", stderr: "") })
        XCTAssertThrowsError(try empty.suggest(for: .newTopic(pane(), nil)))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(calls, 0)

        let unsafe = TopicTitleSuggester(commands: ["model"], transcriptLoader: { _ in loads += 1; return ["secret"] },
                                         modelCall: { _, _, _ in calls += 1; return .completed(status: 0, stdout: "Title", stderr: "") })
        XCTAssertThrowsError(try unsafe.suggest(for: .newTopic(pane(id: "../outside"), nil)))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(calls, 0)
    }

    func testReadsOnlyUserMessagesFromClaudeCodexAndPiJSONL() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let fixtures: [(AgentKind, String, String, String)] = [
            (.claude, "claude-id", ".claude/projects/work/claude-id.jsonl",
             "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"ignore\"}}\n{\"type\":\"user\",\"isMeta\":true,\"message\":{\"role\":\"user\",\"content\":\"claude meta\"}}\n{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"claude user\"}}\n"),
            (.codex, "codex-id", ".codex/sessions/2026/rollout-now-codex-id.jsonl",
             "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"ignore\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"codex user\"}}\n"),
            (.pi, "pi-id", ".pi/agent/sessions/work/time_pi-id.jsonl",
             "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ignore\"}]}}\n{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"pi user\"}]}}\n"),
        ]
        for (_, _, relative, contents) in fixtures {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        for (kind, id, _, _) in fixtures {
            var prompt = ""
            let suggester = TopicTitleSuggester(commands: ["model"], homeDirectory: home, modelCall: { _, value, _ in
                prompt = value
                return .completed(status: 0, stdout: "Title", stderr: "")
            })
            XCTAssertEqual(try suggester.suggest(for: .newTopic(pane(kind: kind, id: id), nil)), "Title")
            XCTAssertTrue(prompt.contains("\(kind.rawValue) user"))
            XCTAssertFalse(prompt.contains("ignore"))
            XCTAssertFalse(prompt.contains("claude meta"))
        }
    }
}
