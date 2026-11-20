import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

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

    /// tmux 3.8 answers a Pane's background question from a control Client in its Session as black, so the probe sits
    /// in another Session than the one that tmux picks for the events client, the latest.
    func testTheEventsClientWatchesFromASessionTmuxPicksAndNeverAnswersTheColorQueryOfAnotherSession() throws {
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        try server.run(["new-session", "-d", "-s", "spare"])
        try server.run(["set-option", "-g", "window-style", ""])
        let events = TmuxEvents()
        var changes: [String] = []
        events.onEvent = { if case .sessionWindowChanged(_, let window) = $0 { changes.append(window) } }
        defer { events.stop() }
        events.start(invocation: server.invocation)
        try wait("the events client did not attach") { try self.controlClients() == ["spare"] }
        XCTAssertFalse(try sessions().contains(EnvironmentPublisher.leftoverWatchSession), "the events client made a Session")

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

        let sitting = try XCTUnwrap(try controlClients().first)
        try server.run(["kill-session", "-t", "=" + sitting])
        try wait("the events client outlived its Session") { !events.isRunning }
        try wait("the events client did not come back in the Session left", seconds: 5) {
            events.start(invocation: self.server.invocation)
            return try self.controlClients().count == 1
        }
    }

    func testAControlClientWritesABatchFarLargerThanItsPtyWholeAndInOrder() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "no python3 for the probe")
        let script = directory.appendingPathComponent("probe.py").path
        let go = directory.appendingPathComponent("go").path
        // Waits for `go`, then asks for the background (OSC 11) and writes the answer's colour, or `none`.
        try """
            import os, re, select, sys, time, tty
            answer, go = sys.argv[1], sys.argv[2]
            tty.setraw(0)
            while not os.path.exists(go): time.sleep(0.02)
            os.write(1, b'\\x1b]11;?\\x1b\\\\')
            reply, end = b'', time.time() + 2
            while time.time() < end and not reply.endswith(b'\\x1b\\\\'):
                if select.select([0], [], [], 0.05)[0]: reply += os.read(0, 256)
            found = re.search(rb'rgb:[0-9a-f/]+', reply)
            open(answer + '.part', 'w').write(found.group().decode() if found else 'none')
            os.rename(answer + '.part', answer)
            time.sleep(30)
            """.write(toFile: script, atomically: true, encoding: .utf8)
        let answers = (0..<16).map { directory.appendingPathComponent("answer-\($0)").path }
        var panes: [String] = []
        for (index, answer) in answers.enumerated() {
            let place = index == 0 ? ["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"] : ["new-window", "-d", "-t", "work:"]
            panes.append(try server.run(place + ["-P", "-F", "#{pane_id}", "\(python) \(script) \(answer) \(go)"])
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let invocation = try server.invocation(["-C", "attach-session", "-t", "work", "-f", "no-output,ignore-size"])
        let client = try ControlClient(binary: invocation.executable, arguments: invocation.arguments,
                                       onLines: { _ in }, onExit: {})
        defer { client.stop() }
        try wait("the control client did not attach") { try self.controlClients() == ["work"] }
        let pid = try XCTUnwrap(pid_t(try server.run(["list-clients", "-f", "#{client_control_mode}", "-F", "#{client_pid}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)))

        // Each round reports another colour to every Pane, so a Pane answers its last round only when every line
        // reached tmux whole and in order.
        func colours(round: Int, pane: Int) -> TerminalColours {
            TerminalColours(background: TerminalColour(red: UInt8(round), green: UInt8(pane), blue: 0x80),
                            foreground: TerminalColour(red: 0x10, green: 0x20, blue: UInt8(round)))
        }
        let rounds = 16
        let lines = (0..<rounds).flatMap { round in
            panes.enumerated().flatMap { ColourReport.commands(panes: [$0.element], colours: colours(round: round, pane: $0.offset)) }
        } + ["set-option -g @muxify_lossless done"]
        XCTAssertGreaterThan(lines.reduce(0) { $0 + $1.utf8.count + 1 }, 16 * 1024, "the batch fits in the pty")

        // A stopped client reads nothing, so the pty fills after its first few lines.
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGCONT) }
        let started = Date()
        lines.forEach(client.send)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a send waited for the pty")
        kill(pid, SIGCONT)

        try wait("tmux did not run the batch's last line", seconds: 10) {
            (try? self.server.run(["show-options", "-gv", "@muxify_lossless"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "done"
        }
        try "".write(toFile: go, atomically: true, encoding: .utf8)
        try wait("a probe did not answer", seconds: 10) { answers.allSatisfy { FileManager.default.fileExists(atPath: $0) } }
        for (index, answer) in answers.enumerated() {
            XCTAssertEqual(try String(contentsOfFile: answer, encoding: .utf8),
                           colours(round: rounds - 1, pane: index).background.oscReply, "Pane \(panes[index])")
        }
    }

    private func sessions() throws -> [String] {
        try server.run(["list-sessions", "-F", "#{session_name}"]).split(separator: "\n").map(String.init)
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
