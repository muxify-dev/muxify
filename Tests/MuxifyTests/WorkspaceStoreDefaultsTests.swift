import XCTest
@testable import MuxifyCore

/// A store keeps its view state in the UserDefaults it is given, so tests running at the same time never share it.
@MainActor
final class WorkspaceStoreDefaultsTests: XCTestCase {
    func testAStoreOnItsOwnSuiteKeepsItsSidebarModeAndOpenSessionCardsThereAndLeavesStandardAlone() {
        let standard = UserDefaults.standard
        let modeBefore = standard.object(forKey: "sidebarWorkView") as? String
        let cardsBefore = standard.object(forKey: "expandedSessions") as? [String]
        let defaults = isolatedDefaults()
        let visits = isolatedVisits()
        let config = ConfigStore(path: "/nonexistent/muxify-store-defaults.yaml")

        let store = WorkspaceStore(configStore: config, defaults: defaults, visitStore: visits)
        let mode: SidebarMode = modeBefore == SidebarMode.sessions.rawValue ? .board : .sessions
        store.sidebarMode = mode
        store.openSessionCards = ["muxify-test-card"]

        XCTAssertEqual(defaults.string(forKey: "sidebarWorkView"), mode.rawValue)
        XCTAssertEqual(defaults.stringArray(forKey: "expandedSessions"), ["muxify-test-card"])
        let reopened = WorkspaceStore(configStore: config, defaults: defaults, visitStore: visits)
        XCTAssertEqual(reopened.sidebarMode, mode, "a store built on the same suite reads the mode back")
        XCTAssertEqual(reopened.openSessionCards, ["muxify-test-card"])

        XCTAssertEqual(standard.object(forKey: "sidebarWorkView") as? String, modeBefore)
        XCTAssertEqual(standard.object(forKey: "expandedSessions") as? [String], cardsBefore)
    }

    func testAStoreReadsThisMacsVisitsFromTheStateDatabaseAndTakesTheHostCLIsWhenAPaletteOpens() throws {
        let defaults = isolatedDefaults()
        let visits = isolatedVisits()
        let app = VisitKey.directory("/work/app"), old = VisitKey.session(name: "old"), phone = VisitKey.directory("/work/phone")
        try visits.add([app: Date(timeIntervalSince1970: 10)])
        try visits.add([.directory("/work/box"): Date(timeIntervalSince1970: 20)], environment: "box")
        defaults.set(["session:old": 5.0], forKey: LegacyVisits.defaultsKey)
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify-store-visits.yaml"), defaults: defaults, visitStore: visits)
        XCTAssertEqual(store.visits.times, [app: Date(timeIntervalSince1970: 10), old: Date(timeIntervalSince1970: 5)],
                       "this Mac's visits and the ones UserDefaults had, without a Remote Environment's")
        XCTAssertNil(defaults.object(forKey: LegacyVisits.defaultsKey))

        try visits.add([phone: Date(timeIntervalSince1970: 30)])
        XCTAssertNil(store.visits.last(phone))
        store.reloadVisits()
        XCTAssertEqual(store.visits.last(phone), Date(timeIntervalSince1970: 30), "a visit that the Host CLI saved for the phone")
        XCTAssertEqual(store.visits.last(app), Date(timeIntervalSince1970: 10))
    }
}
