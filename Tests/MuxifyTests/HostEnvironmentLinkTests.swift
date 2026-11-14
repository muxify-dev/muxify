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
    /// `serve`, when given, answers the requests in place of a Host Server. `macPaths` holds the Mac's state.
    private func link(build: String = "muxify 0000000 0", inner: EnvironmentLink? = nil, macPaths: MuxifyPaths? = nil,
                      serve: ((ProtocolIncomingRequest, ProtocolServer) -> Void)? = nil,
                      context: @escaping (Int) -> HostServerContext) -> HostEnvironmentLink {
        HostEnvironmentLink(
            environmentName: "box", inner: inner ?? FakeEnvironmentLink(isOnThisMac: false, features: []), build: build,
            nonce: { nil }, helloTimeout: 5,
            openChannel: { [unowned self] _ in
                let up = Pipe(), down = Pipe()
                let server = serve.map {
                    ProtocolServer(input: up.fileHandleForReading, output: down.fileHandleForWriting, build: "muxify 1111111 1", handler: $0)
                } ?? HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting,
                                     build: "muxify 1111111 1", context: context(servers.count))
                server.start()
                servers.append(server)
                serverOutputs.append(down.fileHandleForWriting)
                let writer = up.fileHandleForWriting
                return HostServerChannel(input: down.fileHandleForReading, output: writer, stop: { try? writer.close() })
            },
            install: { $0(HostCLIReady(line: "current")) }, masterAlive: { true }, hostCLIVersion: { _ in nil },
            macWorktrees: MuxifyWorktreeStore(paths: macPaths ?? MuxifyPaths(environment: [
                "XDG_STATE_HOME": directory.appendingPathComponent("mac-state").path,
            ], home: "/nonexistent")))
    }

    /// The Mac's state, with an older Muxify's record files for `rows`, keyed by Environment, imported as rows that wait
    /// to move, and one record of the Mac's own.
    private func macState(waiting rows: [(String, MuxifyWorktreeRecord)]) throws -> MuxifyPaths {
        let mac = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("mac-state").path], home: "/nonexistent")
        try FileManager.default.createDirectory(at: mac.worktrees, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        for (environment, row) in rows {
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoder.encode(row)) as? [String: Any])
            object["environment"] = environment
            try JSONSerialization.data(withJSONObject: object).write(to: mac.worktrees.appendingPathComponent(row.id + ".json"))
        }
        try MuxifyWorktreeStore(paths: mac).write(own)
        return mac
    }

    private let own = MuxifyWorktreeRecord(id: "mac", repository: "/Users/me/app", name: "mine", path: "/Users/me/trees/mine", branch: "mine",
                                           base: "m", createdAt: Date(timeIntervalSince1970: 1_700_000_000))

    private func row(_ id: String, path: String) -> MuxifyWorktreeRecord {
        MuxifyWorktreeRecord(id: id, repository: "/home/me/app", name: id, path: path, branch: id, base: "b",
                             createdAt: Date(timeIntervalSince1970: 1_700_000_000))
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
        XCTAssertEqual(link.features, [], "before the server answers, the link is its Sessions-only link")
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
        XCTAssertEqual(link.features, [.topics, .git, .worktrees], "the Host's server keeps its Muxify Worktrees")
        XCTAssertTrue(link.publishesChanges, "the server's events replace the poll")
        XCTAssertEqual(Array(heard.prefix(2)), ["features", "topics"])
    }

    func testTheHostsConfigComesFromTheServerAndAnEditOnTheHostPushesItWithoutAReload() async throws {
        let tmux = tmux!
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let folder = home.appendingPathComponent(".config/muxify", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("config.yaml")
        try "ui:\n  header_height: 30\n".write(to: file, atomically: true, encoding: .utf8)
        let hostPaths = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("state").path], home: home.path)
        let inner = FakeEnvironmentLink(isOnThisMac: false, features: [])
        let link = link(inner: inner) { _ in HostServerContext(paths: hostPaths, tmux: tmux, config: { Config() }, home: home.path) }
        try link.connect()
        var configs: [HostConfig] = []
        let subscription = link.subscribe { event in
            if case .config(.host(let config)) = event { configs.append(config) }
        }
        defer { subscription.cancel() }
        link.reloadConfig()
        XCTAssertEqual(inner.configReloads, 1, "before the server serves the Config, the Sessions-only link reads it")

        link.startServer()
        try await wait("the server sent no Config") { !configs.isEmpty }
        XCTAssertEqual(configs.last?.text, "ui:\n  header_height: 30\n")
        XCTAssertEqual(configs.last?.shownPath, "~/.config/muxify/config.yaml")
        inner.send(.config(.host(HostConfig(path: file.path, home: home.path, text: "stale"))))
        XCTAssertNotEqual(configs.last?.text, "stale", "a Sessions-only read does not replace the served Config")

        try "ui:\n  header_height: 40\n".write(to: file, atomically: true, encoding: .utf8)
        try await wait("an edit on the Host pushed no Config") { configs.last?.text == "ui:\n  header_height: 40\n" }
        let count = configs.count
        link.reloadConfig()
        XCTAssertEqual(inner.configReloads, 1, "a served Config needs no read")
        XCTAssertEqual(configs.count, count + 1, "Reload Config sends the served Config again")
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

    func testTheServersRequestsReachTheHandlerAndTheConsumersServerNamesItsSocket() async throws {
        let paths = paths!, tmux = tmux!
        let id = String(Int.random(in: 10_000...99_999))
        let link = link { _ in HostServerContext(paths: paths, tmux: tmux, config: { Config() }, socketID: id) }
        let path = socket + ".muxify-browser." + id
        func option() -> String {
            ((try? tmux.run(["show-options", "-sqv", BrowserAgentChannel.option])) ?? "").trimmingCharacters(in: .newlines)
        }
        func send(_ request: some Encodable & Sendable) async throws -> BrowserAgentReply {
            try await Task.detached { try BrowserAgentChannel.send(request, replyTimeout: 20, to: path) }.value
        }
        try link.connect()
        link.setOpenConsumer(true)
        link.startServer()
        try await wait("the server did not answer") { link.features.contains(.topics) }
        try await wait("the consumer's server did not name its socket") { option() == path }

        let tabs = try await send(BrowserAgentRequest(window: "@1", command: .tabs))
        guard case .failure(let message, _) = tabs else { return XCTFail("a request with no handler answered \(tabs)") }
        XCTAssertTrue(message.hasPrefix("cannot reach Muxify"), message)

        let picture = Data([0x89, 0x50, 0x4E, 0x47]) + Data((0..<(100 * 1024)).map { UInt8($0 % 241) })
        var selected: [SelectRequest] = []
        link.serveHostRequests { request in
            switch request {
            case .browser(let browser): return browser.command == .screenshot ? .png(picture) : .tabs([])
            case .select(let select):
                selected.append(select)
                return .done
            case .ask: return nil
            }
        }
        let reply = try await send(BrowserAgentRequest(window: "@1", command: .tabs))
        XCTAssertEqual(reply, .tabs([]))
        let screenshot = try await send(BrowserAgentRequest(window: "@1", command: .screenshot))
        XCTAssertEqual(screenshot, .png(picture), "a picture over one chunk comes back whole")
        let select = try await send(MacRequest.select(.window("@3")))
        XCTAssertEqual(select, .done)
        XCTAssertEqual(selected, [.window("@3")])

        link.setOpenConsumer(false)
        try await wait("a window that stopped consuming @muxify_open left its socket") { option().isEmpty }
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

    func testAGitWriteWhoseChannelEndsBeforeItsAnswerMayOrMayNotHaveHappened() async throws {
        let paths = paths!, tmux = tmux!
        let stalled = StalledScripts()
        defer { stalled.release() }
        let link = link { _ in HostServerContext(paths: paths, tmux: tmux, config: { Config() }, gitWriter: GitWriter(scripts: stalled)) }
        try link.connect()
        link.startServer()
        try await wait("the server did not answer") { link.features.contains(.git) }

        let write = Task { try await link.writeGit(.commit(root: directory.path, message: "Lost")) }
        try await wait("the server did not start the commit") { stalled.started }
        try serverOutputs[0].close()
        do {
            _ = try await write.value
            XCTFail("a commit whose channel ended answered")
        } catch {
            XCTAssertEqual(GitView.message(for: error), "box disconnected before Commit finished. It may or may not have happened.")
        }
        XCTAssertEqual(stalled.runs, 1, "the commit was sent again")
    }
}

