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
        let commands: [TopicCommand] = [.list, .show, .create(title: "Fix", sessionPath: "/work"),
            .addSession(sessionPath: "/work", workingCopy: .directory, name: "debug"),
            .addSession(sessionPath: "/work", workingCopy: .newWorktree(from: "/work", base: "main")),
            .move(to: .session(session)), .move(to: .newSession(topic: .id("fix"))),
            .move(to: .newSession(topic: nil)), .move(to: .newTopic(title: "Fix")),
            .settle(choices: [], outcome: "Done"), .forget(choices: [], worktrees: []),
            .removeFromTopic, .removeAndKill(worktrees: []), .rename(title: "Next"), .reopen, .startFresh,
            .lock, .unlock, .moveSession(to: .before(session)), .sortSessions,
            .snooze(until: .never), .unsnooze(), .tags(.set([Tag(name: "backend")!]))]
        for command in commands {
            let request = TopicRequest(command, target: .session(session))
            let text = try json(request)
            XCTAssertEqual(try JSONDecoder().decode(TopicRequest.self, from: Data(text.utf8)), request)
            XCTAssertFalse(text.contains("project"), text)
            XCTAssertTrue(text.contains(#""version":2"#), text)
        }
        XCTAssertEqual(try json(TopicCommand.addSession(sessionPath: "/work", workingCopy: .directory)),
            #"{"add_session":{"directory":"/work","working_copy":{"directory":{}}}}"#)
    }

    func testSessionDetailUsesNameBaseAndDirectoryRatherThanRepositoryIdentity() throws {
        let detail = TopicDetail(id: "a", label: "Fix", title: "Fix", slug: "fix", createdAt: nil,
            snoozedUntil: nil, tags: [], sessions: [.init(id: "$2", name: "debug/fix", baseName: "debug", directory: "/work", worktree: nil, windows: [])])
        let response = TopicResponse.topic(detail)
        let text = try json(response)
        XCTAssertFalse(text.contains("project"))
        XCTAssertTrue(text.contains(#""base_name":"debug""#))
        XCTAssertTrue(text.contains(#""directory":"/work""#))
        XCTAssertEqual(try JSONDecoder().decode(TopicResponse.self, from: Data(text.utf8)), response)
    }

    func testOtherRequestVersionsAreRefusedWithoutReadingAnyState() {
        for version in [1, 3] {
            var request = TopicRequest(.create(title: "Later", sessionPath: nil))
            request.version = version
            let paths = MuxifyPaths(environment: ["XDG_STATE_HOME": "/nonexistent/state"], home: "/nonexistent")
            guard case .failed(let failure) = TopicService(paths: paths).handle(request) else { return XCTFail("expected failure") }
            XCTAssertEqual(failure.kind, .unsupported)
            XCTAssertEqual(failure.phase, .nothingChanged)
        }
    }

    func testIDsAreValidatedAtTheEdge() {
        XCTAssertNil(PaneID(rawValue: "12"))
        XCTAssertNil(WindowID(rawValue: "@x"))
        XCTAssertThrowsError(try JSONDecoder().decode(TopicTarget.self, from: Data(#"{"pane":"@3"}"#.utf8)))
    }
}
