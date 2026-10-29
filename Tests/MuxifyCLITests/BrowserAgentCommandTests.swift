import XCTest
@testable import MuxifyCLI
import MuxifyCore

/// Browser commands through the command line and a real socket, with the app's end replaced by a listener that
/// records each request and sends a fixed reply.
final class BrowserAgentCommandTests: XCTestCase {
    private var socketPath = ""
    private var listener: BrowserAgentListener?
    private let requests = Requests()

    override func setUp() {
        // sun_path holds 104 bytes, so the socket stays in /tmp, not in a long temporary directory.
        socketPath = "/tmp/muxify-cli-test-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        listener?.stop()
    }

    private func serve(_ reply: BrowserAgentReply) throws {
        let requests = requests
        listener = try BrowserAgentListener(path: socketPath) { request, respond in
            requests.append(request)
            respond(reply)
        }
    }

    private func command(_ arguments: [String], pane: String? = "%7") throws -> CLICommand {
        try CLICommand(arguments: ["browser"] + arguments,
                       environment: pane.map { ["TMUX_PANE": $0, "TMPDIR": "/tmp/"] } ?? [:],
                       now: Date(timeIntervalSince1970: 1_000))
    }

    private func tmux(socket: String) -> TmuxAnswers {
        TmuxAnswers(["list-panes": "@12\n", "show-options": socket + "\n"])
    }

    func testBrowserCommandsParseIntoOneRequestEach() throws {
        let tab = UUID()
        func invocation(_ arguments: [String], pane: String? = "%7") throws -> BrowserAgentInvocation {
            guard case .browser(let invocation) = try command(arguments, pane: pane) else { throw CLIError("not a Browser command") }
            return invocation
        }
        XCTAssertEqual(try invocation(["tabs", "--json"]).command, .tabs)
        XCTAssertTrue(try invocation(["tabs", "--json"]).json)
        XCTAssertEqual(try invocation(["eval", "document.title"]).command, .eval(script: "document.title"))
        XCTAssertEqual(try invocation(["eval", "--tab", tab.uuidString, "--", "-1"]).command, .eval(script: "-1"))
        XCTAssertEqual(try invocation(["eval", "--tab", tab.uuidString, "1"]).tab, tab)
        XCTAssertEqual(try invocation(["eval", "--window", "@3", "1"], pane: nil).target, "@3")
        XCTAssertEqual(try invocation(["screenshot"]).screenshotPath, "/tmp/muxify-screenshot-1000000.png")
        XCTAssertEqual(try invocation(["screenshot", "--out", "/x/page.png"]).screenshotPath, "/x/page.png")
        XCTAssertEqual(try invocation(["snapshot"]).command, .snapshot)
        XCTAssertEqual(try invocation(["click", "e3"]).command, .click(ref: "e3"))
        XCTAssertEqual(try invocation(["fill", "e3", "Ada", "Lovelace"]).command, .fill(ref: "e3", text: "Ada Lovelace"))
        XCTAssertEqual(try invocation(["fill", "e3", ""]).command, .fill(ref: "e3", text: ""))
        XCTAssertEqual(try invocation(["press", "Enter"]).command, .press(key: "Enter", ref: nil))
        XCTAssertEqual(try invocation(["press", "a", "e12"]).command, .press(key: "a", ref: "e12"))
        XCTAssertEqual(try invocation(["wait", "--load"]).command, .wait(.load, timeout: 10))
        XCTAssertEqual(try invocation(["wait", "--text", "Saved", "--timeout", "2.5"]).command, .wait(.text("Saved"), timeout: 2.5))
        XCTAssertEqual(try invocation(["wait", "--selector", "#out"]).command, .wait(.selector("#out"), timeout: 10))
        XCTAssertEqual(try invocation(["close"]).command, .close)
        XCTAssertNil(try invocation(["close"]).tab)
        XCTAssertEqual(try invocation(["close", "--tab", tab.uuidString]).tab, tab)
        XCTAssertEqual(try invocation(["close", "--tab", tab.uuidString]).command, .close)
        XCTAssertEqual(try command(["open", "--json", "localhost:3000"]),
                       .browserOpen(window: "%7", tab: nil, urls: ["localhost:3000"], json: true))
        XCTAssertEqual(try command(["open", "--tab", tab.uuidString, "localhost:3000"]),
                       .browserOpen(window: "%7", tab: tab, urls: ["localhost:3000"], json: false))
    }

    func testBrowserCommandsRefuseWhatTheyCannotSend() {
        for (arguments, pane) in [(["eval"], "%7"), (["tabs", "extra"], "%7"), (["screenshot", "extra"], "%7")] as [([String], String?)] {
            XCTAssertThrowsError(try command(arguments, pane: pane), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
            }
        }
        for arguments in [["click"], ["click", "e1", "e2"], ["fill", "e1"], ["press"], ["wait"], ["wait", "--load", "--text", "x"],
                          ["snapshot", "extra"], ["close", "extra"]] {
            XCTAssertThrowsError(try command(arguments), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
            }
        }
        for ref in ["3", "e", "e0", "e03", "e-1", "button"] {
            XCTAssertThrowsError(try command(["click", ref]), ref) { error in
                XCTAssertEqual(error.localizedDescription, "'\(ref)' is not a Ref; muxify browser snapshot gives each element one, such as e3")
            }
        }
        for timeout in ["0", "-1", "soon", "601"] {
            XCTAssertThrowsError(try command(["wait", "--load", "--timeout", timeout]), timeout) { error in
                XCTAssertEqual(error.localizedDescription, "--timeout takes seconds from 0 to 600, such as --timeout 30")
            }
        }
        XCTAssertThrowsError(try command(["open", "--tab", UUID().uuidString, "localhost:3000", "localhost:4000"])) { error in
            XCTAssertEqual(error.localizedDescription, "--tab takes one URL")
        }
        XCTAssertThrowsError(try command(["eval", "--tab", "e3", "1"])) { error in
            XCTAssertEqual(error.localizedDescription, "'e3' is not a Tab id; muxify browser tabs lists them")
        }
        XCTAssertThrowsError(try command(["eval", "1"], pane: nil)) { error in
            XCTAssertEqual(error.localizedDescription, "not inside tmux; specify the Window with --window <id> (e.g. --window @12)")
        }
    }

