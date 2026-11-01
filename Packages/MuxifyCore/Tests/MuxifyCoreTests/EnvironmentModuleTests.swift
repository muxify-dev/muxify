import XCTest
@testable import MuxifyCore

final class EnvironmentModuleTests: XCTestCase {
    @MainActor
    func testAWriteRejectsBothOldInventoryAndOldFailure() throws {
        for fails in [false, true] {
            let module = EnvironmentModule()
            let reader = Reader(module)
            reader.start()
            let oldRead = try XCTUnwrap(reader.pending.first)
            var finishWrite: ((String) -> Void)?
            var receipt: EnvironmentRevision?
            module.write({ finishWrite = $0 }, completion: { receipt = $0.revision })
            oldRead(fails ? failed(.timedOut) : read("old"), ())
            XCTAssertTrue(reader.states.isEmpty)
            XCTAssertFalse(module.isReady)
            try XCTUnwrap(finishWrite)("changed")
            XCTAssertNotNil(receipt)
            try XCTUnwrap(reader.pending.last)(read("new"), ())
            let state = try XCTUnwrap(reader.states.last)
            XCTAssertEqual(state.inventory.current?.lastWindowID, "new")
            XCTAssertTrue(state.revision.isAfter(try XCTUnwrap(receipt)))
            XCTAssertTrue(module.isReady)
            oldRead(failed(.connectionLost), ())
            XCTAssertEqual(reader.states.count, 1)
            XCTAssertEqual(module.state?.inventory.current?.lastWindowID, "new")
        }
    }

    @MainActor
    func testAFailedReadFromBeforeAnInvalidationIsShownAndReadAgain() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        let oldRead = try XCTUnwrap(reader.pending.first)
        module.invalidateRead()
        oldRead(failed(.timedOut), ())
        XCTAssertEqual(reader.states.last?.connection, .failed(.inventory(.timedOut)), "the timeout is shown without a second read")
        XCTAssertFalse(module.isReady)
        XCTAssertEqual(reader.pending.count, 2, "the module reads again")

