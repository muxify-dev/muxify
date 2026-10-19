import XCTest

final class TerminalVisibilityTests: XCTestCase {
    func testSnapshotReadsWhetherAWindowHidThisTerminal() {
        let s = Tmux.separator
        let line = { (terminal: String?) in
            (["W", "@1", "$1", "main", "0", "shell", "", "/", "sh", "1", "1", "0", "0",
              "", "", "", "", "", "", "/"] + (terminal.map { [$0] } ?? [])).joined(separator: s)
        }
        let windows = Tmux.parseSnapshot([line("off"), line(""), line(nil)].joined(separator: "\n")).windows
        XCTAssertEqual(windows.map(\.terminalHidden), [true, false, false])
    }

    func testAPendingChangeOutlivesAStaleSnapshotUntilTmuxAgrees() {
        let now = Date()
        var pending = PendingTerminalVisibility()
        pending.set(true, windowID: "@1", until: now.addingTimeInterval(2))

        let stale = pending.apply(to: [window("@1"), window("@2")], now: now)
        XCTAssertEqual(stale.map(\.terminalHidden), [true, false])

        XCTAssertEqual(pending.apply(to: [window("@1", hidden: true)], now: now).map(\.terminalHidden), [true])
        XCTAssertEqual(pending.apply(to: [window("@1")], now: now).map(\.terminalHidden), [false],
                       "Once tmux agreed, later snapshots win")
    }

    func testAPendingChangeExpires() {
        let now = Date()
        var pending = PendingTerminalVisibility()
        pending.set(true, windowID: "@1", until: now.addingTimeInterval(2))
        XCTAssertEqual(pending.apply(to: [window("@1")], now: now.addingTimeInterval(3)).map(\.terminalHidden), [false])
    }

    func testAPendingChangeGoesWithItsWindow() {
        let now = Date()
        var pending = PendingTerminalVisibility()
        pending.set(true, windowID: "@1", until: now.addingTimeInterval(2))
        XCTAssertEqual(pending.apply(to: [window("@2")], now: now).map(\.terminalHidden), [false])
        XCTAssertEqual(pending.apply(to: [window("@1")], now: now).map(\.terminalHidden), [false],
                       "A reused window id does not inherit the change")
    }

    private func window(_ id: String, hidden: Bool = false) -> TmuxWindow {
        TmuxWindow(id: id, sessionID: "$1", sessionName: "test", index: 0, name: "shell",
                   paneTitle: "", path: "/", command: "sh", isActive: true, paneCount: 1,
                   hasBell: false, sessionActivity: 0, agent: "", storedBrowser: StoredBrowser(), openRequests: [],
                   terminalHidden: hidden)
    }
}
