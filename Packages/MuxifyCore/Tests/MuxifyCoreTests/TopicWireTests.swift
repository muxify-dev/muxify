import XCTest
@testable import MuxifyCore

final class TopicWireTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testRequestsRoundTripAndUseOnlyNewPublicTerms() throws {
        let session = SessionID(rawValue: "$1")!
        let commands: [EnvironmentCommand] = [.list, .show, .create(title: "Fix", tags: [Tag(name: "backend")!]),
            .addSession(sessionPath: "/work", workingCopy: .directory, name: "debug"),
            .addSession(sessionPath: "/work", workingCopy: .newWorktree(from: "/work", start: .ref("main"))),
            .addSession(sessionPath: "/work", workingCopy: .newWorktree(from: "/work", start: .branch("fix"))),
            .addSession(sessionPath: "/work", workingCopy: .newWorktree(from: "/work")), .addSession(sessionPath: "/work", workingCopy: .worktree(path: "/w")),
            .move(to: .session(session)), .move(to: .newSession(topic: .id("fix"))),
            .move(to: .newSession(topic: nil)), .move(to: .newTopic(title: "Fix")),
            .settle(choices: [], outcome: "Done"), .forget(choices: [], worktrees: []),
            .removeFromTopic, .removeAndKill(worktrees: []), .rename(title: "Next"), .reopen, .startFresh,
            .lock, .unlock, .moveSession(to: .before(session)), .moveSession(to: .up), .moveSession(to: .down), .sortSessions,
            .snooze(until: .never), .unsnooze(), .tags(.set([Tag(name: "backend")!])),
            .newWindow(command: ["make", "test"]), .newSession(sessionPath: "/work", name: "notes"), .renameSession(name: "n"),
            .renameWindow(name: "w"), .killWindow, .killSession, .pin, .unpin, .moveCard(.up), .moveCard(.down),
            .moveCard(.before(.topic(.id("fix")))), .moveCard(.after(.lock(session))),
            .moveWindow(to: .before(WindowID(rawValue: "@3")!)), .moveWindow(to: .after(WindowID(rawValue: "@3")!))]
        for command in commands {
            let request = EnvironmentRequest(command, target: .session(session))
            let text = try json(request)
            XCTAssertEqual(try JSONDecoder().decode(EnvironmentRequest.self, from: Data(text.utf8)), request)
            XCTAssertFalse(text.contains("project"), text)
            XCTAssertTrue(text.contains(#""version":2"#), text)
        }
        XCTAssertEqual(try json(EnvironmentCommand.create(title: "Fix")), #"{"create":{"title":"Fix"}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.moveSession(to: .up)), #"{"move_session":{"to":{"up":{}}}}"#)
        XCTAssertEqual(try json(TopicWorkingCopyChoice.newWorktree(from: "/work", start: .branch("fix"))), #"{"new_worktree":{"branch":"fix","from":"/work"}}"#)
        XCTAssertEqual(try json(TopicWorkingCopyChoice.newWorktree(from: "/work", start: .ref("main"))), #"{"new_worktree":{"base":"main","from":"/work"}}"#)
        XCTAssertEqual(try json(TopicWorkingCopyChoice.worktree(path: "/w")), #"{"worktree":{"path":"/w"}}"#)
        XCTAssertThrowsError(try JSONDecoder().decode(TopicWorkingCopyChoice.self, from: Data(#"{"new_worktree":{"from":"/w","base":"a","branch":"b"}}"#.utf8)),
                             "base and branch at once do not decode")
        XCTAssertEqual(try json(EnvironmentCommand.addSession(sessionPath: "/work", workingCopy: .directory)),
            #"{"add_session":{"directory":"/work","working_copy":{"directory":{}}}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.moveCard(.up)), #"{"move_card":{"move":{"up":{}}}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.moveCard(.after(.lock(session)))), #"{"move_card":{"move":{"after":{"card":{"lock":{"session":"$1"}}}}}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.moveWindow(to: .before(WindowID(rawValue: "@3")!))), #"{"move_window":{"to":{"before":{"window":"@3"}}}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.moveWindow(to: .after(WindowID(rawValue: "@5")!))), #"{"move_window":{"to":{"after":{"window":"@5"}}}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.startZen(until: .never)), #"{"start_zen":{"until":"never"}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.endZen), #"{"end_zen":{}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.markRead(.unread, scope: .session)), #"{"mark_read":{"change":"unread","scope":"session"}}"#)
        XCTAssertEqual(try json(EnvironmentCommand.markAllRead), #"{"mark_all_read":{}}"#)
        XCTAssertEqual(try json(EnvironmentResponse.readChanged(TopicReadChange(topicIDs: ["a"], paneIDs: [PaneID(rawValue: "%3")!]))),
            #"{"read_changed":{"pane_ids":["%3"],"topic_ids":["a"]}}"#)
        XCTAssertEqual(try json(TopicSummary(id: "a", label: "Fix", pinned: true)), #"{"id":"a","label":"Fix","pinned":true,"tags":[]}"#)
    }

    func testSessionDetailUsesNameBaseAndDirectoryRatherThanRepositoryIdentity() throws {
        let detail = TopicDetail(id: "a", label: "Fix", title: "Fix", slug: "fix", createdAt: nil,
            snoozedUntil: nil, tags: [], sessions: [.init(id: "$2", name: "debug/fix", baseName: "debug", directory: "/work", worktree: nil, windows: [])])
        let response = EnvironmentResponse.topic(detail)
        let text = try json(response)
        XCTAssertFalse(text.contains("project"))
        XCTAssertTrue(text.contains(#""base_name":"debug""#))
        XCTAssertTrue(text.contains(#""directory":"/work""#))
        XCTAssertEqual(try JSONDecoder().decode(EnvironmentResponse.self, from: Data(text.utf8)), response)
    }

    func testOtherRequestVersionsAreRefusedWithoutReadingAnyState() {
        for version in [1, 3] {
            var request = EnvironmentRequest(.create(title: "Later"))
            request.version = version
            let paths = MuxifyPaths(environment: ["XDG_STATE_HOME": "/nonexistent/state"], home: "/nonexistent")
            guard case .failed(let failure) = EnvironmentService(paths: paths).handle(request) else { return XCTFail("expected failure") }
            XCTAssertEqual(failure.kind, .unsupported)
            XCTAssertEqual(failure.phase, .nothingChanged)
        }
    }

    func testIDsAreValidatedAtTheEdge() {
        XCTAssertNil(PaneID(rawValue: "12"))
        XCTAssertNil(WindowID(rawValue: "@x"))
        XCTAssertThrowsError(try JSONDecoder().decode(EnvironmentTarget.self, from: Data(#"{"pane":"@3"}"#.utf8)))
    }
}
