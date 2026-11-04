import MuxifyCore
import XCTest

final class BenchScrollTests: XCTestCase {
    private let short = BenchGeometry(topHeight: 200, viewportHeight: 600)

    func testAShortBlockSticksAtOnceAndTheBenchScrollsUnderIt() {
        XCTAssertEqual(short.slack, 0)
        XCTAssertEqual(short.areaTop, 204)
        XCTAssertEqual(short.areaHeight, 396)
        XCTAssertEqual(short.stick(at: 0), 0)
        XCTAssertEqual(short.stick(at: 120), 120, "the block moves down as far as the content scrolled up")
    }

    /// The edge pill and the least Bench area hold text, so they grow with the Interface font size, and the Bench's
    /// geometry follows them (ADR 0063, ADR 0067).
    func testAtALargerInterfaceFontSizeThePillsBandAndTheLeastBenchAreaGrowByTheFactor() {
        let size = InterfaceFontSize(18)
        XCTAssertEqual(EdgePill.height(size), 45)
        let tall = BenchGeometry(topHeight: 700, viewportHeight: 600, fontSize: size)
        XCTAssertEqual(tall.indicatorHeight, 45, "the band of the \"more above\" pill is the scaled pill")
        XCTAssertEqual(tall.leastAreaHeight, 144)
        XCTAssertEqual(tall.areaTop, 600 - 144, "a tall block sticks with the scaled least Bench area under it")
        XCTAssertEqual(tall.slack, 4 + 700 - (600 - 144))
        let geometry = BenchGeometry(topHeight: 200, viewportHeight: 600, fontSize: size)
        XCTAssertEqual(900 + geometry.inset - geometry.revealOffset(cardTop: 900, hasCardsAbove: true),
                       geometry.areaTop + 45 + geometry.spacing, "a card with cards before it goes under the scaled pill")
    }

    func testATallBlockScrollsFirstUntilTheLeastBenchAreaShows() {
        let tall = BenchGeometry(topHeight: 700, viewportHeight: 600)
        XCTAssertEqual(tall.leastAreaHeight, BenchGeometry.designLeastAreaHeight, "at 12 the least Bench area is its design height")
        XCTAssertEqual(tall.areaTop, 600 - tall.leastAreaHeight)
        XCTAssertEqual(tall.slack, 200)
        XCTAssertEqual(tall.stick(at: 150), 0, "through the slack the block scrolls with the content")
        XCTAssertEqual(tall.stick(at: 260), 60)
        XCTAssertEqual(tall.autoScrollRange(at: 150), 0...600, "while the block scrolls, the whole viewport is the area")
        XCTAssertEqual(tall.autoScrollRange(at: 200), 504...600)
    }

