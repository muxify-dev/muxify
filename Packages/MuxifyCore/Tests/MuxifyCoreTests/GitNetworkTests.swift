#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import XCTest
@testable import MuxifyCore

/// The Git View's network commands with askpass (ADR 0089, Credentials): fetch, push, pull and remote branch delete
/// against a local bare remote that a fake ssh guards with a passphrase, which it asks through `SSH_ASKPASS` as ssh does
/// under `SSH_ASKPASS_REQUIRE=force`. The helper is the real `muxify askpass`, built beside these tests by the app's
/// Xcode build; without it, as under `swift test` of this package alone, the askpass checks skip.
final class GitNetworkTests: XCTestCase {
    private static let passphrase = "Enter passphrase for key '/fake/id': "
    private var remote: SSHRemote!

    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    override func tearDown() {
        remote?.remove()
    }

    /// The `muxify` beside the test bundle: `muxify-app-cli` from the app's Xcode build, `muxify` from `swift test`.
    private func helper() throws -> String {
        #if os(macOS)
        let folder = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        #else
        let folder = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
        #endif
        for name in ["muxify-app-cli", "muxify"] {
            let path = folder.appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw XCTSkip("no muxify beside the tests to be the askpass helper")
    }

    private func runner(scratch: URL? = nil, environment extra: [String: String] = [:]) throws -> GitNetworkRunner {
        GitNetworkRunner(helper: try helper(), scratch: scratch ?? remote.directory, environment: remote.environment.merging(extra) { $1 })
    }

    // MARK: - The prompts

    func testThePatternsClassifyPassphrasePasswordUsernameAndHostKeyPrompts() {
        let prompts: [(String, GitCredentialPrompt.Kind, Bool)] = [
            ("Password:", .password, true),
            ("git@example.com's password:", .password, true),
            ("Password for 'https://alice@example.com':", .password, true),
            ("Username for 'https://example.com':", .username, false),
            ("Enter passphrase for key '/Users/alice/.ssh/id_ed25519':", .passphrase, true),
            ("Enter PIN for ECDSA-SK key /Users/alice/.ssh/id_ecdsa_sk:", .pin, true),
            ("Enter PIN for 'YubiKey':", .pin, true),
            ("Enter your 2FA Token", .token, true),
            ("Are you sure you want to continue connecting (yes/no/[fingerprint])?", .hostKey, false),
            ("Are you sure you want to continue connecting (yes/no)?", .hostKey, false),
        ]
        for (line, kind, isSecret) in prompts {
            let prompt = GitCredentialPrompt(askpass: line + " ")
            XCTAssertEqual(prompt.kind, kind, line)
            XCTAssertEqual(prompt.isSecret, isSecret, line)
            XCTAssertEqual(GitCredentialPrompt.isSecret(line + " "), isSecret, line)
            XCTAssertEqual(prompt.question, line, line)
            XCTAssertEqual(prompt.context, [], line)
        }
    }

    func testSshsUnknownHostKeyQuestionKeepsWhatSshSaidBeforeIt() {
        let prompt = GitCredentialPrompt(askpass: "The authenticity of host 'box (10.0.0.2)' can't be established.\r\n"
            + "ED25519 key fingerprint is SHA256:abc.\r\nThis key is not known by any other names.\r\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
        XCTAssertEqual(prompt.kind, .hostKey)
        XCTAssertFalse(prompt.isSecret, "the answer to a host key question is yes, no or the fingerprint")
        XCTAssertEqual(prompt.question, "Are you sure you want to continue connecting (yes/no/[fingerprint])?")
        XCTAssertEqual(prompt.context, ["The authenticity of host 'box (10.0.0.2)' can't be established.",
                                        "ED25519 key fingerprint is SHA256:abc.", "This key is not known by any other names."])
    }

    func testAQuestionNoPatternKnowsIsTakenAsASecret() {
        for line in ["Verification code: ", "password: ", "Enter passphrase for key"] {
            let prompt = GitCredentialPrompt(askpass: line)
            XCTAssertEqual(prompt.kind, .other, line)
            XCTAssertTrue(prompt.isSecret, line)
        }
        XCTAssertFalse(GitCredentialPrompt(askpass: "Who are you? ", secret: false).isSecret, "the helper's choice wins")
    }

    // MARK: - The commands

    func testFetchPullPushAndRemoteBranchDeleteAskThroughTheCallback() async throws {
        remote = try SSHRemote()
        let runner = try runner()
        let asked = Recorder<AskRequest>()
        let ask: GitAsk = { request in
            asked.add(request)
            return "right"
        }
        let repo = remote.repo

        try remote.pushFromOther("o.txt")
        _ = try await runner.run(.fetch(root: repo), ask: ask)
        XCTAssertEqual(try remote.git("rev-parse origin/master"), try remote.git("--git-dir ../origin.git rev-parse master"))

        _ = try await runner.run(.pull(root: repo, mode: .plain, remote: "", branch: ""), ask: ask)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/o.txt"), "the pull did not bring the remote's commit")

        try remote.git("checkout -q -b topic")
        try remote.git("commit -q --allow-empty -m topic")
        _ = try await runner.run(.push(root: repo, mode: .upstream, remote: "origin", branch: "topic"), ask: ask)
        XCTAssertEqual(try remote.git("--git-dir ../origin.git rev-parse topic"), try remote.git("rev-parse topic"))
        XCTAssertEqual(try remote.git("rev-parse --abbrev-ref topic@{upstream}"), "origin/topic\n")

        _ = try await runner.run(.deleteRemoteBranch(root: repo, branch: "topic"), ask: ask)
        XCTAssertThrowsError(try remote.git("--git-dir ../origin.git rev-parse --verify -q topic"), "the remote branch is still there")

        XCTAssertEqual(asked.all.map(\.prompt), Array(repeating: Self.passphrase, count: 4))
        XCTAssertTrue(asked.all.allSatisfy(\.secret), "a passphrase is a secret")
        XCTAssertEqual(Set(asked.all.map(\.operation)).count, 4, "each command names its own operation")
        XCTAssertEqual(try remote.helperRuns(), Array(repeating: "0 right", count: 4))
        XCTAssertEqual(try leftovers(in: remote.directory), [], "a command left its folder behind")
    }

    func testAWrongAnswerFailsWithGitsMessage() async throws {
        remote = try SSHRemote()
        let runner = try runner()
        do {
            _ = try await runner.run(.fetch(root: remote.repo)) { _ in "wrong" }
            XCTFail("a wrong passphrase fetched")
        } catch {
            XCTAssertTrue(GitReader.message(for: error).contains("Permission denied (publickey)."), GitReader.message(for: error))
        }
        XCTAssertEqual(try remote.helperRuns(), ["0 wrong"])
    }

    func testACancelledQuestionMakesTheHelperExitNonZeroAndTheCommandEndAtOnce() async throws {
        remote = try SSHRemote()
        let started = Date()
        do {
            _ = try await runner().run(.fetch(root: remote.repo)) { _ in nil }
            XCTFail("a cancelled question fetched")
        } catch TmuxError.cancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the command waited")
        let runs = try remote.helperRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertFalse(runs.first?.hasPrefix("0 ") ?? true, "the helper of a cancelled question exited 0: \(runs)")
    }

    func testACommandThatGoesOnAfterACancelledQuestionIsStopped() async throws {
        remote = try SSHRemote()
        let started = Date()
        do {
            _ = try await runner(environment: ["FAKE_SSH_HANG": "1"]).run(.fetch(root: remote.repo)) { _ in nil }
            XCTFail("a cancelled question fetched")
        } catch TmuxError.cancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "a command that ignored the cancel kept running")
    }

    // MARK: - Through the Host Server

    /// A Host Server here on pipes, whose own socket is `<dir>/s.muxify-browser.7`, and its Mac's end, which answers
    /// each request with `answer`. No tmux runs: the server listens beside where tmux's socket would be.
    private func hostServer(answer: @escaping @Sendable (ProtocolIncomingRequest) -> Void) async throws
        -> (client: ProtocolClient, server: ProtocolServer, state: URL) {
        let state = remote.short.appendingPathComponent("state")
        let context = HostServerContext(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": state.path], home: "/nonexistent"),
                                        tmux: TmuxServer(socketPath: remote.short.appendingPathComponent("s").path), socketID: "7",
                                        gitNetwork: try runner(scratch: state))
        let up = Pipe(), down = Pipe()
        let server = HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting, build: "host", context: context)
        server.start()
        let client = ProtocolClient(input: down.fileHandleForReading, output: up.fileHandleForWriting, build: "mac", helloTimeout: 5,
                                    onRequest: answer)
        _ = try await client.connect()
        return (client, server, state)
    }

