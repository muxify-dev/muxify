import XCTest

final class BodyCountTests: XCTestCase {
    private var wasOn = false

    override func setUp() {
        wasOn = BodyCount.isOn
    }

    override func tearDown() {
        BodyCount.isOn = wasOn
    }

    /// The counter is in every build; Diagnostics turns it on and off with itself.
    func testWithDiagnosticsOffATickChangesNothing() {
        BodyCount.isOn = false
        let before = BodyCount.counts
        for _ in 0..<100 { BodyCount.tick("BodyCountTests") }
        XCTAssertEqual(BodyCount.counts, before)
    }

    func testWithDiagnosticsOnATickCountsUntilAReset() {
        BodyCount.isOn = true
        let before = BodyCount.counts["BodyCountTests", default: 0]
        for _ in 0..<3 { BodyCount.tick("BodyCountTests") }
        XCTAssertEqual(BodyCount.counts["BodyCountTests"], before + 3)
        BodyCount.reset()
        XCTAssertEqual(BodyCount.counts, [:])
    }
}