    func testTheTailKeepsTheContentHeightWhenTheBlockOrTheLastCardGrows() {
        func content(_ geometry: BenchGeometry, bench: CGFloat, last: CGFloat) -> CGFloat {
            let (inset, spacing) = (geometry.inset, geometry.spacing)
            return inset + geometry.topHeight + spacing + bench + spacing + geometry.tail(afterCardOfHeight: last) + inset
        }
        let before = content(short, bench: 300, last: 40)
        XCTAssertEqual(content(BenchGeometry(topHeight: 240, viewportHeight: 600), bench: 300, last: 40), before,
                       "a block 40 points taller takes them from the tail")
        XCTAssertEqual(content(short, bench: 340, last: 80), before, "a last card 40 points taller takes them from the tail")
        XCTAssertEqual(content(short, bench: 40, last: 40), 600, "a Bench of one card does not scroll")
        let end = before - 600
        let lastTop = short.inset + short.topHeight + short.spacing + 300 - 40
        XCTAssertEqual(lastTop - end, short.areaTop + short.spacing, "at the end the last card stands one spacing under the area's top")
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

    /// A card whose top is `top` below the first item stands at `top + inset - offset` in the viewport.
    func testACardScrolledUnderTheLineHasItsTopOneSpacingUnderTheBlock() {
        let offset = short.revealOffset(cardTop: 900, hasCardsAbove: false)
        XCTAssertEqual(900 + short.inset - offset, short.areaTop + short.spacing)
        let tall = BenchGeometry(topHeight: 700, viewportHeight: 600)
        XCTAssertEqual(900 + tall.inset - tall.revealOffset(cardTop: 900, hasCardsAbove: false),
                       600 - tall.leastAreaHeight + tall.spacing, "under a tall block that stuck")
    }

    func testACardWithCardsBeforeItIsRevealedUnderTheMoreAbovePill() {
        let geometry = BenchGeometry(topHeight: 200, viewportHeight: 600)
        XCTAssertEqual(geometry.indicatorHeight, 30, "at 12 the band is the edge pill's design height")
        XCTAssertEqual(900 + geometry.inset - geometry.revealOffset(cardTop: 900, hasCardsAbove: false),
                       geometry.areaTop + geometry.spacing,
                       "the first Benched card goes directly under the line, where no pill shows")
        XCTAssertEqual(900 + geometry.inset - geometry.revealOffset(cardTop: 900, hasCardsAbove: true),
                       geometry.areaTop + 30 + geometry.spacing,
                       "a card with cards before it goes under the pill that counts them")
    }

    func testTheShownBenchKeepsTheLocationsCardWhereItStood() {
        let hidden = BenchedLocationPlace(top: 210, isBenchShown: false, hasCardsAbove: true)
        func opening(_ top: CGFloat, hasCardsAbove: Bool = true, after before: BenchedLocationPlace? = hidden) -> CGFloat? {
            BenchedLocationPlace(top: top, isBenchShown: true, hasCardsAbove: hasCardsAbove).openingScroll(after: before, indicatorHeight: 30)
        }
        XCTAssertEqual(opening(1490), 1250,
                       "the list scrolls as far as the cards that showed above pushed the card down, less the pill over them")
        XCTAssertEqual(opening(210, hasCardsAbove: false), 0, "the first Benched card does not move, and no pill shows over it")
        XCTAssertEqual(opening(230), 0, "a push shorter than the pill does not scroll the Bench up past its top")
        XCTAssertNil(opening(180, after: .init(top: 210, isBenchShown: true, hasCardsAbove: true)),
                     "a scroll of the shown Bench does not scroll again")
        XCTAssertNil(hidden.openingScroll(after: .init(top: 900, isBenchShown: true, hasCardsAbove: true), indicatorHeight: 30),
                     "a hide does not scroll")
        XCTAssertNil(opening(1490, after: nil), "a card that just became the Location on a shown Bench does not scroll")
    }

    func testACardCountsAboveOrBelowWhenAnyPartIsHiddenAndIsOutOfViewWhenNoPartShows() {
        func place(_ top: CGFloat, _ bottom: CGFloat) -> EdgePlace {
            EdgePlace(top: top, bottom: bottom, visibleTop: 100, visibleBottom: 500, indicatorHeight: 30)
        }
        XCTAssertEqual(place(136, 200), EdgePlace(), "a card directly under the pill is in view")
        XCTAssertEqual(place(106, 200), EdgePlace(isUnderIndicator: true),
                       "a card directly under the line is in view, but a shown pill covers its top")
        XCTAssertEqual(place(60, 140), EdgePlace(isAbove: true, isUnderIndicator: true), "a card partly under the block counts as above")
        XCTAssertEqual(place(-40, 100), EdgePlace(isAbove: true, isOutOfView: true, isUnderIndicator: true),
                       "a card that ends at the block's bottom is out of view")
        XCTAssertEqual(place(400, 464), EdgePlace(), "a card directly above the bottom pill is in view")
        XCTAssertEqual(place(400, 480), EdgePlace(isOverBottomIndicator: true),
                       "a card that ends in the bottom pill's band is in view, but a shown pill covers its bottom")
        XCTAssertEqual(place(450, 560), EdgePlace(isBelow: true, isOverBottomIndicator: true))
        XCTAssertEqual(place(500, 560), EdgePlace(isBelow: true, isOutOfView: true, isOverBottomIndicator: true))
        XCTAssertEqual(place(60, 560), EdgePlace(isAbove: true, isBelow: true, isUnderIndicator: true, isOverBottomIndicator: true),
                       "a card taller than the area counts both ways")
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
