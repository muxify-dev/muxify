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
        let config = ConfigStore(path: "/nonexistent/muxify-store-defaults.yaml")

        let store = WorkspaceStore(configStore: config, defaults: defaults)
        let mode: SidebarMode = modeBefore == SidebarMode.sessions.rawValue ? .topics : .sessions
        store.sidebarMode = mode
        store.openSessionCards = ["muxify-test-card"]

        XCTAssertEqual(defaults.string(forKey: "sidebarWorkView"), mode.rawValue)
        XCTAssertEqual(defaults.stringArray(forKey: "expandedSessions"), ["muxify-test-card"])
        let reopened = WorkspaceStore(configStore: config, defaults: defaults)
        XCTAssertEqual(reopened.sidebarMode, mode, "a store built on the same suite reads the mode back")
        XCTAssertEqual(reopened.openSessionCards, ["muxify-test-card"])

        XCTAssertEqual(standard.object(forKey: "sidebarWorkView") as? String, modeBefore)
        XCTAssertEqual(standard.object(forKey: "expandedSessions") as? [String], cardsBefore)
    }
}
