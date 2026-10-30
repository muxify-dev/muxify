import XCTest
@testable import MuxifyCore

final class TopicStoreTests: XCTestCase {
    private var root: URL!
    private var paths: MuxifyPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-store-" + UUID().uuidString)
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testUnreadDefaultsRoundTripsAndPreservesOtherWriters() throws {
        let old = try JSONDecoder().decode(TopicRecord.self, from: Data(#"{"id":"t","future":{"value":7}}"#.utf8))
        XCTAssertFalse(old.isUnread)
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(old) }
        try store.write { try $0.update("t") { $0.isUnread = true } }
        var renamed = old
        renamed.title = "Renamed"
        try store.write { try $0.apply(TopicRecordChange(before: old, after: renamed)) }
        let read = try XCTUnwrap(store.read().records.first)
        XCTAssertTrue(read.isUnread)
        XCTAssertEqual(read.title, "Renamed")
        XCTAssertEqual(read.unknownFields, old.unknownFields)
        XCTAssertEqual(try JSONDecoder().decode(TopicRecord.self, from: JSONEncoder().encode(read)), read)
        try store.write { try $0.update("t") { $0.isUnread = false } }
        let cleared = try XCTUnwrap(store.read().records.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        XCTAssertNil(json["unread"])
        XCTAssertEqual(cleared.title, "Renamed")
    }

    func testStaleEditsCannotCreateAForgottenTopicAgain() throws {
        let store = TopicStore(paths: paths)
        let kept = TopicRecord(id: "kept", title: "Kept")
        let other = TopicRecord(id: "other", title: "Other")
        try store.write { transaction in
            try transaction.create(kept)
            try transaction.create(other)
        }
        var remembered = kept
        remembered.sessions = [.object(["repository_path": .string("/sessionPath")])]
        try store.write { try $0.forget(kept.id) }
        XCTAssertEqual(try store.read().records.map(\.id), [other.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.topics.appendingPathComponent("kept.json").path))
        XCTAssertThrowsError(try store.write { try $0.apply(TopicRecordChange(before: kept, after: remembered)) })
        XCTAssertThrowsError(try store.write { try $0.update(kept.id) { $0.title = "Stale" } })
        XCTAssertEqual(try store.read().records.map(\.id), [other.id])
    }

    private func record(_ id: String, order: Double?) -> TopicRecord {
        var record = TopicRecord(id: id, title: id.uppercased())
        record.order = order
        return record
    }

    private func records(_ store: TopicStore) throws -> [TopicRecord] { try store.read().records }

    /// Writes the records as they are, as files that another writer left.
    private func seed(_ records: TopicRecord...) throws {
        try FileManager.default.createDirectory(at: paths.topics, withIntermediateDirectories: true)
        for record in records { try TopicStore.encoded(record).write(to: paths.topics.appendingPathComponent(record.id + ".json")) }
    }

    func testAnOldPlanKeepsTheNoteThatAnotherWriterSet() throws {
        let a = TopicStore(paths: paths), b = TopicStore(paths: paths)
        try a.write { try $0.create(TopicRecord(id: "t", title: "Old")) }
        let read = try XCTUnwrap(a.read().records.first)
        try b.write { try $0.setNote(of: "t", "Bisect") }
        var renamed = read
        renamed.title = "New"
        try a.write { try $0.apply(TopicRecordChange(before: read, after: renamed)) }
        XCTAssertEqual(try records(a).map(\.title), ["New"])
        XCTAssertEqual(try records(a).map(\.note), ["Bisect"])
    }

    func testTheMergeTakesEachChangedKeyAndKeepsNumbersAndUnknownFieldsExact() throws {
        let store = TopicStore(paths: paths)
        var original = TopicRecord(id: "t", title: "T")
        original.order = 0.30000000000000004
        original.unknownFields = ["large": .unsignedInteger(UInt64.max), "kept": .string("disk")]
        try store.write { try $0.create(original) }
        let read = try XCTUnwrap(records(store).first)
        try store.write {
            try $0.update("t") { record in
                record.unknownFields["other"] = .bool(true)
                record.outcome = "theirs"
            }
        }
        var after = read
        after.unknownFields["kept"] = nil
        after.unknownFields["mine"] = .number(Decimal(string: "1.5e-20")!)
        after.outcome = "mine"
        try store.write { try $0.apply(TopicRecordChange(before: read, after: after)) }
        let merged = try XCTUnwrap(records(store).first)
        XCTAssertEqual(merged.order, read.order)
        XCTAssertEqual(merged.unknownFields["large"], .unsignedInteger(UInt64.max))
        XCTAssertNil(merged.unknownFields["kept"], "a key the plan removed is removed")
        XCTAssertEqual(merged.unknownFields["other"], .bool(true), "a key only the other writer set stays")
        XCTAssertEqual(merged.unknownFields["mine"], .number(Decimal(string: "1.5e-20")!))
        XCTAssertEqual(merged.outcome, "mine", "the last write wins for a key both writers changed")
    }

    func testAWriteWaitsForTheLockThatAnotherProcessHoldsAndACrashReleasesIt() throws {
        let store = TopicStore(paths: paths, lockTimeout: 0.3)
        try store.write { try $0.create(TopicRecord(id: "t")) }
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", #"use Fcntl ":flock"; open(F, "<", $ARGV[0]) or die; flock(F, LOCK_EX) or die; $| = 1; print "held\n"; sleep 30"#,
                            paths.recordLock.path]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }
        XCTAssertEqual(String(data: output.fileHandleForReading.availableData, encoding: .utf8), "held\n")

        XCTAssertThrowsError(try store.write { try $0.update("t") { $0.title = "Blocked" } }) { error in
            XCTAssertTrue(error is FileLock.Busy, "\(error)")
        }
        XCTAssertThrowsError(try store.read(), "a read waits for a writer too")
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        try store.write { try $0.update("t") { $0.title = "After" } }
        XCTAssertEqual(try records(store).map(\.title), ["After"])
    }

