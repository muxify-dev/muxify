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

    func testUnreadDefaultsRoundTripsAndKeepsAnotherWritersChange() throws {
        let old = TopicRecord(id: "t")
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
        XCTAssertEqual(try JSONDecoder().decode(TopicRecord.self, from: JSONEncoder().encode(read)), read)
        try store.write { try $0.update("t") { $0.isUnread = false } }
        let cleared = try XCTUnwrap(store.read().records.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        XCTAssertNil(json["unread"])
        XCTAssertEqual(cleared.title, "Renamed")
        XCTAssertEqual(try paths.storedTopicRecord("t")?["unread"], .integer(0))
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
        try store.write { try $0.forget([kept.id]) }
        XCTAssertEqual(try store.read().records.map(\.id), [other.id])
        XCTAssertNil(try paths.storedTopicRecord("kept"))
        XCTAssertThrowsError(try store.write { try $0.apply(TopicRecordChange(before: kept, after: remembered)) })
        XCTAssertThrowsError(try store.write { try $0.update(kept.id) { $0.title = "Stale" } })
        XCTAssertEqual(try store.read().records.map(\.id), [other.id])
    }

    func testOneForgetRemovesEveryNamedRecordOrNoneWhenOneIsGone() throws {
        let store = TopicStore(paths: paths)
        try store.write { transaction in
            for id in ["a", "b", "c"] { try transaction.create(TopicRecord(id: id, title: id)) }
        }
        XCTAssertThrowsError(try store.write { try $0.forget(["a", "gone"]) })
        XCTAssertEqual(try store.read().records.map(\.id), ["a", "b", "c"], "a forget that names a missing record changed the file")
        try store.write { try $0.forget(["c", "a"]) }
        XCTAssertEqual(try store.read().records.map(\.id), ["b"])
    }

    private func record(_ id: String, order: Double?) -> TopicRecord {
        var record = TopicRecord(id: id, title: id.uppercased())
        record.order = order
        return record
    }

    private func records(_ store: TopicStore) throws -> [TopicRecord] { try store.read().records }

    /// Inserts the records as they are, as another writer left them.
    private func seed(_ records: TopicRecord...) throws {
        for record in records { try paths.seedTopicRecords(record) }
    }

    private func stored(_ id: String) throws -> [String: SQLiteValue] {
        try XCTUnwrap(paths.storedTopicRecord(id), "no row \(id) in topics")
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

    func testTwoStoresThatChangeDifferentFieldsOfOneTopicBothKeepTheirChange() throws {
        let a = TopicStore(paths: paths), b = TopicStore(paths: paths)
        try a.write { try $0.create(TopicRecord(id: "t", title: "Old")) }
        let readByA = try XCTUnwrap(a.read().records.first)
        let readByB = try XCTUnwrap(b.read().records.first)
        var renamed = readByA
        renamed.title = "New"
        var tagged = readByB
        tagged.tags = [Tag(name: "backend")!]
        tagged.isPinned = true
        try a.write { try $0.apply(TopicRecordChange(before: readByA, after: renamed)) }
        try b.write { try $0.apply(TopicRecordChange(before: readByB, after: tagged)) }
        for store in [a, b, TopicStore(paths: paths)] {
            let record = try XCTUnwrap(records(store).first)
            XCTAssertEqual(record.title, "New", "the tag change from an older read kept the title")
            XCTAssertEqual(record.tags, [Tag(name: "backend")!])
            XCTAssertTrue(record.isPinned)
        }
    }

    func testTwoStoresThatChangeTheSameFieldLeaveTheLastWrite() throws {
        let a = TopicStore(paths: paths), b = TopicStore(paths: paths)
        try a.write { transaction in
            try transaction.create(TopicRecord(id: "t", title: "T"))
            try transaction.update("t") { record in
                record.order = 0.30000000000000004
                record.outcome = "none"
            }
        }
        let readByA = try XCTUnwrap(records(a).first)
        let readByB = try XCTUnwrap(records(b).first)
        var mine = readByA, theirs = readByB
        mine.outcome = "mine"
        theirs.outcome = "theirs"
        theirs.note = "Bisect"
        try b.write { try $0.apply(TopicRecordChange(before: readByB, after: theirs)) }
        try a.write { try $0.apply(TopicRecordChange(before: readByA, after: mine)) }
        let merged = try XCTUnwrap(records(TopicStore(paths: paths)).first)
        XCTAssertEqual(merged.outcome, "mine", "the last write wins for a field both writers changed")
        XCTAssertEqual(merged.note, "Bisect", "a field only the other writer changed stays")
        XCTAssertEqual(merged.order, 0.30000000000000004, "a number stays exact")
        try a.write { try $0.update("t") { $0.outcome = nil } }
        XCTAssertNil(try records(b).first?.outcome, "a field set to nothing is NULL for every reader")
    }

    func testTheChangeTokenMovesWhenAnotherConnectionCommitsAndStaysOtherwise() throws {
        let watcher = TopicStore(paths: paths), writer = TopicStore(paths: paths)
        XCTAssertNil(watcher.changeToken(), "there is nothing to watch before the state folder")
        try writer.write { try $0.create(TopicRecord(id: "t", title: "A")) }
        let first = try XCTUnwrap(watcher.changeToken())
        XCTAssertEqual(watcher.changeToken(), first, "no commit, no move")
        _ = try records(writer)
        XCTAssertEqual(watcher.changeToken(), first, "a read commits nothing")
        try writer.write { try $0.update("t") { $0.title = "B" } }
        let second = try XCTUnwrap(watcher.changeToken())
        XCTAssertNotEqual(second, first, "a commit of another store moves it")
        try paths.withStateDatabase { try $0.execute("UPDATE topics SET note = 'raw' WHERE id = 't'") }
        XCTAssertNotEqual(watcher.changeToken(), second, "a commit of any other connection moves it")
        let third = watcher.changeToken()
        try watcher.write { try $0.update("t") { $0.title = "C" } }
        XCTAssertEqual(watcher.changeToken(), third, "the store's own write does not move it")
    }

    func testAWriteThatChangesNothingCommitsNothing() throws {
        let store = TopicStore(paths: paths), watcher = TopicStore(paths: paths)
        try store.write { try $0.create(TopicRecord(id: "t")) }
        try store.write { $0.openPlaces = [OpenPlace(id: "p", order: 1)] }
        let token = watcher.changeToken()
        try store.write { try $0.update("t") { $0.title = nil } }
        try store.write { try $0.setNote(of: "t", " ") }
        try store.write { _ in }
        XCTAssertEqual(watcher.changeToken(), token)
        try store.write { try $0.update("t") { $0.title = "Changed" } }
        XCTAssertNotEqual(watcher.changeToken(), token)
    }

    func testWritersInOneProcessEachSeeTheWriteBeforeIt() throws {
        try TopicStore(paths: paths).write { try $0.create(TopicRecord(id: "t", title: "0")) }
        let shared = TopicStore(paths: paths)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let store = index.isMultiple(of: 2) ? shared : TopicStore(paths: paths)
            try! store.write { transaction in
                try transaction.update("t") { $0.title = String(Int($0.title!)! + 1) }
            }
        }
        XCTAssertEqual(try records(shared).map(\.title), ["20"], "each increment read the one before it")
    }

    func testAReadWithoutAStateFolderCreatesNothing() throws {
        XCTAssertEqual(try TopicStore(paths: paths).read(), TopicContents(records: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRecordRoundTripKeepsUnknownSessionValuesAndLargeIntegers() throws {
        let data = Data(#"{"id":"test","title":"Before","slug":"test","created_at":"2026-10-06T20:00:00Z","settled_at":null,"outcome":null,"order":2,"sessions":[{"repository_path":"/work/app","future_session":42,"large":18446744073709551615,"windows":[{"future_window":{"key":"kept","items":[true,null,0.125]}}]}]}"#.utf8)
        let record = try JSONDecoder().decode(TopicRecord.self, from: data)
        let store = TopicStore(paths: paths)
        try seed(record)
        try store.write { try $0.update("test") { $0.title = "After" } }
        var expected = record
        expected.title = "After"
        let loaded = try XCTUnwrap(records(TopicStore(paths: paths)).first)
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(loaded.sessions.first?["future_session"], .integer(42))
        XCTAssertEqual(loaded.sessions.first?["large"], .unsignedInteger(UInt64.max))
        XCTAssertEqual(try paths.storedJSON("test", "sessions"), try JSONDecoder().decode([String: JSONValue].self, from: data)["sessions"])
        XCTAssertEqual(try stored("test")["title"], .text("After"))
    }

    func testAWriteRejectsARecordThatTheTableCannotHold() throws {
        let store = TopicStore(paths: paths)
        XCTAssertThrowsError(try store.write { try $0.create(TopicRecord(id: "../escape")) })
        try store.write { try $0.create(TopicRecord(id: "valid")) }
        XCTAssertThrowsError(try store.write { try $0.update("valid") { $0.order = .infinity } })
        XCTAssertEqual(try records(store).map { $0.order?.isFinite }, [true])
    }

    func testMovesKeepUnrelatedValuesThatAnotherWriterSaved() throws {
        let store = TopicStore(paths: paths)
        let originals = [record("a", order: 0), record("b", order: 0), record("c", order: 0)]
        try seed(originals[0], originals[1], originals[2])
        try store.write { _ in }
        try paths.withStateDatabase { try $0.execute("UPDATE topics SET note = 'Bisect' WHERE id = 'b'") }
        try store.write { try $0.move(.topic("c"), to: .before(.topic("b"))) }
        let moved = try records(TopicStore(paths: paths))
        XCTAssertEqual(TopicOrder.sorted(moved.map(TopicListEntry.topic)).records.map(\.id), ["a", "c", "b"])
        XCTAssertEqual(moved.first { $0.id == "b" }?.note, "Bisect")
        try store.write { try $0.create(record("new", order: nil)) }
        XCTAssertEqual(TopicOrder.sorted(try records(store).map(TopicListEntry.topic)).records.map(\.id), ["a", "c", "b", "new"])
    }

    func testCreationNormalizesExtremeRanksAndAFailedPreflightWritesNothing() throws {
        let store = TopicStore(paths: paths)
        let existing = record("a", order: -.greatestFiniteMagnitude)
        try seed(existing)
        let before = try paths.storedTopicRows()
        XCTAssertThrowsError(try store.write { try $0.create(record("../invalid", order: nil)) })
        XCTAssertEqual(try paths.storedTopicRows(), before)
        XCTAssertThrowsError(try store.write { try $0.move(.topic("a"), to: .after(.topic("missing"))) })
        XCTAssertEqual(try paths.storedTopicRows(), before)
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

    func testAWriteWhoseBodyFailsChangesNothing() throws {
        try seed(record("a", order: 0), record("b", order: 0), record("c", order: 0))
        let before = try paths.storedTopicRows()
        struct Refused: Error {}
        let store = TopicStore(paths: paths)
        XCTAssertThrowsError(try store.write { transaction in
            try transaction.move(.topic("c"), to: .before(.topic("b")))
            try transaction.create(record("d", order: nil))
            throw Refused()
        })
        XCTAssertEqual(try paths.storedTopicRows(), before)
        XCTAssertEqual(TopicOrder.sorted(try records(store).map(TopicListEntry.topic)).records.map(\.id), ["a", "b", "c"])
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
        XCTAssertEqual(try stored("t")["pinned"], .integer(1))
        XCTAssertEqual(try stored("a")["pinned"], .integer(0), "a Topic that is not Pinned is 0")

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

    func testATopicNoteIsSavedAsOneLineAndSettleClearsIt() throws {
        let old = try JSONDecoder().decode(TopicRecord.self, from: Data(#"{"id":"t","title":"T"}"#.utf8))
        XCTAssertNil(old.note, "a record without a note key has no Note")
        let store = TopicStore(paths: paths)
        try store.write { try $0.create(old) }
        func file() throws -> [String: SQLiteValue] { try stored("t") }

        try store.write { try $0.setNote(of: "t", "  Repro with seed 4411\n\n   then bisect \r\n") }
        XCTAssertEqual(try file()["note"], .text("Repro with seed 4411 then bisect"))
        XCTAssertEqual(try file()["title"], .text("T"), "a Note change keeps the other fields")

        let topic = try XCTUnwrap(records(store).first)
        let settle = TopicSettlePlan(topic: topic, snapshot: TmuxSnapshot(windows: [], clients: [], panes: [], serverRunning: true),
                                     sessionPaths: [], choices: [], outcome: "").edit
        try store.write { try $0.apply(TopicRecordChange(before: topic, after: XCTUnwrap(settle.record))) }
        let settled = try XCTUnwrap(records(store).first)
        XCTAssertNil(settled.note, "Settle clears the Note")
        XCTAssertEqual(try file()["note"], .null, "the Settled record has no Note")
        XCTAssertThrowsError(try store.write { try $0.setNote(of: "t", "later") }, "a Settled Topic takes no Note change")

        let reopen = try TopicReopenPlan(topic: settled, records: try records(store), windows: [], sessionPaths: [],
                                         existingDirectories: []).edit
        try store.write { try $0.apply(TopicRecordChange(before: settled, after: XCTUnwrap(reopen.savedCompletionRecord))) }
        XCTAssertNil(try records(store).first?.note, "a Reopened Topic starts without a Note")

        try store.write { try $0.setNote(of: "t", "y") }
        try store.write { try $0.setNote(of: "t", " \n\t ") }
        XCTAssertEqual(try file()["note"], .null, "text with no words clears the Note")
        try store.write { try $0.setNote(of: "t", "x") }
        try store.write { try $0.setNote(of: "t", nil) }
        XCTAssertNil(try records(store).first?.note)
    }

    func testInsertionPlacesTopicsAroundLocksAndNormalizesBothExtremeEnds() throws {
        for position in TopicInsertPosition.allCases {
            let edge: Double = position == .top ? -.greatestFiniteMagnitude : .greatestFiniteMagnitude
            var pinned = record("p", order: 0)
            pinned.isPinned = true
            var transaction = TopicTransaction(records: [pinned, record("a", order: edge)])
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
                            var transaction = TopicTransaction(records: initial)
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
        var transaction = TopicTransaction(records: [pinned, current, record("a", order: 0)])
        let change = TopicRecordChange(before: settled, after: reopened)
        try transaction.apply(change, arrival: .end(.bottom))
        XCTAssertEqual(TopicOrder.sorted(transaction.records.map(TopicListEntry.topic)).records.map(\.id), ["p", "returning", "a"])
        try transaction.apply(change, arrival: .end(.top))
        XCTAssertEqual(TopicOrder.sorted(transaction.records.map(TopicListEntry.topic)).records.map(\.id), ["p", "returning", "a"])
    }
}