/// Scripts that wait until the test releases them, so a write is still running when its channel ends.
private final class StalledScripts: ScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var count = 0

    var started: Bool { runs > 0 }

    var runs: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func runScript(_ script: String, arguments: [String], timeout: TimeInterval) throws -> String {
        lock.lock()
        count += 1
        lock.unlock()
        _ = gate.wait(timeout: .now() + 10)
        throw TmuxError.timedOut
    }

    func release() { gate.signal() }
}

extension HostEnvironmentLinkTests {
    // MARK: - The Mac's waiting Worktree rows move to the Host (ADR 0088)

    func testAfterHelloTheMacDeletesOnlyTheRowsTheHostTook() async throws {
        let paths = paths!, tmux = tmux!
        let host = MuxifyWorktreeStore(paths: paths)
        try host.write(row("clash", path: "/home/me/trees/clash"))
        let mac = try macState(waiting: [("box", row("new", path: "/home/me/trees/new")),
                                         ("box", row("clash", path: "/home/me/trees/other")),
                                         ("box", row("twin", path: "/home/me/trees/clash")),
                                         ("gone", row("stays", path: "/home/me/trees/stays"))])
        let store = MuxifyWorktreeStore(paths: mac)
        XCTAssertEqual(try store.waiting(for: "box").count, 3)
        let link = link(macPaths: mac) { _ in HostServerContext(paths: paths, tmux: tmux, config: { Config() }) }
        try link.connect()
        link.startServer()

        try await wait("the Mac did not delete the row the Host took") { (try? store.waiting(for: "box").map(\.id).sorted()) == ["clash", "twin"] }
        XCTAssertEqual(host.record("new")?.path, "/home/me/trees/new", "the taken row is the Host's record")
        XCTAssertEqual(host.record("clash")?.path, "/home/me/trees/clash", "a skipped row changes nothing on the Host")
        XCTAssertEqual(try store.waiting(for: "gone").map(\.id), ["stays"], "a row of an Environment not connected stays")
        XCTAssertEqual(try store.all(), [own], "the Mac's own records stay")
    }

