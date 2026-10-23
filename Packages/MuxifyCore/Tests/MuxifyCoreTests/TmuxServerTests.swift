import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class TmuxServerTests: XCTestCase {
    private var directory: URL!
    private var other: TmuxServer!
    private var saved: [String: String?] = [:]

    override func setUpWithError() throws {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxs-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        other = TmuxServer(socketPath: directory.appendingPathComponent("other").path, configPath: "/dev/null")
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let socket = try? other?.run(["display-message", "-p", "#{socket_path}"]) {
            XCTAssertEqual(socket.trimmingCharacters(in: .whitespacesAndNewlines), directory.appendingPathComponent("other").path)
            if socket.trimmingCharacters(in: .whitespacesAndNewlines) == directory.appendingPathComponent("other").path {
                _ = try? other?.run(["kill-server"])
            }
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAServerAtASocketRunsCommandsAndGivesItsSnapshot() throws {
        try other.run(["new-session", "-d", "-s", "work", "-n", "editor", "-c", directory.path])
        XCTAssertEqual(try other.run(["display-message", "-p", "#{socket_path}"]),
                       directory.appendingPathComponent("other").path + "\n")
        let snapshot = other.snapshot()
        XCTAssertTrue(snapshot.serverRunning)
        XCTAssertEqual(snapshot.windows.map(\.sessionName), ["work"])
        XCTAssertEqual(snapshot.windows.map(\.name), ["editor"])
    }

    func testAWindowKeepsTheTogglesAndMaximizeWrittenOntoIt() throws {
        try other.run(["new-session", "-d", "-s", "work", "-c", directory.path])
        let windowID = try XCTUnwrap(other.snapshot().windows.first?.id)
        for layout in [PanelLayout(shown: .browser, maximized: .terminal), PanelLayout(shown: .both, maximized: .browser), PanelLayout()] {
            let stored = StoredBrowser(tabURLs: ["https://example.com"], layout: layout)
            try other.run(stored.setOptionArgs(windowID: windowID))
            XCTAssertEqual(other.snapshot().windows.first?.storedBrowser, stored)
        }
    }

    func testTheLocalServerIsTheDefaultSocketEvenWhenTMUXNamesAnotherServer() throws {
        try other.run(["new-session", "-d", "-s", "elsewhere"])
        let pid = try other.run(["display-message", "-p", "#{pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        setenv("TMUX", directory.appendingPathComponent("other").path + "," + pid + ",0", 1)
        setenv("TMUX_PANE", "%0", 1)
        setenv("TMUX_TMPDIR", directory.path, 1)
        // No server runs on the default socket in the run directory, so tmux names that socket in its error.
        // A server that followed $TMUX would answer with the other socket instead.
        XCTAssertThrowsError(try TmuxServer.local.run(["display-message", "-p", "#{socket_path}"])) { error in
            guard case TmuxError.failed(_, let stderr) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(stderr.contains(directory.path + "/tmux-\(getuid())/default"), stderr)
        }
        XCTAssertFalse(TmuxServer.local.snapshot().serverRunning)
    }
}
