import Darwin
import Foundation
import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class EnvironmentWatchTests: XCTestCase {
    private var root: URL!
    private var server: TmuxServer!
    private var wrapper: URL!
    @MainActor private var watchClients: [EnvironmentWatchClient] = []
    @MainActor private var directProcesses: [Process] = []

    override func setUpWithError() throws {
        _ = try requireTmux()
        root = URL(fileURLWithPath: "/tmp/mxw-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = TmuxServer(socketPath: root.appendingPathComponent("socket").path, configPath: "/dev/null")
        try server.run(["new-session", "-d", "-s", "main", "sleep 300"])
        let folder = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let appCLI = folder.appendingPathComponent("muxify-app-cli")
        let cli = FileManager.default.isExecutableFile(atPath: appCLI.path) ? appCLI : folder.appendingPathComponent("muxify")
        wrapper = root.appendingPathComponent("watch")
        let script = """
        #!/bin/sh
        unset TMUX TMUX_PANE
        export XDG_STATE_HOME=\(Tmux.shellQuote(root.path))
        export XDG_CONFIG_HOME=\(Tmux.shellQuote(root.path))
        export TMUX_TMPDIR=\(Tmux.shellQuote(root.path))
        echo $$ >> \(Tmux.shellQuote(root.appendingPathComponent("pids").path))
        exec \(Tmux.shellQuote(cli.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    }

    override func tearDown() async throws {
        try await stopAllClients()
    }

    @MainActor private func stopAllClients() async throws {
        for process in directProcesses where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            try await wait { !process.isRunning }
        }
        directProcesses.removeAll()
        for client in watchClients { await stop(client) }
        watchClients.removeAll()
    }

    override func tearDownWithError() throws {
        if let socket = try? server.run(["display-message", "-p", "#{socket_path}"]), socket.hasPrefix(root.path + "/") {
            try server.run(["kill-server"])
        }
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor func testAttachedWatchFinishesAfterItsClientLeavesAndRejectsReplacementServer() async throws {
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", try server.invocation(["attach-session", "-t", "main"]).commandLine]
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        directProcesses.append(process)
        try await wait { (try? self.server.snapshot().clients.contains { !$0.isControl }) == true }
        let client = try XCTUnwrap(server.snapshot().clients.first { !$0.isControl })
        let marker = "@muxify_client_bound"
        try server.run(["set-option", "-s", marker, [String(client.pid), client.tty, root.path, "fixture", "remote"].joined(separator: Tmux.separator)])
        let attached = try AttachedTmuxServer(server: server, marker: marker)
        XCTAssertTrue(try server.run(["display-message", "-p", "#{socket_path}"]).hasPrefix(root.path + "/"))
        try attached.run(["kill-session", "-t", "main"])
        XCTAssertFalse(try attached.snapshot().serverRunning)
        try server.run(["new-session", "-d", "-s", "replacement", "sleep 300"])
        XCTAssertThrowsError(try attached.snapshot())
        XCTAssertThrowsError(try attached.run(["rename-window", "-t", "@0", "wrong server"]))
        try? input.fileHandleForWriting.close()
    }

    @MainActor func testFallbackUsesProtocolAndRejectsTopicQueriesAndWrites() async throws {
        let client = EnvironmentWatchClient(fallback: server, rulesScope: .local(socketPath: server.socketPath),
                                            settings: EnvironmentRuleSettings(config: Config()))
        watchClients.append(client)
        let reader = EnvironmentReader(client: client)
        reader.read(context: { () },
                    receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        let source = try XCTUnwrap(reader.state?.inventory.current?.windows.first?.sourceID)
        let queried = try await client.queries(sessionPaths: [], topics: Config.Topics()).inventory().get()
        XCTAssertEqual(queried.windows.first?.sourceID, source)
        let refusal = await perform(EnvironmentRequest(.create(title: "Must not be Local")), on: reader)
        guard case .failed(let failure) = refusal.value else { return XCTFail("Fallback created a Topic") }
        XCTAssertEqual(failure.kind, .topicsUnavailable)
        let query = await client.queries(sessionPaths: [], topics: Config.Topics()).worktreeStarts(from: root.path)
        guard case .failure(let failure) = query else { return XCTFail("Fallback inspected Local Worktrees") }
        XCTAssertEqual(failure.kind, .unsupported)
        let result = await perform(EnvironmentRequest(.renameWindow(name: "fallback"), target: .window(WindowID(rawValue: "@0")!)), on: reader)
        try await wait { reader.state?.revision.isAfter(result.revision) == true }
        XCTAssertEqual(reader.state?.inventory.current?.windows.first?.name, "fallback")
        await retire(reader)
        await stop(client)
        XCTAssertFalse(client.isConnected)
    }

    @MainActor func testReadersShareStateAndReceiptsPrecedeTheirConfirmedState() async throws {
        let client = makeClient()
        let first = EnvironmentReader(client: client), second = EnvironmentReader(client: client)
        var states: [EnvironmentState] = []
        first.read(context: { () }) { state, _ in states.append(state) }
        second.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { first.isReady && second.isReady }
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.state?.revision.moduleID, second.state?.revision.moduleID)
        let sourceID = try XCTUnwrap(first.state?.inventory.current?.windows.first?.sourceID)
        XCTAssertFalse(sourceID.isEmpty)
        XCTAssertEqual(second.state?.inventory.current?.windows.first?.sourceID, sourceID)
        let before = try XCTUnwrap(first.state?.revision)
        let result = await perform(EnvironmentRequest(.create(title: "Shared")), on: first)
        XCTAssertTrue(result.revision.isAfter(before))
        XCTAssertFalse(first.isReady)
        try await wait { first.state?.revision.isAfter(result.revision) == true && second.records.records.contains { $0.title == "Shared" } }
        XCTAssertTrue(states.filter { $0.revision.isAfter(result.revision) }.allSatisfy { $0.records.current?.records.contains { $0.title == "Shared" } == true })
        let failed = await perform(EnvironmentRequest(.renameWindow(name: "missing"), target: .window(WindowID(rawValue: "@99999")!)), on: first)
        guard case .failed = failed.value else { XCTFail("Expected a failed Perform"); await stop(client); return }
        try await wait { first.state?.revision.isAfter(failed.revision) == true }
        let choices = await client.queries(sessionPaths: [], topics: Config.Topics()).settleChoices(for: .topic(.id("missing")))
        if case .success = choices { XCTFail("Unknown Topic query must fail") }
        await retire(first)
        try server.run(["rename-window", "-t", "@0", "survives"])
        try await wait { second.state?.inventory.current?.windows.first?.name == "survives" }
        XCTAssertEqual(second.state?.inventory.current?.windows.first?.sourceID, sourceID)
        await retire(second)
        await stop(client)
    }

    @MainActor func testCrashFailsAttachmentWithoutReplayAndRestoresReadersAndMarkers() async throws {
        let client = makeClient(), driver = HoldingAttachment()
        let reader = EnvironmentReader(client: client, attachmentDriver: driver)
        var disconnected = false
        reader.onDisconnect = { disconnected = true }
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        let old = try XCTUnwrap(reader.state?.revision.moduleID)
        let oldWindow = try XCTUnwrap(reader.state?.inventory.current?.windows.first)
        let marker = EnvironmentClientMarker(id: UUID(), pid: Int(getpid()), tty: "/dev/test", home: root.path, host: "test")
        _ = await perform(EnvironmentRequest(.runtime(.registerClient(marker))), on: reader)
        let option = "@muxify_client_" + marker.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var receipt: EnvironmentWriteReceipt<EnvironmentResponse>?
        reader.perform(EnvironmentRequest(.runtime(.attach(EnvironmentAttachment(destination: nil, directory: root.path, createSessionIfNeeded: false))))) { receipt = $0 }
        try await wait { driver.finish != nil }
        let firstPID = try childPIDs().last.unwrap()
        XCTAssertEqual(kill(firstPID, SIGKILL), 0)
        try await wait { receipt != nil && disconnected }
        guard case .failed = receipt?.value else { XCTFail("Uncertain attachment must fail"); await stop(client); return }
        try server.run(["set-option", "-squ", option])
        try await wait { reader.isReady && reader.state?.revision.moduleID != old }
        let newWindow = try XCTUnwrap(reader.state?.inventory.current?.windows.first)
        XCTAssertEqual(newWindow.id, oldWindow.id)
        XCTAssertFalse(newWindow.sourceID.isEmpty)
        XCTAssertNotEqual(newWindow.sourceID, oldWindow.sourceID)
        let queried = try await client.queries(sessionPaths: [], topics: Config.Topics()).inventory().get()
        XCTAssertEqual(queried.windows.first?.sourceID, newWindow.sourceID)
        XCTAssertFalse(try server.run(["show-option", "-sv", option]).isEmpty)
        XCTAssertEqual(driver.calls, 1)
        XCTAssertEqual(try childPIDs().count, 2)
        XCTAssertEqual(try server.snapshot().clients.filter(\.isControl).count, 1)
        await retire(reader)
        await stop(client)
        XCTAssertEqual(try server.run(["show-option", "-sqv", option]), "")
        XCTAssertTrue(try server.snapshot().clients.filter(\.isControl).isEmpty)
    }

    @MainActor func testWindowIdentityChangesWhenTheServerRestartsWithinTheSameWatch() async throws {
        let client = makeClient(), reader = EnvironmentReader(client: client)
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        let module = try XCTUnwrap(reader.state?.revision.moduleID)
        let old = try XCTUnwrap(reader.state?.inventory.current)
        let oldWindow = try XCTUnwrap(old.windows.first)
        let socket = try server.run(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .newlines)
        guard socket.hasPrefix(root.path + "/") else { return XCTFail("Server is outside the test directory") }
        try server.run(["kill-server"])
        try await wait { reader.state?.connection == .noServer }
        try server.run(["new-session", "-d", "-s", "main", "sleep 300"])
        try await wait { reader.isReady && reader.state?.connection == .available }
        let next = try XCTUnwrap(reader.state?.inventory.current)
        let nextWindow = try XCTUnwrap(next.windows.first)
        XCTAssertEqual(reader.state?.revision.moduleID, module)
        XCTAssertNotEqual(next.serverID, old.serverID)
        XCTAssertEqual(nextWindow.id, oldWindow.id)
        XCTAssertFalse(nextWindow.sourceID.isEmpty)
        XCTAssertNotEqual(nextWindow.sourceID, oldWindow.sourceID)
        let queried = try await client.queries(sessionPaths: [], topics: Config.Topics()).inventory().get()
        XCTAssertEqual(queried.windows.first?.sourceID, nextWindow.sourceID)
        await retire(reader)
        await stop(client)
    }

    @MainActor func testInventoryQueryReadsNewPanesWithThePublishedWindowIdentity() async throws {
        let client = makeClient(), reader = EnvironmentReader(client: client)
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        let window = try XCTUnwrap(reader.state?.inventory.current?.windows.first)
        let before = try await client.queries(sessionPaths: [], topics: Config.Topics()).inventory().get()
        XCTAssertEqual(before.windows.first?.sourceID, window.sourceID)
        let pane = try server.run(["split-window", "-d", "-t", window.id, "-P", "-F", "#{pane_id}", "sleep 300"])
            .trimmingCharacters(in: .newlines)
        let after = try await client.queries(sessionPaths: [], topics: Config.Topics()).inventory().get()
        XCTAssertEqual(after.windows.first?.sourceID, window.sourceID)
        XCTAssertEqual(Set(after.panes.map(\.id)), Set(before.panes.map(\.id)).union([pane]))
        await retire(reader)
        await stop(client)
    }

    @MainActor func testSuspendedServerTimesOutAndRecoversWithinTheSameWatch() async throws {
        let client = makeClient(), reader = EnvironmentReader(client: client)
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        let module = try XCTUnwrap(reader.state?.revision.moduleID)
        let socket = try server.run(["display-message", "-p", "#{socket_path}"]).trimmingCharacters(in: .newlines)
        guard socket.hasPrefix(root.path + "/") else { return XCTFail("Server is outside the test directory") }
        let pid = try XCTUnwrap(Int32(try server.run(["display-message", "-p", "#{pid}"]).trimmingCharacters(in: .newlines)))
        XCTAssertEqual(kill(pid, SIGSTOP), 0)
        defer { kill(pid, SIGCONT) }
        reader.read(context: { () }, receive: { _, _ in })
        try await wait(timeout: 20) { reader.state?.connection == .failed(.inventory(.timedOut)) }
        XCTAssertFalse(reader.isReady)
        XCTAssertNotNil(reader.state?.inventory.lastKnown?.windows.first)
        XCTAssertEqual(kill(pid, SIGCONT), 0)
        reader.read(context: { () }, receive: { _, _ in })
        try await wait { reader.isReady && reader.state?.connection == .available }
        XCTAssertEqual(reader.state?.revision.moduleID, module)
        await retire(reader)
        await stop(client)
    }

    @MainActor func testClosingReaderCancelsAttachmentAndDrainsAdmittedBrowserSave() async throws {
        let client = makeClient(), driver = HoldingAttachment()
        let reader = EnvironmentReader(client: client, attachmentDriver: driver)
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        var receipt: EnvironmentWriteReceipt<EnvironmentResponse>?
        reader.perform(EnvironmentRequest(.runtime(.attach(EnvironmentAttachment(destination: nil, directory: root.path, createSessionIfNeeded: false))))) { receipt = $0 }
        try await wait { driver.finish != nil }
        var interactive: EnvironmentResponse?
        reader.perform(EnvironmentRequest(.renameWindow(name: "must-not-run"), target: .window(WindowID(rawValue: "@0")!))) { interactive = $0.value }
        let browser = EnvironmentBrowserState(window: WindowID(rawValue: "@0")!, browser: StoredBrowser(tabURLs: ["https://saved.invalid"]))
        var saved = false
        reader.perform(EnvironmentRequest(.runtime(.browser([browser])))) { result in
            if case .changed = result.value { saved = true }
        }
        let closed = expectation(description: "reader closes while attaching")
        reader.retire { closed.fulfill() }
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertNotNil(receipt)
        XCTAssertTrue(saved)
        guard case .failed = interactive else { XCTFail("Reader close must cancel queued interactive work"); await stop(client); return }
        XCTAssertNotEqual(try server.snapshot().windows.first?.name, "must-not-run")
        XCTAssertEqual(try server.snapshot().windows.first?.storedBrowser.tabURLs, ["https://saved.invalid"])
        await stop(client)
    }

    @MainActor func testOverloadDrainsAdmittedBrowserSaveBeforeRestart() async throws {
        let client = makeClient(), driver = HoldingAttachment()
        let reader = EnvironmentReader(client: client, attachmentDriver: driver)
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        let module = try XCTUnwrap(reader.state?.revision.moduleID)
        reader.perform(EnvironmentRequest(.runtime(.attach(EnvironmentAttachment(createSessionIfNeeded: false)))))
        try await wait { driver.finish != nil }
        let browser = EnvironmentBrowserState(window: WindowID(rawValue: "@0")!,
            browser: StoredBrowser(tabURLs: ["https://saved-before-overload.invalid"]))
        reader.perform(EnvironmentRequest(.runtime(.browser([browser]))))
        for index in 0..<128 {
            reader.perform(EnvironmentRequest(.renameWindow(name: "queued-\(index)"), target: .window(WindowID(rawValue: "@0")!)))
        }
        try await wait { reader.isReady && reader.state?.revision.moduleID != module }
        XCTAssertEqual(try server.snapshot().windows.first?.storedBrowser.tabURLs, ["https://saved-before-overload.invalid"])
        await retire(reader)
        await stop(client)
    }

    @MainActor func testAttachmentReceiptWaitsForNativeReadiness() async throws {
        let client = makeClient(), driver = HoldingAttachment()
        let reader = EnvironmentReader(client: client, attachmentDriver: driver)
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        var receipt: EnvironmentWriteReceipt<EnvironmentResponse>?
        reader.perform(EnvironmentRequest(.runtime(.attach(EnvironmentAttachment(createSessionIfNeeded: false))))) { receipt = $0 }
        try await wait { driver.finish != nil }
        XCTAssertNil(receipt)
        XCTAssertFalse(reader.isReady)
        driver.finish?(.success(()))
        try await wait { receipt != nil && reader.isReady }
        XCTAssertTrue(reader.state?.revision.isAfter(try XCTUnwrap(receipt).revision) == true)
        await retire(reader)
        await stop(client)
    }

    @MainActor func testStopWaitsForChildThatIsAlreadyDrainingAfterOverload() async throws {
        let client = makeClient(), driver = HoldingAttachment()
        let reader = EnvironmentReader(client: client, attachmentDriver: driver)
        reader.read(context: { () }, receive: { _, _ in })
        client.start()
        try await wait { reader.isReady }
        let child = try childPIDs().last.unwrap()
        reader.perform(EnvironmentRequest(.runtime(.attach(EnvironmentAttachment(createSessionIfNeeded: false)))))
        try await wait { driver.finish != nil }
        try server.run(["set-hook", "-g", "after-set-option", "run-shell 'sleep 0.05'"])
        for index in 0..<16 {
            let browser = EnvironmentBrowserState(window: WindowID(rawValue: "@0")!,
                browser: StoredBrowser(tabURLs: ["https://draining-\(index).invalid"]))
            reader.perform(EnvironmentRequest(.runtime(.browser([browser]))))
        }
        for index in 0..<112 {
            reader.perform(EnvironmentRequest(.renameWindow(name: "queued-\(index)"), target: .window(WindowID(rawValue: "@0")!)))
        }
        try await wait { !client.isConnected }
        XCTAssertEqual(kill(child, 0), 0)
        await stop(client)
        XCTAssertEqual(kill(child, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(try server.snapshot().windows.first?.storedBrowser.tabURLs, ["https://draining-15.invalid"])
    }

    @MainActor func testWatchExitsAfterInputEOFAndAfterOutputCloses() async throws {
        for closeOutput in [false, true] {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = wrapper
            process.arguments = ["environment", "watch", "--socket", server.socketPath, "--tmux-config", "/dev/null"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            directProcesses.append(process)
            try output.fileHandleForWriting.close()
            let hello = EnvironmentWatchInput.hello(version: EnvironmentWatchProtocol.version, settings: EnvironmentRuleSettings(config: Config()))
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(hello) + Data([10]))
            if closeOutput { try output.fileHandleForReading.close() }
            else { try input.fileHandleForWriting.close() }
            do { try await wait { !process.isRunning } }
            catch {
                kill(process.processIdentifier, SIGKILL)
                try await wait { !process.isRunning }
                throw error
            }
            if !closeOutput { XCTAssertFalse(output.fileHandleForReading.readDataToEndOfFile().isEmpty) }
        }
    }

    @MainActor private func makeClient() -> EnvironmentWatchClient {
        let client = EnvironmentWatchClient(executable: wrapper, socketPath: server.socketPath, configPath: "/dev/null", settings: EnvironmentRuleSettings(config: Config()))
        watchClients.append(client)
        return client
    }

    @MainActor private func wait(timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw NSError(domain: "EnvironmentWatchTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Watch condition timed out"]) }
    }

    private func childPIDs() throws -> [pid_t] {
        try String(contentsOf: root.appendingPathComponent("pids"), encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
    }

    @MainActor private func perform(_ request: EnvironmentRequest, on reader: EnvironmentReader) async -> EnvironmentWriteReceipt<EnvironmentResponse> {
        await withCheckedContinuation { continuation in reader.perform(request) { continuation.resume(returning: $0) } }
    }
    @MainActor private func retire(_ reader: EnvironmentReader) async {
        await withCheckedContinuation { continuation in reader.retire { continuation.resume() } }
    }
    @MainActor private func stop(_ client: EnvironmentWatchClient) async {
        await withCheckedContinuation { continuation in client.stop { continuation.resume() } }
    }
}

@MainActor private final class HoldingAttachment: EnvironmentAttachmentDriver {
    var finish: ((Result<Void, Error>) -> Void)?
    var calls = 0
    func attach(_ plan: EnvironmentAttachment, completion: @escaping (Result<Void, Error>) -> Void) {
        calls += 1
        finish = completion
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped { try XCTUnwrap(self) }
}
