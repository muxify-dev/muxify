import XCTest

final class BenchScrollTests: XCTestCase {
    /// A 200-point block in a 600-point viewport: the Bench area starts at 204, under the 4-point inset.
    private let short = BenchGeometry(topHeight: 200, viewportHeight: 600)

    func testAShortBlockSticksAtOnceAndTheBenchScrollsUnderIt() {
        XCTAssertEqual(short.slack, 0)
        XCTAssertEqual(short.areaTop, 204)
        XCTAssertEqual(short.areaHeight, 396)
        XCTAssertEqual(short.stick(at: 0), 0)
        XCTAssertEqual(short.stick(at: 120), 120, "the block moves down as far as the content scrolled up")
    }

    func testATallBlockScrollsFirstUntilTheLeastBenchAreaShows() {
        let tall = BenchGeometry(topHeight: 700, viewportHeight: 600)
        XCTAssertEqual(tall.areaTop, 600 - BenchGeometry.leastAreaHeight)
        XCTAssertEqual(tall.slack, 200)
        XCTAssertEqual(tall.stick(at: 150), 0, "through the slack the block scrolls with the content")
        XCTAssertEqual(tall.stick(at: 260), 60)
        XCTAssertEqual(tall.autoScrollRange(at: 150), 0...600, "while the block scrolls, the whole viewport is the area")
        XCTAssertEqual(tall.autoScrollRange(at: 200), 504...600)
    }

    func testTheTailKeepsTheContentHeightWhenTheBlockOrTheLastCardGrows() {
        // inset, block, spacing, the Bench's cards (the last one 40 of them), spacing, tail, inset.
        func content(_ geometry: BenchGeometry, bench: CGFloat, last: CGFloat) -> CGFloat {
            4 + geometry.topHeight + 6 + bench + 6 + geometry.tail(afterCardOfHeight: last) + 4
        }
        let before = content(short, bench: 300, last: 40)
        XCTAssertEqual(content(BenchGeometry(topHeight: 240, viewportHeight: 600), bench: 300, last: 40), before,
                       "a block 40 points taller takes them from the tail")
        XCTAssertEqual(content(short, bench: 340, last: 80), before, "a last card 40 points taller takes them from the tail")
        XCTAssertEqual(content(short, bench: 40, last: 40), 600, "a Bench of one card does not scroll")
        // At the end of the scroll, the last card's top is one spacing under the area's top.
        let end = before - 600
        let lastTop = 4 + 200 + 6 + 300 - 40
        XCTAssertEqual(CGFloat(lastTop) - end, short.areaTop + 6)
    }

    func testThePointerScrollsAtTheEdgesOfTheAreaOnly() {
        let area: ClosedRange<CGFloat> = 204...600
        func step(_ pointer: CGFloat?, offset: CGFloat = 100) -> CGFloat {
            EdgeAutoScroll.step(pointer: pointer, in: area, offset: offset, end: 500)
        }
        XCTAssertEqual(step(nil), 0)
        XCTAssertEqual(step(400), 0, "in the middle of the area nothing scrolls")
        XCTAssertGreaterThan(step(590), 0, "near the bottom it scrolls down")
        XCTAssertGreaterThan(step(599), step(580), "deeper into the band is faster")
        XCTAssertEqual(step(700), EdgeAutoScroll.speed, "past the bottom edge at full speed")
        XCTAssertLessThan(step(210), 0, "under the block it scrolls up")
        XCTAssertEqual(step(100), 0, "over the block it does not scroll")
        XCTAssertEqual(step(210, offset: 0), 0, "at the top it does not scroll up")
        XCTAssertEqual(step(590, offset: 500), 0, "at the end it does not scroll down")
        XCTAssertLessThan(EdgeAutoScroll.step(pointer: -20, in: 0...600, offset: 100, end: 500), 0,
                          "while the block scrolls, above the viewport it scrolls up")
    }

    func testThePointerScrollsOnlyAfterItRestsInTheBand() {
        var dwell = EdgeAutoScroll.Dwell()
        XCTAssertEqual(dwell.pass(8, at: 0), 0)
        XCTAssertEqual(dwell.pass(8, at: 0.1), 0, "a card that passes the edge does not scroll")
        XCTAssertEqual(dwell.pass(8, at: 0.25), 8)
        XCTAssertEqual(dwell.pass(0, at: 0.3), 0)
        XCTAssertEqual(dwell.pass(8, at: 0.4), 0, "out of the band and back, it waits again")
    }
}
