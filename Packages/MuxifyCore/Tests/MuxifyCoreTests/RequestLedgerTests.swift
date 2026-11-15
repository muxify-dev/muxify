import XCTest
@testable import MuxifyCore

final class RequestLedgerTests: XCTestCase {
    private var root: URL!
    private var paths: MuxifyPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-requests-" + UUID().uuidString)
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func request(_ id: String = "3F2B8C1E-7A4D-4E9B-9C0A-5D6E7F8A9B0C", verb: String = "topic new", words: [String] = ["Fix login"],
                         pane: String? = "%1", directory: String = "/work") throws -> PendingRequest {
        PendingRequest(id: try XCTUnwrap(RequestID(id)), verb: verb, words: words, callerPane: pane, workingDirectory: directory)
    }

    func testARequestIDIsAUUIDInLowerCase() throws {
        XCTAssertEqual(RequestID("3F2B8C1E-7A4D-4E9B-9C0A-5D6E7F8A9B0C")?.rawValue, "3f2b8c1e-7a4d-4e9b-9c0a-5d6e7f8a9b0c")
        XCTAssertNil(RequestID("fix-login"))
        XCTAssertNil(RequestID(""))
    }

    func testANewIDIsNewAndReadsCreateNoStateFolder() throws {
        XCTAssertEqual(try RequestLedger(paths: paths).lookup(try request()), .new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
    }

    func testAFinishedRequestReplaysItsReplyForTheSameVerbAndArguments() throws {
        let ledger = RequestLedger(paths: paths)
        let reply = RequestReply(stdout: "{\"changed\":{}}\n", stderr: "No changes were made.", exitCode: 1)
        try ledger.finish(try request(), reply: reply)
        XCTAssertEqual(try ledger.lookup(try request()), .replay(reply))
        XCTAssertEqual(try RequestLedger(paths: paths).lookup(try request("3f2b8c1e-7a4d-4e9b-9c0a-5d6e7f8a9b0c")), .replay(reply),
                       "the id is the same in upper and lower case")
    }

    func testTheSameIDWithAnotherVerbOrOtherArgumentsIsAMismatch() throws {
        let ledger = RequestLedger(paths: paths)
        try ledger.finish(try request(), reply: RequestReply(stdout: "id\n"))
        XCTAssertEqual(try ledger.lookup(try request(verb: "topic rename")), .mismatch(verb: "topic new"))
        XCTAssertEqual(try ledger.lookup(try request(words: ["Other"])), .mismatch(verb: "topic new"))
        XCTAssertEqual(try ledger.lookup(try request(pane: "%2")), .mismatch(verb: "topic new"), "the caller Pane is the default target")
        XCTAssertEqual(try ledger.lookup(try request(directory: "/other")), .mismatch(verb: "topic new"),
                       "a relative folder means another folder there")
    }

    func testARecordWriteStartsTheRequestInItsTransaction() throws {
        let pending = try request()
        let store = TopicStore(paths: paths, request: pending)
        XCTAssertThrowsError(try store.write { transaction in
            try transaction.create(TopicRecord(id: "a", title: "A"))
            throw CancellationError()
        })
        XCTAssertEqual(try RequestLedger(paths: paths).lookup(pending), .new, "a write that rolls back starts nothing")

        try store.write { try $0.create(TopicRecord(id: "a", title: "A")) }
        XCTAssertEqual(try RequestLedger(paths: paths).lookup(pending), .resume)
        XCTAssertEqual(try RequestLedger(paths: paths).lookup(try request(words: ["Other"])), .mismatch(verb: "topic new"))

        try store.write { try $0.update("a") { $0.title = "B" } }
        try RequestLedger(paths: paths).finish(pending, reply: RequestReply(stdout: "a\n"))
        try store.write { try $0.update("a") { $0.title = "C" } }
        XCTAssertEqual(try RequestLedger(paths: paths).lookup(pending), .replay(RequestReply(stdout: "a\n")),
                       "a later write of the same Request leaves the done row")
    }

    func testAStoreWithNoRequestWritesNoRow() throws {
        try TopicStore(paths: paths).write { try $0.create(TopicRecord(id: "a", title: "A")) }
        let connection = try StateDatabase.open(paths)
        XCTAssertEqual(try connection.query("SELECT COUNT(*) FROM applied_requests") { $0.int(0) }, [0])
    }

    func testALedgerWriteRemovesTheRowsOlderThanADay() throws {
        let ledger = RequestLedger(paths: paths)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try request(), recent = try request("aaaaaaaa-7a4d-4e9b-9c0a-5d6e7f8a9b0c")
        try ledger.finish(old, reply: RequestReply(stdout: "old\n"), now: now.addingTimeInterval(-86401))
        try ledger.finish(recent, reply: RequestReply(stdout: "recent\n"), now: now.addingTimeInterval(-86399))
        XCTAssertEqual(try ledger.lookup(old), .replay(RequestReply(stdout: "old\n")), "a read removes nothing")

        try ledger.finish(try request("bbbbbbbb-7a4d-4e9b-9c0a-5d6e7f8a9b0c"), reply: RequestReply(stdout: "new\n"), now: now)
        XCTAssertEqual(try ledger.lookup(old), .new, "the id of a removed row runs as a new Request")
        XCTAssertEqual(try ledger.lookup(recent), .replay(RequestReply(stdout: "recent\n")))
    }

    func testTheSecondLockOfOneIDWaitsForTheFirst() throws {
        let ledger = RequestLedger(paths: paths)
        let id = try request().id
        let first = try ledger.lock(id)
        let other = try ledger.lock(try XCTUnwrap(RequestID("aaaaaaaa-7a4d-4e9b-9c0a-5d6e7f8a9b0c")))
        other.unlock()

        let taken = expectation(description: "the second lock")
        let order = Order()
        Thread.detachNewThread {
            let second = try? RequestLedger(paths: self.paths).lock(id)
            order.add("second")
            second?.unlock()
            taken.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        order.add("first")
        first.unlock()
        wait(for: [taken], timeout: 5)
        XCTAssertEqual(order.values, ["first", "second"])
    }

    func testOnlyAnOldLockFileThatNoProcessHoldsIsRemoved() throws {
        let ledger = RequestLedger(paths: paths)
        let now = Date()
        let held = try ledger.lock(try request().id, now: now)
        let idle = try ledger.lock(try XCTUnwrap(RequestID("aaaaaaaa-7a4d-4e9b-9c0a-5d6e7f8a9b0c")), now: now)
        idle.unlock()
        let folder = paths.state.appendingPathComponent("requests")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)

        let fresh = try ledger.lock(try XCTUnwrap(RequestID("bbbbbbbb-7a4d-4e9b-9c0a-5d6e7f8a9b0c")), now: now.addingTimeInterval(86400 * 2))
        fresh.unlock()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["3f2b8c1e-7a4d-4e9b-9c0a-5d6e7f8a9b0c.lock", "bbbbbbbb-7a4d-4e9b-9c0a-5d6e7f8a9b0c.lock"])
        held.unlock()
    }

    func testOnlyARefusalThatChangedNothingIsFinal() {
        XCTAssertTrue(TopicFailure(kind: .tagUndefined, phase: .nothingChanged, message: "").isRefusal)
        XCTAssertTrue(TopicFailure(kind: .topicUnavailable, phase: .nothingChanged, message: "").isRefusal)
        XCTAssertTrue(TopicFailure(kind: .cardAtEnd, phase: .nothingChanged, message: "").isRefusal)
        for kind in [TopicFailure.Kind.storeBusy, .storeFailed, .tmuxFailed, .gitFailed, .hookFailed, .sourceUnavailable,
                     TopicFailure.Kind(rawValue: "a_kind_of_a_newer_muxify")] {
            XCTAssertFalse(TopicFailure(kind: kind, phase: .nothingChanged, message: "").isRefusal, kind.rawValue)
        }
        XCTAssertFalse(TopicFailure(kind: .topicUnavailable, phase: .recordSaved, message: "").isRefusal,
                       "a failure after the record changed is not a refusal")
    }
}

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func add(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