    func testAChannelThatEndsBeforeTheAnswerLeavesEveryWaitingRow() async throws {
        let paths = paths!, tmux = tmux!
        let mac = try macState(waiting: [("box", row("one", path: "/home/me/trees/one")), ("box", row("two", path: "/home/me/trees/two"))])
        let sent = Gate()
        // The server ends the channel when the rows arrive, before it answers.
        let link = link(macPaths: mac, serve: { request, server in
            if case .adoptWorktrees(let adopt)? = try? request.body(HostRequest.self) {
                XCTAssertEqual(adopt.rows.map(\.id), ["one", "two"])
                sent.close()
                server.stop(.shutdown)
            }
        }, context: { _ in HostServerContext(paths: paths, tmux: tmux, config: { Config() }) })
        try link.connect()
        link.startServer()

        try await wait("the Mac did not send its waiting rows after hello") { sent.isClosed }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try MuxifyWorktreeStore(paths: mac).waiting(for: "box").map(\.id), ["one", "two"], "no row was deleted")
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

extension HostEnvironmentLinkTests {
    // MARK: - git's questions come back as `ask` (ADR 0087, Credentials)

    /// A bare `origin.git` and a clone `repo` that reaches it over a fake ssh, which asks for a passphrase through
    /// `SSH_ASKPASS` and serves the repository only for the answer `right`.
    private func sshRemote() throws -> String {
        let folder = directory.appendingPathComponent("net")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ssh = folder.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        [ "$SSH_ASKPASS_REQUIRE" = force ] || { echo "ssh would ask on a terminal" >&2; exit 255; }
        answer=$("$SSH_ASKPASS" "Enter passphrase for key '/fake/id': ") || exit 255
        [ "$answer" = right ] || { echo "Permission denied (publickey)." >&2; exit 255; }
        for last; do :; done
        exec /bin/sh -c "$last"
        """.write(to: ssh, atomically: true, encoding: .utf8)
        chmod(ssh.path, 0o755)
        _ = try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", """
        cd "$1" && export GIT_CONFIG_NOSYSTEM=1 HOME="$1" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git init -q --bare -b master origin.git
        git init -q -b master repo && cd repo && git commit -q --allow-empty -m first && git push -q ../origin.git master
        git remote add origin "ssh://fake.invalid$1/origin.git" && git config core.sshCommand "$1/ssh"
        """, "muxify", folder.path]), timeout: 30)
        return folder.appendingPathComponent("repo").path
    }

    func testANetworkCommandsQuestionOnTheHostReachesItsAskAndItsAnswerReachesGit() async throws {
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("muxify-app-cli").path
        guard FileManager.default.isExecutableFile(atPath: cli) else { throw XCTSkip("no muxify-app-cli beside the tests") }
        let paths = paths!, tmux = tmux!
        let repo = try sshRemote()
        let environment = ["HOME": directory.appendingPathComponent("net").path, "GIT_CONFIG_NOSYSTEM": "1",
                           "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        let link = link { number in
            HostServerContext(paths: paths, tmux: tmux, config: { Config() }, socketID: "9\(number)",
                              gitNetwork: GitNetworkRunner(helper: cli, scratch: paths.state, environment: environment))
        }
        try link.connect()
        link.startServer()
        try await wait("the server did not answer") { link.features.contains(.git) }

        let asked = AskLog()
        _ = try await link.runGitNetwork(.fetch(root: repo)) { request in
            asked.add(request)
            return "right"
        }
        XCTAssertEqual(asked.all.map(\.prompt), ["Enter passphrase for key '/fake/id': "])
        XCTAssertEqual(asked.all.map(\.secret), [true])

        do {
            _ = try await link.runGitNetwork(.fetch(root: repo)) { _ in nil }
            XCTFail("a cancelled question fetched")
        } catch {
            XCTAssertEqual(GitView.message(for: error, cancelled: "Fetch cancelled."), "Fetch cancelled.")
        }
    }

    func testAnAskThatNoNetworkCommandWaitsForEndsUnavailable() async throws {
        let paths = paths!, tmux = tmux!
        let code = AskLog()
        let link = link(serve: { request, server in
            guard code.codes.isEmpty, !code.sent else { return }
            code.sent = true
            Task {
                do {
                    _ = try await server.call(MacRequest.ask(AskRequest(prompt: "Password: ", secret: true, operation: "nobody")), as: AskAnswer.self)
                    code.addCode(nil)
                } catch let error as ProtocolError {
                    code.addCode(error.code)
                }
            }
            _ = request
        }, context: { _ in HostServerContext(paths: paths, tmux: tmux, config: { Config() }) })
        try link.connect()
        link.startServer()
        try await wait("the Mac did not answer the ask") { !code.codes.isEmpty }
        XCTAssertEqual(code.codes, [.unavailable])
    }
}

/// What a test's askpass questions and answers were, across threads.
private final class AskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AskRequest] = []
    private var errorCodes: [ProtocolErrorCode?] = []
    private var didSend = false

    func add(_ request: AskRequest) { lock.lock(); requests.append(request); lock.unlock() }
    var all: [AskRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func addCode(_ code: ProtocolErrorCode?) { lock.lock(); errorCodes.append(code); lock.unlock() }
    var codes: [ProtocolErrorCode?] { lock.lock(); defer { lock.unlock() }; return errorCodes }
    var sent: Bool {
        get { lock.lock(); defer { lock.unlock() }; return didSend }
        set { lock.lock(); didSend = newValue; lock.unlock() }
    }
}
