import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class VisitLogTests: XCTestCase {
    private let sessionPaths = [SessionPath(path: "/work/app", name: "app"),
                            SessionPath(path: "/work/game", name: "game", layout: .bareRepository([Worktree(path: "/work/game/main", branch: "main")]))]

    private func window(_ id: String, session: String, directory: String, topic: String? = nil) -> TmuxWindow {
        .fixture(id: id, sessionID: "$" + session, sessionName: session, path: directory, topicID: topic, sessionPath: directory)
    }

    private func store() throws -> VisitStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VisitLogTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return VisitStore(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent"))
    }

    func testOneLookRecordsTheTopicTheSessionAndTheWorktreeAndARepeatChangesNothing() {
        var log = VisitLog()
        let first = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(log.record(window("@1", session: "game/fix", directory: "/work/game/main/src", topic: "fix"),
                                  group: .topic("fix"), sessionPaths: sessionPaths, folders: .local, at: first),
                       [.topic(.topic("fix")), .session(name: "game/fix"), .directory("/work/game/main")], "the keys to save")
        XCTAssertEqual(log.last(.topic(.topic("fix"))), first)
        XCTAssertEqual(log.last(.session(name: "game/fix")), first)
        XCTAssertEqual(log.last(.directory("/work/game/main")), first, "the Worktree row, not the SessionPath folder")
        XCTAssertNil(log.last(.directory("/work/game")))
        XCTAssertEqual(log.record(window("@2", session: "game/fix", directory: "/work/game/main/src", topic: "fix"),
                                  group: .topic("fix"), sessionPaths: sessionPaths, folders: .local, at: Date(timeIntervalSince1970: 200)),
                       [], "another Window of the same Session in the same Topic is the same look")
        XCTAssertEqual(log.last(.session(name: "game/fix")), first)
        XCTAssertFalse(log.record(window("@3", session: "scratch", directory: "/elsewhere"), group: .noTopic, sessionPaths: sessionPaths, folders: .local,
                                  at: Date(timeIntervalSince1970: 300)).isEmpty)
        XCTAssertEqual(log.last(.topic(.noTopic)), Date(timeIntervalSince1970: 300))
        XCTAssertEqual(log.times.count, 5, "a Session outside every SessionPath records no directory")
    }

    func testVisitsRoundTripThroughTheStateDatabaseAndUnknownKeysAreSkipped() throws {
        let store = try store()
        XCTAssertEqual(try store.times(), [:], "no state folder gives no visits")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.state.path), "and the read makes none")
        var log = VisitLog()
        let at = Date(timeIntervalSince1970: 7.25)
        let stamped = log.record(window("@1", session: "app", directory: "/work/app"), group: .noTopic, sessionPaths: sessionPaths, folders: .local, at: at)
        try store.add(Dictionary(uniqueKeysWithValues: stamped.map { ($0, at) }))
        let connection = try StateDatabase.open(store.paths)
        XCTAssertEqual(try connection.query("SELECT place FROM visits WHERE environment IS NULL ORDER BY place") { $0.text(0) },
                       ["path:/work/app", "session:app", "topic:-"])
        try connection.execute("INSERT INTO visits (place, visited_at) VALUES ('bogus:1', 3), ('nocolon', 4)")
        XCTAssertEqual(try store.times(), log.times, "the times come back to the fraction of a second")
        XCTAssertEqual(VisitLog(times: try store.times()), VisitLog(times: log.times))
    }

    func testAKeyKeepsItsNewerTimeAndAMergeKeepsAVisitThatIsNotSavedYet() throws {
        let store = try store()
        let app = VisitKey.directory("/work/app"), game = VisitKey.directory("/work/game")
        try store.add([app: Date(timeIntervalSince1970: 50), game: Date(timeIntervalSince1970: 60)])
        try store.add([app: Date(timeIntervalSince1970: 40), game: Date(timeIntervalSince1970: 90)])
        XCTAssertEqual(try store.times(), [app: Date(timeIntervalSince1970: 50), game: Date(timeIntervalSince1970: 90)],
                       "an older time changes nothing")
        var log = VisitLog(times: [app: Date(timeIntervalSince1970: 70)])
        log.merge(try store.times())
        XCTAssertEqual(log.times, [app: Date(timeIntervalSince1970: 70), game: Date(timeIntervalSince1970: 90)])
    }

    func testARemoteEnvironmentsVisitsStayApartFromThisMachines() throws {
        let store = try store()
        let app = VisitKey.directory("/work/app")
        try store.add([app: Date(timeIntervalSince1970: 10)])
        try store.add([app: Date(timeIntervalSince1970: 20), .session(name: "box"): Date(timeIntervalSince1970: 21)], environment: "box")
        XCTAssertEqual(try store.times(), [app: Date(timeIntervalSince1970: 10)])
        XCTAssertEqual(try store.times(environment: "box"), [app: Date(timeIntervalSince1970: 20), .session(name: "box"): Date(timeIntervalSince1970: 21)])
        XCTAssertEqual(try store.times(environment: "other"), [:])
    }

    func testOnlyTheNewestTwoThousandVisitsOfAMachineAreKept() throws {
        let store = try store()
        try store.add([.session(name: "box"): Date(timeIntervalSince1970: 1)], environment: "box")
        try store.add(Dictionary(uniqueKeysWithValues: (0..<2100).map { (VisitKey.session(name: "s\($0)"), Date(timeIntervalSince1970: TimeInterval($0))) }))
        let saved = try store.times()
        XCTAssertEqual(saved.count, VisitLog.capacity)
        XCTAssertNil(saved[.session(name: "s99")])
        XCTAssertEqual(saved[.session(name: "s100")], Date(timeIntervalSince1970: 100))
        XCTAssertEqual(saved[.session(name: "s2099")], Date(timeIntervalSince1970: 2099))
        XCTAssertEqual(try store.times(environment: "box").count, 1, "the cap of one machine removes no visit of another")
    }

    func testAgeIsShort() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-125), now: now), "2m")
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-3600 * 5), now: now), "5h")
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-86400 * 3 - 10), now: now), "3d")
    }
}
