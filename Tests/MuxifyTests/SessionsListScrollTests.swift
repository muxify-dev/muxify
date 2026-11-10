import MuxifyCore
import XCTest

/// The arithmetic of the Sessions list's scroll (ADR 0074), which both versions of the list call: how far the header
/// of an open card moves down to stick to the top of the list, and where the list glides to show the card of the
/// Location's Session.
final class SessionsListScrollTests: XCTestCase {
    // A card 300 points high with a header 37 points high: the header can move 300 - 37 - 8 = 255 points.
    private func stuck(cardTop: CGFloat, inset: CGFloat = 0) -> CGFloat {
        StuckHeader.offset(cardTop: cardTop, cardHeight: 300, headerHeight: 37, inset: inset)
    }

    func testTheHeaderStaysAtTheCardsTopWhileThatTopIsInView() {
        XCTAssertEqual(stuck(cardTop: 120), 0)
        XCTAssertEqual(stuck(cardTop: 0), 0)
    }

    func testTheHeaderMovesDownByTheDistanceScrolledPastTheCardsTop() {
        XCTAssertEqual(stuck(cardTop: -1), 1)
        XCTAssertEqual(stuck(cardTop: -120), 120)
        // Under a block that sticks to the top, the header sticks under the block.
        XCTAssertEqual(stuck(cardTop: -20, inset: 50), 70)
    }

    func testTheHeaderGoesNoFurtherThanTheCardsHeightLessItsOwnAndTheGapUnderIt() {
        XCTAssertEqual(StuckHeader.gap, 8)
        XCTAssertEqual(stuck(cardTop: -255), 255)
        XCTAssertEqual(stuck(cardTop: -400), 255)
        // A card with no room under its header leaves the header where it is.
        XCTAssertEqual(StuckHeader.offset(cardTop: -100, cardHeight: 40, headerHeight: 37), 0)
    }

    // A viewport 400 points high at the offset 600 shows the content from 600 to 1000; the content ends at 2000.
    private func glide(_ top: CGFloat, _ bottom: CGFloat, end: CGFloat = 1600) -> CGFloat? {
        SessionsListScroll.offset(showing: top, to: bottom, from: 600, height: 400, end: end)
    }

    func testACardThatShowsWholeDoesNotMoveTheList() {
        XCTAssertNil(glide(600, 1000))
        XCTAssertNil(glide(700, 760))
    }

    func testTheListMovesByTheLeastThatShowsTheCardWhole() {
        XCTAssertEqual(glide(500, 560), 500, "a card above shows at the top")
        XCTAssertEqual(glide(580, 700), 580, "a card cut at the top shows at the top")
        XCTAssertEqual(glide(1200, 1260), 860, "a card below shows at the bottom")
        XCTAssertEqual(glide(950, 1050), 650, "a card cut at the bottom shows at the bottom")
        XCTAssertEqual(glide(900, 1500), 900, "a card higher than the viewport shows its top")
    }

    func testTheGlideStaysInsideTheScrollRange() {
        XCTAssertEqual(glide(1900, 2000, end: 1500), 1500)
        XCTAssertEqual(SessionsListScroll.offset(showing: 4, to: 60, from: 600, height: 400, end: 1600), 4)
        XCTAssertNil(SessionsListScroll.offset(showing: 4, to: 60, from: 0, height: 400, end: 0), "a list with no scroll range")
        XCTAssertNil(SessionsListScroll.offset(showing: 1900, to: 2000, from: 1600, height: 400, end: 1600))
    }
}
