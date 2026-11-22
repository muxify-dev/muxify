import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// A Board Session in the state database: what each read of the server changes in it, and what Reopen and Start Fresh of a
/// Dormant Board Session create.
final class BoardSessionTests: XCTestCase {
    private func window(_ n: Int, session: String = "$1", name: String = "notes", boardSession: String = "g1", topic: String? = nil) -> TmuxWindow {
        .fixture(id: "@\(n)", sessionID: session, sessionName: name, index: n, name: "w\(n)", path: "/work/notes/\(n)", topicID: topic,
                 savedSessionID: boardSession, sessionPath: "/work/notes")
    }

    private func snapshot(_ windows: [TmuxWindow], server: String = "1:1", running: Bool = true) -> TmuxSnapshot {
        TmuxSnapshot(windows: windows, clients: [], panes: [], serverRunning: running, serverID: server)
    }

    private let boardSession = BoardSession(id: "g1", order: 4, isGuest: true)

    func testALiveBoardSessionIsRememberedWithEachOfItsWindows() throws {
        let live = snapshot([window(1), window(2), window(3, session: "$2", name: "other", boardSession: "")])
        guard case .remembered(let session)? = boardSession.remembering(live, open: []) else { return XCTFail("nothing remembered") }
        XCTAssertEqual(session["id"], .string("g1"))
        XCTAssertEqual(session["name"], .string("notes"))
        XCTAssertEqual(session["directory"], .string("/work/notes"))
        XCTAssertEqual(session["windows"]?.array?.compactMap { $0["name"]?.string }, ["w1", "w2"], "only the Windows of its own Session")

        let saved = BoardSession(id: "g1", order: 4, isGuest: true, session: session)
        XCTAssertNil(saved.remembering(live, open: []), "a layout that did not change writes nothing")
    }

    func testATmuxRestartKeepsTheBoardSessionDormantAndAnEndOnTheSameServerEndsIt() {
        let before = [window(1)]
        XCTAssertNil(boardSession.remembering(snapshot([], server: "2:2"), open: [], previously: []),
                     "a new server, whose read follows none of the same server, ends nothing")
        XCTAssertNil(boardSession.remembering(snapshot([], running: false), open: [], previously: before), "a stopped server ends nothing")
        XCTAssertNil(boardSession.remembering(snapshot([]), open: []), "the first read after a start ends nothing")
        XCTAssertEqual(boardSession.remembering(snapshot([]), open: [], previously: before), .ended, "the Session ended on the same server")
    }

    func testASessionThatWentIntoAnOpenTopicIsNotABoardSessionAndLeavesTheBoard() {
        let moved = snapshot([window(1, topic: "t")])
        XCTAssertTrue(boardSession.windows(in: moved.windows, open: ["t"]).isEmpty)
        XCTAssertEqual(boardSession.remembering(moved, open: ["t"], previously: [window(1)]), .ended)
        XCTAssertEqual(boardSession.windows(in: moved.windows, open: []).map(\.id), ["@1"], "a Settled Topic's Session can be a Board Session")
    }

    func testReopenCreatesTheSessionWithItsWindowsAndPointsItAtTheBoardSession() throws {
        let live = snapshot([window(1), window(2)])
        guard case .remembered(let session)? = boardSession.remembering(live, open: []) else { return XCTFail("nothing remembered") }
        let dormant = BoardSession(id: "g1", order: 4, isGuest: true, session: session)

        let edit = try BoardSessionReopenPlan(boardSession: dormant, records: [], windows: [window(9, session: "$9", name: "main", boardSession: "")]).edit
        XCTAssertEqual(edit.selection, .sessionName("notes"))
        XCTAssertEqual(edit.commands.first, .reopenSession(name: "notes", directory: "/work/notes", windowName: "w1"))
        XCTAssertTrue(edit.commands.contains(.tmux(["set-option", "-t", "=notes:", "@muxify_session_id", "g1"])))
        XCTAssertTrue(edit.commands.contains(.tmux(["new-window", "-d", "-a", "-t", "=notes:$", "-c", "/work/notes/2", "-n", "w2"])))
        XCTAssertFalse(edit.commands.contains { if case .tmux(let arguments) = $0 { arguments.contains("@muxify_topic") } else { false } },
                       "a Board Session is in no Topic")
        XCTAssertNil(edit.record)

        let taken = try BoardSessionReopenPlan(boardSession: dormant, records: [], windows: [window(9, session: "$9", boardSession: "")]).edit
        XCTAssertEqual(taken.selection, .sessionName("notes+2"), "a name that a live Session has gets +2")

        let shown = try BoardSessionReopenPlan(boardSession: dormant, records: [], windows: [window(1)]).edit
        XCTAssertEqual(shown.commands, [], "a live Board Session is only shown")
        XCTAssertEqual(shown.selection, .sessionID("$1"))
    }

    func testStartFreshCreatesTheSessionWithOneShellWindowAndPointsItAtTheBoardSession() throws {
        let agent: JSONValue = .object(["name": .string("agent"), "directory": .string("/work/notes"), "agent": .string("claude"),
                                        "agent_conversation": .string("c1"), "browser_tabs": .array([.string("https://example.com")])])
        let dormant = BoardSession(id: "g1", order: 4, isGuest: true, session: .object([
            "id": .string("g1"), "name": .string("notes"), "directory": .string("/work/notes"),
            "windows": .array([.object(["name": .string("edit"), "directory": .string("/work/notes/1")]), agent]),
        ]))

        let edit = try BoardSessionReopenPlan(boardSession: dormant, records: [], windows: [window(9, session: "$9", boardSession: "")], choice: .startFresh).edit
        XCTAssertEqual(edit.selection, .sessionName("notes+2"), "a name that a live Session has gets +2, as for Reopen")
        XCTAssertEqual(edit.commands.first, .reopenSession(name: "notes+2", directory: "/work/notes", windowName: "shell"))
        XCTAssertTrue(edit.commands.contains(.tmux(["set-option", "-t", "=notes+2:", "@muxify_session_id", "g1"])),
                      "the new Session points at the same Board Session, so its card keeps its place")
        XCTAssertFalse(edit.commands.contains { if case .tmux(let arguments) = $0 { arguments.first == "new-window" } else { false } },
                       "only one Window")
        XCTAssertFalse(edit.commands.contains { if case .sendKeys = $0 { true } else { false } }, "no Agent resumes")
        XCTAssertTrue(edit.commands.contains(.tmux(StoredBrowser().setOptionArgs(windowID: "=notes+2:$"))), "no Tab comes back")

        XCTAssertThrowsError(try BoardSessionReopenPlan(boardSession: dormant, records: [], windows: [window(1)], choice: .startFresh),
                             "Start Fresh of a live Board Session fails, as for a live Topic") { error in
            XCTAssertEqual(String(describing: error), TopicRequestError.boardSessionLive("g1").description)
        }
    }
}
