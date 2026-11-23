import XCTest
import Darwin
@testable import MuxifyCore
import MuxifyTestSupport

/// Opt-in tests of the Host Server over a real SSH master, gated like `LiveSSHTests`: the install chain (A, the Host
/// downloads; B, the Mac sends), `muxify server` on a `-T` channel of the master, `hello`, the `environment`
/// subscription, a dropped master and the server's silence rule. Each test's `HOME` and tmux server live in a fresh
/// remote temporary directory, not the user's. `make test-live-linux` runs them on throwaway OrbStack machines.
final class LiveHostServerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    /// Chain A: the Host downloads `cli-latest` from `MUXIFY_CLI_BASE_URL`, then its server answers `hello` and
    /// pushes a tmux change made on the machine.
    func testChainAInstallsAndTheServerPushesATmuxChange() async throws {
        let host = try LiveHost(self)
        let ready = host.runChain(baseURL: host.reachableBaseURL)
        XCTAssertEqual(ready, HostCLIReady(line: "installed \(host.published)"))
        XCTAssertNil(ready.server)

        let server = try await host.startServer()
        XCTAssertEqual(server.session.peerBuild, host.versionLine)
        try await host.wait("no first item", seconds: 15, server) { !server.recorder.items.isEmpty }
        let main = "session " + (try host.sessionID("main"))
        XCTAssertTrue(server.recorder.keys.isSuperset(of: [main, "open_places", "server"]), "\(server.recorder.keys)")
        XCTAssertTrue(host.isolated(server), "\(String(describing: server.recorder.state.server?.socketPath))")
        try await host.settle(server.recorder)

        _ = try host.raw(host.prefix + "tmux -f /dev/null new-session -d -s changed -c \"$HOME\"")
        let changed = "session " + (try host.sessionID("changed"))
        try await host.wait("a tmux change on the Host did not push its Session", seconds: 10, server) {
            server.recorder.keys.contains(changed)
        }
        XCTAssertEqual(server.recorder.state.sessions[String(changed.dropFirst("session ".count))]?.windows.first?.sessionName, "changed")
        server.close()
        print("Live Host Server passed chain A on \(host.label)")
    }

    /// Chain B: the Host cannot reach the base URL, which only the Mac's loopback serves, so the Mac fetches the
    /// asset and streams it over the master, and the server starts from the uploaded file.
    func testChainBSendsTheBinaryFromTheMacAndTheServerStartsFromIt() async throws {
        let host = try LiveHost(self)
        let ready = host.runChain(baseURL: host.macOnlyBaseURL)
        let target = host.home + "/.local/bin/muxify"
        XCTAssertEqual(ready, HostCLIReady(line: "uploaded \(host.published) to \(target)"))
        XCTAssertTrue(host.reports.contains { $0.hasPrefix("Host CLI: Live test: failed: cannot fetch \(host.macOnlyBaseURL)") },
                      "the Host itself downloaded: \(host.reports)")
        XCTAssertEqual(try host.raw(host.prefix + "\"$HOME/.local/bin/muxify\" --version"), host.versionLine + "\n")

        let server = try await host.startServer()
        XCTAssertEqual(server.session.peerBuild, host.versionLine)
        try await host.wait("no first item", seconds: 15, server) { server.recorder.state.server != nil }
        XCTAssertTrue(host.isolated(server), "\(String(describing: server.recorder.state.server?.socketPath))")
        XCTAssertEqual(try host.servers(), 1, "the server does not run from the uploaded file")
        server.close()
        print("Live Host Server passed chain B on \(host.label)")
    }

    /// A master that dies fails the waiting subscription with `unavailable`; a new master and a new server deliver
    /// the full state, Topics included.
    func testADroppedMasterFailsTheWaitingRequestAndANewServerDeliversTheFullState() async throws {
        let host = try LiveHost(self)
        XCTAssertEqual(host.runChain(baseURL: host.reachableBaseURL).line, "installed \(host.published)")
        _ = try host.raw(host.prefix + "tmux -f /dev/null new-session -d -s kept -c \"$HOME\"")
        let created = try host.raw(host.prefix + "cd \"$HOME\" && \"$HOME/.local/bin/muxify\" topic new 'Live server' --json")
        let topic = try XCTUnwrap(((try JSONSerialization.jsonObject(with: Data(created.utf8)) as? [String: Any])?["changed"]
            as? [String: Any])?["topic_id"] as? String, created)

        let first = try await host.startServer()
        try await host.wait("no first item", seconds: 15, first) { first.recorder.state.server != nil }
        let expected: Set<String> = ["session " + (try host.sessionID("main")), "session " + (try host.sessionID("kept")),
                                     "topic " + topic, "open_places", "server"]
        XCTAssertTrue(first.recorder.keys.isSuperset(of: expected), "\(first.recorder.keys)")

        host.killMaster()
        try await host.wait("the waiting subscription did not end when the master died", seconds: 10, first) {
            first.recorder.ended != nil
        }
        let failure = try XCTUnwrap(first.recorder.ended as? ProtocolError, "\(String(describing: first.recorder.ended))")
        XCTAssertEqual(failure.code, .unavailable)
        do {
            try await first.client.ping()
            XCTFail("a request on the dropped channel must fail")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .unavailable)
        }
        XCTAssertNotNil(first.channel.exitStatus(waiting: 5), "the channel's ssh outlived its master")
        first.close()

        try host.startMaster()
        let second = try await host.startServer()
        try await host.wait("the new server sent no first item", seconds: 15, second) { !second.recorder.items.isEmpty }
        let full = Set(try XCTUnwrap(second.recorder.items.first).map(\.key))
        XCTAssertTrue(full.isSuperset(of: expected), "the first item lacks \(expected.subtracting(full))")
        XCTAssertEqual(second.recorder.state.topics[topic]?.title, "Live server")
        try await second.client.ping()
        second.close()
        print("Live Host Server passed drop and reconnect on \(host.label)")
    }

    /// A server whose Mac stops sending exits after its silence timeout, here 3 s through `MUXIFY_SERVER_SILENCE`
    /// instead of the 45 s default.
    func testAServerWhoseMacFallsSilentExits() async throws {
        let silence: TimeInterval = 3
        let host = try LiveHost(self, environment: ["MUXIFY_SERVER_SILENCE": String(Int(silence))])
        XCTAssertEqual(host.runChain(baseURL: host.reachableBaseURL).line, "installed \(host.published)")

        // Only the handshake: no subscription, so the server sends nothing that the client would answer.
        let server = try await host.startServer(subscribing: false)
        let answered = Date()
        // absence: the server does not exit before its silence timeout.
        try await Task.sleep(nanoseconds: UInt64((silence - 1.5) * 1_000_000_000))
        XCTAssertNil(server.channel.exitStatus(waiting: 0), "the server exited before its silence timeout")
        try await host.wait("the server outlived its silence timeout", seconds: silence + 10, server) {
            server.channel.exitStatus(waiting: 0) != nil
        }
        let elapsed = Date().timeIntervalSince(answered)
        XCTAssertGreaterThanOrEqual(elapsed, silence - 1, "exited after \(elapsed) s")
        XCTAssertEqual(server.channel.exitStatus(waiting: 0), 0, "a silent Mac is a clean exit: \(server.errors.lines)")
        XCTAssertEqual(try host.servers(), 0, "the server still runs on the Host")
        server.close()
        print("Live Host Server passed silence (\(Int(silence)) s, exited after \(String(format: "%.1f", elapsed)) s) on \(host.label)")
    }
}

