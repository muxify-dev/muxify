import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

/// Runs the `environment` publisher against a throwaway tmux server and a temporary state database.
final class EnvironmentPublisherTests: DescriptorCheckedTestCase {
    private var directory: URL!
    private var server: TmuxServer!
    private var paths: MuxifyPaths!
    private var publishers: [EnvironmentPublisher] = []
    private var saved: [String: String?] = [:]
    private var clientProcess: Process?
    /// The Clients attached after the Terminal's: other terminals.
    private var otherProcesses: [Process] = []
    /// What the publisher of `startTerminal` sent its Listeners, and their connections.
    private let sent = SentLines()
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
        for process in [clientProcess].compactMap({ $0 }) + otherProcesses where process.isRunning {
            process.terminate()
            // `waitUntilExit` can miss the exit and wait for ever, as in HostServerTests: wait for the pid, a while at
            // most, then kill it.
            let pid = process.processIdentifier
            if !eventually("", timeout: 5, fail: { _, _, _ in }, until: { kill(pid, 0) != 0 }) {
                kill(pid, SIGKILL)
                eventually("a Client's process outlived SIGKILL") { kill(pid, 0) != 0 }
            }
        }
        // Each Client's input is open until closed: on Linux a Process and its Pipes are never freed (DescriptorCheck).
        for process in [clientProcess].compactMap({ $0 }) + otherProcesses {
            try? (process.standardInput as? Pipe)?.fileHandleForWriting.close()
        }
        clientProcess = nil
        otherProcesses = []
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

