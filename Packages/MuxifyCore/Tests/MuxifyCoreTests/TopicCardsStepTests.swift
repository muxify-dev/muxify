import XCTest
@testable import MuxifyCore

final class TopicCardsStepTests: XCTestCase {
    private func topic(_ id: String, order: Double) -> TopicRecord {
        var record = TopicRecord(id: id, title: id)
        record.order = order
        return record
    }

    private let places = 2

    private var cards: [TopicListEntry] {
        TopicCards.order(records: ["a", "b", "c", "d", "e"].enumerated().map { topic($1, order: Double($0)) }, windows: [])
    }

    func testAShownBenchReordersAndItsTopMakesAGuest() {
        func step(_ id: String, _ step: TopicCards.Step) -> TopicCards.Outcome { TopicCards.step(.topic(id), step, in: cards, inPlay: places) }
        XCTAssertEqual(step("c", .up), .makeGuest)
        XCTAssertEqual(step("d", .up), .reorder(.before(.topic("c"))))
        XCTAssertEqual(step("c", .down), .reorder(.after(.topic("d"))))
        XCTAssertEqual(step("e", .down), .atEnd)
    }

    func testAHiddenBenchMakesAGuestFromEveryBenchedCardAndHasNoDown() {
        func step(_ id: String, _ step: TopicCards.Step) -> TopicCards.Outcome {
            TopicCards.step(.topic(id), step, in: cards, inPlay: places, benchShown: false)
        }
        for id in ["c", "d", "e"] {
            XCTAssertEqual(step(id, .up), .makeGuest, id)
            XCTAssertEqual(step(id, .down), .atEnd, id)
        }
        XCTAssertEqual(step("b", .down), .toGuests, "the places do not depend on the Bench")
    }

    func testWithoutInPlayAStepIsAReorderAmongTheCardsWithTheSamePin() {
        XCTAssertEqual(TopicCards.step(.topic("c"), .up, in: cards, inPlay: nil), .reorder(.before(.topic("b"))))
        XCTAssertEqual(TopicCards.step(.topic("e"), .down, in: cards, inPlay: nil), .atEnd)
    }
}
