import XCTest

final class SwitchPaceTests: XCTestCase {
    /// The runs of the test in this process: a repeated run starts well after the last move of the one before.
    @MainActor private static var runs = 0

    /// A switch on its own animates; each switch of a quick run after the first does not, and the next switch on its
    /// own animates again.
    @MainActor func testOnlyAMoveOnItsOwnAnimates() {
        // The last move is kept across runs and dated up to 0.6 s ahead of its run's start, so each run starts later.
        Self.runs += 1
        let start = Date().addingTimeInterval(Double(Self.runs) * 10)
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