        module.invalidateRead()
        reader.pending[1](read("old"), ())
        XCTAssertEqual(reader.states.count, 1, "old data from before an invalidation stays hidden")
        XCTAssertEqual(reader.pending.count, 3)
    }

    @MainActor
    func testReadRequestedDuringWriteWaitsAndWritesKeepTheirOrder() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        var finishFirst: ((()) -> Void)?
        var effects: [String] = []
        var receipts: [EnvironmentRevision] = []
        module.write({ finish in effects.append("first"); finishFirst = finish }, completion: { receipts.append($0.revision) })
        reader.start()
        module.write({ finish in effects.append("second"); finish(()) }, completion: { receipts.append($0.revision) })
        XCTAssertTrue(reader.pending.isEmpty)
        XCTAssertEqual(effects, ["first"])
        try XCTUnwrap(finishFirst)(())
        XCTAssertEqual(effects, ["first", "second"])
        XCTAssertEqual(reader.pending.count, 1)
        XCTAssertTrue(receipts[1].isAfter(receipts[0]))
        try XCTUnwrap(reader.pending.last)(read("after-both"), ())
        XCTAssertEqual(reader.states.last?.inventory.current?.lastWindowID, "after-both")
        XCTAssertTrue(try XCTUnwrap(reader.states.last).revision.isAfter(receipts[1]))
    }

    @MainActor
    func testReceiptsPrecedeStateWithSynchronousDriversAndReentrantWrites() {
        let module = EnvironmentModule()
        var value = "initial"
        var events: [String] = []
        module.refresh({ finish in finish(self.read(value), ()) }, receive: { state, _ in
            events.append("state-" + (state.inventory.current?.lastWindowID ?? "missing"))
        })
        module.write({ finish in value = "first"; finish(()) }, completion: { _ in
            events.append("receipt-first")
            module.write({ finish in value = "second"; finish(()) }, completion: { _ in
                events.append("receipt-second")
            })
        })
        XCTAssertEqual(events, ["state-initial", "receipt-first", "receipt-second", "state-second"])
        XCTAssertTrue(module.isReady)
    }

    @MainActor
    func testFailedReadKeepsDisplayInventoryButCannotConfirmAWrite() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        try XCTUnwrap(reader.pending.last)(read("before"), ())
        var receipt: EnvironmentRevision?
        module.write({ $0(Result<Void, Error>.failure(TmuxError.timedOut)) }, completion: { receipt = $0.revision })
        try XCTUnwrap(reader.pending.last)(failed(.connectionLost), ())
        let state = try XCTUnwrap(reader.states.last)
        XCTAssertNil(state.inventory.current)
        XCTAssertEqual(state.inventory.lastKnown?.lastWindowID, "before")
        XCTAssertEqual(state.connection, .failed(.inventory(.connectionLost)))
        XCTAssertFalse(state.isConfirmed)
        XCTAssertFalse(module.isReady)
        XCTAssertTrue(state.revision.isAfter(try XCTUnwrap(receipt)))
        reader.start()
        try XCTUnwrap(reader.pending.last)(read("after"), ())
        XCTAssertEqual(module.state?.inventory.current?.lastWindowID, "after")
        XCTAssertTrue(module.isReady)
    }

    @MainActor
    func testFailedWriteStillPublishesRecordsItSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-module-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TopicStore(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent"))
        let module = EnvironmentModule()
        var states: [EnvironmentState] = []
        module.refresh({ finish in
            finish(EnvironmentRead(inventory: .success(self.inventory("current")), records: Result { try store.read() }), ())
        }, receive: { state, _ in states.append(state) })
        var receipt: EnvironmentWriteReceipt<Result<Void, Error>>?
        module.write({ finish in
            let result: Result<Void, Error> = Result {
                try store.write { try $0.create(TopicRecord(id: "saved", title: "Saved before tmux failed")) }
                throw TmuxError.timedOut
            }
            finish(result)
        }, completion: { receipt = $0 })
        XCTAssertThrowsError(try XCTUnwrap(receipt).value.get())
        let state = try XCTUnwrap(states.last)
        XCTAssertEqual(state.records.current?.records.map(\.id), ["saved"])
        XCTAssertTrue(state.revision.isAfter(try XCTUnwrap(receipt).revision))
    }

    @MainActor
    func testNoOpAndFailureBothGetARevision() {
        let module = EnvironmentModule()
        let before = module.revision
        var receipts: [EnvironmentRevision] = []
        module.write({ $0(Result<Void, Error>.success(())) }, completion: { receipts.append($0.revision) })
        module.write({ $0(Result<Void, Error>.failure(TmuxError.notReady)) }, completion: { receipts.append($0.revision) })
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts[0].isAfter(before))
        XCTAssertTrue(receipts[1].isAfter(receipts[0]))
        XCTAssertFalse(module.isReady)
    }

    @MainActor
    func testUnavailableRecordsCannotAuthorizeRules() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        try XCTUnwrap(reader.pending.last)(EnvironmentRead(inventory: .success(inventory("one")),
            records: .success(TopicContents(records: [TopicRecord(id: "kept")]))), ())
        reader.start()
        try XCTUnwrap(reader.pending.last)(EnvironmentRead(inventory: .success(inventory("two")),
            records: .failure(TmuxError.timedOut)), ())
        XCTAssertNil(module.state?.records.current)
        XCTAssertEqual(module.state?.records.lastKnown?.records.map(\.id), ["kept"])
        XCTAssertFalse(module.isReady)
    }

    @MainActor
    func testRetirementDropsQueuedWritesAndLateCallbacks() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        var finish: ((()) -> Void)?
        var callbacks = 0
        module.write({ finish = $0 }, completion: { _ in callbacks += 1 })
        module.write({ (_: @escaping (()) -> Void) in callbacks += 100 })
        module.retire()
        try XCTUnwrap(finish)(())
        try XCTUnwrap(reader.pending.last)(read("old"), ())
        reader.start()
        module.write({ (_: @escaping (()) -> Void) in callbacks += 1000 })
        XCTAssertEqual(callbacks, 0)
        XCTAssertTrue(reader.states.isEmpty)
        XCTAssertFalse(module.isReady)
        XCTAssertFalse(EnvironmentModule().revision.isAfter(module.revision))
    }

    @MainActor
    func testFinalRemoteInventoryIsOnlyDisplayDataAndStopsPolling() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        let final = try XCTUnwrap(module.finishReading(lastKnownInventory: inventory("final")))
        try XCTUnwrap(reader.pending.last)(read("old"), ())
        XCTAssertNil(final.inventory.current)
        XCTAssertEqual(final.inventory.lastKnown?.lastWindowID, "final")
        XCTAssertEqual(module.state?.connection, .failed(.inventory(.connectionLost)))
        XCTAssertFalse(module.isReady)
        XCTAssertTrue(reader.states.isEmpty)
        module.write({ $0(()) })
        XCTAssertEqual(reader.pending.count, 1)
    }

    @MainActor
    func testFinalInventoryCannotReplaceAConfirmedReadAfterACompletedWrite() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        let capturedBeforeWrite = inventory("old")
        reader.start()
        try XCTUnwrap(reader.pending.last)(read("before"), ())
        var receipt: EnvironmentRevision?
        module.write({ $0(()) }, completion: { receipt = $0.revision })
        try XCTUnwrap(reader.pending.last)(read("after-write"), ())
        let final = try XCTUnwrap(module.finishReading(lastKnownInventory: capturedBeforeWrite))
        XCTAssertTrue(final.revision.isAfter(try XCTUnwrap(receipt)))
        XCTAssertNil(final.inventory.current)
        XCTAssertEqual(final.inventory.lastKnown?.lastWindowID, "after-write")
        XCTAssertEqual(final.connection, .failed(.inventory(.connectionLost)))
        XCTAssertFalse(module.isReady)
        XCTAssertEqual(reader.states.count, 2)
    }

    @MainActor
    func testFailedRemoteExitPublishesConnectionLossWithoutClearingDisplayData() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        try XCTUnwrap(reader.pending.last)(read("last-known"), ())
        let final = try XCTUnwrap(module.finishReading())
        XCTAssertEqual(final.connection, .failed(.inventory(.connectionLost)))
        XCTAssertEqual(final.inventory.lastKnown?.lastWindowID, "last-known")
        XCTAssertFalse(final.isConfirmed)
        XCTAssertFalse(module.isReady)
    }

    @MainActor
    func testFinalInventoryDuringAWriteCannotConfirmIt() throws {
        let module = EnvironmentModule()
        var finish: ((()) -> Void)?
        module.write { finish = $0 }
        let final = try XCTUnwrap(module.finishReading(lastKnownInventory: inventory("uncertain")))
        try XCTUnwrap(finish)(())
        XCTAssertNil(final.inventory.current)
        XCTAssertEqual(module.state?.connection, .failed(.inventory(.connectionLost)))
        XCTAssertFalse(module.isReady)
    }

    @MainActor
    func testRetirementDrainsRequiredRecordsAndCancelsQueuedTransportWork() throws {
        let module = EnvironmentModule()
        var finishTransport: ((()) -> Void)?
        var finishSave: ((()) -> Void)?
        var saved = false
        var transportRan = false
        var callbackRan = false
        var retired = false
        module.write { finishTransport = $0 }
        module.write(requiredPersistence: true, { finish in
            saved = true
            finishSave = finish
        }, completion: { _ in callbackRan = true })
        module.write { (finish: @escaping (()) -> Void) in transportRan = true; finish(()) }
        module.retire { retired = true }
        XCTAssertFalse(saved)
        XCTAssertFalse(retired)
        try XCTUnwrap(finishTransport)(())
        XCTAssertTrue(saved)
        XCTAssertFalse(retired)
        try XCTUnwrap(finishSave)(())
        XCTAssertTrue(retired)
        XCTAssertFalse(transportRan)
        XCTAssertFalse(callbackRan)
        XCTAssertFalse(module.isReady)
    }

    @MainActor
    func testActiveRequiredSaveRetainsRetiredModuleUntilItFinishes() throws {
        var module: EnvironmentModule? = EnvironmentModule()
        weak var retained = module
        var finishSave: ((()) -> Void)?
        var retired = false
        module?.write(requiredPersistence: true, { finishSave = $0 })
        module?.retire { retired = true }
        module = nil
        XCTAssertNotNil(retained)
        XCTAssertFalse(retired)
        try XCTUnwrap(finishSave)(())
        XCTAssertTrue(retired)
        finishSave = nil
        XCTAssertNil(retained)
    }

    @MainActor
    func testExternalInvalidationRejectsAnOldRead() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        module.invalidateRead()
        try XCTUnwrap(reader.pending.last)(read("old-view-or-records"), ())
        XCTAssertTrue(reader.states.isEmpty)
        XCTAssertEqual(reader.pending.count, 2)
        try XCTUnwrap(reader.pending.last)(read("current-view-and-records"), ())
        XCTAssertTrue(module.isReady)
        XCTAssertEqual(module.state?.inventory.current?.lastWindowID, "current-view-and-records")
    }

    @MainActor
    func testConnectionDistinctionsAndStateRoundTrip() throws {
        let module = EnvironmentModule()
        let reader = Reader(module)
        reader.start()
        try XCTUnwrap(reader.pending.last)(EnvironmentRead(inventory: .success(TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: false)), records: .success(TopicContents())), ())
        XCTAssertEqual(module.state?.connection, .noServer)
        reader.start()
        try XCTUnwrap(reader.pending.last)(read("running-empty"), ())
        XCTAssertEqual(module.state?.connection, .available)
        reader.start()
        try XCTUnwrap(reader.pending.last)(EnvironmentRead(inventory: .failure(TmuxError.notReady), records: .success(TopicContents())), ())
        XCTAssertEqual(module.state?.connection, .failed(.tmux(.notReady)))
        let state = try XCTUnwrap(module.state)
        let copy = try JSONDecoder().decode(EnvironmentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(copy.revision, state.revision)
        XCTAssertEqual(copy.connection, state.connection)
        XCTAssertEqual(copy.inventory.lastKnown?.lastWindowID, "running-empty")
        XCTAssertNil(copy.inventory.current)
    }

    private func inventory(_ value: String) -> TmuxSnapshot {
        TmuxSnapshot(windows: [], clients: [], panes: [], lastWindowID: value, serverRunning: true)
    }

    private func read(_ value: String) -> EnvironmentRead {
        EnvironmentRead(inventory: .success(inventory(value)), records: .success(TopicContents()))
    }

    private func failed(_ error: InventoryReadFailure) -> EnvironmentRead {
        EnvironmentRead(inventory: .failure(error), records: .success(TopicContents()))
    }
}

@MainActor
private final class Reader {
    let module: EnvironmentModule
    var pending: [(EnvironmentRead, Void) -> Void] = []
    var states: [EnvironmentState] = []

    init(_ module: EnvironmentModule) { self.module = module }

    func start() {
        module.refresh({ [self] finish in pending.append(finish) }, receive: { [self] state, _ in states.append(state) })
    }
}