/// One `muxify server` on a channel of the master, with its client and what its `environment` subscription sent.
private struct LiveServer {
    let channel: HostServerChannel
    let client: ProtocolClient
    let session: ProtocolClient.Session
    let errors: HostServerErrors
    let recorder: Recorder
    let consumer: Task<Void, Never>?

    func close() {
        consumer?.cancel()
        client.close()
        channel.close()
    }
}

/// What a subscription sent, and the error it ended with.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[EnvironmentChange]] = []
    private var applied = EnvironmentState()
    private var failure: Error?

    func add(_ changes: [EnvironmentChange]) {
        lock.withLock {
            log.append(changes)
            applied.apply(changes)
        }
    }

    func end(_ error: Error) { lock.withLock { failure = error } }
    var items: [[EnvironmentChange]] { lock.withLock { log } }
    var keys: Set<String> { Set(items.joined().map(\.key)) }
    var state: EnvironmentState { lock.withLock { applied } }
    var ended: Error? { lock.withLock { failure } }
    func clear() { lock.withLock { log.removeAll() } }
}

/// One test's Host over SSH, as `LiveHostCLITests` sets it up: a fresh remote directory for `HOME` and
/// `TMUX_TMPDIR` with a `main` Session, `build/host-cli/` served from this Mac, an SSH shim that gives every remote
/// script that environment, and the connection's master. Its teardown stops only what it started.
private final class LiveHost: @unchecked Sendable {
    let label: String
    let home: String
    let prefix: String
    let versionLine: String
    let published: String
    let reachableBaseURL: String
    let macOnlyBaseURL: String
    private let host: String
    /// The test's remote directory: its `TMUX_TMPDIR`, with `HOME` inside.
    let root: String
    private let rawOptions: [String]
    private let runner = CommandRunner()
    private let directory: TestDirectory
    private let connection: TmuxConnection
    private let remote: RemoteSSH
    private var master: Process?
    private let reported = NSLock()
    private var lines: [String] = []

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `environment` is added to every remote script's, the server's included.
    init(_ test: XCTestCase, environment extra: [String: String] = [:]) throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["MUXIFY_SSH_TEST_HOST"], let username = env["MUXIFY_SSH_TEST_USER"] else {
            throw XCTSkip("Set MUXIFY_SSH_TEST_HOST and MUXIFY_SSH_TEST_USER to test a real SSH host")
        }
        let assets = Self.repository.appendingPathComponent("build/host-cli")
        let missing = ["version", "muxify-linux-aarch64", "muxify-linux-x86_64", "muxify-darwin-arm64"]
            .filter { !FileManager.default.fileExists(atPath: assets.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw XCTSkip("build/host-cli lacks \(missing.joined(separator: ", ")): run make host-cli")
        }
        versionLine = try String(contentsOf: assets.appendingPathComponent("version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        published = String(versionLine.dropFirst("muxify ".count))
        self.host = host
        let environment = RemoteEnvironment(name: "Live test", host: host, username: username,
                                            port: env["MUXIFY_SSH_TEST_PORT"].flatMap(Int.init),
                                            identityFile: env["MUXIFY_SSH_TEST_IDENTITY"])
        var options = ["-l", username,
                       "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                       "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
                       "-o", "KbdInteractiveAuthentication=no", "-o", "ConnectTimeout=10"]
        if let key = environment.identityFile { options += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        if let port = environment.port { options += ["-p", String(port)] }
        rawOptions = options
        directory = try TestDirectory()

        // The Mac serves on its loopback only. OrbStack's host.orb.internal reaches it from the machine; the
        // machine's own 127.0.0.1 does not, which blocks the Host's download while the Mac still fetches (chain B).
        let serveHost = env["MUXIFY_SSH_TEST_SERVE_HOST"] ?? "host.orb.internal"
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", "-u", "-m", "http.server", "0", "--directory", assets.path,
                            "--bind", serveHost == "host.orb.internal" ? "127.0.0.1" : "0.0.0.0"]
        let serverOutput = Pipe()
        server.standardOutput = serverOutput
        server.standardError = FileHandle.nullDevice
        try server.run()
        test.addTeardownBlock {
            kill(server.processIdentifier, SIGTERM)
            server.waitUntilExit()
        }
        var banner = ""
        while !banner.contains("\n") {
            let chunk = serverOutput.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            banner += String(decoding: chunk, as: UTF8.self)
        }
        let port = try XCTUnwrap(banner.range(of: #"port (\d+)"#, options: .regularExpression)
            .map { banner[$0].dropFirst("port ".count) }, "python3 -m http.server did not start: \(banner)")
        reachableBaseURL = "http://\(serveHost):\(port)/"
        macOnlyBaseURL = "http://127.0.0.1:\(port)/"

        // Auth and host verification must already work without prompts. Never approve a new host key.
        let root = "/tmp/muxify-live-" + UUID().uuidString.lowercased()
        let home = root + "/home"
        let prefix = "export HOME=" + Tmux.shellQuote(home) + " TMUX_TMPDIR=" + Tmux.shellQuote(root)
            + " LC_ALL=C; unset TMUX TMUX_PANE; "
        self.root = root
        self.home = home
        self.prefix = prefix
        label = "\(username)@\(host)"
        let rawRunner = runner
        let rawOptions = options
        func raw(_ script: String) throws -> String {
            try rawRunner.run(CommandInvocation(executable: "/usr/bin/ssh", arguments: rawOptions + [
                "--", host, "exec /bin/sh -c " + Tmux.shellQuote(script),
            ]))
        }
        _ = try raw("mkdir -m 700 " + Tmux.shellQuote(root) + " && mkdir " + Tmux.shellQuote(home))
        test.addTeardownBlock {
            // Only this test's processes and server: each runs a program from the test's directory (anchored, so
            // that this very shell, which names the directory too, is spared), and the tmux socket must be inside it.
            _ = try? raw("pkill -f " + Tmux.shellQuote("^" + root + "/") + "; "
                         + prefix + "if socket=$(tmux display -p '#{socket_path}' 2>/dev/null); then "
                         + "case $socket in " + Tmux.shellQuote(root) + "/*) tmux kill-server ;; esac; fi; "
                         + "rm -rf " + Tmux.shellQuote(root))
        }
        _ = try raw(prefix + "tmux -f /dev/null new-session -d -s main -c \"$HOME\"")

        // The production lanes need the connection's master; the shim gives every remote script this test's
        // environment and leaves the lanes' options and script text as they are.
        let exports = (["HOME": home, "TMUX_TMPDIR": root, "LC_ALL": "C"].merging(extra) { $1 })
            .sorted { $0.key < $1.key }.map { "\($0.key)=" + Tmux.shellQuote($0.value) }
        let isolatedCommand = "exec env -u TMUX -u TMUX_PANE " + exports.joined(separator: " ") + " "
        let shim = directory.url.appendingPathComponent("ssh")
        try """
        #!/bin/bash
        args=("$@")
        last=$((${#args[@]} - 1))
        if [[ "${args[last]}" == "exec /bin/sh -c "* ]]; then
            args[last]=\(Tmux.shellQuote(isolatedCommand))"${args[last]#exec }"
        fi
        exec /usr/bin/ssh "${args[@]}"

        """.write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        connection = try TmuxConnection(environment: environment, sshExecutable: shim.path)
        remote = try XCTUnwrap(connection.remote)
        test.addTeardownBlock { [self] in
            connection.retire()
            stopMaster()
            connection.cleanup()
            withExtendedLifetime(directory) {}
        }
        try startMaster()
    }

    func raw(_ script: String) throws -> String {
        try runner.run(CommandInvocation(executable: "/usr/bin/ssh", arguments: rawOptions + [
            "--", host, "exec /bin/sh -c " + Tmux.shellQuote(script),
        ]))
    }

    /// How many `muxify server` processes run from the test's `~/.local/bin/muxify`. Anchored, so that the shell
    /// that asks, whose command line names the path too, never counts.
    func servers() throws -> Int? {
        Int(try raw("pgrep -f " + Tmux.shellQuote("^" + home + "/.local/bin/muxify server$") + " | wc -l")
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether the server serves the tmux server of the test's own directory.
    func isolated(_ server: LiveServer) -> Bool {
        server.recorder.state.server?.socketPath?.hasPrefix(root + "/") == true
    }

    func sessionID(_ name: String) throws -> String {
        try raw(prefix + "tmux display-message -p -t " + Tmux.shellQuote("=" + name + ":") + " '#{session_id}'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: The master

    /// A master on the connection's control path, as the attachment opens it.
    func startMaster() throws {
        // A master that was killed may leave its socket behind, which a new master would refuse.
        try? FileManager.default.removeItem(atPath: remote.socketPath)
        let master = Process()
        master.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        master.arguments = rawOptions + ["-o", "ControlPath=" + remote.socketPath, "-M", "-N",
                                         "-o", "ControlPersist=no", "--", host]
        master.standardInput = FileHandle.nullDevice
        master.standardOutput = FileHandle.nullDevice
        master.standardError = FileHandle.nullDevice
        try master.run()
        self.master = master
        // A master that exits stops the wait at once, and the check below says why.
        eventually("the SSH master did not start", timeout: 15) {
            (try? runner.run(remote.control("check"))) != nil || !master.isRunning
        }
        XCTAssertNoThrow(try runner.run(remote.control("check")), "the SSH master did not start")
    }

    /// Kills the master as a lost network or a crashed ssh would end it.
    func killMaster() {
        guard let master, master.isRunning else { return }
        kill(master.processIdentifier, SIGKILL)
        master.waitUntilExit()
        self.master = nil
    }

    private func stopMaster() {
        guard let master, master.isRunning else { return }
        master.terminate()
        master.waitUntilExit()
        self.master = nil
    }

    // MARK: The install chain and the server

    var reports: [String] { reported.withLock { lines } }

    /// The app's install chain over the master, without a Debug build.
    func runChain(baseURL: String) -> HostCLIReady {
        HostCLIChain.run(over: connection, environmentName: "Live test", baseURL: baseURL, debug: nil) { line in
            reported.withLock { lines.append(line) }
        }
    }

    /// `muxify server` on a `-T` channel of the master, as the app opens it, after its `hello`; with `subscribing`,
    /// its `environment` subscription runs.
    func startServer(subscribing: Bool = true) async throws -> LiveServer {
        let channel = try HostServerChannel.process(remote.serverInvocation())
        let errors = HostServerErrors()
        errors.read(channel.errors)
        let client = ProtocolClient(input: channel.input, output: channel.output, build: "muxify live-test 0")
        let session: ProtocolClient.Session
        do {
            session = try await client.connect()
        } catch {
            let status = channel.exitStatus(waiting: 2)
            channel.close()
            XCTFail("the Host Server did not answer hello on \(label): \(error), exit \(String(describing: status)); "
                    + "stderr: \(errors.lines.joined(separator: " | "))")
            throw error
        }
        let recorder = Recorder()
        var consumer: Task<Void, Never>?
        if subscribing {
            let events = client.subscribe(HostRequest.subscribe(.environment), as: EnvironmentItem.self)
            consumer = Task {
                do {
                    for try await item in events { recorder.add(item.changes) }
                } catch {
                    recorder.end(error)
                }
            }
        }
        return LiveServer(channel: channel, client: client, session: session, errors: errors, recorder: recorder,
                          consumer: consumer)
    }

    // MARK: Waiting

    /// The shared wait, with the Host and the server's stderr in its failure.
    func wait(_ message: String, seconds: TimeInterval, _ server: LiveServer, file: StaticString = #filePath, line: UInt = #line,
              until done: () async throws -> Bool) async throws {
        try await eventually("\(message) on \(label); server stderr: \(server.errors.lines.joined(separator: " | "))",
                             timeout: seconds, file: file, line: line, until: done)
    }

    /// Waits until no item has come for a moment, and forgets what came before.
    func settle(_ recorder: Recorder) async throws {
        await settled("the server's items did not settle on \(label)", timeout: 15) { recorder.items }
        recorder.clear()
    }
}