    func testEvalSendsTheCallersWindowAndFailsWithTheAppsMessage() async throws {
        try serve(.failure(message: "tmux Window @12 has no Tab", exitCode: 1))
        do {
            try await command(["eval", "document.title"]).execute(using: tmux(socket: socketPath))
            XCTFail("the app's failure must fail the command")
        } catch let error as CLIError {
            XCTAssertEqual(error.message, "tmux Window @12 has no Tab")
            XCTAssertEqual(error.exitCode, 1)
        }
        XCTAssertEqual(requests.all, [BrowserAgentRequest(window: "@12", command: .eval(script: "document.title"))])
    }

    func testWaitGivesTheAppLongerThanItsOwnTimeout() async throws {
        XCTAssertGreaterThan(BrowserAgentCommand.wait(.load, timeout: 120).replyTimeout, 120)
        try serve(.done)
        try await command(["wait", "--text", "Saved", "--timeout", "120"]).execute(using: tmux(socket: socketPath))
        XCTAssertEqual(requests.all.map(\.command), [.wait(.text("Saved"), timeout: 120)])
    }

    func testScreenshotWritesTheAppsPictureWhereOutSays() async throws {
        let picture = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try serve(.png(picture))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        try await command(["screenshot", "--out", out.path]).execute(using: tmux(socket: socketPath))
        XCTAssertEqual(try Data(contentsOf: out), picture)
        XCTAssertEqual(requests.all.map(\.command), [.screenshot])
    }

    func testOpenJsonNeedsTheAppButPlainOpenFallsBackToTheTmuxOption() async throws {
        let stale = TmuxAnswers(["list-panes": "@12\n", "show-options": socketPath + "\n", "set-option": ""])
        do {
            try await command(["open", "--json", "localhost:3000"]).execute(using: stale)
            XCTFail("without the app nothing can name the new Tab")
        } catch let error as CLIError {
            XCTAssertTrue(error.message.hasPrefix("cannot reach Muxify"), error.message)
        }
        XCTAssertFalse(stale.ran("set-option"))
        do {
            try await command(["open", "--tab", UUID().uuidString, "localhost:3000"]).execute(using: stale)
            XCTFail("without the app nothing can load the URL into the Tab")
        } catch let error as CLIError {
            XCTAssertTrue(error.message.hasPrefix("cannot reach Muxify"), error.message)
        }
        XCTAssertFalse(stale.ran("set-option"), "@muxify_open would open a new Tab, not load into the Tab")
        try await command(["open", "localhost:3000"]).execute(using: stale)
        XCTAssertEqual(stale.arguments(of: "set-option"), ["set-option", "-wa", "-t", "@12", "@muxify_open", " localhost:3000"])
    }

    func testOpenGoesThroughTheAppWhenItServes() async throws {
        let tab = UUID()
        try serve(.opened(BrowserAgentTab(id: tab, url: "http://localhost:3000/", title: "", active: true)))
        let answers = tmux(socket: socketPath)
        try await command(["open", "localhost:3000"]).execute(using: answers)
        try await command(["open", "--tab", tab.uuidString, "localhost:4000"]).execute(using: answers)
        XCTAssertEqual(requests.all, [BrowserAgentRequest(window: "@12", command: .open(url: "localhost:3000")),
                                      BrowserAgentRequest(window: "@12", tab: tab, command: .open(url: "localhost:4000"))])
        XCTAssertFalse(answers.ran("set-option"), "the app opened the Tab, so @muxify_open stays empty")
    }

    func testListenerReplacesAStaleSocketAndLeavesTheFileOfANewerListener() throws {
        try serve(.value("1"))
        let newer = try BrowserAgentListener(path: socketPath) { _, respond in respond(.value("2")) }
        listener?.stop()
        XCTAssertEqual(try BrowserAgentChannel.send(BrowserAgentRequest(window: "@1", command: .tabs), to: socketPath), .value("2"))
        newer.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }
}

private final class Requests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [BrowserAgentRequest] = []

    func append(_ request: BrowserAgentRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var all: [BrowserAgentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

/// tmux answers keyed by subcommand, because a Browser command asks tmux in an order that the test does not fix.
private final class TmuxAnswers: CLICommandRunning {
    private let answers: [String: String]
    private var calls: [[String]] = []

    init(_ answers: [String: String]) { self.answers = answers }

    func run(_ command: String, arguments: [String], quiet: Bool) throws -> CLICommandResult {
        calls.append(arguments)
        guard command == "tmux", let output = answers[arguments[0]] else { return CLICommandResult(status: 1, output: "") }
        return CLICommandResult(status: 0, output: output)
    }

    func ran(_ subcommand: String) -> Bool { calls.contains { $0.first == subcommand } }
    func arguments(of subcommand: String) -> [String]? { calls.first { $0.first == subcommand } }
}
