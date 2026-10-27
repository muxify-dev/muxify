import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class PaneSearchTests: XCTestCase {
    private var directory: URL!
    private var server: TmuxServer!
    private var saved: [String: String?] = [:]

    override func tearDownWithError() throws {
        if let server, let socket = try? server.run(["display-message", "-p", "#{socket_path}"]) {
            let own = directory.appendingPathComponent("search").path
            XCTAssertEqual(socket.trimmingCharacters(in: .whitespacesAndNewlines), own)
            if socket.trimmingCharacters(in: .whitespacesAndNewlines) == own { _ = try? server.run(["kill-server"]) }
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A Pane that printed `lines` and waits, on a throwaway server.
    private func pane(printing lines: [String]) throws -> String {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxs-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
        server = TmuxServer(socketPath: directory.appendingPathComponent("search").path, configPath: "/dev/null")
        let script = directory.appendingPathComponent("lines")
        try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)
        let pane = try server.run(["new-session", "-d", "-P", "-F", "#{pane_id}", "-x", "40", "-y", "10",
                                   "cat \(script.path); exec sleep 1000"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let deadline = Date().addingTimeInterval(5)
        while try !server.run(["capture-pane", "-p", "-t", pane]).contains(lines.last!), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return pane
    }

    private let styles = PaneSearch.Styles(match: PaneSearch.style(red: 0xFF, green: 0xD5, blue: 0x4F),
                                           current: PaneSearch.style(red: 0x70, green: 0x5E, blue: 0x14))

    /// The count of the last query, which a step without one keeps.
    private var total: Int?

    /// Runs a step as the app does, and gives the status with the current match's place.
    private func run(_ step: PaneSearch.Step, query: String, in pane: String) throws -> (PaneSearch.Status, Int) {
        let status = try XCTUnwrap(PaneSearch.Status(try server.run(PaneSearch.commands(step, query: query, target: pane, styles: styles))))
        total = step == .query ? status.total : status.total ?? total
        let text = try server.run(PaneSearch.capture(status))
        return (status, PaneSearch.index(of: query, in: text, column: status.column, total: total ?? 0))
    }

    /// tmux takes emacs keys unless EDITOR names vi, and a search down moves the cursor differently with them.
    private func forBothModeKeys(_ pane: String, _ check: () throws -> Void) throws {
        for keys in ["vi", "emacs"] {
            _ = try server.run(["set-option", "-w", "-t", pane, "mode-keys", keys])
            _ = try server.run(PaneSearch.cancel(pane: pane))
            try check()
        }
    }

    func testAQueryFindsTheNewestMatchAndNextGoesUpToOlderOutput() throws {
        let pane = try pane(printing: (1...30).map { "row\($0) abc" })
        try forBothModeKeys(pane) { try stepThroughTheMatches(in: pane) }
    }

    private func stepThroughTheMatches(in pane: String) throws {
        var (status, index) = try run(.query, query: "ABC", in: pane)
        XCTAssertFalse(status.found, "a capital makes the search match case")
        (status, index) = try run(.query, query: "abc", in: pane)
        XCTAssertEqual(status.pane, pane)
        XCTAssertTrue(status.found)
        XCTAssertEqual(status.total, 30)
        XCTAssertEqual(index, 0)
        (status, index) = try run(.next, query: "abc", in: pane)
        XCTAssertEqual(index, 1)
        for _ in 0..<15 { (status, index) = try run(.next, query: "abc", in: pane) }
        XCTAssertLessThan(status.line, 0, "the match is in the history")
        XCTAssertEqual(index, 16)
        (status, index) = try run(.previous, query: "abc", in: pane)
        XCTAssertEqual(index, 15)
        (status, index) = try run(.previous, query: "abc", in: pane)
        XCTAssertEqual(index, 14)
        (status, index) = try run(.next, query: "abc", in: pane)
        XCTAssertEqual(index, 15)
    }

    func testAChangedQuerySearchesAgainFromTheNewestOutput() throws {
        let pane = try pane(printing: (1...30).map { "row\($0) abc" })
        _ = try run(.query, query: "ab", in: pane)
        _ = try run(.next, query: "ab", in: pane)
        let (status, index) = try run(.query, query: "abc", in: pane)
        XCTAssertTrue(status.found)
        XCTAssertEqual(index, 0)
    }

    func testPreviousFromTheNewestMatchWrapsToTheOldest() throws {
        let pane = try pane(printing: (1...30).map { "row\($0) abc" })
        try forBothModeKeys(pane) {
            _ = try run(.query, query: "abc", in: pane)
            let (status, index) = try run(.previous, query: "abc", in: pane)
            XCTAssertTrue(status.found)
            XCTAssertEqual(index, 29)
        }
    }

    func testTheCurrentMatchCountsOnlyTheMatchesAfterItOnItsLine() throws {
        let pane = try pane(printing: ["x abc abc abc", "end"])
        _ = try run(.query, query: "abc", in: pane)
        let (status, index) = try run(.next, query: "abc", in: pane)
        XCTAssertEqual(status.column, 6)
        XCTAssertEqual(index, 1)
    }

    func testAQueryThatEndsInASemicolonIsSearchedForAsTyped() throws {
        let pane = try pane(printing: ["a; b", "c;"])
        let (status, index) = try run(.query, query: "c;", in: pane)
        XCTAssertTrue(status.found)
        XCTAssertEqual(status.total, 1)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(try server.run(["display-message", "-p", "-t", pane, "#{pane_search_string}"]), "c;\n")
    }

    func testAQueryWithNoMatchIsNotFound() throws {
        let pane = try pane(printing: ["abc"])
        let status = try XCTUnwrap(PaneSearch.Status(try server.run(PaneSearch.commands(.query, query: "zzz", target: pane, styles: styles))))
        XCTAssertFalse(status.found)
    }

    func testTheSearchedPaneShowsTheStylesUntilCancelLeavesCopyMode() throws {
        let pane = try pane(printing: ["abc"])
        let options = ["show-options", "-pqv", "-t", pane]
        _ = try server.run(PaneSearch.commands(.query, query: "abc", target: pane, styles: styles))
        XCTAssertEqual(try server.run(["display-message", "-p", "-t", pane, "#{pane_mode}"]), "copy-mode\n")
        XCTAssertEqual(try server.run(options + ["copy-mode-match-style"]), "bg=#ffd54f,fg=#000000\n")
        XCTAssertEqual(try server.run(options + ["copy-mode-current-match-style"]), "bg=#705e14,fg=#ffffff\n")
        _ = try server.run(PaneSearch.cancel(pane: pane))
        XCTAssertEqual(try server.run(["display-message", "-p", "-t", pane, "#{pane_mode}"]), "\n")
        XCTAssertEqual(try server.run(options + ["copy-mode-match-style"]), "")
        XCTAssertEqual(try server.run(options + ["copy-mode-current-match-style"]), "")
    }

    func testAStyleHasTheTextColorThatReadsBestOnItsBackground() {
        XCTAssertEqual(PaneSearch.style(red: 0xFF, green: 0x96, blue: 0x00), "bg=#ff9600,fg=#000000")
        XCTAssertEqual(PaneSearch.style(red: 0x1E, green: 0x3A, blue: 0x8A), "bg=#1e3a8a,fg=#ffffff")
    }

    func testAWideCharacterFillsTwoCellsBeforeTheCurrentMatch() {
        XCTAssertEqual(PaneSearch.index(of: "ab", in: "日本ab ab\nab", column: 4, total: 3), 2)
    }

    func testTheStatusReadsAnOldTmuxThatDoesNotCount() {
        let status = PaneSearch.Status("%3 1  5 2 7\n")
        XCTAssertEqual(status?.total, nil)
        XCTAssertEqual(status?.line, -5)
        XCTAssertNil(PaneSearch.Status("no server running"))
    }
}
