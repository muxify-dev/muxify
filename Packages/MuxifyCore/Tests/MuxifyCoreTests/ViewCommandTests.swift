import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class ViewCommandWireTests: XCTestCase {
    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func testEveryViewCommandHasPinnedJSONAndRoundTrips() throws {
        let styles = PaneSearch.Styles(match: "bg=#ffff00", current: "bg=#ff8800")
        let browser = StoredBrowser(tabURLs: ["https://a.test", "about:blank"], activeTab: 1,
                                    layout: PanelLayout(shown: .both, maximized: .browser))
        let pinned: [(ViewCommand, String)] = [
            (.selectPane(target: "%1"), #"{"select_pane":{"target":"%1"}}"#),
            (.selectPane(target: "@2", move: .previous), #"{"select_pane":{"move":"previous","target":"@2"}}"#),
            (.selectPane(target: "%1", move: .left), #"{"select_pane":{"move":"left","target":"%1"}}"#),
            (.switchClient(client: "/dev/ttys001", target: "$1:@2"), #"{"switch_client":{"client":"/dev/ttys001","target":"$1:@2"}}"#),
            (.splitPane(target: "%1", side: .down), #"{"split_pane":{"side":"down","target":"%1"}}"#),
            (.splitPane(target: "%1", side: .left, directory: "/work"), #"{"split_pane":{"directory":"/work","side":"left","target":"%1"}}"#),
            (.splitPane(target: "%1", side: .right, full: true), #"{"split_pane":{"full":true,"side":"right","target":"%1"}}"#),
            (.resizePane(target: "%1", by: .zoom), #"{"resize_pane":{"by":{"zoom":{}},"target":"%1"}}"#),
            (.resizePane(target: "%1", by: .border(.up, cells: 10)),
             #"{"resize_pane":{"by":{"border":{"cells":10,"direction":"up"}},"target":"%1"}}"#),
            (.selectLayout(target: "%1"), #"{"select_layout":{"target":"%1"}}"#),
            (.setLastWindow(window: "@2"), #"{"set_last_window":{"window":"@2"}}"#),
            (.setAgentUnread([PaneUnread(pane: "%1", unread: true), PaneUnread(pane: "%2", unread: false)]),
             #"{"set_agent_unread":{"panes":[{"pane":"%1","unread":true},{"pane":"%2","unread":false}]}}"#),
            (.setBrowser(window: "@2", browser: browser),
             #"{"set_browser":{"browser":{"active_tab":1,"maximized":"browser","shown":"both","tabs":["https://a.test","about:blank"]},"window":"@2"}}"#),
            (.setBrowser(window: "@2", browser: StoredBrowser()),
             #"{"set_browser":{"browser":{"active_tab":0,"shown":"terminal","tabs":[]},"window":"@2"}}"#),
            (.clearOpenRequests(window: "@2"), #"{"clear_open_requests":{"window":"@2"}}"#),
            (.setBrowserSocket(path: "/tmp/b.sock"), #"{"set_browser_socket":{"path":"/tmp/b.sock"}}"#),
            (.setBrowserSocket(path: nil), #"{"set_browser_socket":{}}"#),
            (.activePane(window: "@2"), #"{"active_pane":{"window":"@2"}}"#),
            (.paneIsActive(pane: "%1"), #"{"pane_is_active":{"pane":"%1"}}"#),
            (.findInPane(.query, query: "error", target: "@2", styles: styles),
             #"{"find_in_pane":{"query":"error","step":"query","styles":{"current":"bg=#ff8800","match":"bg=#ffff00"},"target":"@2"}}"#),
            (.cancelFind(pane: "%1"), #"{"cancel_find":{"pane":"%1"}}"#),
            (.capturePane(pane: "%1", fromLine: -3), #"{"capture_pane":{"from_line":-3,"pane":"%1"}}"#),
            (.sendKeys(target: "%1", keys: ["ls"], literal: true, client: "/dev/ttys001"),
             #"{"send_keys":{"client":"/dev/ttys001","keys":["ls"],"literal":true,"target":"%1"}}"#),
            (.sendKeys(target: "%1", keys: ["Enter"], literal: false, client: nil),
             #"{"send_keys":{"keys":["Enter"],"literal":false,"target":"%1"}}"#),
            (.newWindow(target: "$1:@2", after: true, directory: "/work", command: "vi a"),
             #"{"new_window":{"after":true,"command":"vi a","directory":"/work","target":"$1:@2"}}"#),
            (.killSession(session: "$9"), #"{"kill_session":{"session":"$9"}}"#),
            (.clientPane(client: "/dev/ttys001"), #"{"client_pane":{"client":"/dev/ttys001"}}"#),
            (.paste(pane: "%1", text: "/tmp/a b"), #"{"paste":{"pane":"%1","text":"/tmp/a b"}}"#),
        ]
        for (command, text) in pinned {
            XCTAssertEqual(try json(command), text)
            XCTAssertEqual(try JSONDecoder().decode(ViewCommand.self, from: Data(text.utf8)), command, text)
        }
    }

    func testEachCommandIsOneTmuxInvocationAsTheAppSentItBefore() {
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .selectPane(target: "@2", move: .next)), ["select-pane", "-t", "@2.+"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .selectPane(target: "%1", move: .up)), ["select-pane", "-U", "-t", "%1"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .switchClient(client: "/dev/t", target: "$1:@2")),
                       ["switch-client", "-Z", "-c", "/dev/t", "-t", "$1:@2"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .splitPane(target: "%1", side: .up)),
                       ["split-window", "-v", "-b", "-t", "%1", "-c", "#{pane_current_path}"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .splitPane(target: "%1", side: .down, full: true)),
                       ["split-window", "-v", "-f", "-t", "%1", "-c", "#{pane_current_path}"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .splitPane(target: "%1", side: .right, full: true)),
                       ["split-window", "-h", "-f", "-t", "%1", "-c", "#{pane_current_path}"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .splitPane(target: "%1", side: .right, full: false)),
                       ["split-window", "-h", "-t", "%1", "-c", "#{pane_current_path}"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .resizePane(target: "%1", by: .border(.left, cells: 10))),
                       ["resize-pane", "-L", "-t", "%1", "10"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .setAgentUnread([PaneUnread(pane: "%1", unread: true), PaneUnread(pane: "%2", unread: false)])),
                       AgentUnread.command(true, paneID: "%1") + [";"] + AgentUnread.command(false, paneID: "%2"))
        let browser = StoredBrowser(tabURLs: ["https://a.test"])
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .setBrowser(window: "@2", browser: browser)), browser.setOptionArgs(windowID: "@2"))
        XCTAssertEqual(ViewCommandExecutor.arguments(for: .newWindow(target: "$1:", after: false, directory: "/h", command: "vi")),
                       ["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "$1:", "-c", "/h", "vi"])
    }
}

final class ViewCommandExecutorTests: DescriptorCheckedTestCase {
    private var directory: URL!
    private var server: TmuxServer!
    private var socket: String { directory.appendingPathComponent("view").path }
    private var executor: ViewCommandExecutor { ViewCommandExecutor(server: server) }
    private var clientProcess: Process?
    private var saved: [String: String?] = [:]

    override func setUpWithError() throws {
        _ = try requireTmux()
        // A short path: a socket path must fit in 104 bytes.
        directory = URL(fileURLWithPath: "/tmp/mxv-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server = TmuxServer(socketPath: socket, configPath: "/dev/null")
        for name in ["TMUX", "TMUX_PANE", "TMUX_TMPDIR"] { saved[name] = ProcessInfo.processInfo.environment[name] }
        unsetenv("TMUX")
        unsetenv("TMUX_PANE")
        setenv("TMUX_TMPDIR", directory.path, 1)
        try server.run(["new-session", "-d", "-s", "work", "-x", "120", "-y", "40", "-c", directory.path])
    }

    override func tearDownWithError() throws {
        if let clientProcess, clientProcess.isRunning { clientProcess.terminate(); clientProcess.waitUntilExit() }
        // The Client's input is open until closed: on Linux a Process and its Pipes are never freed (DescriptorCheck).
        try? (clientProcess?.standardInput as? Pipe)?.fileHandleForWriting.close()
        clientProcess = nil
        if let found = try? server?.run(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .whitespacesAndNewlines),
           found == socket {
            _ = try? server?.run(["kill-server"])
        }
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func tmux(_ arguments: [String]) throws -> String {
        try server.run(arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Client attached to `session` in a pseudo-terminal: its tty and pid.
    private func attachClient(to session: String) throws -> ViewCommandExecutor.Client {
        let binary = try XCTUnwrap(server.binary)
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
        var fields: [String] = []
        guard eventually("no attached Client", until: {
            fields = (try? tmux(["list-clients", "-F", "#{client_tty} #{client_pid}"]))?.components(separatedBy: " ") ?? []
            return fields.count == 2 && !fields[0].isEmpty
        }) else { throw TmuxError.timedOut }
        return ViewCommandExecutor.Client(tty: fields[0], pid: try XCTUnwrap(Int(fields[1])))
    }

    func testSplitPaneAndSelectPane() throws {
        let first = try tmux(["display-message", "-p", "-t", "=work:", "#{pane_id}"])
        try executor.run(.splitPane(target: first, side: .right))
        let panes = try tmux(["list-panes", "-t", "=work:", "-F", "#{pane_id}"]).components(separatedBy: "\n")
        XCTAssertEqual(panes.count, 2)
        let second = try XCTUnwrap(panes.first { $0 != first })
        XCTAssertEqual(try tmux(["display-message", "-p", "-t", "=work:", "#{pane_id}"]), second, "the new Pane is active")
        XCTAssertEqual(try executor.run(.activePane(window: "=work:")).components(separatedBy: " ").first, second)

        try executor.run(.selectPane(target: first))
        XCTAssertEqual(try tmux(["display-message", "-p", "-t", "=work:", "#{pane_id}"]), first)
        XCTAssertEqual(try executor.run(.paneIsActive(pane: first)).trimmingCharacters(in: .whitespacesAndNewlines), "1")
        try executor.run(.selectPane(target: first, move: .right))
        XCTAssertEqual(try tmux(["display-message", "-p", "-t", "=work:", "#{pane_id}"]), second)
    }

    func testSetAgentUnreadSetsAndClearsEachPane() throws {
        let first = try tmux(["display-message", "-p", "-t", "=work:", "#{pane_id}"])
        let second = try tmux(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", first])
        func unread(_ pane: String) throws -> String { try tmux(["show-options", "-pqv", "-t", pane, Tmux.agentUnreadOption]) }
        try executor.run(.setAgentUnread([PaneUnread(pane: first, unread: true), PaneUnread(pane: second, unread: true)]))
        XCTAssertEqual(try unread(first), "1")
        XCTAssertEqual(try unread(second), "1")
        try executor.run(.setAgentUnread([PaneUnread(pane: first, unread: false)]))
        XCTAssertEqual(try unread(first), "")
        XCTAssertEqual(try unread(second), "1")
    }

    func testCapturePaneReadsThePaneFromALine() throws {
        let pane = try tmux(["new-window", "-d", "-P", "-F", "#{pane_id}", "-t", "=work:", "printf 'first-line\\nsecond-line\\n'; exec sleep 60"])
        eventually("the Pane's output did not come") { (try? executor.run(.capturePane(pane: pane, fromLine: 0)))?.contains("second-line") == true }
        let text = try executor.run(.capturePane(pane: pane, fromLine: 1))
        XCTAssertTrue(text.hasPrefix("second-line"), text)
        XCTAssertFalse(text.contains("first-line"), text)
    }

    func testSwitchClientMovesTheOwnClient() throws {
        try server.run(["new-session", "-d", "-s", "other", "-c", directory.path])
        let client = try attachClient(to: "work")
        let own = ViewCommandExecutor(server: server, ownClient: client)
        try own.run(.switchClient(client: client.tty, target: "=other:"))
        XCTAssertEqual(try tmux(["list-clients", "-F", "#{client_session}"]), "other")
        XCTAssertTrue(try own.run(.clientPane(client: client.tty)).hasPrefix("%"))
    }

    func testASwitchRunsOnTheListenerWhenOneTakesItAndHereWhenNone() throws {
        var ran: [[String]] = []
        var listener: [String] = []
        var attached = true
        let executor = ViewCommandExecutor(run: { ran.append($0); return "" }, switchOnListener: { client, target in
            if attached { listener.append(client + " " + target) }
            return attached
        })
        try executor.run(.switchClient(client: "/dev/ttys001", target: "$1:@2"))
        XCTAssertEqual(listener, ["/dev/ttys001 $1:@2"])
        XCTAssertEqual(ran, [], "a switch that the Listener took also ran here")

        attached = false
        try executor.run(.switchClient(client: "/dev/ttys001", target: "$1:@2"))
        XCTAssertEqual(ran, [["switch-client", "-Z", "-c", "/dev/ttys001", "-t", "$1:@2"]])
        try executor.run(.selectPane(target: "%1", move: nil))
        XCTAssertEqual(ran.last, ["select-pane", "-t", "%1"], "only a switch goes to the Listener")
    }

    func testTheOwnClientCheckRefusesACommandWhoseTTYNamesAnotherClient() throws {
        try server.run(["new-session", "-d", "-s", "other", "-c", directory.path])
        let client = try attachClient(to: "work")
        // The tty now belongs to a Client of another pid, as after the App Window's Client ended.
        let changed = ViewCommandExecutor(server: server, ownClient: .init(tty: client.tty, pid: client.pid + 100_000))
        XCTAssertThrowsError(try changed.run(.switchClient(client: client.tty, target: "=other:"))) { error in
            XCTAssertEqual(error as? ViewCommandError, .clientChanged(tty: client.tty))
        }
        XCTAssertThrowsError(try changed.run(.clientPane(client: client.tty)))
        XCTAssertEqual(try tmux(["list-clients", "-F", "#{client_session}"]), "work", "the refused switch did not run")
        let gone = ViewCommandExecutor(server: server, ownClient: client)
        XCTAssertThrowsError(try gone.run(.switchClient(client: "/dev/ttys-none", target: "=other:")),
                             "a tty that names no Client is refused")
    }
}
