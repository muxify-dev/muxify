import XCTest
@testable import MuxifyCore

final class PaletteCheckTests: XCTestCase {
    func testReturnGoesOnWithTheCheckedCardsOnAnyRowElseWithTheRowsCard() {
        let draft = CheckDraft(action: .chooseInPlay(places: 2), checked: [.topic("a"), .locked("$1")])
        XCTAssertEqual(draft.goingOn(from: .topic("z")), [.topic("a"), .locked("$1")], "not with the highlighted card")
        XCTAssertEqual(CheckDraft(action: .chooseInPlay(places: 2)).goingOn(from: .topic("z")), [.topic("z")])
    }

    func testChooseInPlayAsksForEveryCheckedCardUntilOneIsLeftAndThePlacesAfterInPlayAreOnTheBench() {
        let cards: [TopicGroupID] = [.topic("a"), .locked("$1"), .topic("b"), .topic("c")]
        var draft = OrderDraft(cards: cards, places: 2)
        XCTAssertNil(draft.chosen)
        XCTAssertFalse(draft.placeIsOnBench)
        draft = draft.placing(.topic("b"))
        XCTAssertEqual(draft.place, 2)
        XCTAssertEqual(draft.remaining, [.topic("a"), .locked("$1"), .topic("c")], "the rows of a place keep the list order")
        XCTAssertFalse(draft.placeIsOnBench)
        draft = draft.placing(.topic("c"))
        XCTAssertNil(draft.chosen, "the cards after the last In Play place are ordered too")
        XCTAssertEqual(draft.place, 3)
        XCTAssertTrue(draft.placeIsOnBench)
        XCTAssertEqual(draft.placing(.locked("$1")).chosen, [.topic("b"), .topic("c"), .locked("$1"), .topic("a")],
                       "the last remaining card needs no choice")
        XCTAssertEqual(OrderDraft(cards: [.topic("a"), .topic("b")], places: 5).placing(.topic("b")).chosen, [.topic("b"), .topic("a")])
        XCTAssertEqual(OrderDraft(cards: [.topic("a")], places: 5).chosen, [.topic("a")])
    }

    func testTheCheckNoteSaysHowManyCheckedCardsGoToTheTopOfTheBench() {
        XCTAssertEqual(CheckAction.chooseInPlay(places: 2).outcome(4), "4 checked for 2 In Play places. The last 2 go to the top of the Bench.")
        XCTAssertEqual(CheckAction.chooseInPlay(places: 2).outcome(2), "2 checked for 2 In Play places.")
        XCTAssertEqual(CheckAction.chooseInPlay(places: 1).outcome(0), "0 checked for 1 In Play place.")
    }
}