    func testAQuestionOnTheServerBecomesAnAskOnTheClientAndItsAnswerReachesGit() async throws {
        remote = try SSHRemote()
        let asked = Recorder<AskRequest>()
        let host = try await hostServer { request in
            guard case .ask(let ask)? = try? request.body(MacRequest.self) else { return request.fail(ProtocolError(.invalid, "not an ask")) }
            asked.add(ask)
            request.finish(AskAnswer(answer: "right"))
        }
        try remote.pushFromOther("o.txt")
        _ = try await host.client.call(HostRequest.gitNetwork(GitNetworkRequest(network: .fetch(root: remote.repo), operation: "op-1")),
                                       as: GitWritten.self)
        XCTAssertEqual(asked.all, [AskRequest(prompt: Self.passphrase, secret: true, operation: "op-1")])
        XCTAssertEqual(try remote.helperRuns(), ["0 right"], "the Mac's answer did not reach git")
        XCTAssertEqual(try remote.git("rev-parse origin/master"), try remote.git("--git-dir ../origin.git rev-parse master"))

        // A cancelled question ends the request `cancelled`.
        let cancelling = try await hostServer { $0.fail(ProtocolError(.cancelled, "the question was cancelled")) }
        do {
            _ = try await cancelling.client.call(HostRequest.gitNetwork(GitNetworkRequest(network: .fetch(root: remote.repo), operation: "op-2")),
                                                 as: GitWritten.self)
            XCTFail("a cancelled question fetched")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertEqual(try remote.helperRuns().count, 2)
        XCTAssertFalse(try remote.helperRuns()[1].hasPrefix("0 "), "the helper of a cancelled question exited 0")
        for host in [host, cancelling] {
            host.client.close()
            _ = await host.server.wait()
        }
    }

    func testClosingTheChannelMakesTheHelperExitNonZeroAtOnceAndTheCommandEnd() async throws {
        remote = try SSHRemote()
        let box = ClientBox()
        let host = try await hostServer { request in
            // The Mac goes away while the question waits.
            DispatchQueue.global().async { box.client?.close() }
            _ = request
        }
        box.client = host.client
        let call = Task {
            try await host.client.call(HostRequest.gitNetwork(GitNetworkRequest(network: .fetch(root: remote.repo), operation: "op")),
                                       as: GitWritten.self)
        }
        try await wait("the helper did not exit") { (try? self.remote.helperRuns().count) == 1 }
        XCTAssertFalse(try remote.helperRuns()[0].hasPrefix("0 "), "the helper of a closed channel exited 0")
        try await wait("the command did not end") { (try? self.leftovers(in: host.state)) == [] }
        _ = await host.server.wait()
        _ = try? await call.value
    }

    func testTheNetworkRequestAndTheAskArePinned() throws {
        func text(_ line: Data) -> String { String(decoding: line, as: UTF8.self) }
        let push = GitNetwork.push(root: "/r", mode: .upstream, remote: "origin", branch: "b")
        XCTAssertEqual(text(try ProtocolLine.request(id: 5, HostRequest.gitNetwork(GitNetworkRequest(network: push, operation: "op")))),
                       #"{"id":5,"kind":"request","request":{"git_network":{"network":{"push":{"branch":"b","mode":"upstream","remote":"origin","root":"/r"}},"operation":"op"}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.request(id: 6, MacRequest.ask(AskRequest(prompt: "Password: ", secret: true, operation: "op")))),
                       #"{"id":6,"kind":"request","request":{"ask":{"operation":"op","prompt":"Password: ","secret":true}}}"# + "\n")
        XCTAssertEqual(text(try ProtocolLine.ok(id: 6, AskAnswer(answer: "x"))), #"{"end":{"ok":{"answer":"x"}},"id":6,"kind":"end"}"# + "\n")
        for network in [GitNetwork.fetch(root: "/r"), .pull(root: "/r", mode: .plain, remote: "", branch: ""),
                        .deleteRemoteBranch(root: "/r", branch: "b"), push] {
            XCTAssertEqual(try JSONDecoder().decode(GitNetwork.self, from: JSONEncoder().encode(network)), network)
        }
        XCTAssertEqual(GitNetwork.deleteRemoteBranch(root: "/r", branch: "b").action, "Delete Remote Branch")
    }

    // MARK: - Helpers

    /// The folders that commands made in `folder` and did not remove.
    private func leftovers(in folder: URL) throws -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("mxa.") }
    }

    private func wait(_ message: String, seconds: TimeInterval = 5, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail(message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// A bare `origin.git`, a clone `repo` that reaches it over a fake ssh, and a clone `other` that pushes to it over its
/// path. The fake ssh asks for a passphrase through `SSH_ASKPASS`, logs the helper's exit status and answer to
/// `helper-runs`, and serves the repository only for the answer `right`. With `FAKE_SSH_HANG`, it ignores a failed
/// question and waits, as a command that goes on would.
private final class SSHRemote {
    let directory: URL
    /// A short folder for the Host Server's socket, which must fit in 104 bytes.
    let short: URL
    let environment: [String: String]
    var repo: String { directory.appendingPathComponent("repo").path }
    private var log: URL { directory.appendingPathComponent("helper-runs") }

    init() throws {
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muxify-net-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        guard let real = realpath(made.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        directory = URL(fileURLWithPath: String(cString: real))
        free(real)
        short = URL(fileURLWithPath: "/tmp/mxn-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: short, withIntermediateDirectories: true)
        environment = [
            "HOME": directory.path, "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Yauhen Karatkou", "GIT_AUTHOR_EMAIL": "y@example.com",
            "GIT_COMMITTER_NAME": "Yauhen Karatkou", "GIT_COMMITTER_EMAIL": "y@example.com",
        ]
        let ssh = directory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        if [ "$SSH_ASKPASS_REQUIRE" != force ] || [ -z "$DISPLAY" ] || [ -z "$SSH_ASKPASS" ]; then
            echo "ssh would ask on a terminal" >&2; exit 255
        fi
        answer=$("$SSH_ASKPASS" "Enter passphrase for key '/fake/id': ")
        status=$?
        printf '%s %s\\n' "$status" "$answer" >> \(Tmux.shellQuote(log.path))
        if [ $status -ne 0 ] && [ -n "$FAKE_SSH_HANG" ]; then sleep 5; fi
        [ $status -eq 0 ] && [ "$answer" = right ] || { echo "Permission denied (publickey)." >&2; exit 255; }
        for last; do :; done
        exec /bin/sh -c "$last"
        """.write(to: ssh, atomically: true, encoding: .utf8)
        guard chmod(ssh.path, 0o755) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try run("""
        cd "$1"
        git init -q --bare -b master origin.git
        git init -q -b master seed && cd seed && git commit -q --allow-empty -m first && git push -q ../origin.git master && cd ..
        git clone -q origin.git other
        git clone -q origin.git repo && cd repo
        git remote set-url origin "ssh://fake.invalid$1/origin.git"
        git config core.sshCommand "$1/ssh"
        git config pull.rebase false
        """, directory.path)
    }

    /// Runs a script, its first argument as `$1`, with the private HOME.
    @discardableResult
    func run(_ script: String, _ arguments: String...) throws -> String {
        try CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", script, "muxify"] + arguments),
                                timeout: 30, environment: environment)
    }

    /// git in `repo`.
    @discardableResult
    func git(_ arguments: String) throws -> String {
        try run("cd \"$1\" && git \(arguments)", repo)
    }

    /// A commit that `other` pushes to the remote's master, adding `file`.
    func pushFromOther(_ file: String) throws {
        try run("cd \"$1/other\" && echo x > \"$2\" && git add \"$2\" && git commit -q -m \"$2\" && git push -q origin master",
                directory.path, file)
    }

    /// Each run of the helper, as the fake ssh logged it: its exit status, then the answer it printed.
    func helperRuns() throws -> [String] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: short)
    }
}

private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func add(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private final class ClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProtocolClient?

    var client: ProtocolClient? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
