import XCTest
@testable import MuxifyCore

final class CodexReportsTests: XCTestCase {
    private let first = "01a13784-4701-7cc1-9e20-657cdcab1649"
    private let second = "01a13784-4701-7cc1-9e20-757cdcab1649"

    private func pane(_ id: String, conversation: String, command: String = "codex", agent: String = "", status: String = "") -> String {
        ["P", id, "@1", command, agent, status, "0", "", "0", "1", "/work", conversation, "/dev/ttys001"]
            .joined(separator: Tmux.separator)
    }

    private func report(_ id: String, status: String?, version: Int = 1) -> String {
        let json: [String: Any] = ["version": version, "conversation": id, "status": status as Any? ?? NSNull()]
        return "D" + Tmux.separator + String(decoding: try! JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    func testDaemonReportsFollowEachPaneConversationInsteadOfReportOrder() {
        let snapshot = Tmux.parseSnapshot([
            pane("%1", conversation: String(first.prefix(29)) + "... ⠋ Working | first task"),
            pane("%2", conversation: "Action required | " + String(second.prefix(29)) + "... | second task"),
            report(second, status: "blocked"), report(first, status: "working"),
        ].joined(separator: "\n"))
        XCTAssertEqual(snapshot.panes.map(\.agent), ["codex", "codex"])
        XCTAssertEqual(snapshot.panes.map(\.agentStatus), ["working", "blocked"])
        XCTAssertEqual(snapshot.panes.map(\.agentConversation), [first, second])
        XCTAssertEqual(snapshot.panes.map(\.label), ["Working | first task", "Action required | second task"])
    }

    func testTitleCanArriveAfterReportAndMultiplePanesCanShowOneConversation() {
        let rows = [pane("%1", conversation: first + " | task"), pane("%2", conversation: first + " | task")]
        let snapshot = Tmux.parseSnapshot(([report(first, status: "done")] + rows).joined(separator: "\n"))
        XCTAssertEqual(snapshot.panes.map(\.agentStatus), ["done", "done"])
        XCTAssertEqual(snapshot.panes.map(\.agentConversation), [first, first])
    }

    func testNewCodexAndChangedConversationDoNotUseOldPaneOptions() {
        let snapshot = Tmux.parseSnapshot([
            pane("%1", conversation: "codex", agent: "codex", status: "blocked"),
            pane("%2", conversation: second, agent: "codex", status: "done"),
            report(first, status: "working"),
        ].joined(separator: "\n"))
        XCTAssertEqual(snapshot.panes.map(\.agent), ["codex", "codex"])
        XCTAssertEqual(snapshot.panes.map(\.agentStatus), ["", ""])
        XCTAssertEqual(snapshot.panes.map(\.agentConversation), ["", ""])
    }

    func testStaleTitleDoesNotIdentifyShellOrAnotherProgram() {
        let snapshot = Tmux.parseSnapshot([
            pane("%1", conversation: first, command: "zsh", agent: "codex", status: "done"),
            pane("%2", conversation: first, command: "vim", agent: "codex", status: "blocked"),
            report(first, status: "done"),
        ].joined(separator: "\n"))
        XCTAssertEqual(snapshot.panes.map(Agent.runs(in:)), [false, false])
    }

    func testAmbiguousTruncatedIdentifierDoesNotChooseAReport() {
        let collision = String(first.prefix(29)) + "0000000"
        let snapshot = Tmux.parseSnapshot([
            pane("%1", conversation: String(first.prefix(29)) + "... | task"),
            report(first, status: "working"), report(collision, status: "blocked"),
        ].joined(separator: "\n"))
        XCTAssertEqual(snapshot.panes[0].agentConversation, "")
        XCTAssertEqual(snapshot.panes[0].agentStatus, "")
    }

    func testUnsupportedAndInvalidReportsCannotSupplyIdentityOrStatus() {
        let snapshot = Tmux.parseSnapshot([
            pane("%1", conversation: first),
            report(first, status: "done", version: 2),
            report("../../" + first, status: "blocked"),
            "D" + Tmux.separator + "not JSON",
        ].joined(separator: "\n"))
        XCTAssertEqual(snapshot.panes[0].agentConversation, "")
        XCTAssertEqual(snapshot.panes[0].agentStatus, "")
    }

    func testSessionEndKeepsIdentityWithoutInventingStatus() {
        let snapshot = Tmux.parseSnapshot([
            pane("%1", conversation: first), report(first, status: nil),
        ].joined(separator: "\n"))
        XCTAssertEqual(snapshot.panes[0].agentConversation, first)
        XCTAssertEqual(snapshot.panes[0].agentStatus, "")
        XCTAssertTrue(Agent.runs(in: snapshot.panes[0]))
    }

    func testFinalInventoryReadsOnlyReportsForItsLiveCodexPanes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent(".local/state/muxify/codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for id in [first, second] {
            let json = report(id, status: "working").components(separatedBy: Tmux.separator)[1]
            try json.write(to: directory.appendingPathComponent(id + ".json"), atomically: true, encoding: .utf8)
        }
        let inventory = pane("%1", conversation: String(first.prefix(29)) + "... ⠋ Working")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        let output = try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: [
            "-c", "printf '%s\\n' \"$1\" | /bin/sh -c " + Tmux.shellQuote(Tmux.codexReportsForInventoryScript),
            "verify", inventory,
        ]), environment: environment)
        XCTAssertFalse(output.contains(second))
        let snapshot = Tmux.parseSnapshot(inventory + "\n" + output)
        XCTAssertEqual(snapshot.panes[0].agentConversation, first)
        XCTAssertEqual(snapshot.panes[0].agentStatus, "working")
    }
}
