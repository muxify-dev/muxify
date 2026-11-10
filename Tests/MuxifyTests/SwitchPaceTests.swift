import XCTest

final class SwitchPaceTests: XCTestCase {
    /// A switch on its own animates; each switch of a quick run after the first does not, and the next switch on its
    /// own animates again.
    @MainActor func testOnlyAMoveOnItsOwnAnimates() {
        let start = Date()
        SwitchPace.moved(now: start)
        XCTAssertTrue(SwitchPace.animates, "a move long after the last")
        SwitchPace.moved(now: start.addingTimeInterval(0.1))
        XCTAssertFalse(SwitchPace.animates, "a move in a quick run")
        SwitchPace.moved(now: start.addingTimeInterval(0.2))
        XCTAssertFalse(SwitchPace.animates)
        SwitchPace.moved(now: start.addingTimeInterval(0.2 + SwitchPace.quick + 0.01))
        XCTAssertTrue(SwitchPace.animates, "a move once the run is over")
    }
}
