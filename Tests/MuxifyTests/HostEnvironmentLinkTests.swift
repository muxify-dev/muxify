import AppKit
import Darwin
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// `HostEnvironmentLink` through pipes to a Host Server in this process, on a throwaway tmux server and a temporary
/// state database (ADR 0087: the Mac's half of the protocol, tested without SSH).
@MainActor
final class HostEnvironmentLinkTests: XCTestCase {
    private var directory: URL!
    private var tmux: TmuxServer!
    private var paths: MuxifyPaths!
    private var servers: [ProtocolServer] = []
    /// Each server's own output, which a test closes to drop that channel.
    private var serverOutputs: [FileHandle] = []
    private var saved: [String: String?] = [:]
    private var socket: String { directory.appendingPathComponent("s").path }

    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    override func setUpWithError() throws {
        _ = try requireTmux()
        _ = NSApplication.shared
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxl-" + UUID().uuidString.prefix(8), isDirectory: true)
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
        serverOutputs.forEach { try? $0.close() }
        for server in servers { server.stop(.shutdown) }
        if let actual = try? tmux?.run(["display-message", "-p", "#{socket_path}"]),
           actual.trimmingCharacters(in: .whitespacesAndNewlines) == socket {
            _ = try? tmux.run(["kill-server"])
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// A link whose every channel is a pair of pipes to a new Host Server here, made with the context `context`
    /// gives for its number, from 0.
    private func link(build: String = "muxify 0000000 0",
                      context: @escaping (Int) -> HostServerContext) -> HostEnvironmentLink {
        HostEnvironmentLink(
            environmentName: "box", inner: FakeEnvironmentLink(isOnThisMac: false, features: [.git]), build: build,
            nonce: { nil }, helloTimeout: 5,
            openChannel: { [unowned self] _ in
                let up = Pipe(), down = Pipe()
                let server = HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting,
                                             build: "muxify 1111111 1", context: context(servers.count))
                server.start()
                servers.append(server)
                serverOutputs.append(down.fileHandleForWriting)
                let writer = up.fileHandleForWriting
                return HostServerChannel(input: down.fileHandleForReading, output: writer, stop: { try? writer.close() })
            },
            install: { $0(HostCLIReady(line: "current")) }, masterAlive: { true }, hostCLIVersion: { _ in nil })
    }

    private func wait(_ message: String, seconds: TimeInterval = 10, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func configStore() -> ConfigStore {
        ConfigStore(path: directory.appendingPathComponent("config.yaml").path)
    }

    // MARK: - Checks

    func testFeaturesComeFromTheServersHelloAndItsFirstState() async throws {
        let paths = paths!, tmux = tmux!
        let link = link { _ in HostServerContext(paths: paths, tmux: tmux, config: { Config() }) }
        try link.connect()
        XCTAssertEqual(link.features, [.git], "before the server answers, the link is its Sessions-only link")
        XCTAssertFalse(link.publishesChanges)
        var heard: [String] = []
        let subscription = link.subscribe { event in
            switch event {
            case .featuresChanged: heard.append("features")
            case .topics: heard.append("topics")
            default: break
            }
        }
        defer { subscription.cancel() }

        link.startServer()
        try await wait("the server's hello and first state did not give the link its features") { link.features.contains(.topics) }
        XCTAssertEqual(link.features, [.topics, .git])
        XCTAssertTrue(link.publishesChanges, "the server's events replace the poll")
        XCTAssertEqual(Array(heard.prefix(2)), ["features", "topics"])
    }

    func testAnAppsInfoPlistCarriesTheBuildLineAndTheMacsHelloSendsIt() async throws {
        let app = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Muxify.app")
        let bundle = try XCTUnwrap(Bundle(url: app), "no Muxify.app beside the tests at \(app.path)")
        let line = AppBuild.line(in: bundle)
        XCTAssertNotNil(line.range(of: #"^muxify [0-9a-f]{7,} [0-9]+$"#, options: .regularExpression),
                        "the build phase stamps `muxify <short-sha> <commit-unix-time>`, not \(line)")

        let paths = paths!, tmux = tmux!
        let link = link(build: line) { _ in HostServerContext(paths: paths, tmux: tmux, config: { Config() }) }
        try link.connect()
        link.startServer()
        try await wait("the server did not answer") { link.features.contains(.topics) }
        XCTAssertEqual(servers.first?.client?.build, line)
    }

    func testAClosedChannelFailsAWaitingMutationWhichTheStoreReportsAndNeverSendsAgain() async throws {
        let paths = paths!, tmux = tmux!
        // The first server never gets its Config for a request once the test says so, so the request waits on it.
        let gate = Gate()
        let link = link { number in
            HostServerContext(paths: paths, tmux: tmux, config: {
                if number == 0, gate.isClosed { try await Task.sleep(nanoseconds: 30_000_000_000) }
                if number == 1 { gate.countSecond() }
                return Config()
            })
        }
        let store = WorkspaceStore(configStore: configStore(), environment: RemoteEnvironment(name: "box", host: "box", username: "user"),
                                   defaults: isolatedDefaults()) { _ in link }
        var alerts: [String] = []
        store.showAlert = { _, text in alerts.append(text) }
        store.startLinkForTesting()
        link.startServer()
        try await wait("the server did not answer") { store.link.features.contains(.topics) }

        gate.close()
        XCTAssertTrue(store.perform(EnvironmentRequest(.create(title: "Lost"))))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(alerts, [], "the request waits on the server")
        try serverOutputs[0].close()

        try await wait("the store did not report the request that the drop left uncertain") { !alerts.isEmpty }
        XCTAssertEqual(alerts, ["box disconnected before New Topic finished. It may or may not have happened."])

        // The link says the server stopped while the master lives; the store starts it again on a new channel.
        try await wait("the server did not start again", seconds: 15) { servers.count == 2 && store.link.features.contains(.topics) }
        let requests = gate.second
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(gate.second, requests, "the new server got a request: nothing is sent again after a reconnect")
        XCTAssertFalse(try TopicStore(paths: paths).read().records.contains { $0.title == "Lost" })
        XCTAssertEqual(alerts.count, 1)
    }
}

/// What a test's Host Server contexts share across threads.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var secondCalls = 0

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var second: Int {
        lock.lock()
        defer { lock.unlock() }
        return secondCalls
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func countSecond() {
        lock.lock()
        secondCalls += 1
        lock.unlock()
    }
}
