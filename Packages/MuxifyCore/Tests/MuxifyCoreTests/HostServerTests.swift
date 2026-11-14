#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// The Host Server's Environment through a pair of pipes in this process: a protocol client and `HostServer` against
/// a throwaway tmux server and a temporary state database.
final class HostServerTests: XCTestCase {
    private var directory: URL!
    private var tmux: TmuxServer!
    private var paths: MuxifyPaths!
    private var servers: [ProtocolServer] = []
    private var clients: [ProtocolClient] = []
    private var consumers: [Task<Void, Never>] = []
    private var clientProcess: Process?
    private var saved: [String: String?] = [:]
    private var socket: String { directory.appendingPathComponent("s").path }

    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    override func setUpWithError() throws {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxh-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tmux = TmuxServer(socketPath: socket, configPath: "/dev/null")
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("state").path], home: "/nonexistent")
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
        try tmux.run(["new-session", "-d", "-s", "work", "-x", "120", "-y", "40", "-c", directory.path])
    }

    override func tearDown() async throws {
        consumers.forEach { $0.cancel() }
        clients.forEach { $0.close() }
        for server in servers { _ = await server.wait() }
        if let clientProcess, clientProcess.isRunning { clientProcess.terminate(); clientProcess.waitUntilExit() }
        if let actual = try? tmux?.run(["display-message", "-p", "#{socket_path}"]),
           actual.trimmingCharacters(in: .whitespacesAndNewlines) == socket {
            _ = try? tmux.run(["kill-server"])
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - The environment subscription

    func testTheFirstItemHoldsEveryKeyAndATmuxChangeAndAnotherProcesssTopicPushTheirKeys() async throws {
        try tmux.run(["new-session", "-d", "-s", "other"])
        let external = TopicStore(paths: paths)
        try external.write { try $0.create(TopicRecord(id: "first", title: "First")) }
        let client = try await connect()
        let recorder = subscribe(client)

        try await wait("no first item") { !recorder.items.isEmpty }
        let first = try XCTUnwrap(recorder.items.first)
        let work = "session " + (try sessionID("work"))
        XCTAssertEqual(Set(first.map(\.key)), [work, "session \(try sessionID("other"))", "topic first", "open_places", "server"])
        guard case .server(let server)? = first.first(where: { $0.key == "server" }) else { return XCTFail("no server event") }
        XCTAssertTrue(server.isRunning)
        XCTAssertEqual(server.socketPath, socket)
        XCTAssertNotNil(server.serverID, "the Mac stamps sourceID from it")
        XCTAssertEqual(server.hostName, Tmux.hostName)
        XCTAssertNil(server.ownClient)
        try await settle(recorder)

        try tmux.run(["split-window", "-d", "-t", "work:"])
        try await wait("a split did not push its Session", seconds: 3) { recorder.keys.contains(work) }
        XCTAssertFalse(recorder.keys.contains("topic first"), "a tmux change pushed a Topic")
        try await settle(recorder)

        try external.write { try $0.update("first") { $0.title = "Second" } }
        try await wait("a Topic written by another process did not push its key", seconds: 3) { recorder.keys.contains("topic first") }
        guard case .topic(_, let record)? = recorder.items.joined().last(where: { $0.key == "topic first" }) else { return XCTFail("no topic") }
        XCTAssertEqual(record?.title, "Second")
    }

    func testAnEnvironmentRequestAnswersItsResponseAfterTheSubscriptionPushedItsTopic() async throws {
        let client = try await connect()
        let recorder = subscribe(client)
        try await wait("no first item") { !recorder.items.isEmpty }
        try await settle(recorder)

        let response = try await client.call(HostRequest.environment(EnvironmentRequest(.create(title: "Made"))), as: EnvironmentResponse.self)
        guard case .changed(let change) = response, let id = change.topicID else { return XCTFail("unexpected \(response)") }
        // The server reads before it answers, so the event came before the `end`: it is there at once, well inside
        // the 0.25 s tick of `data_version`.
        try await wait("the created Topic's event did not come before the answer", seconds: 0.15) { recorder.keys.contains("topic \(id)") }
        XCTAssertEqual(try TopicStore(paths: paths).read().records.map(\.title), ["Made"])

        do {
            _ = try await client.call(HostRequest.environment(EnvironmentRequest(.rename(title: "x"), target: .topic(.id("missing")))),
                                      as: EnvironmentResponse.self)
            XCTFail("a failed request must not end ok")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .failed)
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testMarkReadClearsTheUnreadMarksAndWritesTheRememberedSessions() async throws {
        var record = TopicRecord(id: "t", title: "Topic")
        record.isUnread = true
        try TopicStore(paths: paths).write { try $0.create(record) }
        try tmux.run(["set-option", "-t", "=work:", "@muxify_topic", "t"])
        let pane = try tmuxOutput(["display-message", "-p", "-t", "=work:", "#{pane_id}"])
        try tmux.run(["set-option", "-p", "-t", pane, Tmux.agentUnreadOption, "1"])
        let client = try await connect()

        try await client.call(HostRequest.markRead(MarkRead(topics: ["t"], panes: [pane])))

        let after = try XCTUnwrap(try TopicStore(paths: paths).read().records.first { $0.id == "t" })
        XCTAssertFalse(after.isUnread)
        XCTAssertEqual(after.sessions.compactMap { $0["name"]?.string }, ["work"])
        XCTAssertEqual(try tmuxOutput(["show-options", "-pqv", "-t", pane, Tmux.agentUnreadOption]), "")
    }

    func testOwnClientIsNullUntilTheMarkerNamesAnAttachedClient() async throws {
        let nonce = "n" + UUID().uuidString.prefix(8).lowercased()
        let client = try await connect(nonce: nonce)
        let recorder = subscribe(client)
        try await wait("no first item") { recorder.server != nil }
        XCTAssertNil(recorder.server?.ownClient)

        let attached = try attachClient(to: "work")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(recorder.server?.ownClient, "a Client with no marker is not the own Client")

        let value = [String(attached.pid), attached.tty, "/home/u", "box", "remote"].joined(separator: Tmux.separator)
        try tmux.run(["set-option", "-sq", ClientMarker.option(nonce: nonce), value])
        try await wait("the marker's Client was not pushed", seconds: 3) { recorder.server?.ownClient == attached }
    }

    // MARK: - View commands

    func testAViewCommandRunsOnTheServersTmux() async throws {
        let client = try await connect()
        let pane = try tmuxOutput(["display-message", "-p", "-t", "=work:", "#{pane_id}"])
        _ = try await client.call(HostRequest.view(.splitPane(target: pane, side: .right)), as: ViewOutput.self)
        XCTAssertEqual(try tmuxOutput(["list-panes", "-t", "=work:", "-F", "#{pane_id}"]).split(separator: "\n").count, 2)

        let active = try await client.call(HostRequest.view(.activePane(window: "=work:")), as: ViewOutput.self)
        XCTAssertNotEqual(active.output.split(separator: " ").first.map(String.init), pane, "the new Pane is active")

        do {
            _ = try await client.call(HostRequest.view(.switchClient(client: "/dev/none", target: "=work:")), as: ViewOutput.self)
            XCTFail("a command as the own Client must not run before the marker names one")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .failed)
        }
    }

    // MARK: - Helpers

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

    private func connect(nonce: String? = nil) async throws -> ProtocolClient {
        let up = Pipe(), down = Pipe()
        let server = HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting, build: "server",
                                     context: HostServerContext(paths: paths, tmux: tmux))
        server.start()
        servers.append(server)
        let client = ProtocolClient(input: down.fileHandleForReading, output: up.fileHandleForWriting, build: "client",
                                    helloTimeout: 5, nonce: nonce)
        clients.append(client)
        try await client.connect()
        return client
    }

    private func subscribe(_ client: ProtocolClient) -> Recorder {
        let recorder = Recorder()
        let events = client.subscribe(HostRequest.subscribe(.environment), as: EnvironmentItem.self)
        consumers.append(Task {
            do {
                for try await item in events { recorder.add(item.changes) }
            } catch {}
        })
        return recorder
    }

    /// Waits until no item has come for a moment, and forgets what came before.
    private func settle(_ recorder: Recorder) async throws {
        var seen = -1
        try await wait("the subscription did not settle", seconds: 10) {
            let now = recorder.items.count
            defer { seen = now }
            if now == seen { return true }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            return false
        }
        recorder.clear()
    }

    private func sessionID(_ name: String) throws -> String {
        try tmuxOutput(["display-message", "-p", "-t", "=" + name + ":", "#{session_id}"])
    }

    private func tmuxOutput(_ arguments: [String]) throws -> String {
        try tmux.run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wait(_ message: String, seconds: TimeInterval = 3, until done: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try await !done() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A Client attached to `session` in a pseudo-terminal: its tty and pid.
    private func attachClient(to session: String) throws -> ViewCommandExecutor.Client {
        let binary = try XCTUnwrap(tmux.binary)
        let attach = [binary, "-u", "-S", socket, "-f", "/dev/null", "attach-session", "-t", session]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        #if os(Linux)
        process.arguments = ["-qfc", attach.map(Tmux.shellQuote).joined(separator: " "), "/dev/null"]
        #else
        process.arguments = ["-q", "/dev/null"] + attach
        #endif
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        clientProcess = process
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let fields = (try? tmuxOutput(["list-clients", "-f", "#{==:#{client_control_mode},0}", "-F", "#{client_tty} #{client_pid}"]))?
                .components(separatedBy: " ") ?? []
            if fields.count == 2, !fields[0].isEmpty, let pid = Int(fields[1]) { return ViewCommandExecutor.Client(tty: fields[0], pid: pid) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw TmuxError.timedOut
    }
}