    func testTwoWritersInOneProcessExcludeEachOther() throws {
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(TopicRecord(id: "t", title: "0")) }
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            try! store.write { transaction in
                try transaction.update("t") { $0.title = String(Int($0.title!)! + 1) }
            }
        }
        XCTAssertEqual(try records(store).map(\.title), ["20"], "each increment read the one before it")
    }

    func testAWriteRemovesTheStagingFolderThatACrashedSwapLeft() throws {
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(record("a", order: 0)) }
        let orphan = paths.state.appendingPathComponent(".topics-crashed", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try store.write { try $0.update("a") { $0.title = "Next" } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testAReadWithoutAStateFolderCreatesNothing() throws {
        XCTAssertEqual(try TopicStore(paths: paths).read(), TopicContents(records: [], problems: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testTheStampChangesForEachWriteEvenWithTheSameSize() throws {
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(TopicRecord(id: "t", title: "A")) }
        let first = store.stamp()
        try store.write { try $0.update("t") { $0.title = "B" } }
        XCTAssertNotEqual(store.stamp(), first)
    }

    func testRecordRoundTripPreservesUnknownNestedValuesAndLargeIntegers() throws {
        let data = Data(#"{"id":"test","title":"Before","slug":"test","home_project":"/work/app","created_at":"2026-10-06T20:00:00Z","settled_at":null,"outcome":null,"order":2,"future":{"large":18446744073709551615,"items":[true,null,0.125]},"sessions":[{"repository_path":"/work/app","future_session":42,"windows":[{"future_window":{"key":"kept"}}]}]}"#.utf8)
        let record = try JSONDecoder().decode(TopicRecord.self, from: data)
        let store = TopicStore(paths: paths)
        try seed(record)
        try store.write { try $0.update("test") { $0.title = "After" } }
        var expected = record
        expected.title = "After"
        let loaded = try XCTUnwrap(records(TopicStore(paths: paths)).first)
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(loaded.unknownFields["future"]?["large"], .unsignedInteger(UInt64.max))
        XCTAssertEqual(loaded.sessions.first?["future_session"], .integer(42))
        let rewritten = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: paths.topics.appendingPathComponent("test.json")))
        XCTAssertEqual(rewritten["sessions"], try JSONDecoder().decode([String: JSONValue].self, from: data)["sessions"])
        XCTAssertEqual(rewritten["title"], .string("After"))
    }

    func testInvalidFileDoesNotHideOtherTopicsAndAWriteRejectsPathIDs() throws {
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(TopicRecord(id: "valid")) }
        try Data("{".utf8).write(to: paths.topics.appendingPathComponent("bad.json"))
        let contents = try store.read()
        XCTAssertEqual(contents.records.map(\.id), ["valid"])
        XCTAssertEqual(contents.problems.count, 1)
        XCTAssertThrowsError(try store.write { try $0.create(TopicRecord(id: "../escape")) })
    }

    func testMovesKeepUnrelatedValuesThatAnotherWriterSaved() throws {
        let store = TopicStore(paths: paths)
        let originals = [record("a", order: 0), record("b", order: 0), record("c", order: 0)]
        try seed(originals[0], originals[1], originals[2])
        try TopicStore(paths: paths).write {
            try $0.update("b") { record in
                record.note = "Bisect"
                record.unknownFields["external"] = .bool(true)
            }
        }
        try store.write { try $0.move(.topic("c"), to: .before(.topic("b"))) }
        let moved = try records(TopicStore(paths: paths))
        XCTAssertEqual(TopicOrder.sorted(moved.map(TopicListEntry.topic)).records.map(\.id), ["a", "c", "b"])
        XCTAssertEqual(moved.first { $0.id == "b" }?.note, "Bisect")
        XCTAssertEqual(moved.first { $0.id == "b" }?.unknownFields["external"], .bool(true))
        try store.write { try $0.create(record("new", order: nil)) }
        XCTAssertEqual(TopicOrder.sorted(try records(store).map(TopicListEntry.topic)).records.map(\.id), ["a", "c", "b", "new"])
    }

    func testCreationNormalizesExtremeRanksAndAFailedPreflightWritesNothing() throws {
        let store = TopicStore(paths: paths)
        let existing = record("a", order: -.greatestFiniteMagnitude)
        try seed(existing)
        let file = paths.topics.appendingPathComponent("a.json")
        let before = try Data(contentsOf: file)
        XCTAssertThrowsError(try store.write { try $0.create(record("../invalid", order: nil)) })
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try store.write { try $0.move(.topic("a"), to: .after(.topic("missing"))) })
        XCTAssertEqual(try Data(contentsOf: file), before)
        try store.write { try $0.create(record("new", order: nil), arrival: .end(.top)) }
        XCTAssertEqual(TopicOrder.sorted(try records(store).map(TopicListEntry.topic)).records.map(\.id), ["new", "a"])
        XCTAssertTrue(try records(store).allSatisfy { $0.order?.isFinite == true })
    }

    func testANewTopicFromALockedSessionTakesTheLocksPlace() throws {
        let store = TopicStore(paths: paths)
        try seed(record("a", order: 0), record("b", order: 1))
        let left = try store.write(locks: [SessionLock(sessionID: "$4", order: 0.5)]) { transaction -> [SessionLock] in
            try transaction.create(record("new", order: nil), replacingLockOf: "$4")
            try transaction.create(record("other", order: nil), replacingLockOf: "$9")
            return transaction.locks
        }
        XCTAssertEqual(left, [], "the Topic takes the place of the Lock, which ends")
        XCTAssertEqual(try shown(store), ["a", "new", "b", "other"], "a Topic from no Lock uses the configured end")
    }

    func testALockGoesLastAndALockedSessionKeepsItsPlace() throws {
        let store = TopicStore(paths: paths)
        try seed(record("a", order: 0), record("b", order: 1))
        let locks = [SessionLock(sessionID: "$1", order: 0.5)]
        let added = try store.write(locks: locks) { transaction -> [SessionLockChange] in
            transaction.lock("$2") + transaction.lock("$1")
        }
        XCTAssertEqual(added, [.set(SessionLock(sessionID: "$2", order: 2))])
    }

    func testCreationDoesNotReplaceAnUnreadableTopicFile() throws {
        try FileManager.default.createDirectory(at: paths.topics, withIntermediateDirectories: true)
        let file = paths.topics.appendingPathComponent("occupied.json")
        let contents = Data("not json".utf8)
        try contents.write(to: file)
        XCTAssertThrowsError(try TopicStore(paths: paths).write { try $0.create(record("occupied", order: nil)) })
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testAFailedMoveAfterOneStagedWriteKeepsTheOrderOnDisk() throws {
        let originals = [record("a", order: 0), record("b", order: 0), record("c", order: 0)]
        try seed(originals[0], originals[1], originals[2])
        let writes = Counter()
        let failing = TopicStore(paths: paths) { data, url in
            if writes.next() == 2 { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
        }
        XCTAssertThrowsError(try failing.write { try $0.move(.topic("c"), to: .before(.topic("b"))) })
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(TopicOrder.sorted(try records(failing).map(TopicListEntry.topic)).records.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.state.path).filter { $0.hasPrefix(".topics-") }, [])
    }

    func testApplyingANewTopicPutsItLast() throws {
        try seed(record("a", order: 0))
        try TopicStore(paths: paths).write { try $0.apply(TopicRecordChange(before: nil, after: record("new", order: nil))) }
        XCTAssertEqual(TopicOrder.sorted(try records(TopicStore(paths: paths)).map(TopicListEntry.topic)).records.map(\.id), ["a", "new"])
    }

    private func shown(_ store: TopicStore) throws -> [String] { TopicOrder.sorted(try records(store).map(TopicListEntry.topic)).records.map(\.id) }

    func testPinPutsATopicLastAmongPinnedTopicsAndUnpinFirstAmongTheOthers() throws {
        let store = TopicStore(paths: paths)
        try seed(record("a", order: 0), record("b", order: 1), record("c", order: 2), record("d", order: 3), record("e", order: 4))
        try store.write { try $0.pin("c", true) }
        XCTAssertEqual(try shown(store), ["c", "a", "b", "d", "e"])
        try store.write { try $0.pin("e", true) }
        XCTAssertEqual(try shown(store), ["c", "e", "a", "b", "d"], "a new Pin goes below the Topics already Pinned")
        try store.write { try $0.pin("c", false) }
        XCTAssertEqual(try shown(store), ["e", "c", "a", "b", "d"], "Unpin puts the Topic first among the others")
        XCTAssertEqual(try records(store).filter(\.isPinned).map(\.id), ["e"])
        XCTAssertThrowsError(try store.write { try $0.pin("missing", true) })
    }

    func testUnpinNextToAnExhaustedRankRenumbersTheOpenTopics() throws {
        let store = TopicStore(paths: paths)
        var pinned = record("p", order: 0)
        pinned.isPinned = true
        try seed(record("a", order: -.greatestFiniteMagnitude), pinned)
        try store.write { try $0.pin("p", false) }
        XCTAssertEqual(try shown(store), ["p", "a"])
        XCTAssertTrue(try records(store).allSatisfy { !$0.isPinned && $0.order?.isFinite == true })
    }

    func testMovesStayAmongTheTopicsWithTheSamePin() throws {
        let store = TopicStore(paths: paths)
        var first = record("p1", order: 0), second = record("p2", order: 1)
        first.isPinned = true
        second.isPinned = true
        try seed(first, second, record("a", order: 0), record("b", order: 1), record("c", order: 2))
        try store.write { try $0.move(.topic("b"), to: .before(.topic("p1"))) }
        XCTAssertEqual(try shown(store), ["p1", "p2", "b", "a", "c"], "an anchor among the Pinned Topics puts the Topic first among the others")
        try store.write { try $0.move(.topic("p1"), to: .after(.topic("c"))) }
        XCTAssertEqual(try shown(store), ["p2", "p1", "b", "a", "c"], "an anchor below the Pinned Topics puts the Topic last among them")
        try store.write { try $0.move(.topic("a"), to: .after(.topic("p1"))) }
        XCTAssertEqual(try shown(store), ["p2", "p1", "a", "b", "c"])
        XCTAssertEqual(try records(store).filter(\.isPinned).map(\.id).sorted(), ["p1", "p2"], "a move never pins or unpins")
    }

    func testANewTopicGoesBelowThePinnedTopics() throws {
        let store = TopicStore(paths: paths)
        var pinned = record("p", order: 5)
        pinned.isPinned = true
        try seed(pinned, record("a", order: 0))
        try store.write { try $0.create(record("new", order: nil)) }
        let planned = TopicRecord(newTopic: "planned", title: "Planned", slug: "planned", now: Date())
        try store.write { try $0.apply(TopicRecordChange(before: nil, after: planned)) }
        XCTAssertEqual(try shown(store), ["p", "a", "new", "planned"])
    }

    func testAPinIsSavedAsPinnedAndSurvivesSettleAndReopen() throws {
        let store = TopicStore(paths: paths)
        var other = record("p", order: 0)
        other.isPinned = true
        try seed(other, record("a", order: 0), record("t", order: 1))
        try store.write { try $0.pin("t", true) }
        let file = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: paths.topics.appendingPathComponent("t.json")))
        XCTAssertEqual(file["pinned"], .bool(true))
        let unpinned = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: paths.topics.appendingPathComponent("a.json")))
        XCTAssertNil(unpinned["pinned"], "a Topic that is not Pinned has no pinned key")
        XCTAssertEqual(try records(store).first { $0.id == "t" }?.unknownFields, [:])

        let topic = try XCTUnwrap(records(store).first { $0.id == "t" })
        let settle = TopicSettlePlan(topic: topic, snapshot: TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: true),
                                     sessionPaths: [], choices: [], outcome: "").edit
        try store.write { try $0.apply(TopicRecordChange(before: topic, after: XCTUnwrap(settle.record))) }
        XCTAssertEqual(try shown(store), ["p", "a"])
        let settled = try XCTUnwrap(records(store).first { $0.id == "t" })
        XCTAssertTrue(settled.isPinned, "Settle keeps the Pin")

        let reopen = try TopicReopenPlan(topic: settled, records: try records(store), windows: [], sessionPaths: [],
                                         existingDirectories: []).edit
        try store.write { try $0.apply(TopicRecordChange(before: settled, after: XCTUnwrap(reopen.savedCompletionRecord))) }
        XCTAssertEqual(try shown(store), ["p", "t", "a"], "Reopen brings the Topic back last among the Pinned Topics")
    }

    func testATopicNoteIsSavedAsOneLineAndSurvivesSettleAndReopen() throws {
        let old = try JSONDecoder().decode(TopicRecord.self, from: Data(#"{"id":"t","title":"T","future":{"value":7}}"#.utf8))
        XCTAssertNil(old.note, "a record without a note key has no Note")
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(old) }
        func file() throws -> [String: JSONValue] {
            try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: paths.topics.appendingPathComponent("t.json")))
        }

        try store.write { try $0.setNote(of: "t", "  Repro with seed 4411\n\n   then bisect \r\n") }
        XCTAssertEqual(try file()["note"], .string("Repro with seed 4411 then bisect"))
        XCTAssertEqual(try file()["future"], old.unknownFields["future"], "a Note change keeps unknown fields")
        let noted = try XCTUnwrap(records(store).first)
        XCTAssertEqual(try JSONDecoder().decode(TopicRecord.self, from: TopicStore.encoded(noted)), noted)

        let topic = try XCTUnwrap(records(store).first)
        let settle = TopicSettlePlan(topic: topic, snapshot: TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: true),
                                     sessionPaths: [], choices: [], outcome: "").edit
        try store.write { try $0.apply(TopicRecordChange(before: topic, after: XCTUnwrap(settle.record))) }
        let settled = try XCTUnwrap(records(store).first)
        XCTAssertEqual(settled.note, "Repro with seed 4411 then bisect", "Settle keeps the Note")
        XCTAssertThrowsError(try store.write { try $0.setNote(of: "t", "later") }, "a Settled Topic takes no Note change")

        let reopen = try TopicReopenPlan(topic: settled, records: try records(store), windows: [], sessionPaths: [],
                                         existingDirectories: []).edit
        try store.write { try $0.apply(TopicRecordChange(before: settled, after: XCTUnwrap(reopen.savedCompletionRecord))) }
        XCTAssertEqual(try records(store).first?.note, "Repro with seed 4411 then bisect", "a Reopened Topic shows where the user stopped")

        try store.write { try $0.setNote(of: "t", " \n\t ") }
        XCTAssertNil(try file()["note"], "text with no words clears the Note, and the record has no note key")
        try store.write { try $0.setNote(of: "t", "x") }
        try store.write { try $0.setNote(of: "t", nil) }
        XCTAssertNil(try records(store).first?.note)
    }

    func testInsertionPlacesTopicsAroundLocksAndNormalizesBothExtremeEnds() throws {
        for position in TopicInsertPosition.allCases {
            let edge: Double = position == .top ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
            var pinned = record("p", order: 0)
            pinned.isPinned = true
            var transaction = TopicTransaction(records: [pinned, record("a", order: edge)], topics: paths.topics)
            transaction.locks = [SessionLock(sessionID: "$1", order: edge)]
            let moved = try transaction.create(record("new", order: nil), arrival: .end(position))
            let shown = TopicOrder.sorted(transaction.records.map(TopicListEntry.topic) + transaction.locks.map(TopicListEntry.lock))
            let expected: [TopicListID] = position == .top
                ? [.topic("p"), .topic("new"), .lock(sessionID: "$1"), .topic("a")]
                : [.topic("p"), .lock(sessionID: "$1"), .topic("a"), .topic("new")]
            XCTAssertEqual(shown.map(\.id), expected)
            XCTAssertTrue(shown.allSatisfy { $0.order?.isFinite == true })
            XCTAssertEqual(moved, transaction.locks.map(SessionLockChange.set))
        }
    }

    func testReopenAndStartFreshPlaceOnlySettledTopicsAtTheConfiguredEnd() throws {
        for position in TopicInsertPosition.allCases {
            for pinned in [false, true] {
                for settled in [false, true] {
                    for remembered in [false, true] {
                        for choice: TopicReopening.Choice in [.reopen, .startFresh] {
                            var first = record("first", order: 0), last = record("last", order: 2)
                            first.isPinned = pinned
                            last.isPinned = pinned
                            var topic = record("returning", order: 1)
                            topic.isPinned = pinned
                            topic.settledAt = settled ? "2026-10-01T00:00:00Z" : nil
                            if remembered { topic.sessions = [.object(["id": .string("s"), "name": .string("app"), "directory": .string("/work/app")])] }
                            let initial = [first, topic, last]
                            let plan = try TopicReopenPlan(topic: topic, records: initial, windows: [], sessionPaths: [],
                                                          existingDirectories: [], choice: choice).edit
                            var transaction = TopicTransaction(records: initial, topics: paths.topics)
                            if let saved = plan.savedCompletionRecord {
                                try transaction.apply(TopicRecordChange(before: topic, after: saved), arrival: .end(position))
                            }
                            let expected = !settled ? ["first", "returning", "last"]
                                : position == .top ? ["returning", "first", "last"] : ["first", "last", "returning"]
                            XCTAssertEqual(TopicOrder.sorted(transaction.records.map(TopicListEntry.topic)).records.map(\.id), expected)
                        }
                    }
                }
            }
        }
    }

    func testReopenUsesCurrentPinAndDoesNotMoveAnAlreadyReopenedTopicAgain() throws {
        var settled = record("returning", order: 1)
        settled.settledAt = "2026-10-01T00:00:00Z"
        var reopened = settled
        reopened.settledAt = nil
        var current = settled
        current.isPinned = true
        var pinned = record("p", order: 0)
        pinned.isPinned = true
        var transaction = TopicTransaction(records: [pinned, current, record("a", order: 0)], topics: paths.topics)
        let change = TopicRecordChange(before: settled, after: reopened)
        try transaction.apply(change, arrival: .end(.bottom))
        XCTAssertEqual(TopicOrder.sorted(transaction.records.map(TopicListEntry.topic)).records.map(\.id), ["p", "returning", "a"])
        try transaction.apply(change, arrival: .end(.top))
        XCTAssertEqual(TopicOrder.sorted(transaction.records.map(TopicListEntry.topic)).records.map(\.id), ["p", "returning", "a"])
    }

    func testAWriteThatChangesNothingWritesNoFile() throws {
        let writes = Counter()
        let store = TopicStore(paths: paths) { data, url in
            _ = writes.next()
            try data.write(to: url, options: .atomic)
        }
        try store.write { try $0.create(TopicRecord(id: "t")) }
        try store.write { try $0.update("t") { $0.title = nil } }
        XCTAssertEqual(writes.count, 1)
    }

    func testTheUpgradeEndsZenThenPutsEachSnoozedTopicAtTheTopOfTheBenchInWakeOrder() throws {
        let lock = SessionLock(sessionID: "$1", order: 1.5)
        let cases: [(inPlay: Int?, position: TopicInsertPosition, expected: [String])] = [
            (2, .bottom, ["p", "kept", "zenA", "$1", "early", "zenB", "never", "c", "d"]),
            (nil, .top, ["p", "early", "zenB", "never", "kept", "zenA", "$1", "c", "d"]),
            (nil, .bottom, ["p", "kept", "zenA", "$1", "c", "d", "early", "zenB", "never"]),
        ]
        for (inPlay, position, expected) in cases {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: paths.topics, withIntermediateDirectories: true)
            let zenUntil = "2026-11-03T17:00:00Z"
            let files = [
                "p": #"{"id":"p","order":0,"pinned":true,"snoozed_until":"never"}"#,
                "kept": #"{"id":"kept","order":0}"#,
                "zenA": #"{"id":"zenA","order":1,"snoozed_until":"\#(zenUntil)"}"#,
                "zenB": #"{"id":"zenB","order":2,"snoozed_until":"\#(zenUntil)"}"#,
                "early": #"{"id":"early","order":3,"snoozed_until":"2026-11-01T09:00:00Z"}"#,
                "never": #"{"id":"never","order":4,"snoozed_until":"never"}"#,
                "c": #"{"id":"c","order":5}"#,
                "d": #"{"id":"d","order":6}"#,
                "s": #"{"id":"s","order":7,"settled_at":"2026-10-01T00:00:00Z","snoozed_until":"never"}"#,
            ]
            for (id, json) in files { try Data(json.utf8).write(to: paths.topics.appendingPathComponent(id + ".json")) }
            try Data(#"""
            {"kept_topic_id":"kept","until":"\#(zenUntil)","changes":[
              {"topic_id":"zenA","previous_snoozed_until":null},
              {"topic_id":"zenB","previous_snoozed_until":"2026-11-02T09:00:00Z"}]}
            """#.utf8).write(to: paths.legacyZenFile)
            let store = TopicStore(paths: paths)
            XCTAssertTrue(try store.read().needsUpgrade)

            try store.upgrade(locks: [lock], arrival: TopicArrival(inPlay: inPlay, insertPosition: position))
            let upgraded = try store.read()
            let shown = TopicOrder.sorted(upgraded.records.map(TopicListEntry.topic) + [.lock(lock)]).map { entry in
                switch entry.id {
                case .topic(let id): return id
                case .lock(let sessionID): return sessionID
                }
            }
            XCTAssertEqual(shown, expected, "in_play \(String(describing: inPlay)), insert_position \(position)")
            XCTAssertFalse(upgraded.needsUpgrade)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyZenFile.path), "the upgrade removes zen.json")
            for id in files.keys {
                let saved = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: paths.topics.appendingPathComponent(id + ".json")))
                XCTAssertNil(saved["snoozed_until"], "\(id) is written without its Snooze")
            }

            let stamp = store.stamp()
            XCTAssertEqual(try store.upgrade(locks: [lock], arrival: TopicArrival(inPlay: inPlay, insertPosition: position)), [])
            XCTAssertEqual(store.stamp(), stamp, "a second upgrade writes nothing")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
