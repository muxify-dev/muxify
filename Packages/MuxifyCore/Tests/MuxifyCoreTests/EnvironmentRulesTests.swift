import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class EnvironmentRulesTests: XCTestCase {
    private var root: URL!
    private var paths: MuxifyPaths!
    private var server: TmuxServer!
    private var clients: [Process] = []

    override func setUpWithError() throws {
        _ = try requireTmux()
        root = URL(fileURLWithPath: "/tmp/mxr-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
        server = TmuxServer(socketPath: root.appendingPathComponent("s").path, configPath: "/dev/null")
        try server.run(["new-session", "-d", "-s", "main", "sleep 300"])
        try server.run(["set-option", "-pq", "-t", "%0", Tmux.agentOption, "claude"])
    }

    override func tearDownWithError() throws {
        for client in clients where client.isRunning { client.terminate() }
        if let socket = try? server.run(["display-message", "-p", "#{socket_path}"]), socket.hasPrefix(root.path + "/") {
            try server.run(["kill-server"])
        }
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor private func module(manualRead: Bool = false, inPlay: Int? = nil, paths: MuxifyPaths? = nil, transport: (any TmuxRunning)? = nil) -> EnvironmentModule {
        var config = Config()
        config.notifications.manualRead = manualRead
        config.topics.inPlay = inPlay
        return EnvironmentModule(paths: paths ?? self.paths, server: transport ?? server,
            rulesScope: .local(socketPath: server.socketPath), ruleSettings: EnvironmentRuleSettings(config: config))
    }

    @MainActor private func read(_ module: EnvironmentModule, inventory: (() throws -> TmuxSnapshot)? = nil) async -> EnvironmentState {
        await withCheckedContinuation { continuation in
            var finished = false
            module.read(context: { () }, inventory: inventory ?? { try self.server.snapshot() }) { state, _ in
                if !finished { finished = true; continuation.resume(returning: state) }
            }
        }
    }

    @MainActor private func retire(_ module: EnvironmentModule) async {
        await withCheckedContinuation { continuation in module.retire { continuation.resume() } }
    }

    @MainActor private func perform(_ request: EnvironmentRequest, on module: EnvironmentModule) async -> EnvironmentResponse {
        await withCheckedContinuation { continuation in module.perform(request) { continuation.resume(returning: $0.value) } }
    }

    private func status(_ status: String) throws {
        try server.run(["set-option", "-pq", "-t", "%0", Tmux.agentStatusOption, status])
    }

    @MainActor func testOwnerContentionAndPersistedStatusAfterRelease() async throws {
        try status("working")
        let owner = module()
        let first = await read(owner)
        XCTAssertTrue(first.ownsRules)
        XCTAssertEqual(first.inventory.current?.panes[0].agentSeenStatus, "working")
        let otherPaths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.appendingPathComponent("other").path], home: "/nonexistent")
        let other = module(manualRead: true, paths: otherPaths)
        let waiting = await read(other)
        XCTAssertFalse(waiting.ownsRules)
        XCTAssertEqual(waiting.ruleSettings?.manualRead, false)
        await retire(owner)
        try status("done")
        let successor = await read(other)
        XCTAssertTrue(successor.ownsRules)
        XCTAssertEqual(successor.ruleSettings?.manualRead, true)
        XCTAssertEqual(successor.inventory.current?.panes[0].agentSeenStatus, "done")
        XCTAssertEqual(successor.inventory.current?.panes[0].unread, true)
        await retire(other)
    }

    @MainActor func testFirstSeenDoneDoesNotInventUnreadAndManualVisitDoesNotAcknowledge() async throws {
        try status("done")
        let owner = module(manualRead: true)
        let first = await read(owner)
        XCTAssertEqual(first.inventory.current?.panes[0].unread, false)
        try status("working")
        _ = await read(owner)
        try status("blocked")
        let next = await read(owner)
        XCTAssertEqual(next.inventory.current?.panes[0].unread, true)
        let visit = EnvironmentVisit.panes(window: WindowID(rawValue: "@0")!, shown: [PaneID(rawValue: "%0")!])
        _ = await perform(EnvironmentRequest(.runtime(.visit(visit, manualRead: true))), on: owner)
        XCTAssertTrue(try server.snapshot().panes[0].unread)
        _ = await perform(EnvironmentRequest(.runtime(.visit(visit, manualRead: false))), on: owner)
        XCTAssertFalse(try server.snapshot().panes[0].unread)
        await retire(owner)
    }

    @MainActor func testZeroUnreadOptionDoesNotBlockStatusRules() async throws {
        try status("working")
        try server.run(["set-option", "-pq", "-t", "%0", Tmux.agentUnreadOption, "0"])
        let owner = module()
        _ = await read(owner)
        XCTAssertEqual(try server.snapshot().panes[0].agentSeenStatus, "working")
        try status("done")
        _ = await read(owner)
        XCTAssertTrue(try server.snapshot().panes[0].unread)
        await retire(owner)
    }

    @MainActor func testFailedInventoryDoesNotRunRulesAndFinalInventoryCannotRunThem() async throws {
        let owner = module()
        try status("working")
        _ = await read(owner)
        try status("done")
        let failed = await read(owner, inventory: { throw InventoryReadFailure.connectionLost })
        XCTAssertNil(failed.inventory.current)
        XCTAssertEqual(try server.snapshot().panes[0].agentSeenStatus, "working")
        _ = owner.finishReading(lastKnownInventory: try server.snapshot())
        XCTAssertFalse(try server.snapshot().panes[0].unread)
        await retire(owner)
    }

    @MainActor func testStaleRuleCannotOverrideReadWhenStatusRepeats() async throws {
        let gate = GatedServer(server)
        let owner = module(transport: gate)
        try status("working")
        _ = await read(owner)
        try status("done")
        let entered = expectation(description: "rule reached transport")
        gate.gate = { entered.fulfill(); gate.release.wait() }
        let pending = Task { await self.read(owner) }
        await fulfillment(of: [entered], timeout: 3)
        let reader = EnvironmentModule(paths: paths, server: server)
        try status("working")
        _ = await perform(EnvironmentRequest(.markAllRead), on: reader)
        gate.release.signal()
        _ = await pending.value
        XCTAssertFalse(try server.snapshot().panes[0].unread)
        XCTAssertEqual(try server.snapshot().panes[0].agentSeenStatus, "working")
        await retire(owner)
        await retire(reader)
    }

    @MainActor func testRecordsPollAndNoServerUpgradeOlderRecords() async throws {
        let socket = try server.run(["display-message", "-p", "#{socket_path}"])
        XCTAssertTrue(socket.hasPrefix(root.path + "/"))
        try server.run(["kill-server"])
        let owner = module(inPlay: 1)
        _ = await read(owner)
        let upgraded = expectation(description: "the module upgrades records that an older Muxify wrote")
        var observed = false
        owner.read(context: { () }, inventory: { try self.server.snapshot() }) { state, _ in
            if !observed, let records = state.records.current, records.records.count == 3, !records.needsUpgrade {
                observed = true
                upgraded.fulfill()
            }
        }
        try paths.seedTopicRecords(entries: [#"{"id":"a","order":0}"#, #"{"id":"b","order":1}"#,
                                             #"{"id":"sleeping","order":2,"snoozed_until":"never"}"#])
        await fulfillment(of: [upgraded], timeout: 3)
        let state = await read(owner)
        XCTAssertEqual(state.connection, .noServer)
        let order = TopicOrder.sorted((state.records.current?.records ?? []).map(TopicListEntry.topic)).map(\.id)
        XCTAssertEqual(order, [.topic("a"), .topic("sleeping"), .topic("b")], "a Snoozed Topic returns at the top of the Bench")
        XCTAssertNil(try XCTUnwrap(paths.storedTopicRecord("sleeping"))["snoozed_until"])
        XCTAssertFalse(try server.snapshot().serverRunning)
        await retire(owner)
    }

    @MainActor func testPartialRuleFailurePublishesFreshInventoryAndTypedFailure() async throws {
        try server.run(["split-window", "-d", "-t", "@0", "sleep 300",
                        ";", "set-option", "-pq", "-t", "%1", Tmux.agentOption, "claude"])
        try status("working")
        try server.run(["set-option", "-pq", "-t", "%1", Tmux.agentStatusOption, "working"])
        let gate = GatedServer(server)
        let owner = module(transport: gate)
        let before = await read(owner)
        try status("done")
        try server.run(["set-option", "-pq", "-t", "%1", Tmux.agentStatusOption, "done"])
        gate.failPane = "%1"
        let failed = await read(owner)
        XCTAssertTrue(failed.revision.isAfter(before.revision))
        XCTAssertEqual(failed.ruleFailure, .tmux(.timedOut))
        XCTAssertFalse(failed.isConfirmed)
        XCTAssertEqual(failed.inventory.current?.panes.first { $0.id == "%0" }?.unread, true)
        XCTAssertEqual(failed.inventory.current?.panes.first { $0.id == "%1" }?.unread, false)
        gate.failPane = nil
        await retire(owner)
    }

    @MainActor func testTopicMemoryFlushAndOutsideRemoval() async throws {
        try TopicStore(paths: paths).write { try $0.create(TopicRecord(id: "memory")) }
        try server.run(["set-option", "-t", "main", "@muxify_topic", "memory"])
        let owner = module()
        _ = await read(owner)
        await retire(owner)
        let remembered = try TopicStore(paths: paths).read().records[0]
        XCTAssertEqual(remembered.sessions.count, 1)
        let next = module()
        _ = await read(next)
        try server.run(["rename-window", "-t", "@0", "changed"])
        _ = await read(next)
        try TopicStore(paths: paths).write { try $0.update("memory") { $0.sessions = [] } }
        await retire(next)
        XCTAssertTrue(try TopicStore(paths: paths).read().records[0].sessions.isEmpty)
    }

    @MainActor func testRecordRemovalDuringInventoryCannotBeRecreatedByMemory() async throws {
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(TopicRecord(id: "removed")) }
        try server.run(["set-option", "-t", "main", "@muxify_topic", "removed"])
        let owner = module()
        _ = await read(owner)
        _ = await perform(EnvironmentRequest(.markAllRead), on: owner)
        XCTAssertEqual(try store.read().records[0].sessions.count, 1)
        let captured = expectation(description: "Inventory captured before external removal")
        let release = DispatchSemaphore(value: 0)
        var block = true
        let pending = Task { await self.read(owner, inventory: {
            let snapshot = try self.server.snapshot()
            if block { block = false; captured.fulfill(); release.wait() }
            return snapshot
        }) }
        await fulfillment(of: [captured], timeout: 3)
        try server.run(["set-option", "-u", "-t", "main", "@muxify_topic"])
        try store.write { try $0.update("removed") { $0.sessions = [] } }
        release.signal()
        _ = await pending.value
        await retire(owner)
        XCTAssertTrue(try store.read().records[0].sessions.isEmpty)
    }

    @MainActor func testMemoryWaitsForRemoveEditToDetachBeforeObservationAndRetirement() async throws {
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(TopicRecord(id: "editing")) }
        try server.run(["set-option", "-t", "main", "@muxify_topic", "editing"])
        let owner = module()
        _ = await read(owner)
        _ = await perform(EnvironmentRequest(.markAllRead), on: owner)
        try server.run(["rename-window", "-t", "@0", "pending"])
        _ = await read(owner)
        let saved = expectation(description: "Remove saved records while holding edit lock")
        let release = DispatchSemaphore(value: 0)
        let server = self.server!
        let edited = expectation(description: "Remove finished")
        DispatchQueue.global().async {
            defer { edited.fulfill() }
            do {
                try FileLock.withLock(store.paths.editLock, .exclusive, rank: .edit, timeout: 3) {
                    try store.write { try $0.update("editing") { $0.sessions = [] } }
                    saved.fulfill()
                    release.wait()
                    try server.run(["set-option", "-u", "-t", "main", "@muxify_topic"])
                }
            } catch { XCTFail("Remove failed: \(error)") }
        }
        await fulfillment(of: [saved], timeout: 3)
        let observed = DispatchSemaphore(value: 0)
        let reading = Task { await self.read(owner, inventory: {
            observed.signal()
            return try server.snapshot()
        }) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(observed.wait(timeout: .now()), .timedOut, "Inventory must wait for the Topic edit")
        release.signal()
        await fulfillment(of: [edited], timeout: 3)
        _ = await reading.value
        await retire(owner)
        XCTAssertTrue(try store.read().records[0].sessions.isEmpty)
    }

    @MainActor private func startClient() async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", try requireTmux(), "-S", server.socketPath, "attach-session", "-t", "main"]
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        clients.append(process)
        var client: TmuxClient?
        for _ in 0..<100 {
            client = try server.snapshot().clients.first { !$0.isControl }
            if client != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try XCTUnwrap(client?.tty)
    }

    @MainActor func testSharedModuleKeepsEachReadersViewingUntilThatReaderCloses() async throws {
        let tty = try await startClient()
        let owner = module()
        try status("working")
        _ = await read(owner)
        let first = UUID(), second = UUID()
        let settings = EnvironmentRuleSettings(config: Config())
        let visible = EnvironmentViewing(client: tty, window: "@0", visible: true)
        owner.updateRules(settings: settings, viewing: visible, reader: first)
        owner.updateRules(settings: settings, viewing: visible, reader: second)
        _ = await read(owner)
        owner.removeReader(first)
        try status("done")
        _ = await read(owner)
        XCTAssertFalse(try server.snapshot().panes[0].unread)
        owner.updateRules(settings: settings, viewing: EnvironmentViewing(), reader: second)
        try status("working")
        _ = await read(owner)
        try status("done")
        _ = await read(owner)
        XCTAssertTrue(try server.snapshot().panes[0].unread)
        await retire(owner)
    }

    @MainActor func testHidingDuringBlockedInventoryPublishesFactsForBothOwnerAndNonOwner() async throws {
        let tty = try await startClient()
        for ownsRules in [true, false] {
            try status("working")
            try server.run(AgentUnread.command(false, paneID: "%0"))
            let owner = module()
            _ = await read(owner)
            let reader = ownsRules ? owner : module()
            _ = await read(reader)
            reader.updateRules(settings: EnvironmentRuleSettings(config: Config()),
                viewing: EnvironmentViewing(client: tty, window: "@0", visible: true))
            _ = await read(reader)
            let entered = expectation(description: "Inventory is blocked")
            let release = DispatchSemaphore(value: 0)
            var block = true
            let pending = Task { await self.read(reader, inventory: {
                if block { block = false; entered.fulfill(); release.wait() }
                return try self.server.snapshot()
            }) }
            await fulfillment(of: [entered], timeout: 3)
            reader.updateRules(settings: EnvironmentRuleSettings(config: Config()), viewing: EnvironmentViewing())
            try status("done")
            if !ownsRules { _ = await read(owner) }
            release.signal()
            _ = await pending.value
            XCTAssertTrue(try server.snapshot().panes[0].unread, "Hidden facts must reach the owner without waiting for the reader's Inventory")
            if !ownsRules { await retire(reader) }
            await retire(owner)
        }
    }

    @MainActor func testNonOwnerViewingSuppressesUpdatesAndRetirementRemovesFacts() async throws {
        let tty = try await startClient()
        try status("working")
        let owner = module()
        _ = await read(owner)
        let reader = module()
        _ = await read(reader)
        reader.updateRules(settings: EnvironmentRuleSettings(config: Config()),
                           viewing: EnvironmentViewing(client: tty, window: "@0", visible: true))
        _ = await read(reader)
        try status("done")
        _ = await read(owner)
        XCTAssertFalse(try server.snapshot().panes[0].unread)
        await retire(reader)
        try status("working")
        _ = await read(owner)
        try status("done")
        _ = await read(owner)
        XCTAssertTrue(try server.snapshot().panes[0].unread)
        await retire(owner)
    }
}

private final class GatedServer: TmuxRunning, @unchecked Sendable {
    let base: TmuxServer
    var gate: (() -> Void)?
    var failPane: String?
    let release = DispatchSemaphore(value: 0)
    init(_ base: TmuxServer) { self.base = base }
    func snapshot() throws -> TmuxSnapshot { try base.snapshot() }
    func run(_ arguments: [String]) throws -> String {
        if arguments.first == "if-shell", arguments.contains(failPane ?? "missing") { throw TmuxError.timedOut }
        if arguments.first == "if-shell", let action = gate { gate = nil; action() }
        return try base.run(arguments)
    }
}
