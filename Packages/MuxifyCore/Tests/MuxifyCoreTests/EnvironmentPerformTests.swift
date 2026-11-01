import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class EnvironmentPerformTests: XCTestCase {
    private var root: URL!
    private var paths: MuxifyPaths!
    private var local: TmuxServer!
    private var remote: TmuxServer!

    override func setUpWithError() throws {
        _ = try requireTmux()
        root = URL(fileURLWithPath: "/tmp/mxp-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
        local = TmuxServer(socketPath: root.appendingPathComponent("local").path, configPath: "/dev/null")
        remote = TmuxServer(socketPath: root.appendingPathComponent("remote").path, configPath: "/dev/null")
        for server in [local!, remote!] { try server.run(["new-session", "-d", "-s", "main", "-c", root.path]) }
    }

    override func tearDownWithError() throws {
        for server in [local, remote].compactMap({ $0 }) {
            let socket = try? server.run(["display-message", "-p", "#{socket_path}"])
            if socket?.hasPrefix(root.path + "/") == true { try server.run(["kill-server"]) }
        }
        if let root { try FileManager.default.removeItem(at: root) }
    }

    @MainActor private func perform(_ request: EnvironmentRequest, on module: EnvironmentModule,
                                    preparing browsers: [EnvironmentBrowserState] = []) async -> EnvironmentWriteReceipt<EnvironmentResponse> {
        await withCheckedContinuation { continuation in
            module.perform(request, preparing: browsers) { continuation.resume(returning: $0) }
        }
    }

    @MainActor func testCommandScopeReadsItsCompletedWriteAndRetiresOnError() async throws {
        var retained: EnvironmentModule?
        do {
            try await EnvironmentModule.withCommand(paths: paths, server: local) { module in
                retained = module
                let receipt = await module.perform(EnvironmentRequest(.create(title: "Command", tags: nil)))
                guard case .changed(let change) = receipt.value else { return XCTFail("Expected a saved Topic") }
                let read = await module.readNow()
                XCTAssertEqual(try read.records.get().records.first?.id, change.topicID)
                XCTAssertEqual(try read.inventory.get().windows.count, 1)
                throw TmuxError.cancelled
            }
            XCTFail("Expected the command error")
        } catch TmuxError.cancelled {}
        let module = try XCTUnwrap(retained)
        XCTAssertTrue(module.isRetired)
        let query = await module.queries().inventory()
        guard case .failure(let failure) = query else { return XCTFail("Expected a closed query") }
        XCTAssertEqual(failure.kind, .cancelled)
        let read = await module.readNow()
        XCTAssertThrowsError(try read.records.get())
        XCTAssertEqual(try TopicStore(paths: paths).read().records.first?.title, "Command")
    }

    @MainActor func testQueuedQueryReturnsCancellationWhenModuleRetires() async throws {
        let module = EnvironmentModule(paths: paths, server: local)
        var release: ((()) -> Void)?
        module.write { release = $0 }
        let answered = expectation(description: "Queued query receives cancellation")
        module.query(.inventory, sessionPaths: [], topics: Config.Topics()) { response in
            guard case .failed(let failure) = response else { return XCTFail("Expected cancellation") }
            XCTAssertEqual(failure.kind, .cancelled)
            answered.fulfill()
        }
        let retired = expectation(description: "Module retires after active work")
        module.retire { retired.fulfill() }
        try XCTUnwrap(release)(())
        await fulfillment(of: [answered, retired], timeout: 5)
    }

    @MainActor func testRemoteWritesDoNotTouchLocalOrRequireLocalRecords() async throws {
        let window = try XCTUnwrap(WindowID(rawValue: remote.snapshot().windows[0].id))
        XCTAssertEqual(try local.snapshot().windows[0].id, window.rawValue)
        let blockedPaths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.appendingPathComponent("not-a-folder").path], home: "/nonexistent")
        try Data().write(to: root.appendingPathComponent("not-a-folder"))
        let module = EnvironmentModule(paths: blockedPaths, server: remote, topicsAvailable: false)
        let browser = EnvironmentBrowserState(window: window, browser: StoredBrowser(tabURLs: ["https://remote.invalid"]))
        let receipt = await perform(EnvironmentRequest(.runtime(.browser([browser]))), on: module)
        XCTAssertEqual(receipt.value, .changed(TopicChange(topicID: nil)))
        let split = await perform(EnvironmentRequest(.runtime(.pane(window: window, action: .split(.right)))), on: module)
        XCTAssertTrue(split.revision.isAfter(receipt.revision))
        XCTAssertEqual(try remote.snapshot().windows[0].storedBrowser.tabURLs, ["https://remote.invalid"])
        XCTAssertEqual(try local.snapshot().windows[0].storedBrowser.tabURLs, [])
        XCTAssertEqual(try remote.snapshot().panes.count, 2)
        XCTAssertEqual(try local.snapshot().panes.count, 1)
    }

    @MainActor func testPaneSearchUsesItsEnvironmentAndRetirementCancelsCopyMode() async throws {
        try remote.run(["respawn-pane", "-k", "-t", "%0", "printf 'needle\\nneedle\\n'; exec sleep 300"])
        let deadline = Date().addingTimeInterval(5)
        while try !remote.run(["capture-pane", "-p", "-t", "%0"]).contains("needle"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let module = EnvironmentModule(paths: paths, server: remote, topicsAvailable: false)
        let resolved = await perform(EnvironmentRequest(.runtime(.paneSearch(.resolve(WindowID(rawValue: "@0")!)))), on: module)
        guard case .paneSearch(.resolved(let pane)) = resolved.value else { return XCTFail("Expected a resolved Pane") }
        let styles = PaneSearch.Styles(match: "bg=yellow", current: "bg=red")
        let search = EnvironmentRequest(.runtime(.paneSearch(.search(step: .query, query: "needle", pane: pane, styles: styles, previousTotal: nil))))
        let receipt = await perform(search, on: module)
        XCTAssertEqual(receipt.value, .paneSearch(.searched(found: true, total: 2, index: 0)))
        XCTAssertEqual(try remote.run(["display-message", "-p", "-t", "%0", "#{pane_mode}"]), "copy-mode\n")
        XCTAssertEqual(try local.run(["display-message", "-p", "-t", "%0", "#{pane_mode}"]), "\n")
        XCTAssertEqual(try JSONDecoder().decode(EnvironmentRequest.self, from: JSONEncoder().encode(search)), search)
        XCTAssertEqual(try JSONDecoder().decode(EnvironmentResponse.self, from: JSONEncoder().encode(receipt.value)), receipt.value)

        var release: ((()) -> Void)?
        module.write { release = $0 }
        let cancelled = expectation(description: "Search cleanup survives retirement")
        module.perform(EnvironmentRequest(.runtime(.paneSearch(.cancel(pane))))) { receipt in
            XCTAssertEqual(receipt.value, .paneSearch(.cancelled))
            cancelled.fulfill()
        }
        let retired = expectation(description: "Environment closes after search cleanup")
        module.retire { retired.fulfill() }
        try XCTUnwrap(release)(())
        await fulfillment(of: [cancelled, retired], timeout: 10)
        XCTAssertEqual(try remote.run(["display-message", "-p", "-t", "%0", "#{pane_mode}"]), "\n")
        XCTAssertEqual(try remote.run(["show-options", "-pqv", "-t", "%0", "copy-mode-match-style"]), "")
    }

    @MainActor func testVisitsAreWindowScopedAndManualReadPreservesMarks() async throws {
        try local.run(["split-window", "-d", "-t", "@0"])
        try local.run(["new-window", "-d", "-t", "main"])
        let snapshot = try local.snapshot()
        let shown = snapshot.panes.filter { $0.windowID == "@0" }
        let first = try XCTUnwrap(PaneID(rawValue: shown[0].id))
        let second = try XCTUnwrap(PaneID(rawValue: shown[1].id))
        let outside = try XCTUnwrap(PaneID(rawValue: snapshot.panes.first { $0.windowID != "@0" }?.id ?? ""))
        let module = EnvironmentModule(paths: paths, server: local)
        var record = TopicRecord(id: "visit")
        record.isUnread = true
        try TopicStore(paths: paths).write { try $0.create(record) }
        for pane in [first, second, outside] { try local.run(AgentUnread.command(true, paneID: pane.rawValue)) }
        let visit = EnvironmentVisit.panes(window: WindowID(rawValue: "@0")!, shown: [first, outside])
        _ = await perform(EnvironmentRequest(.runtime(.visit(visit, manualRead: true))), on: module)
        XCTAssertEqual(try local.snapshot().panes.filter(\.unread).count, 3)
        _ = await perform(EnvironmentRequest(.runtime(.visit(visit, manualRead: false))), on: module)
        XCTAssertEqual(Set(try local.snapshot().panes.filter(\.unread).map(\.id)), [second.rawValue, outside.rawValue])
        XCTAssertTrue(try TopicStore(paths: paths).read().records[0].isUnread)
        _ = await perform(EnvironmentRequest(.runtime(.visit(.emptyTopic("visit"), manualRead: true))), on: module)
        XCTAssertTrue(try TopicStore(paths: paths).read().records[0].isUnread)
        _ = await perform(EnvironmentRequest(.runtime(.visit(.emptyTopic("visit"), manualRead: false))), on: module)
        XCTAssertFalse(try TopicStore(paths: paths).read().records[0].isUnread)
        try local.run(AgentUnread.command(true, paneID: first.rawValue))
        XCTAssertTrue(try local.snapshot().panes.first { $0.id == first.rawValue }!.unread)
    }

    @MainActor func testReadAcknowledgesStatusEvenBeforeRulesSetUnread() async throws {
        try local.run(["new-window", "-d", "-t", "main", "sleep 300"])
        let pane = try XCTUnwrap(local.snapshot().panes.first { $0.windowID == "@1" })
        try local.run(["set-option", "-pq", "-t", pane.id, Tmux.agentOption, "claude",
                       ";", "set-option", "-pq", "-t", pane.id, Tmux.agentStatusOption, "done",
                       ";", "set-option", "-pq", "-t", pane.id, Tmux.agentSeenStatusOption, "working"])
        let module = EnvironmentModule(paths: paths, server: local)
        _ = await perform(EnvironmentRequest(.markAllRead), on: module)
        let read = try XCTUnwrap(local.snapshot().panes.first { $0.id == pane.id })
        XCTAssertFalse(read.unread)
        XCTAssertEqual(read.agentSeenStatus, "done")
        try local.run(["set-option", "-pq", "-t", pane.id, Tmux.agentStatusOption, "blocked"])
        let visit = EnvironmentVisit.panes(window: WindowID(rawValue: pane.windowID)!, shown: [PaneID(rawValue: pane.id)!])
        _ = await perform(EnvironmentRequest(.runtime(.visit(visit, manualRead: true))), on: module)
        XCTAssertEqual(try local.snapshot().panes.first { $0.id == pane.id }?.agentSeenStatus, "done")
        _ = await perform(EnvironmentRequest(.runtime(.visit(visit, manualRead: false))), on: module)
        XCTAssertEqual(try local.snapshot().panes.first { $0.id == pane.id }?.agentSeenStatus, "blocked")
    }

    @MainActor func testRetirementCompletesCancelledRequestsAndPersistsBrowser() async throws {
        let module = EnvironmentModule(paths: paths, server: local)
        var finish: ((()) -> Void)?
        module.write { finish = $0 }
        var cancelled: [EnvironmentWriteReceipt<EnvironmentResponse>] = []
        let window = WindowID(rawValue: "@0")!
        module.perform(EnvironmentRequest(.runtime(.pane(window: window, action: .split(.right))))) { cancelled.append($0) }
        let saved = expectation(description: "Browser write completed")
        module.perform(EnvironmentRequest(.runtime(.browser([EnvironmentBrowserState(window: window, browser: StoredBrowser(tabURLs: ["https://saved.invalid"]))])))) {
            XCTAssertEqual($0.value, .changed(TopicChange(topicID: nil)))
            saved.fulfill()
        }
        let retired = expectation(description: "Retirement finished")
        module.retire { retired.fulfill() }
        module.perform(EnvironmentRequest(.runtime(.selectPane(PaneID(rawValue: "%0")!)))) { cancelled.append($0) }
        XCTAssertEqual(cancelled.count, 2)
        for receipt in cancelled {
            guard case .failed(let failure) = receipt.value else { return XCTFail("Expected cancellation") }
            XCTAssertEqual(failure.kind, .cancelled)
            XCTAssertEqual(failure.phase, .nothingChanged)
        }
        XCTAssertTrue(cancelled[1].revision.isAfter(cancelled[0].revision))
        try XCTUnwrap(finish)(())
        await fulfillment(of: [saved, retired], timeout: 10)
        XCTAssertEqual(try local.snapshot().panes.count, 1)
        XCTAssertEqual(try local.snapshot().windows[0].storedBrowser.tabURLs, ["https://saved.invalid"])
    }

    @MainActor func testRetirementRetriesFailedMarkerRemoval() async throws {
        let server = MarkerRemovalFailure(server: local)
        let module = EnvironmentModule(paths: paths, server: server)
        let first = EnvironmentClientMarker(id: UUID(), pid: 42, tty: "/dev/ttys001", home: root.path, host: "test")
        let second = EnvironmentClientMarker(id: UUID(), pid: 43, tty: "/dev/ttys002", home: root.path, host: "test")
        _ = await perform(EnvironmentRequest(.runtime(.registerClient(first))), on: module)
        let failed = await perform(EnvironmentRequest(.runtime(.removeClient(first.id))), on: module)
        guard case .failed = failed.value else { return XCTFail("Expected marker removal failure") }
        _ = await perform(EnvironmentRequest(.runtime(.registerClient(second))), on: module)
        let retired = expectation(description: "Both marker removals finished")
        module.retire { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 10)
        let options = try local.run(["show-options", "-s"])
        XCTAssertFalse(options.contains(EnvironmentClientMarker.option(first.id)))
        XCTAssertFalse(options.contains(EnvironmentClientMarker.option(second.id)))
    }

    private final class MarkerRemovalFailure: TmuxRunning, @unchecked Sendable {
        let server: TmuxServer
        private let lock = NSLock()
        private var hasFailed = false
        init(server: TmuxServer) { self.server = server }
        func snapshot() throws -> TmuxSnapshot { try server.snapshot() }
        func run(_ arguments: [String]) throws -> String {
            lock.lock()
            let fail = arguments.first == "set-option" && arguments.contains("-squ") && !hasFailed
            if fail { hasFailed = true }
            lock.unlock()
            if fail { throw TmuxError.timedOut }
            return try server.run(arguments)
        }
    }

    @MainActor func testPreparationFailureStopsCommandAndKeepsRevision() async throws {
        let module = EnvironmentModule(paths: paths, server: FailingServer(server: local, command: "set-option"))
        let window = WindowID(rawValue: "@0")!
        let bad = EnvironmentBrowserState(window: WindowID(rawValue: "@999")!, browser: StoredBrowser(tabURLs: ["https://invalid.invalid"]))
        let first = await perform(EnvironmentRequest(.runtime(.pane(window: window, action: .split(.right)))), on: module, preparing: [bad])
        guard case .failed(let failure) = first.value else { return XCTFail("Expected preparation failure") }
        XCTAssertEqual(failure.phase, .changesStarted)
        XCTAssertEqual(try local.snapshot().panes.count, 1)
        let noop = await perform(EnvironmentRequest(.runtime(.browser([]))), on: module)
        XCTAssertTrue(noop.revision.isAfter(first.revision))
        var invalid = EnvironmentRequest(.runtime(.pane(window: window, action: .split(.right))))
        invalid.version = -1
        let rejected = await perform(invalid, on: module)
        XCTAssertTrue(rejected.revision.isAfter(noop.revision))
        XCTAssertEqual(try local.snapshot().panes.count, 1)
    }

    @MainActor func testPartialRecordSaveAndStaleReadThroughPerform() async throws {
        let module = EnvironmentModule(paths: paths, server: FailingServer(server: local, command: "new-session"))
        var firstRead: ((EnvironmentRead, Void) -> Void)?
        var readCount = 0
        var states: [EnvironmentState] = []
        module.refresh({ finish in
            readCount += 1
            if readCount == 1 { firstRead = finish }
            else { finish(EnvironmentRead(inventory: Result { try self.local.snapshot() }, records: Result { try TopicStore(paths: self.paths).read() }), ()) }
        }, receive: { state, _ in states.append(state) })
        let pane = try XCTUnwrap(PaneID(rawValue: local.snapshot().panes[0].id))
        let receipt = await perform(EnvironmentRequest(.move(to: .newTopic(title: "Saved")), target: .pane(pane)), on: module)
        guard case .failed(let failure) = receipt.value else { return XCTFail("Expected partial failure") }
        XCTAssertEqual(failure.phase, .recordSaved)
        XCTAssertEqual(try TopicStore(paths: paths).read().records.first?.title, "Saved")
        try XCTUnwrap(firstRead)(EnvironmentRead(inventory: .failure(InventoryReadFailure.timedOut), records: .failure(InventoryReadFailure.timedOut)), ())
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].records.current?.records.first?.title, "Saved")
        XCTAssertTrue(states[0].revision.isAfter(receipt.revision))
    }

    @MainActor func testAttachmentReceiptWaitsForItsBoundDriverAndRetirement() async throws {
        let driver = HoldingAttachmentDriver()
        let module = EnvironmentModule(paths: paths, server: local, attachmentDriver: driver)
        let started = expectation(description: "Native attachment started")
        driver.started = { started.fulfill() }
        let completed = expectation(description: "Attachment returned its receipt")
        var receipt: EnvironmentWriteReceipt<EnvironmentResponse>?
        var completionCount = 0
        module.perform(EnvironmentRequest(.runtime(.attach(EnvironmentAttachment())))) {
            completionCount += 1
            receipt = $0
            if completionCount == 1 { driver.completion?(.success(())) }
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 10)
        XCTAssertNil(receipt)
        XCTAssertTrue(module.isWriting)
        let retired = expectation(description: "Attachment drained before retirement")
        module.retire { retired.fulfill() }
        XCTAssertNil(receipt)
        try XCTUnwrap(driver.completion)(.failure(TmuxError.cancelled))
        await fulfillment(of: [completed, retired], timeout: 10)
        XCTAssertEqual(completionCount, 1)
        guard case .failed(let failure) = try XCTUnwrap(receipt).value else { return XCTFail("Expected cancelled attachment") }
        XCTAssertEqual(failure.kind, .cancelled)
        XCTAssertEqual(failure.phase, .changesStarted)
    }

    @MainActor private final class HoldingAttachmentDriver: EnvironmentAttachmentDriver {
        var started: (() -> Void)?
        var completion: ((Result<Void, Error>) -> Void)?
        func attach(_ plan: EnvironmentAttachment, completion: @escaping (Result<Void, Error>) -> Void) {
            self.completion = completion
            started?()
        }
    }

    private struct FailingServer: TmuxRunning {
        let server: TmuxServer
        let command: String
        func snapshot() throws -> TmuxSnapshot { try server.snapshot() }
        func run(_ arguments: [String]) throws -> String {
            if arguments.contains(command) { throw TmuxError.timedOut }
            return try server.run(arguments)
        }
    }

    func testNewRequestsRoundTrip() throws {
        let window = WindowID(rawValue: "@0")!, pane = PaneID(rawValue: "%0")!, session = SessionID(rawValue: "$0")!
        let operations: [EnvironmentOperation] = [
            .openBrowser(target: "%0", urls: ["https://example.invalid"]),
            .browser([EnvironmentBrowserState(window: window, browser: StoredBrowser(tabURLs: ["https://example.invalid"]))]),
            .visit(.panes(window: window, shown: [pane]), manualRead: false), .visit(.emptyTopic("topic"), manualRead: true),
            .pane(window: window, action: .split(.right)), .pane(window: window, action: .resize(.down, amount: 10)),
            .selectPane(pane), .switchClient(session: session, window: window), .rememberWindow(window), .consumeOpen(window),
            .sendText(pane: pane, text: "text"), .pasteText(pane: pane, text: "paste"),
            .editorWindow(session: session, after: window, directory: "/tmp", command: "vi"),
            .attach(EnvironmentAttachment(destination: .init(session: session, window: window))),
            .registerClient(EnvironmentClientMarker(id: UUID(), pid: 42, tty: "/dev/ttys001", home: "/tmp", host: "test")), .removeClient(UUID()),
            .browserSocket("/tmp/tmux-501/default.muxify-browser"), .browserSocket(nil)
        ]
        for operation in operations {
            let request = EnvironmentRequest(.runtime(operation))
            XCTAssertEqual(try JSONDecoder().decode(EnvironmentRequest.self, from: JSONEncoder().encode(request)), request)
        }
    }
}
