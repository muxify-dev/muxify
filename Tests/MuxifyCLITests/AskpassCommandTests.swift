import XCTest
@testable import MuxifyCLI
import MuxifyCore
import MuxifyTestSupport

/// `muxify askpass`, the helper that git and ssh run for the Git View's network commands (ADR 0089), run as git runs
/// it: the built CLI with the prompt as its one argument, against a socket that a test listener serves.
final class AskpassCommandTests: XCTestCase {
    private var socketPath = ""
    private var listener: BrowserAgentListener?

    override func setUp() {
        // sun_path holds 104 bytes, so the socket stays in /tmp, not in a long temporary directory.
        socketPath = "/tmp/muxify-askpass-test-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        listener?.stop()
    }

    /// The CLI beside this test bundle: `muxify-app-cli` from the app's Xcode build, `muxify` from `swift test`.
    private var cli: URL {
        #if os(macOS)
        let folder = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        #else
        let folder = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
        #endif
        let appCLI = folder.appendingPathComponent("muxify-app-cli")
        return FileManager.default.isExecutableFile(atPath: appCLI.path) ? appCLI : folder.appendingPathComponent("muxify")
    }

    /// Runs the helper as git does, and answers its exit status, its stdout and its stderr, and how long it took.
    private func askpass(_ prompt: String, socket: String) throws -> (status: Int32, output: String, errors: String, seconds: TimeInterval) {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["askpass", prompt]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        environment[GitAskpass.socketVariable] = socket
        environment[GitAskpass.operationVariable] = "op-7"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let started = Date()
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self),
                Date().timeIntervalSince(started))
    }

    private func serve(_ reply: BrowserAgentReply, recording requests: Requests) throws {
        listener = try BrowserAgentListener.lines(at: socketPath) { line, respond in
            if case .ask(let ask)? = try? JSONDecoder().decode(MacRequest.self, from: line) { requests.append(ask) }
            respond(reply)
        }
    }

    func testTheHelperSendsThePromptAndPrintsTheAnswer() throws {
        let requests = Requests()
        try serve(.value("right"), recording: requests)
        let run = try askpass("Enter passphrase for key '/k/id': ", socket: socketPath)
        XCTAssertEqual(run.status, 0, run.errors)
        XCTAssertEqual(run.output, "right\n")
        XCTAssertEqual(requests.all, [AskRequest(prompt: "Enter passphrase for key '/k/id': ", secret: true, operation: "op-7")])
        _ = try askpass("Username for 'https://example.com': ", socket: socketPath)
        XCTAssertEqual(requests.all.last?.secret, false, "a username is not a secret")
    }

    func testACancelledQuestionMakesTheHelperExitNonZeroAtOnce() throws {
        try serve(.failure("Muxify: nobody answered \"Password:\""), recording: Requests())
        let run = try askpass("Password: ", socket: socketPath)
        XCTAssertNotEqual(run.status, 0)
        XCTAssertEqual(run.output, "", "a cancelled question printed an answer")
        XCTAssertTrue(run.errors.contains("nobody answered"), run.errors)
        // A correct run takes well under a second; a helper that waited would wait for its reply timeout of an hour.
        XCTAssertLessThan(run.seconds, scaled(5))
    }

    func testAHelperWhoseSocketIsGoneExitsNonZeroAtOnce() throws {
        let run = try askpass("Password: ", socket: socketPath)
        XCTAssertNotEqual(run.status, 0)
        XCTAssertEqual(run.output, "")
        XCTAssertTrue(run.errors.contains("cannot reach Muxify"), run.errors)
        XCTAssertLessThan(run.seconds, scaled(5), "a correct run takes well under a second")
    }

    func testAHelperRunOutsideAGitViewCommandSaysSo() throws {
        let run = try askpass("Password: ", socket: "")
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.errors.contains("runs only under a Git View command"), run.errors)
    }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AskRequest] = []

    func append(_ request: AskRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var all: [AskRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
