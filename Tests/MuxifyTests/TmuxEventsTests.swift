import XCTest
import MuxifyCore
import MuxifyTestSupport
@testable import Muxify

/// Runs the events client against a throwaway tmux server.
final class TmuxEventsTests: XCTestCase {
    private var directory: URL!
    private var server: TmuxServer!
    private var socket: String { directory.appendingPathComponent("s").path }
    private var saved: [String: String?] = [:]

    override func setUpWithError() throws {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxe-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = TmuxServer(socketPath: socket, configPath: "/dev/null")
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let actual = try? server?.run(["display-message", "-p", "#{socket_path}"]),
           actual.trimmingCharacters(in: .whitespacesAndNewlines) == socket {
            _ = try? server.run(["kill-server"])
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testTheEventsClientWatchesFromItsOwnSessionAndNeverAnswersAPanesColorQuery() throws {
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        try server.run(["set-option", "-g", "window-style", ""])
        let events = TmuxEvents()
        var changes: [String] = []
        events.onEvent = { if case .sessionWindowChanged(_, let window) = $0 { changes.append(window) } }
        defer { events.stop() }
        events.start(invocation: server.invocation)
        try wait("the events client did not attach") { try self.controlClients() == [Tmux.watchSessionName] }

        let reply = directory.appendingPathComponent("reply").path
        let probe = "stty raw -echo min 0 time 10; printf '\\033]11;?\\033\\\\'; head -c 64 > \(reply); touch \(reply).done"
        try server.run(["new-window", "-d", "-t", "work:", "sh", "-c", probe])
        try wait("the color query did not finish") { FileManager.default.fileExists(atPath: reply + ".done") }
        XCTAssertFalse(try String(contentsOfFile: reply, encoding: .utf8).contains("rgb:0000/0000/0000"),
                       "the events client answered a Pane's color query with black")

        let window = try server.run(["new-window", "-d", "-t", "work:", "-P", "-F", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try server.run(["select-window", "-t", window])
        try wait("no session-window-changed from the user's Session") { changes.contains(window) }

        try server.run(["kill-session", "-t", "=" + Tmux.watchSessionName])
        try wait("the events client outlived its Session") { !events.isRunning }
        try wait("the events client did not come back with its Session", seconds: 5) {
            events.start(invocation: self.server.invocation)
            return try self.controlClients() == [Tmux.watchSessionName]
        }
    }

    private func controlClients() throws -> [String] {
        try server.run(["list-clients", "-f", "#{client_control_mode}", "-F", "#{session_name}"])
            .split(separator: "\n").map(String.init)
    }

    private func wait(_ message: String, seconds: TimeInterval = 3, until done: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !done() {
            guard Date() < deadline else { return XCTFail(message) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
