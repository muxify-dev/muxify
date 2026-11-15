import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class VisitLogTests: XCTestCase {
    private let sessionPaths = [SessionPath(path: "/work/app", name: "app"),
                            SessionPath(path: "/work/game", name: "game", layout: .bareRepository([Worktree(path: "/work/game/main", branch: "main")]))]

    private func window(_ id: String, session: String, directory: String, topic: String? = nil) -> TmuxWindow {
        .fixture(id: id, sessionID: "$" + session, sessionName: session, path: directory, topicID: topic, sessionPath: directory)
    }

    private func defaults() throws -> UserDefaults {
        let name = "VisitLogTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testOneLookRecordsTheTopicTheSessionAndTheWorktreeAndARepeatChangesNothing() {
        var log = VisitLog()
        let first = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(log.record(window("@1", session: "game/fix", directory: "/work/game/main/src", topic: "fix"),
                                 group: .topic("fix"), sessionPaths: sessionPaths, folders: .local, at: first))
        XCTAssertEqual(log.last(.topic(.topic("fix"))), first)
        XCTAssertEqual(log.last(.session(name: "game/fix")), first)
        XCTAssertEqual(log.last(.directory("/work/game/main")), first, "the Worktree row, not the SessionPath folder")
        XCTAssertNil(log.last(.directory("/work/game")))
        XCTAssertFalse(log.record(window("@2", session: "game/fix", directory: "/work/game/main/src", topic: "fix"),
                                  group: .topic("fix"), sessionPaths: sessionPaths, folders: .local, at: Date(timeIntervalSince1970: 200)),
                       "another Window of the same Session in the same Topic is the same look")
        XCTAssertEqual(log.last(.session(name: "game/fix")), first)
        XCTAssertTrue(log.record(window("@3", session: "scratch", directory: "/elsewhere"), group: .noTopic, sessionPaths: sessionPaths, folders: .local,
                                 at: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(log.last(.topic(.noTopic)), Date(timeIntervalSince1970: 300))
        XCTAssertEqual(log.times.count, 5, "a Session outside every SessionPath records no directory")
    }

    func testVisitsRoundTripThroughUserDefaultsAndUnknownKeysAreSkipped() throws {
        let defaults = try defaults()
        var log = VisitLog()
        _ = log.record(window("@1", session: "app", directory: "/work/app"), group: .noTopic, sessionPaths: sessionPaths, folders: .local, at: Date(timeIntervalSince1970: 7))
        log.save(to: defaults)
        var stored = try XCTUnwrap(defaults.dictionary(forKey: VisitLog.defaultsKey))
        XCTAssertEqual(stored.keys.sorted(), ["path:/work/app", "session:app", "topic:-"])
        stored["bogus:1"] = 3.0
        stored["topic:x"] = "not a number"
        defaults.set(stored, forKey: VisitLog.defaultsKey)
        let reloaded = VisitLog(defaults: defaults)
        XCTAssertEqual(reloaded.times, [.directory("/work/app"): Date(timeIntervalSince1970: 7),
                                        .session(name: "app"): Date(timeIntervalSince1970: 7),
                                        .topic(.noTopic): Date(timeIntervalSince1970: 7)])
    }

    func testOnlyTheNewestTwoThousandVisitsAreSaved() throws {
        let defaults = try defaults()
        var log = VisitLog()
        for index in 0..<2100 {
            _ = log.record(window("@\(index)", session: "s\(index)", directory: "/x"), group: .noTopic, sessionPaths: [], folders: .local,
                           at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        log.save(to: defaults)
        let saved = VisitLog(defaults: defaults)
        XCTAssertEqual(saved.times.count, VisitLog.capacity)
        XCTAssertNil(saved.last(.session(name: "s0")))
        XCTAssertEqual(saved.last(.session(name: "s2099")), Date(timeIntervalSince1970: 2099))
    }

    func testAgeIsShort() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-5), now: now), "now")
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-125), now: now), "2m")
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-3600 * 5), now: now), "5h")
        XCTAssertEqual(VisitAge.short(since: now.addingTimeInterval(-86400 * 3 - 10), now: now), "3d")
    }
}
