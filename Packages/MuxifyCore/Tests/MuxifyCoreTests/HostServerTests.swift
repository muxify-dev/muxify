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

    // MARK: - Worktrees on the Host (ADR 0088)

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

    private final class ConfigRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [HostConfig] = []

        func add(_ config: HostConfig) { lock.lock(); log.append(config); lock.unlock() }
        var items: [HostConfig] { lock.lock(); defer { lock.unlock() }; return log }
    }

    private func connect(nonce: String? = nil, context: HostServerContext? = nil) async throws -> ProtocolClient {
        let up = Pipe(), down = Pipe()
        let server = HostServer.make(input: up.fileHandleForReading, output: down.fileHandleForWriting, build: "server",
                                     context: context ?? HostServerContext(paths: paths, tmux: tmux, temporaryDirectory: uploads.path))
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
