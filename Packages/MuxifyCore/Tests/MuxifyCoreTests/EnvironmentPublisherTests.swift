import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// Runs the `environment` publisher against a throwaway tmux server and a temporary state database.
final class EnvironmentPublisherTests: XCTestCase {
    private var directory: URL!
    private var server: TmuxServer!
    private var paths: MuxifyPaths!
    private var publishers: [EnvironmentPublisher] = []
    private var saved: [String: String?] = [:]
    private var socket: String { directory.appendingPathComponent("s").path }

    override func setUpWithError() throws {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxp-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = TmuxServer(socketPath: socket, configPath: "/dev/null")
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("state").path], home: "/nonexistent")
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
    }

    override func tearDownWithError() throws {
        publishers.forEach { $0.stop() }
        publishers = []
        if let actual = try? server?.run(["display-message", "-p", "#{socket_path}"]),
           actual.trimmingCharacters(in: .whitespacesAndNewlines) == socket {
            _ = try? server.run(["kill-server"])
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testTheFirstItemHoldsEveryKeyAndAnUnchangedReadSendsNothing() async throws {
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        try server.run(["new-session", "-d", "-s", "other"])
        try TopicStore(paths: paths).write { try $0.create(TopicRecord(id: "first", title: "First")) }
        let recorder = start()

        try await wait("no first item") { !recorder.items.isEmpty }
        let first = try XCTUnwrap(recorder.items.first)
        XCTAssertEqual(Set(first.map(\.key)), ["session \(try sessionID("work"))", "session \(try sessionID("other"))",
                                               "topic first", "open_places", "server"])
        guard case .server(let state)? = first.first(where: { $0.key == "server" }) else { return XCTFail("no server event") }
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.socketPath, socket)

        try await settle(recorder, controlClients: 1)
        await publishers[0].read()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(recorder.keys, [], "a read of an unchanged server and database sent events")
    }

    func testEachChangeSendsOnlyItsKeyWithinTwoSeconds() async throws {
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        try server.run(["new-session", "-d", "-s", "other"])
        let work = "session " + (try sessionID("work"))
        let other = try sessionID("other")
        // Another process: a store with its own connection.
        let external = TopicStore(paths: paths)
        try external.write { try $0.create(TopicRecord(id: "first", title: "First")) }
        let recorder = start()
        try await settle(recorder, controlClients: 1)

        let pane = try server.run(["split-window", "-d", "-t", "work:", "-P", "-F", "#{pane_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await expectOnly(work, from: recorder, "a split")

        try server.run(["kill-pane", "-t", pane])
        try await expectOnly(work, from: recorder, "killing a non-active Pane")

        try server.run(["set-option", "-p", "-t", "work:", Tmux.agentStatusOption, "working"])
        try await expectOnly(work, from: recorder, "set -p @muxify_agent_status")

        try server.run(["set-option", "-t", other, "@muxify_topic", "first"])
        try await expectOnly("session " + other, from: recorder, "set @muxify_topic on another Session")

        try external.write { try $0.update("first") { $0.title = "Second" } }
        try await expectOnly("topic first", from: recorder, "a Topic record written by another process")

        try await publishers[0].write { try $0.update("first") { $0.title = "Third" } }
        XCTAssertEqual(recorder.keys, ["topic first"], "the publisher's own write did not send its event before it returned")
        guard case .topic(_, let record)? = recorder.items.last?.last else { return XCTFail("no topic event") }
        XCTAssertEqual(record?.title, "Third")
        try await expectOnly("topic first", from: recorder, "a write by the publisher's own process")
    }

    func testTwoPublishersKeepTheWatchSessionRule() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        let first = start(), second = start()
        try await wait("both publishers did not join the Watch Session") {
            try self.controlClients() == [Tmux.watchSessionName, Tmux.watchSessionName]
        }

        try server.run(["kill-session", "-t", "=work"])
        try await wait("the Watch Session outlived the last user Session") { !(try self.sessions().contains(Tmux.watchSessionName)) }
        for recorder in [first, second] {
            try await wait("a publisher did not say the server stopped") { recorder.server?.isRunning == false }
        }

        try server.run(["new-session", "-d", "-s", "again"])
        try await wait("a new user Session did not bring both publishers back", seconds: 5) {
            try self.controlClients() == [Tmux.watchSessionName, Tmux.watchSessionName]
        }
    }

    func testASwitchThatReturnsFindsTheColourReportOnEveryPaneOfItsSession() async throws {
        let probes = try probe(session: "work")
        try server.run(["split-window", "-d", "-t", "work:", probeCommand(probes.1)])
        let recorder = start()
        try await settle(recorder, controlClients: 1)
        publishers[0].reportColours(Self.light)

        publishers[0].reportColours(beforeRunning: ["select-window", "-t", "work:", ";", "switch-client", "-c", "/dev/none", "-t", "work:"])
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        for answer in [probes.0, probes.1] {
            try await wait("no answer from a probe", seconds: 5) { FileManager.default.fileExists(atPath: answer) }
            XCTAssertEqual(try String(contentsOfFile: answer, encoding: .utf8), "rgb:fbfb/f1f1/c7c7")
        }
    }

    func testAPaneOfANewSessionThatNoClientShowsAnswersOnlyAfterTheReportBeforeTyping() async throws {
        let recorder = start()
        try server.run(["new-session", "-d", "-s", "other"])
        try await settle(recorder, controlClients: 1)
        publishers[0].reportColours(Self.light)
        let probes = try probe(session: "made")
        let pane = try server.run(["display-message", "-p", "-t", "made:", "#{pane_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)

        publishers[0].reportColours(beforeTypingInto: pane)
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        try await wait("no answer from the probe", seconds: 5) { FileManager.default.fileExists(atPath: probes.0) }
        XCTAssertEqual(try String(contentsOfFile: probes.0, encoding: .utf8), "rgb:fbfb/f1f1/c7c7")
    }

    func testWithoutColoursASwitchReportsNothing() async throws {
        let probes = try probe(session: "work")
        let recorder = start()
        try await settle(recorder, controlClients: 1)

        publishers[0].reportColours(beforeRunning: ["switch-client", "-c", "/dev/none", "-t", "work:"])
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        try await wait("no answer from the probe", seconds: 5) { FileManager.default.fileExists(atPath: probes.0) }
        XCTAssertEqual(try String(contentsOfFile: probes.0, encoding: .utf8), "none")
    }

    // MARK: - Helpers

    private static let light = TerminalColours(background: TerminalColour(red: 0xfb, green: 0xf1, blue: 0xc7),
                                               foreground: TerminalColour(red: 0x3c, green: 0x38, blue: 0x36))

    /// A Session whose Pane runs a program that waits for the file `go`, then asks for the background (OSC 11) as
    /// Claude Code does, and writes the answer's colour, or `none` after a second without one, to the returned file.
    /// A second answer file is for one more probe Pane.
    private func probe(session: String) throws -> (String, String) {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "no python3 for the probe")
        let script = directory.appendingPathComponent("probe.py").path
        try """
            import os, re, select, sys, termios, tty, time
            answer, go = sys.argv[1], sys.argv[2]
            tty.setraw(0)
            while not os.path.exists(go): time.sleep(0.02)
            os.write(1, b'\\x1b]11;?\\x1b\\\\')
            reply, end = b'', time.time() + 1
            while time.time() < end and not reply.endswith(b'\\x1b\\\\'):
                if select.select([0], [], [], 0.05)[0]: reply += os.read(0, 256)
            found = re.search(rb'rgb:[0-9a-f/]+', reply)
            open(answer + '.part', 'w').write(found.group().decode() if found else 'none')
            os.rename(answer + '.part', answer)
            time.sleep(30)
            """.write(toFile: script, atomically: true, encoding: .utf8)
        let first = directory.appendingPathComponent(session + "-1").path
        let second = directory.appendingPathComponent(session + "-2").path
        try server.run(["new-session", "-d", "-s", session, "-x", "80", "-y", "24", probeCommand(first)])
        return (first, second)
    }

    private func probeCommand(_ answer: String) -> String {
        "/usr/bin/python3 \(directory.appendingPathComponent("probe.py").path) \(answer) \(directory.appendingPathComponent("go").path)"
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [[EnvironmentChange]] = []
        private var state = EnvironmentState()

        func add(_ changes: [EnvironmentChange]) {
            lock.lock()
            log.append(changes)
            state.apply(changes)
            lock.unlock()
        }

        var items: [[EnvironmentChange]] { lock.lock(); defer { lock.unlock() }; return log }
        var keys: Set<String> { Set(items.joined().map(\.key)) }
        var server: EnvironmentServer? { lock.lock(); defer { lock.unlock() }; return state.server }
        func clear() { lock.lock(); log = []; lock.unlock() }
    }

    private func start() -> Recorder {
        let recorder = Recorder()
        let publisher = EnvironmentPublisher(server: server, topics: TopicStore(paths: paths),
                                             delivery: DispatchQueue(label: "test.environment-events"))
        publishers.append(publisher)
        publisher.start(recorder.add)
        return recorder
    }

    /// Waits for the control Clients, then for a quiet moment, and forgets what came before.
    private func settle(_ recorder: Recorder, controlClients count: Int) async throws {
        try await wait("the publisher did not join the Watch Session") {
            try self.controlClients() == Array(repeating: Tmux.watchSessionName, count: count)
        }
        var seen = -1
        try await wait("the publisher did not settle", seconds: 10) {
            let now = recorder.items.count
            defer { seen = now }
            if now == seen { return true }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            return false
        }
        recorder.clear()
    }

    /// Waits up to 2 s for the first event, then a little longer for any other, and checks that only `key` came.
    private func expectOnly(_ key: String, from recorder: Recorder, _ change: String) async throws {
        let start = Date()
        try await wait("no event within 2 s of \(change)", seconds: 2) { !recorder.items.isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.05, change)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(recorder.keys, [key], change)
        recorder.clear()
    }

    private func sessionID(_ name: String) throws -> String {
        try server.run(["display-message", "-p", "-t", "=" + name + ":", "#{session_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Sessions of the control Clients; none when no server runs.
    private func controlClients() throws -> [String] {
        ((try? server.run(["list-clients", "-f", "#{client_control_mode}", "-F", "#{session_name}"])) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func sessions() throws -> [String] {
        ((try? server.run(["list-sessions", "-F", "#{session_name}"])) ?? "").split(separator: "\n").map(String.init)
    }

    private func wait(_ message: String, seconds: TimeInterval = 3, until done: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try await !done() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