        await eventually("no first item") { !recorder.items.isEmpty }
        let first = try XCTUnwrap(recorder.items.first)
        XCTAssertEqual(Set(first.map(\.key)), ["session \(try sessionID("work"))", "session \(try sessionID("other"))",
                                               "topic first", "open_places", "board_sessions", "server"])
        guard case .server(let state)? = first.first(where: { $0.key == "server" }) else { return XCTFail("no server event") }
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.socketPath, socket)

        try await settle(recorder, controlClients: 1)
        // It returns once the read's events were delivered.
        await publishers[0].read()
        XCTAssertEqual(recorder.keys, [], "a read of an unchanged server and database sent events")
    }

    func testEachChangeSendsOnlyItsKeySoonAfterIt() async throws {
        // A shell names its Window as it starts, which sends its Session's key, and a busy machine can start it during
        // a later step: each Pane runs a program that writes nothing, so tmux never names its Window after it.
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24", "exec sleep 600"])
        try server.run(["new-session", "-d", "-s", "other", "exec sleep 600"])
        try await eventually("the Panes do not run their program") {
            try server.run(["list-panes", "-a", "-F", "#{pane_current_command}"]).split(separator: "\n") == ["sleep", "sleep"]
        }
        let work = "session " + (try sessionID("work"))
        let other = try sessionID("other")
        // Another process: a store with its own connection.
        let external = TopicStore(paths: paths)
        try external.write { try $0.create(TopicRecord(id: "first", title: "First")) }
        let recorder = start()
        try await settle(recorder, controlClients: 1)

        let pane = try server.run(["split-window", "-d", "-t", "work:", "-P", "-F", "#{pane_id}", "exec sleep 600"])
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

    func testTheListenerSitsInTheSessionTmuxPicksThenFollowsTheMarkedClientWhereverItSwitches() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        try server.run(["new-session", "-d", "-s", "other"])
        try server.run(["new-session", "-d", "-s", "third"])
        let marker = ClientMarker.option(nonce: "terminal")
        let recorder = start(clientMarker: marker)
        try await settle(recorder, controlClients: 1)
        XCTAssertTrue(try sessions().contains(try XCTUnwrap(try controlClients().first)), "the Listener sits in no Session")
        XCTAssertFalse(try sessions().contains(EnvironmentPublisher.leftoverWatchSession), "the Listener made a Watch Session")
        XCTAssertEqual(try sessions().count, 3, "the Listener made a Session")

        let terminal = try attachClient(to: "work")
        let value = [String(terminal.pid), terminal.tty, "/Users/u", "mac", "local"].joined(separator: Tmux.separator)
        try server.run(["set-option", "-sq", marker, value])
        try await eventually("the Listener did not move to the marked Client's Session") { try self.controlClients() == ["work"] }
        // tmux answers a Pane's background question from the first Client of its Session, and a control Client's as black.
        XCTAssertEqual(try server.run(["list-clients", "-F", "#{client_control_mode}"]).split(separator: "\n"), ["0", "1"],
                       "the Listener came before the Terminal's Client")

        try server.run(["switch-client", "-c", terminal.tty, "-t", "=other"])
        try await eventually("the Listener did not follow a switch-client from outside Muxify") { try self.controlClients() == ["other"] }

        try server.run(["switch-client", "-c", terminal.tty, "-t", "=third"])
        try await eventually("the Listener did not follow the next switch") { try self.controlClients() == ["third"] }
    }

    func testTheListenerIsAttachedAgainWithinHalfASecondAfterItsSessionIsKilled() async throws {
        for name in ["work", "other", "third"] { try server.run(["new-session", "-d", "-s", name]) }
        let recorder = start()
        try await settle(recorder, controlClients: 1)
        let sitting = try XCTUnwrap(try controlClients().first)

        let killed = Date()
        try server.run(["kill-session", "-t", "=" + sitting])
        try await eventually("the Listener was not attached again") {
            let clients = try self.controlClients()
            return clients.count == 1 && clients[0] != sitting
        }
        // A Listener that never attached waits a second before it starts again; one that did starts in a twentieth.
        XCTAssertLessThan(Date().timeIntervalSince(killed), scaled(0.5), "the Listener waited before it attached again")
    }

    func testALeftoverWatchSessionIsKilledOnConnect() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        try server.run(["new-session", "-d", "-s", EnvironmentPublisher.leftoverWatchSession, "cat"])
        let recorder = start()
        try await settle(recorder, controlClients: 1)
        XCTAssertEqual(try sessions(), ["work"])
        XCTAssertEqual(try controlClients(), ["work"])
    }

    func testTheServerExitsAfterTheLastSessionClosesAndBothListenersComeBackWithTheNext() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        let first = start(), second = start()
        try await eventually("both publishers did not attach") { try self.controlClients() == ["work", "work"] }

        try server.run(["kill-session", "-t", "=work"])
        try await serverExited("the server outlived the last Session")
        for recorder in [first, second] {
            await eventually("a publisher did not say the server stopped") { recorder.server?.isRunning == false }
        }

        try server.run(["new-session", "-d", "-s", "again"])
        try await eventually("a new Session did not bring both publishers back") {
            try self.controlClients() == ["again", "again"]
        }
        XCTAssertEqual(try sessions(), ["again"])
    }

    func testEveryPaneOfTheSessionTheTerminalSwitchesToAnswersTheReportedColour() async throws {
        let work = try probe(session: "work")
        let other = try probe(session: "other")
        try server.run(["split-window", "-d", "-t", "other:", probeCommand(other.1)])
        let third = try probe(session: "third")
        let unvisited = try probe(session: "unvisited")
        let terminal = try startTerminal(in: "work", colours: Self.light)
        try await listenerFollowsTheTerminal(in: "work")

        // A switch that Muxify starts runs this same command on the Terminal's Client.
        try server.run(["switch-client", "-c", terminal.tty, "-t", "=other"])
        try await eventually("the Listener did not follow the Terminal") { try self.controlClients() == ["other"] }
        try server.run(["switch-client", "-c", terminal.tty, "-t", "=third"])
        try await eventually("the Listener did not follow the next switch") { try self.controlClients() == ["third"] }
        try await tmuxRanTheListenersCommands()
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        for answer in [work.0, other.0, other.1, third.0] {
            await eventually("no answer from a probe") { FileManager.default.fileExists(atPath: answer) }
            XCTAssertEqual(try String(contentsOfFile: answer, encoding: .utf8), "rgb:fbfb/f1f1/c7c7", answer)
        }
        await eventually("no answer from the probe") { FileManager.default.fileExists(atPath: unvisited.0) }
        XCTAssertNotEqual(try String(contentsOfFile: unvisited.0, encoding: .utf8), "rgb:fbfb/f1f1/c7c7",
                          "a Session that the Terminal never showed got the Colour Report")
    }

    func testAScreensDetachGivesTheTerminalsSessionMuxifysColoursAgain() async throws {
        let work = try probe(session: "work")
        try server.run(["split-window", "-d", "-t", "work:", probeCommand(work.1)])
        _ = try startTerminal(in: "work", colours: Self.light)
        try await listenerFollowsTheTerminal(in: "work")

        try await screenWritesAndDetaches(in: "work", flags: nil)
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        for answer in [work.0, work.1] {
            await eventually("no answer from a probe") { FileManager.default.fileExists(atPath: answer) }
            XCTAssertEqual(try String(contentsOfFile: answer, encoding: .utf8), "rgb:fbfb/f1f1/c7c7", answer)
        }
    }

    func testAListenersDetachWritesNothing() async throws {
        let work = try probe(session: "work")
        _ = try startTerminal(in: "work", colours: Self.light)
        // The Listener sits in `work` before the Terminal attaches, then starts again after it and reports there: the
        // screen writes after tmux ran that report, or a slow start again writes over the screen's colours. Sent is
        // not run: tmux can run the screen's report before a report still on the Listener's connection.
        try await listenerFollowsTheTerminal(in: "work")
        XCTAssertEqual(try server.run(["list-clients", "-F", "#{client_control_mode}"]).split(separator: "\n"), ["0", "1"],
                       "the Listener came before the Terminal's Client")
        XCTAssertTrue(sent.lines.contains { $0.hasPrefix("refresh-client -r") }, "the Listener's start in the Terminal's Session did not report")

        // The publisher has handled the detach, and tmux ran anything that it sent for it, before the probe asks.
        try await screenWritesAndDetaches(in: "work", flags: "ignore-size,no-output")
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        await eventually("no answer from the probe") { FileManager.default.fileExists(atPath: work.0) }
        XCTAssertEqual(try String(contentsOfFile: work.0, encoding: .utf8), "rgb:1010/1010/1010",
                       "a Listener's detach made the publisher write")
    }

    func testAPaneOfANewSessionThatNoClientShowsAnswersOnlyAfterTheReportBeforeTyping() async throws {
        let recorder = start(sent: sent)
        try server.run(["new-session", "-d", "-s", "other"])
        try await settle(recorder, controlClients: 1)
        publishers[0].reportColours(Self.light)
        let probes = try probe(session: "made")
        let pane = try server.run(["display-message", "-p", "-t", "made:", "#{pane_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)

        publishers[0].reportColours(beforeTypingInto: pane)
        try await tmuxRanTheListenersCommands()
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        await eventually("no answer from the probe") { FileManager.default.fileExists(atPath: probes.0) }
        XCTAssertEqual(try String(contentsOfFile: probes.0, encoding: .utf8), "rgb:fbfb/f1f1/c7c7")
    }

    /// Before, each switch waited for tmux to answer its Colour Report, counting answers over the Listener's life, so
    /// one lost answer made every later switch wait a second. A Listener that does not read its commands now holds no
    /// switch up, and once it reads them it reports to every Pane of the Session that the Terminal ended in.
    func testTwelveSwitchesBetweenSessionsOfElevenAndEightPanesNeverWaitForTheColourReport() async throws {
        _ = try probes(session: "big", panes: 11)
        let answers = try probes(session: "small", panes: 8)
        let terminal = try startTerminal(in: "small", colours: Self.light)
        try await listenerFollowsTheTerminal(in: "small")
        let listener = try XCTUnwrap(sent.latest)
        let moves = { listener.heard.filter { $0.hasPrefix("%client-session-changed \(terminal.tty) ") }.count }
        let movesBefore = moves()
        let tmux = ColourReportingTmux(server: server, publisher: publishers[0])
        let pid = try XCTUnwrap(pid_t(try server.run(["list-clients", "-f", "#{client_control_mode}", "-F", "#{client_pid}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)), "no control Client")

        kill(pid, SIGSTOP)
        var slowest: TimeInterval = 0
        for target in Array(repeating: ["=big", "=small"], count: 6).joined() {
            let start = Date()
            try tmux.run(["switch-client", "-c", terminal.tty, "-t", target])
            slowest = max(slowest, Date().timeIntervalSince(start))
        }
        kill(pid, SIGCONT)

        // A switch takes a few thousandths of a second; one that waits for its Colour Report took a second.
        XCTAssertLessThan(slowest, scaled(0.5), "a switch waited for its Colour Report")
        // The Listener reads what waited for it, and the publisher reports to the Session of the last move; the probes
        // ask after tmux ran that.
        await eventually("the Listener did not hear every move") { moves() == movesBefore + 12 }
        try await tmuxRanTheListenersCommands()
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)
        for answer in answers {
            await eventually("no answer from a probe") { FileManager.default.fileExists(atPath: answer) }
            XCTAssertEqual(try String(contentsOfFile: answer, encoding: .utf8), "rgb:fbfb/f1f1/c7c7", answer)
        }
    }

    func testWithoutColoursASwitchReportsNothing() async throws {
        let probes = try probe(session: "work")
        try server.run(["new-session", "-d", "-s", "spare"])
        let terminal = try startTerminal(in: "spare", colours: nil)
        try await listenerFollowsTheTerminal(in: "spare")

        try server.run(["switch-client", "-c", terminal.tty, "-t", "=work"])
        try await eventually("the Listener did not follow the Terminal") { try self.controlClients() == ["work"] }
        try await tmuxRanTheListenersCommands()
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        await eventually("no answer from the probe") { FileManager.default.fileExists(atPath: probes.0) }
        XCTAssertNotEqual(try String(contentsOfFile: probes.0, encoding: .utf8), "rgb:fbfb/f1f1/c7c7")
    }

    /// tmux tells a program with mode 2031 of a new colour scheme at the switch, when its Terminal's differs from the
    /// one the Pane was last told. A report written after the switch then changes the answer but sends no notice, so
    /// the program would keep the other screen's look. A switch through the publisher runs on the Listener after the
    /// report: at the notice, the program gets the reported colours.
    func testAProgramThatAsksAtTheSwitchsNoticeGetsTheReportedColours() async throws {
        let notices = try themeProbe(session: "other")
        // tmux tells only a program that has turned mode 2031 on, and the other screen's report sends no notice later.
        try await colourProbes.themeProbeIsReady(notices, in: "other")
        try server.run(["new-session", "-d", "-s", "work"])
        let terminal = try startTerminal(in: "work", colours: Self.light)
        try await listenerFollowsTheTerminal(in: "work")
        try terminalSays(.light)
        try await screenWritesAndDetaches(in: "other", flags: "ignore-size,no-output", hearingTheDetach: false)
        await eventually("the probe was not told dark") { self.lines(notices).last == "dark" }

        XCTAssertTrue(try publishers[0].switchClient(terminal.tty, to: "=other:"), "no Listener took the switch")

        try await eventually("the Terminal did not move") { try self.clientSession(terminal.tty) == "other" }
        await eventually("the probe was not told light") { self.lines(notices).last?.hasPrefix("light") == true }
        XCTAssertEqual(lines(notices).last, "light rgb:fbfb/f1f1/c7c7", "the program at the notice got other colours")
        try await eventually("the Listener did not follow the Terminal") { try self.controlClients() == ["other"] }
    }

    /// The report goes before the switch, on one connection, and the Terminal's move that follows does not write the
    /// Session again. With no Listener, the publisher takes no switch, and the move writes.
    func testASwitchThroughThePublisherWritesItsSessionOnceBeforeTheSwitch() async throws {
        let other = try probe(session: "other")
        try server.run(["split-window", "-d", "-t", "other:", probeCommand(other.1)])
        try server.run(["new-session", "-d", "-s", "work"])
        let terminal = try startTerminal(in: "work", colours: Self.light)
        try await listenerFollowsTheTerminal(in: "work")
        sent.clear()

        XCTAssertTrue(try publishers[0].switchClient(terminal.tty, to: "=other:"))
        try await eventually("the Listener did not follow the Terminal") { try self.controlClients() == ["other"] }
        // The publisher has handled the Terminal's move, and tmux ran what it sent for it.
        try await tmuxRanTheListenersCommands()

        let panes = try server.run(["list-panes", "-s", "-t", "=other", "-F", "#{pane_id}"]).split(separator: "\n").map(String.init)
        let report = ColourReport.commands(panes: panes, colours: Self.light)
        let switchLine = try XCTUnwrap(sent.lines.firstIndex { $0.hasPrefix("'switch-client'") }, "\(sent.lines)")
        XCTAssertEqual(Array(sent.lines[..<switchLine]), report, "the report did not go just before the switch")
        XCTAssertEqual(sent.lines.filter { $0.hasPrefix("refresh-client -r") }, report, "the move wrote the Session again")
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)
        for answer in [other.0, other.1] {
            await eventually("no answer from a probe") { FileManager.default.fileExists(atPath: answer) }
            XCTAssertEqual(try String(contentsOfFile: answer, encoding: .utf8), "rgb:fbfb/f1f1/c7c7", answer)
        }

        publishers[0].stop()
        try await eventually("the Listener did not detach") { try self.controlClients().isEmpty }
        XCTAssertFalse(try publishers[0].switchClient(terminal.tty, to: "=work:"), "a switch went to no Listener")
    }

    func testAFocusChangeInTheWindowThatTheTerminalShowsReachesTheSubscriber() async throws {
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        let second = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "work:"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try server.run(["new-session", "-d", "-s", "other"])
        let otherPane = try server.run(["split-window", "-d", "-P", "-F", "#{pane_id}", "-t", "other:"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let news = NewsLog()
        _ = try startTerminal(in: "work", colours: Self.light, news: news)
        try await listenerFollowsTheTerminal(in: "work")
        // The news of the Terminal's and the Listener's arrival.
        await settled("the news did not stop") { news.lines }
        let shown = try windowID("work:")
        news.clear()

        try server.run(["select-pane", "-t", second])
        await eventually("the focus change did not reach the subscriber") { news.lines.contains("focus " + shown) }

        try server.run(["select-pane", "-t", otherPane])
        // absence: no focus news follows a focus change in a Session that the Terminal does not show.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(news.lines.filter { $0.hasPrefix("focus") }, ["focus " + shown],
                       "a focus change in a Session that the Terminal does not show reached the subscriber")

        let added = try server.run(["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "work:"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try server.run(["select-window", "-t", added])
        await eventually("the Session's new Window did not reach the subscriber") { news.lines.contains("focus " + added) }
    }

    func testAnotherClientThatMovesIntoTheTerminalsSessionTakesTheShownWindow() async throws {
        try server.run(["new-session", "-d", "-s", "work", "-x", "80", "-y", "24"])
        let news = NewsLog()
        _ = try startTerminal(in: "work", colours: Self.light, news: news)
        try await listenerFollowsTheTerminal(in: "work")
        let shown = try windowID("work:")
        news.clear()

        let screen = try controlClient(attachingTo: "work")
        defer { screen.terminate() }

        await eventually("another Client's move into the Terminal's Session did not reach the subscriber") {
            news.lines.contains("taken " + shown)
        }
    }

    func testWritingAWindowWritesOnlyThatWindowsPanes() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        let painted = try probe(session: "paint")
        try server.run(["split-window", "-d", "-t", "paint:", probeCommand(painted.1)])
        let unpainted = directory.appendingPathComponent("paint-3").path
        try server.run(["new-window", "-d", "-t", "paint:", probeCommand(unpainted)])
        _ = try startTerminal(in: "work", colours: Self.light)
        // A report sent to a Listener that then starts again can be lost with it.
        try await listenerFollowsTheTerminal(in: "work")

        publishers[0].reportColours(toWindow: try windowID("paint:^"))
        try await tmuxRanTheListenersCommands()
        try "".write(toFile: directory.appendingPathComponent("go").path, atomically: true, encoding: .utf8)

        for answer in [painted.0, painted.1] {
            await eventually("no answer from a probe") { FileManager.default.fileExists(atPath: answer) }
            XCTAssertEqual(try String(contentsOfFile: answer, encoding: .utf8), "rgb:fbfb/f1f1/c7c7", answer)
        }
        await eventually("no answer from the probe") { FileManager.default.fileExists(atPath: unpainted) }
        XCTAssertNotEqual(try String(contentsOfFile: unpainted, encoding: .utf8), "rgb:fbfb/f1f1/c7c7",
                          "a Pane of another Window got the colours")
    }

    // MARK: - Helpers

    /// What the publisher told its in-process subscriber of focus: `focus @w` and `taken @w`.
    private final class NewsLog: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return log }
        func clear() { lock.lock(); log = []; lock.unlock() }
        func add(_ news: EnvironmentPublisher.News) {
            let line: String
            switch news {
            case .focusChanged(let window): line = "focus " + window
            case .taken(let window): line = "taken " + window
            case .heard, .readFailed: return
            }
            lock.lock(); log.append(line); lock.unlock()
        }
    }

    private func windowID(_ target: String) throws -> String {
        try server.run(["display-message", "-p", "-t", target, "#{window_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A control Client of another screen, as Muxify Mobile is one, attached to `session`.
    private func controlClient(attachingTo session: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(server.binary))
        process.arguments = ["-S", socket, "-f", "/dev/null", "-C", "attach-session", "-t", session]
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        process.environment = environment
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        otherProcesses.append(process)
        return process
    }

    private enum Theme: String { case dark = "1", light = "2" }

    /// The Terminal's Client tells tmux the colour scheme of its terminal, as Ghostty does when asked.
    private func terminalSays(_ theme: Theme) throws {
        try ColourProbes.terminalSays(theme == .dark ? 1 : 2, through: clientProcess)
    }

    private var colourProbes: ColourProbes { ColourProbes(directory: directory, server: server) }

    private func themeProbe(session: String) throws -> String {
        try colourProbes.themeProbe(session: session)
    }

    private func lines(_ path: String) -> [String] {
        colourProbes.lines(path)
    }

    private func clientSession(_ tty: String) throws -> String {
        try server.run(["display-message", "-p", "-c", tty, "#{client_session}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - tmux's status line (ADR 0099)

    func testWhileTheHeaderShowsTheSessionEachSessionTheTerminalShowsHasNoStatusLine() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        try server.run(["new-session", "-d", "-s", "other"])
        try server.run(["new-session", "-d", "-s", "third"])
        let terminal = try startTerminal(in: "work", colours: nil, hidingStatusLine: true)
        try await eventually("the Terminal's Session kept its status line") { try self.sessionStatus("work") == "off" }
        XCTAssertNil(try sessionStatus("other"), "a Session that the Terminal never showed lost its status line")
        try await eventually("the Listener did not move to the Terminal's Session") { try self.controlClients() == ["work"] }

        XCTAssertTrue(try publishers[0].switchClient(terminal.tty, to: "=other"), "no Listener ran the switch")
        try await eventually("a switch that Muxify started kept the status line") { try self.sessionStatus("other") == "off" }

        try server.run(["switch-client", "-c", terminal.tty, "-t", "=third"])
        try await eventually("a switch made inside tmux kept the status line") { try self.sessionStatus("third") == "off" }
        XCTAssertEqual(try sessionStatus("work"), "off", "the Terminal's own arrival gave the status line back")
    }

    func testAnotherTerminalThatArrivesInAHiddenSessionGetsTheStatusLineBack() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        try server.run(["new-session", "-d", "-s", "other"])
        try server.run(["set-option", "-t", "=other:", "status", "2"])
        _ = try startTerminal(in: "work", colours: nil, hidingStatusLine: true)
        try await eventually("the Terminal's Session kept its status line") { try self.sessionStatus("work") == "off" }
        try await waitForTheHooks()

        let screen = try attachClient(to: "other")
        try server.run(["switch-client", "-c", screen.tty, "-t", "=work"])
        try await eventually("another terminal's move did not give the status line back") { try self.sessionStatus("work") == nil }
        XCTAssertEqual(try sessionStatus("other"), "2", "the hook changed a status line that Muxify did not hide")
        XCTAssertEqual(try server.run(["show-options", "-qv", "-t", "=work:", TmuxStatusLine.marker]), "", "the mark stayed")
    }

    func testTurningItOffGivesEveryHiddenSessionItsStatusLineBackAndRemovesTheHooks() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        try server.run(["new-session", "-d", "-s", "other"])
        try server.run(["set-option", "-t", "=other:", "status", "2"])
        let terminal = try startTerminal(in: "work", colours: nil, hidingStatusLine: true)
        // The Listener hides the status line once it starts again in the Terminal's Session. A hide on a connection
        // that tmux has not run yet can come after the give-back, so the test turns it off once tmux ran the hide.
        try await listenerFollowsTheTerminal(in: "work")
        XCTAssertEqual(try sessionStatus("work"), "off", "the Terminal's Session kept its status line")
        try await waitForTheHooks()

        publishers[0].hideStatusLine(false)
        try await tmuxRanTheListenersCommands()
        XCTAssertEqual(try sessionStatus("work"), nil, "the Terminal's Session did not get its status line back")
        XCTAssertFalse(try server.run(["show-hooks", "-g"]).contains("[77]"), "Muxify's hooks stayed")
        XCTAssertEqual(try sessionStatus("other"), "2", "a status line that Muxify did not hide changed")

        try server.run(["switch-client", "-c", terminal.tty, "-t", "=other"])
        try await eventually("the Listener did not follow the Terminal") { try self.controlClients() == ["other"] }
        try await tmuxRanTheListenersCommands()
        XCTAssertEqual(try sessionStatus("other"), "2", "a move hid the status line while the header does not show the Session")
    }

    /// Muxify's hooks come after `status off` on the Listener's connection, so a Session can lose its status line
    /// before they are set.
    private func waitForTheHooks() async throws {
        try await eventually("no hook gives the status line back") {
            let hooks = try self.server.run(["show-hooks", "-g"])
            return hooks.contains("client-attached[77]") && hooks.contains("client-session-changed[77]")
        }
    }

    private static let light = ColourProbes.light
    private static let dark = ColourProbes.dark

    /// A publisher with a Client marker, a Terminal's Client attached to `session` that the marker names, and the
    /// colours of the key App Window, or none.
    private func startTerminal(in session: String, colours: TerminalColours?, news: NewsLog? = nil,
                               hidingStatusLine: Bool = false) throws -> ViewCommandExecutor.Client {
        let marker = ClientMarker.option(nonce: "terminal")
        _ = start(clientMarker: marker, sent: sent, news: news)
        publishers[0].reportColours(colours)
        if hidingStatusLine { publishers[0].hideStatusLine(true) }
        // Muxify sets it for its Terminal's processes, on this Mac and over SSH.
        let terminal = try attachClient(to: session, environment: ["MUXIFY_TERMINAL": "1"])
        let value = [String(terminal.pid), terminal.tty, "/Users/u", "mac", "local"].joined(separator: Tmux.separator)
        try server.run(["set-option", "-sq", marker, value])
        return terminal
    }

    /// Another screen, as Muxify Mobile is: a control Client in `session`, attached with `flags`, writes its own
    /// colours to every Pane of the Session and detaches once the publisher has read it. Then, `hearingTheDetach`, it
    /// waits until the publisher handled the detach and tmux ran what the publisher sent for it.
    private func screenWritesAndDetaches(in session: String, flags: String?, hearingTheDetach: Bool = true) async throws {
        try await colourProbes.screenWritesAndDetaches(in: session, flags: flags, afterAttach: { await self.publishers[0].read() },
                                                       afterDetach: { screen in
            if hearingTheDetach { try await self.listenerHeardTheDetach(of: screen) }
        })
    }

    /// Waits until the publisher has handled what came before, in a read of its own too, and tmux has run every command
    /// it sent its Listener so far: tmux runs one connection's commands in order, so it answers one sent after them
    /// last.
    private func tmuxRanTheListenersCommands() async throws {
        await publishers[0].read()
        let connection = try XCTUnwrap(sent.latest, "no Listener started")
        let ping = connection.ping()
        await eventually("tmux did not run the Listener's commands") { connection.heard.contains(ping) }
        await publishers[0].caughtUp()
    }

    /// Waits until the Listener sits in `session`, the Terminal's, on a connection that the publisher started there
    /// once it knew the Terminal's Client, and tmux ran what the publisher sent it. Before that the Listener sits in
    /// the Session that tmux picks, and then starts again: a report or a hide sent before the start can run after a
    /// test's next step, or go with the connection that ends.
    private func listenerFollowsTheTerminal(in session: String) async throws {
        try await eventually("the Listener did not start again in the Terminal's Session") {
            guard let connection = sent.latest, connection.followsTheTerminal, connection.attached else { return false }
            return try controlClients() == [session]
        }
        try await tmuxRanTheListenersCommands()
    }

    /// Waits until the Listener heard `screen`, a Client's name, detach, and tmux ran what the publisher sent for it.
    private func listenerHeardTheDetach(of screen: String) async throws {
        let connection = try XCTUnwrap(sent.latest, "no Listener started")
        await eventually("the Listener did not hear the screen detach") { connection.heard.contains("%client-detached " + screen) }
        try await tmuxRanTheListenersCommands()
    }

    private func probe(session: String) throws -> (String, String) {
        try colourProbes.probe(session: session)
    }

    private func probes(session: String, panes: Int) throws -> [String] {
        try colourProbes.probes(session: session, panes: panes)
    }

    private func probeCommand(_ answer: String) -> String {
        colourProbes.probeCommand(answer)
    }

    // MARK: - Board Sessions

    func testABoardSessionThatEndsOnTheSameServerLeavesTheBoardAndATmuxRestartKeepsItDormant() async throws {
        for name in ["work", "notes", "scratch"] { try server.run(["new-session", "-d", "-s", name]) }
        try server.run(["new-window", "-d", "-t", "=scratch:"])
        let service = EnvironmentService(paths: paths, server: server)
        for name in ["notes", "scratch"] {
            guard case .changed = service.handle(EnvironmentRequest(.makeGuest, target: .sessionName(name))) else { return XCTFail(name) }
        }
        let store = TopicStore(paths: paths)
        let recorder = start()
        await eventually("no first item") { recorder.server?.isRunning == true }
        let first = try XCTUnwrap(recorder.server?.serverID)

        try server.run(["kill-session", "-t", "=notes"])
        try await eventually("the row of a Board Session that ended on the same server stayed") {
            try store.read().boardSessions.map(\.name) == ["scratch"]
        }

        try server.run(["kill-server"])
        // A new Session that reaches the server while it exits fails with "server exited unexpectedly".
        try await serverExited()
        try server.run(["new-session", "-d", "-s", "work"])
        await eventually("the publisher did not read the new server") {
            recorder.server?.isRunning == true && recorder.server?.serverID != first
        }
        // The read after the one that found the new server keeps the Board Session too.
        await publishers[0].read()
        let dormant = try XCTUnwrap(store.read().boardSessions.first, "a tmux restart took the Board Session off the Board")
        XCTAssertEqual(dormant.name, "scratch")
        XCTAssertEqual(dormant.session["windows"]?.array?.count, 2, "the Board Session keeps the Windows to Reopen")
        XCTAssertTrue(recorder.items.joined().contains { if case .boardSessions(let boardSessions) = $0 { boardSessions.map(\.id) == [dormant.id] } else { false } },
                      "the Board Sessions go out on the subscription")
    }

    func testACardThatAnOlderMuxifyKeptInTmuxIsImportedOnce() async throws {
        try server.run(["new-session", "-d", "-s", "work"])
        try server.run(["new-session", "-d", "-s", "notes"])
        try server.run(["set-option", "-t", "=notes:", BoardSession.legacyOption, "7"])
        let store = TopicStore(paths: paths)
        _ = start()
        try await eventually("the Board Session was not imported") { try store.read().boardSessions.count == 1 }
        let boardSession = try XCTUnwrap(store.read().boardSessions.first)
        XCTAssertEqual(boardSession.order, 7, "the Board Session keeps its order")
        XCTAssertEqual(boardSession.name, "notes")
        try await eventually("the option stayed") {
            try self.server.run(["show-options", "-qv", "-t", "=notes:", BoardSession.legacyOption]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        XCTAssertEqual(try server.run(["show-options", "-qv", "-t", "=notes:", "@muxify_session_id"]).trimmingCharacters(in: .whitespacesAndNewlines),
                       boardSession.id, "the Session points at its new Board Session")
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

    private func start(clientMarker: String? = nil, sent: SentLines? = nil, news: NewsLog? = nil) -> Recorder {
        let recorder = Recorder()
        let startControlClient: TmuxControlClientStart = sent?.recording() ?? PipeControlClient.start
        let publisher = EnvironmentPublisher(server: server, topics: TopicStore(paths: paths),
                                             delivery: DispatchQueue(label: "test.environment-events"),
                                             startControlClient: startControlClient, clientMarker: clientMarker)
        publishers.append(publisher)
        if let news {
            publisher.start(news: news.add) { changes, _ in recorder.add(changes) }
        } else {
            publisher.start(recorder.add)
        }
        return recorder
    }

    /// Waits for the control Clients, then for a quiet moment, and forgets what came before.
    private func settle(_ recorder: Recorder, controlClients count: Int) async throws {
        try await eventually("the publisher did not attach its Listener") { try self.controlClients().count == count }
        await settled("the publisher did not settle") { recorder.items }
        recorder.clear()
    }

    /// How soon a change's event comes. The format subscription, which tmux checks each second, sees a change that
    /// has no notification within its second and a read, at most about 1.1 s, where the whole read every 5 s could
    /// take longer; a notification's change comes in a few tenths.
    private static let soon = scaled(4.5)

    /// Waits for the first event, which comes `soon`, then a little longer for any other, and checks that only `key`
    /// came.
    private func expectOnly(_ key: String, from recorder: Recorder, _ change: String) async throws {
        let start = Date()
        await eventually("no event of \(change)") { !recorder.items.isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(start), Self.soon, "the event of \(change) came late")
        // absence: no event of another key follows the change.
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

    /// Waits until no server answers on the socket.
    private func serverExited(_ message: String = "the server did not exit") async throws {
        await eventually(message) {
            do { _ = try server.run(["display-message", "-p", "#{pid}"]); return false } catch {
                return (error as? TmuxError)?.indicatesNoServer == true
            }
        }
    }

    private func sessions() throws -> [String] {
        ((try? server.run(["list-sessions", "-F", "#{session_name}"])) ?? "").split(separator: "\n").map(String.init)
    }

    /// A Client attached to `session` in a pseudo-terminal, as a Terminal is: its tty and pid. The first is the
    /// Terminal's; a later one is another terminal. `environment` adds to the Client's environment.
    private func attachClient(to session: String, environment extra: [String: String] = [:]) throws -> ViewCommandExecutor.Client {
        let attachedBefore = Set(try nonControlClients().map(\.tty))
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
        environment.merge(extra) { $1 }
        process.environment = environment
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        if clientProcess == nil { clientProcess = process } else { otherProcesses.append(process) }
        var attached: ViewCommandExecutor.Client?
        try eventually("the Client did not attach") {
            attached = try nonControlClients().first { !attachedBefore.contains($0.tty) }
            return attached != nil
        }
        guard let attached else { throw TmuxError.timedOut }
        return attached
    }

    private func nonControlClients() throws -> [ViewCommandExecutor.Client] {
        ((try? server.run(["list-clients", "-f", "#{==:#{client_control_mode},0}", "-F", "#{client_tty} #{client_pid}"])) ?? "")
            .split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ")
                guard fields.count == 2, let pid = Int(fields[1]) else { return nil }
                return ViewCommandExecutor.Client(tty: String(fields[0]), pid: pid)
            }
    }

    /// The `status` that `session` sets itself, such as `off`; nil when it takes the global one.
    private func sessionStatus(_ session: String) throws -> String? {
        let value = try server.run(["show-options", "-qv", "-t", "=" + session + ":", "status"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
