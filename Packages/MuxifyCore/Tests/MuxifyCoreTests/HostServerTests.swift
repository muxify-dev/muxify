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
    /// The Host's `TMPDIR`, where uploads go.
    private var uploads: URL { directory.appendingPathComponent("tmp", isDirectory: true) }

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
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
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

    // MARK: - Capabilities and Request ids

    func testTheServerDeclaresItsCapabilitiesAndAClientThatDeclaredNoneGetsNoneOfThem() async throws {
        let client = try await connect()
        let session = try await client.connect()
        XCTAssertEqual(session.peerCapabilities, ["request", "snapshot", "topic-detail", "ranked-session-paths", "browser-tabs"])
        let recorder = subscribe(client)
        try await wait("no first item") { !recorder.items.isEmpty }
        let before = try windows(of: "work")

        let request = EnvironmentRequest(.newWindow(command: nil), target: .sessionName("work"), request: RequestID(UUID().uuidString))
        do {
            _ = try await client.call(HostRequest.environment(request), as: EnvironmentResponse.self)
            XCTFail("a Request id from a client that did not declare request must not run")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .unsupported)
            XCTAssertTrue(error.message.contains("request"), error.message)
        }
        XCTAssertEqual(try windows(of: "work"), before, "the refused request changed the Host")

        _ = try await client.call(HostRequest.environment(EnvironmentRequest(.create(title: "Plain"))), as: EnvironmentResponse.self)
        try await wait("the created Topic's event did not come") { recorder.keys.contains { $0.hasPrefix("topic ") } }
        let base = ["session ", "topic ", "open_places", "server"]
        for key in recorder.keys {
            XCTAssertTrue(base.contains { key.hasPrefix($0) }, "a client that declared no capability got the key \(key)")
        }
    }

    func testAWriteWithARequestIDSentTwiceChangesTheHostOnceAndGivesTheFirstAnswerBothTimes() async throws {
        let client = try await connect(capabilities: ["request"])
        let before = try windows(of: "work")
        let request = HostRequest.environment(EnvironmentRequest(.newWindow(command: nil), target: .sessionName("work"),
                                                                 request: RequestID(UUID().uuidString)))

        let first = try await client.call(request, as: EnvironmentResponse.self)
        let second = try await client.call(request, as: EnvironmentResponse.self)

        guard case .changed(let change) = first, let window = change.window else { return XCTFail("unexpected \(first)") }
        XCTAssertEqual(second, first)
        XCTAssertEqual(try windows(of: "work"), before + [window.rawValue])
    }

    func testAClashAReadAndARequestInDoubtEachFailWithAKindOfTheirOwn() async throws {
        let client = try await connect(capabilities: ["request"])
        let id = RequestID(UUID().uuidString)
        _ = try await client.call(HostRequest.environment(EnvironmentRequest(.newWindow(command: nil), target: .sessionName("work"), request: id)),
                                  as: EnvironmentResponse.self)
        let before = try windows(of: "work")

        let clash = try await failure(of: EnvironmentRequest(.create(title: "Other"), request: id), from: client)
        XCTAssertEqual(clash?.kind, .requestClash)
        XCTAssertEqual(clash?.phase, .nothingChanged)
        XCTAssertEqual(try TopicStore(paths: paths).read().records.count, 0, "the clash made a Topic")

        let read = try await failure(of: EnvironmentRequest(.list, request: RequestID(UUID().uuidString)), from: client)
        XCTAssertEqual(read?.kind, .requestOnRead)

        // A first send that wrote its records and never finished: the store writes the `started` row with them.
        let started = EnvironmentRequest(.newWindow(command: nil), target: .sessionName("work"), request: RequestID(UUID().uuidString))
        try TopicStore(paths: paths, request: PendingRequest(started)).write { try $0.create(TopicRecord(id: "t", title: "T")) }
        let inDoubt = try await failure(of: started, from: client)
        XCTAssertEqual(inDoubt?.kind, .requestInDoubt)
        XCTAssertEqual(inDoubt?.phase, .recordSaved)
        XCTAssertEqual(try windows(of: "work"), before, "a refused Request changed tmux")
    }

    func testTwoHostServersOnOneDatabaseApplyOneRequestIDOneTime() async throws {
        let one = try await connect(context: HostServerContext(paths: paths, tmux: tmux, socketID: "one", temporaryDirectory: uploads.path),
                                    capabilities: ["request"])
        let two = try await connect(context: HostServerContext(paths: paths, tmux: tmux, socketID: "two", temporaryDirectory: uploads.path),
                                    capabilities: ["request"])
        let before = try windows(of: "work")
        let request = HostRequest.environment(EnvironmentRequest(.newWindow(command: nil), target: .sessionName("work"),
                                                                 request: RequestID(UUID().uuidString)))

        async let first = one.call(request, as: EnvironmentResponse.self)
        async let second = two.call(request, as: EnvironmentResponse.self)
        let answers = try await [first, second]

        XCTAssertEqual(answers[0], answers[1])
        XCTAssertEqual(try windows(of: "work").count, before.count + 1)
    }

    // MARK: - The topic subscription

    func testATopicSubscriptionPushesTheDetailFirstThenAfterASplitAndARenameAsShowAnswersIt() async throws {
        try TopicStore(paths: paths).write { try $0.create(TopicRecord(id: "t", title: "Topic")) }
        try tmux.run(["set-option", "-t", "=work:", "@muxify_topic", "t"])
        let client = try await connect(capabilities: ["topic-detail"])
        let recorder = subscribe(client, topic: "t")

        try await wait("no first item") { !recorder.items.isEmpty }
        let first = try XCTUnwrap(recorder.detail)
        XCTAssertEqual(first.label, "Topic")
        XCTAssertEqual(first.sessions.map(\.name), ["work"])
        XCTAssertEqual(first.sessions.first?.windows.first?.panes.count, 1)
        try await settle(recorder)
        let show = HostRequest.environment(EnvironmentRequest(.show, target: .topic(.id("t"))))
        let shown = try await client.call(show, as: EnvironmentResponse.self)
        XCTAssertEqual(recorder.latest, .some(shown), "the item is not what show answers")

        try tmux.run(["split-window", "-d", "-t", "=work:"])
        try await wait("a split of the Topic's Session did not push its detail") { recorder.detail?.sessions.first?.windows.first?.panes.count == 2 }
        try await settle(recorder)

        _ = try await client.call(HostRequest.environment(EnvironmentRequest(.rename(title: "Renamed"), target: .topic(.id("t")))),
                                  as: EnvironmentResponse.self)
        // The server reads again before it answers, so the new detail came before the `end`.
        try await wait("the rename's detail did not come before the answer", seconds: 0.15) { recorder.detail?.label == "Renamed" }
        XCTAssertEqual(recorder.items.count, 1, "one change pushed more than one item")
        let renamed = try await client.call(show, as: EnvironmentResponse.self)
        XCTAssertEqual(recorder.latest, .some(renamed), "the item is not what show answers")
    }

    func testForgettingTheTopicPushesANullItem() async throws {
        let client = try await connect(capabilities: ["topic-detail"])
        let created = try await client.call(HostRequest.environment(EnvironmentRequest(.create(title: "Gone"))), as: EnvironmentResponse.self)
        guard case .changed(let change) = created, let id = change.topicID else { return XCTFail("unexpected \(created)") }
        let recorder = subscribe(client, topic: id)
        try await wait("no first item") { recorder.detail?.label == "Gone" }

        _ = try await client.call(HostRequest.environment(EnvironmentRequest(.forget(choices: [], worktrees: []), target: .topic(.id(id)))),
                                  as: EnvironmentResponse.self)

        try await wait("forgetting the Topic did not push null") { recorder.items.count == 2 }
        XCTAssertEqual(recorder.items.last, .some(nil))
    }

    func testTwoTopicSubscriptionsOnOneChannelPushApartAndCancellingOneLeavesTheOther() async throws {
        try TopicStore(paths: paths).write { transaction in
            try transaction.create(TopicRecord(id: "a", title: "A"))
            try transaction.create(TopicRecord(id: "b", title: "B"))
        }
        let client = try await connect(capabilities: ["topic-detail"])
        let a = subscribe(client, topic: "a")
        let b = subscribe(client, topic: "b")
        try await wait("no first items") { a.detail?.label == "A" && b.detail?.label == "B" }
        try await settle(a)
        try await settle(b)

        try await rename("a", to: "A2", on: client)
        try await wait("the rename of a did not push a") { a.detail?.label == "A2" }
        XCTAssertTrue(b.items.isEmpty, "the rename of a pushed b")

        a.cancel()
        try await wait("the cancel did not end the subscription") { a.ended }
        try await rename("b", to: "B2", on: client)
        try await wait("cancelling a ended b") { b.detail?.label == "B2" }
    }

    func testAClientThatDidNotDeclareTopicDetailGetsUnsupportedForATopicSubscription() async throws {
        let client = try await connect()
        let events = client.subscribe(HostRequest.subscribe(.topic(TopicSubscription(id: "t"))), as: TopicDetailItem.self)
        do {
            for try await item in events { XCTFail("an item came: \(String(describing: item))") }
            XCTFail("the subscription ended ok")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .unsupported)
            XCTAssertTrue(error.message.contains("topic-detail"), error.message)
        }
    }

    private func rename(_ topic: String, to title: String, on client: ProtocolClient) async throws {
        _ = try await client.call(HostRequest.environment(EnvironmentRequest(.rename(title: title), target: .topic(.id(topic)))),
                                  as: EnvironmentResponse.self)
    }

    /// The `TopicFailure` that a request ends with; nil, with a failure of the test, when it ends otherwise.
    private func failure(of request: EnvironmentRequest, from client: ProtocolClient) async throws -> TopicFailure? {
        do {
            let response = try await client.call(HostRequest.environment(request), as: EnvironmentResponse.self)
            XCTFail("the request ended ok: \(response)")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .failed)
            XCTAssertEqual(error.message, error.topicFailure?.message)
            return error.topicFailure
        }
        return nil
    }

    private func windows(of session: String) throws -> [String] {
        try tmuxOutput(["list-windows", "-t", "=" + session + ":", "-F", "#{window_id}"]).split(separator: "\n").map(String.init)
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

    // MARK: - The config subscription

    /// A context whose Host home is `home` in the run's directory, where its Config lives.
    private func configContext() -> (HostServerContext, home: URL) {
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let hostPaths = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("state").path], home: home.path)
        return (HostServerContext(paths: hostPaths, tmux: tmux, home: home.path), home)
    }

    private func subscribeConfig(_ client: ProtocolClient) -> ConfigRecorder {
        let recorder = ConfigRecorder()
        let configs = client.subscribe(HostRequest.subscribe(.config), as: HostConfig.self)
        consumers.append(Task {
            do {
                for try await config in configs { recorder.add(config) }
            } catch {}
        })
        return recorder
    }

    func testTheFirstConfigItemCarriesTheHostsTextAndAnEditPushesTheNewText() async throws {
        let (context, home) = configContext()
        let folder = home.appendingPathComponent(".config/muxify", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("config.yaml")
        try "ui:\n  header_height: 30\noverride: ~/machine.yaml\n".write(to: file, atomically: true, encoding: .utf8)
        try "ui:\n  header_height: 40\n".write(to: home.appendingPathComponent("machine.yaml"), atomically: true, encoding: .utf8)
        let client = try await connect(context: context)
        let recorder = subscribeConfig(client)

        try await wait("no first config item") { !recorder.items.isEmpty }
        let first = try XCTUnwrap(recorder.items.first)
        XCTAssertEqual(first.path, file.path)
        XCTAssertEqual(first.shownPath, "~/.config/muxify/config.yaml")
        XCTAssertEqual(first.text, "ui:\n  header_height: 30\noverride: ~/machine.yaml\n")
        XCTAssertEqual(first.overrides, [HostConfig.Override(path: "~/machine.yaml", text: "ui:\n  header_height: 40\n")])

        // An edit in place, as `echo >>` makes it, and an editor's save, which renames a new file over it.
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("sidebar:\n  agents: false\n".utf8))
        try handle.close()
        try await wait("an edit of the Config pushed nothing", seconds: 5) {
            recorder.items.last?.text?.hasSuffix("sidebar:\n  agents: false\n") == true
        }
        try "ui:\n  header_height: 50\n".write(to: home.appendingPathComponent("machine.yaml"), atomically: true, encoding: .utf8)
        try await wait("an edit of a Config Override pushed nothing", seconds: 5) {
            recorder.items.last?.overrides.first?.text == "ui:\n  header_height: 50\n"
        }
    }

    func testAHostWithNoConfigPushesMissingAndThenTheConfigItGets() async throws {
        let (context, home) = configContext()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let client = try await connect(context: context)
        let recorder = subscribeConfig(client)

        try await wait("no first config item") { !recorder.items.isEmpty }
        let first = try XCTUnwrap(recorder.items.first)
        XCTAssertTrue(first.isMissing, "a Host with no Config pushes missing: \(first)")
        XCTAssertEqual(first.path, home.appendingPathComponent(".config/muxify/config.yaml").path)

        // Not even the Config's folder was there: the watch of the folder above it hears it made.
        let folder = home.appendingPathComponent(".config/muxify", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "ui:\n  header_height: 30\n".write(to: folder.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try await wait("a new Config pushed nothing", seconds: 5) { recorder.items.last?.text == "ui:\n  header_height: 30\n" }

        try FileManager.default.removeItem(at: folder.appendingPathComponent("config.yaml"))
        try await wait("removing the Config did not push missing", seconds: 5) { recorder.items.last?.isMissing == true }
    }

    // MARK: - Worktrees on the Host (ADR 0090)

    func testAdoptWorktreesTakesNewRowsAndSkipsAnIDOrAPathThatTheHostHas() async throws {
        let host = MuxifyWorktreeStore(paths: paths)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try host.write(MuxifyWorktreeRecord(id: "here", repository: "/src/app", name: "here", path: "/trees/app/here", branch: "here", base: "a",
                                            createdAt: date))
        let new = MuxifyWorktreeRecord(id: "new", repository: "/src/app", name: "new", path: "/trees/app/new", branch: "new", base: "b",
                                       createdAt: date)
        let sameID = MuxifyWorktreeRecord(id: "here", repository: "/src/app", name: "other", path: "/trees/app/other", branch: "o", base: "c",
                                          createdAt: date)
        let samePath = MuxifyWorktreeRecord(id: "twin", repository: "/src/app", name: "here", path: "/trees/app/here", branch: "t", base: "d",
                                            createdAt: date)
        let client = try await connect()

        let answer = try await client.call(HostRequest.adoptWorktrees(AdoptWorktrees(rows: [new, sameID, samePath])), as: AdoptedWorktrees.self)

        XCTAssertEqual(answer.rows.map(\.id), ["new", "here", "twin"])
        XCTAssertEqual(answer.rows.map(\.result), [.taken, .skipped, .skipped])
        XCTAssertNil(answer.rows[0].reason)
        XCTAssertEqual(answer.rows[1].reason, "a Muxify Worktree record with the id here is on the Host already")
        XCTAssertEqual(answer.rows[2].reason, "a Muxify Worktree record at /trees/app/here is on the Host already")
        XCTAssertEqual(try host.all().map(\.id).sorted(), ["here", "new"])
        XCTAssertEqual(host.record("new"), new, "the taken row is the Host's record, with no Environment")
        XCTAssertEqual(host.record("here")?.name, "here", "a skipped row changes nothing")
    }

    func testCreateWorktreeOnTheServerWritesTheHostsRecordUnderTheHostsRootAndTheStartsListItsBranches() async throws {
        let repository = directory.appendingPathComponent("app").path
        try git(["init", "-q", "-b", "main", repository], in: directory.path)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: repository)
        try git(["branch", "feature"], in: repository)
        let client = try await connect()

        let starts = try await client.call(HostRequest.worktreeStarts(WorktreeStartsRequest(from: repository)), as: WorktreeStarts.self)
        XCTAssertEqual(Set(starts.starts.map(\.branch)), ["main", "feature"])
        XCTAssertNotNil(starts.starts.first { $0.branch == "main" }?.checkedOutAt)

        let response = try await client.call(HostRequest.environment(EnvironmentRequest(.createWorktree(name: "fix", from: repository, start: .head,
                                                                                                        open: false))),
                                             as: EnvironmentResponse.self)
        guard case .changed(let change) = response, let id = change.worktreeID else { return XCTFail("unexpected \(response)") }
        let record = try XCTUnwrap(MuxifyWorktreeStore(paths: paths).record(id), "the Host's database has no record")
        let root = Folder.local(paths.worktrees.path).real
        XCTAssertEqual(record.path, root + "/app/fix", "the Worktree goes under the Host's $XDG_STATE_HOME/muxify/worktrees")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path + "/.git"))
        XCTAssertEqual(record.branch, "fix")

        let listed = try await client.call(HostRequest.environment(EnvironmentRequest(.listWorktrees(all: true, from: nil))),
                                           as: EnvironmentResponse.self)
        guard case .worktrees(let worktrees) = listed else { return XCTFail("unexpected \(listed)") }
        XCTAssertEqual(worktrees.map(\.id), [id])
    }

    // MARK: - Session paths

    func testSessionPathsReturnsTheServersFoldersForTheRootsAndTheirDepth() async throws {
        let projects = directory.appendingPathComponent("projects")
        for folder in ["alpha", "beta/inner", ".hidden"] {
            try FileManager.default.createDirectory(at: projects.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let client = try await connect()
        func folders(depth: Int) async throws -> [String] {
            let roots = [SessionPathRoot(path: projects.path, depth: depth)]
            let answer = try await client.call(HostRequest.sessionPaths(SessionPathsRequest(roots: roots)), as: SessionPathsOutput.self)
            let output = try XCTUnwrap(answer.output, "discovery ran on the server and printed nothing")
            return SessionPathDiscovery.sessionPaths(in: output, roots: roots, aliases: [:]).map { $0.folder.path }
        }
        let shallow = try await folders(depth: 1)
        XCTAssertEqual(shallow, ["alpha", "beta"].map { projects.appendingPathComponent($0).path }, "a hidden folder is skipped")
        let deep = try await folders(depth: 2)
        XCTAssertEqual(deep, ["alpha", "beta", "beta/inner"].map { projects.appendingPathComponent($0).path })
    }

    func testRankedSessionPathsATopicsRowsAndAVisitNeedTheCapabilityAndRootsAnswerWithoutIt() async throws {
        let projects = directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        let client = try await connect()
        let refused: [HostRequest] = [
            .sessionPaths(SessionPathsRequest(.ranked(query: "alp"))),
            .sessionPaths(SessionPathsRequest(.ranked(query: ""))),
            .sessionPaths(try JSONDecoder().decode(SessionPathsRequest.self, from: Data("{}".utf8))),
            .sessionPaths(SessionPathsRequest(.topic("t"))),
            .visitSessionPath(VisitSessionPath(folder: projects.path)),
        ]
        for request in refused {
            do {
                _ = try await client.call(request, as: ProtocolEmpty.self)
                XCTFail("\(request) ran for a client that did not declare ranked-session-paths")
            } catch let error as ProtocolError {
                XCTAssertEqual(error.code, .unsupported, "\(request)")
                XCTAssertTrue(error.message.contains("ranked-session-paths"), error.message)
            }
        }
        XCTAssertEqual(try VisitStore(paths: paths).times(), [:], "the refused visit was recorded")
        let roots = [SessionPathRoot(path: projects.path, depth: 1)]
        let answer = try await client.call(HostRequest.sessionPaths(SessionPathsRequest(roots: roots)), as: SessionPathsOutput.self)
        XCTAssertEqual(SessionPathDiscovery.sessionPaths(in: try XCTUnwrap(answer.output), roots: roots, aliases: [:]).map(\.folder.path),
                       [projects.appendingPathComponent("alpha").path])
    }

    func testSessionPathsRankByTheLastVisitAndTheQueryAndATopicGetsItsAddASessionRows() async throws {
        let projects = directory.appendingPathComponent("projects")
        for folder in ["alpha", "beta/src"] {
            try FileManager.default.createDirectory(at: projects.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let config = directory.appendingPathComponent("config.yml")
        try "sessions:\n  paths:\n    - path: \(projects.path)/*\n".write(to: config, atomically: true, encoding: .utf8)
        let hostPaths = MuxifyPaths(environment: ["XDG_STATE_HOME": directory.appendingPathComponent("state").path, "MUXIFY_CONFIG": config.path],
                                    home: "/nonexistent")
        let client = try await connect(context: HostServerContext(paths: hostPaths, tmux: tmux, temporaryDirectory: uploads.path),
                                       capabilities: ["ranked-session-paths"])
        func names(_ ask: SessionPathsRequest.Ask) async throws -> [String] {
            try await client.call(HostRequest.sessionPaths(SessionPathsRequest(ask)), as: RankedSessionPathsAnswer.self).rows.map(\.name)
        }

        let unvisited = try await names(.ranked(query: ""))
        XCTAssertEqual(unvisited, ["alpha", "beta"], "with no visit, the order of the Config")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostPaths.sessionPathCache(remote: nil).path), "the first answer saves the discovery")

        _ = try await client.call(HostRequest.visitSessionPath(VisitSessionPath(folder: projects.appendingPathComponent("beta/src").path)),
                                  as: ProtocolEmpty.self)
        let beta = Folder.local(projects.appendingPathComponent("beta").path)
        XCTAssertNotNil(try VisitStore(paths: hostPaths).times()[.directory(beta.real)], "the visit is to the Session Path that holds the folder")
        let visited = try await names(.ranked(query: ""))
        XCTAssertEqual(visited, ["beta", "alpha"], "the last visited first")
        let matched = try await names(.ranked(query: "alp"))
        XCTAssertEqual(matched, ["alpha"])

        let created = try await client.call(HostRequest.environment(EnvironmentRequest(.create(title: "Ship"))), as: EnvironmentResponse.self)
        guard case .changed(let change) = created, let id = change.topicID else { return XCTFail("unexpected \(created)") }
        let topic = try await client.call(HostRequest.sessionPaths(SessionPathsRequest(.topic(id))), as: TopicSessionPathsAnswer.self)
        XCTAssertEqual(topic.topic.id, id)
        XCTAssertEqual(topic.rows.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(topic.rows.map(\.inThisTopic), [false, false])
        XCTAssertEqual(topic.rows.map { $0.lastVisit != nil }, [false, true])
    }

    // MARK: - Upload

    func testA200KiBUploadArrivesIntactInChunksOfAtMost64KiB() async throws {
        let bytes = Data((0..<200 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
        let file = directory.appendingPathComponent("local.bin")
        try bytes.write(to: file)
        let client = try await connect()

        let path = try await client.upload(file, name: "big file.bin", window: 2)
        let uploaded = URL(fileURLWithPath: path)
        XCTAssertEqual(uploaded.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path,
                       uploads.resolvingSymlinksInPath().path, "the file goes to the Host's TMPDIR: \(path)")
        XCTAssertEqual(uploaded.lastPathComponent, "big file.bin")
        XCTAssertEqual(try Data(contentsOf: uploaded), bytes, "the upload did not arrive intact")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: uploaded.deletingLastPathComponent().path), ["big file.bin"],
                       "only the published file is left in its folder")
        let mode = try FileManager.default.attributesOfItem(atPath: uploaded.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "the folder is private")

        do {
            let tooLarge = Data(count: HostProtocol.maxChunkBytes + 1)
            _ = try await client.call(HostRequest.upload(UploadChunk(name: "large", offset: 0, data: tooLarge, last: true)), as: UploadPath.self)
            XCTFail("a chunk over 64 KiB must be refused")
        } catch let error as ProtocolError {
            XCTAssertEqual(error.code, .failed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: uploads.path).count, 1, "the refused upload left a folder")
    }

    func testAFailedChunkFailsTheUploadAndLeavesNoPartialFile() async throws {
        let client = try await connect()
        let chunk = Data(repeating: 7, count: HostProtocol.maxChunkBytes)
        let first = client.begin(HostRequest.upload(UploadChunk(name: "partial.bin", offset: 0, data: chunk, last: false)), as: UploadPath.self)
        // A chunk that overlaps what was written fails the run.
        let overlapping = client.begin(HostRequest.upload(UploadChunk(name: "partial.bin", offset: 10, data: chunk, last: false)), as: UploadPath.self)
        let later = client.begin(HostRequest.upload(UploadChunk(name: "partial.bin", offset: 2 * chunk.count, data: chunk, last: true)), as: UploadPath.self)
        let path = try await first.value.path
        for call in [overlapping, later] {
            do {
                _ = try await call.value
                XCTFail("a chunk of a failed upload must fail")
            } catch let error as ProtocolError {
                XCTAssertEqual(error.code, .failed)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path),
                       "the failed upload left its partial file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: uploads.path), [])

        // A channel that ends mid-upload deletes the partial file too.
        let started = client.begin(HostRequest.upload(UploadChunk(name: "cut.bin", offset: 0, data: chunk, last: false)), as: UploadPath.self)
        _ = try await started.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: uploads.path).count, 1)
        client.close()
        try await wait("an upload cut off by the channel's end left its partial file") {
            (try? FileManager.default.contentsOfDirectory(atPath: uploads.path))?.isEmpty == true
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: [String], in folder: String) throws -> String {
        try Shell.run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgSign=false"] + arguments,
                      directory: folder)
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

    private final class TopicRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [TopicDetailItem] = []
        private var last: TopicDetailItem??
        private var done = false
        var task: Task<Void, Never>?

        func add(_ item: TopicDetailItem) { lock.lock(); log.append(item); last = item; lock.unlock() }
        func end() { lock.lock(); done = true; lock.unlock() }
        var items: [TopicDetailItem] { lock.lock(); defer { lock.unlock() }; return log }
        var ended: Bool { lock.lock(); defer { lock.unlock() }; return done }
        /// The latest item, also after `clear`.
        var latest: TopicDetailItem? { lock.lock(); defer { lock.unlock() }; return last ?? nil }
        /// The detail of the latest item, nil before the first and when it is null.
        var detail: TopicDetail? {
            guard case .topic(let detail)?? = latest else { return nil }
            return detail
        }
        func clear() { lock.lock(); log = []; lock.unlock() }
        func cancel() { task?.cancel() }
    }

    private final class ConfigRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [HostConfig] = []

        func add(_ config: HostConfig) { lock.lock(); log.append(config); lock.unlock() }
        var items: [HostConfig] { lock.lock(); defer { lock.unlock() }; return log }
    }

    private func connect(nonce: String? = nil, context: HostServerContext? = nil, capabilities: [String] = []) async throws -> ProtocolClient {
        let up = Pipe(), down = Pipe()
        let server = HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting, build: "server",
                                     context: context ?? HostServerContext(paths: paths, tmux: tmux, temporaryDirectory: uploads.path))
        server.start()
        servers.append(server)
        let client = ProtocolClient(input: down.fileHandleForReading, output: up.fileHandleForWriting, build: "client",
                                    capabilities: capabilities, helloTimeout: 5, nonce: nonce)
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

    private func subscribe(_ client: ProtocolClient, topic: String) -> TopicRecorder {
        let recorder = TopicRecorder()
        let events = client.subscribe(HostRequest.subscribe(.topic(TopicSubscription(id: topic))), as: TopicDetailItem.self)
        let task = Task {
            do {
                for try await item in events { recorder.add(item) }
            } catch {}
            recorder.end()
        }
        recorder.task = task
        consumers.append(task)
        return recorder
    }

    /// Waits until no item has come for a moment, and forgets what came before.
    private func settle(_ recorder: TopicRecorder) async throws {
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
