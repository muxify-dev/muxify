import MuxifyCore
import XCTest

final class LegacyVisitsTests: XCTestCase {
    func testTheVisitsOfUserDefaultsMoveIntoTheStateDatabaseOneTime() throws {
        let defaults = isolatedDefaults(), store = isolatedVisits()
        let app = VisitKey.directory("/work/app")
        try store.add([app: Date(timeIntervalSince1970: 80), .session(name: "phone"): Date(timeIntervalSince1970: 81)])
        defaults.set(["path:/work/app": 70.0, "path:/work/game": 60.0, "topic:-": 5.0, "bogus:1": 3.0, "topic:x": "not a number"],
                     forKey: LegacyVisits.defaultsKey)

        LegacyVisits.move(from: defaults, to: store)
        let moved = try store.times()
        XCTAssertEqual(moved, [app: Date(timeIntervalSince1970: 80), .session(name: "phone"): Date(timeIntervalSince1970: 81),
                               .directory("/work/game"): Date(timeIntervalSince1970: 60), .topic(.noTopic): Date(timeIntervalSince1970: 5)],
                       "a visit the Host CLI saved first keeps its newer time, and an entry that is no visit is left out")
        XCTAssertNil(defaults.object(forKey: LegacyVisits.defaultsKey), "the key is gone, so the next launch moves nothing")
        XCTAssertEqual(try store.times(environment: "box"), [:], "the old visits are this machine's")

        try store.add([app: Date(timeIntervalSince1970: 90)])
        LegacyVisits.move(from: defaults, to: store)
        XCTAssertEqual(try store.times()[app], Date(timeIntervalSince1970: 90))
    }
}
