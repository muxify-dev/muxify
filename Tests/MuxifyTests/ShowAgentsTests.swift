import XCTest
@testable import MuxifyCore

final class ShowAgentsTests: XCTestCase {
    func testEachModeKeepsItsOwnValueAndStartsFromTheSingleEarlierOne() {
        let unset = ShowAgents(defaults: isolatedDefaults())
        XCTAssertTrue(unset[.topics], "no stored value shows Agents in Topics")
        XCTAssertTrue(unset[.sessions], "no stored value shows Agents in Sessions")

        let hidden = isolatedDefaults()
        hidden.set(false, forKey: "agentsVisible")
        XCTAssertFalse(ShowAgents(defaults: hidden)[.topics], "Topics starts from the earlier false")
        XCTAssertFalse(ShowAgents(defaults: hidden)[.sessions], "Sessions starts from the earlier false")

        let shown = isolatedDefaults()
        shown.set(true, forKey: "agentsVisible")
        var showAgents = ShowAgents(defaults: shown)
        showAgents[.topics] = false
        XCTAssertFalse(ShowAgents(defaults: shown)[.topics], "the Topics value is remembered")
        XCTAssertTrue(ShowAgents(defaults: shown)[.sessions], "the Sessions value still starts from the earlier value")
    }
}
