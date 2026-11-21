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
        TopicCards.order(records: ["a", "b", "c", "d", "e"].enumerated().map { topic($1, order: Double($0)) })
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

    /// The cards of `list` in order, as GuestTests writes a Sidebar: `📌name` is Pinned, `name(G)` is a Guest Topic,
    /// `~name` is a Guest Session, `_` is the Open Place, and `+` and `|` only mark the Guests line and the Bench line.
    private func cards(_ list: String) -> [TopicListEntry] {
        list.split(separator: " ").filter { $0 != "+" && $0 != "|" }.enumerated().map { order, card in
            if card == "_" { return .openPlace(OpenPlace(id: "open", order: Double(order))) }
            if card.hasPrefix("~") { return .lock(SessionLock(id: String(card.dropFirst()), order: Double(order))) }
            var record = topic(String(card).replacingOccurrences(of: "📌", with: "").replacingOccurrences(of: "(G)", with: ""), order: Double(order))
            record.isPinned = card.hasPrefix("📌")
            record.isGuest = card.hasSuffix("(G)")
            return .topic(record)
        }
    }

    /// Each step that the Topics list can take with a shown Bench, with two places.
    func testEachStepGoesAsFarAsTheEndOfItsSectionAndThenIntoTheNext() {
        let cases: [(list: String, card: String, step: TopicCards.Step, outcome: TopicCards.Outcome, why: String)] = [
            ("a b + | c", "a", .down, .reorder(.after(.topic("b"))), "inside the places, a step swaps with the neighbor"),
            ("a b + | c", "a", .up, .atEnd, "the first place has no Up"),
            ("a b + | c", "b", .down, .toGuests, "Down from the last place makes the top Guest"),
            ("a _ + b(G) | c", "b", .up, .fill(openPlace: "open"), "Up from the top Guest fills the Open Place"),
            ("a b + c(G) | d", "c", .up, .trade(.topic("b")), "with every place full, Up from the top Guest trades with the last place"),
            ("a + b(G) |", "b", .up, .takePlace, "with room in the places and no Open Place, the Guest takes the next place"),
            ("a b + c(G) d(G) | e", "c", .down, .reorder(.after(.topic("d"))), "inside the Guests, a step reorders"),
            ("a b + c(G) | d", "c", .down, .bench, "Down from the last Guest is Bench"),
            ("📌p 📌q a b + |", "p", .down, .reorder(.after(.topic("q"))), "a Pinned Topic steps among the Pinned Topics"),
            ("📌p 📌q a b + |", "q", .down, .atEnd, "a Pinned Topic does not cross into the places"),
            ("a b + ~s | c", "~s", .up, .refused(.guestSession), "a Guest Session cannot take a place"),
            ("a _ + ~s | c", "~s", .up, .refused(.guestSession), "an Open Place does not change that"),
            ("a b + c(G) ~s | d", "~s", .up, .reorder(.before(.topic("c"))), "a Guest Session's card steps among the Guests"),
            ("a b + ~s | c", "~s", .down, .bench, "Down from the last Guest Unlocks the Session"),
        ]
        for (list, card, step, outcome, why) in cases {
            let id: TopicListID = card.hasPrefix("~") ? .lock(String(card.dropFirst())) : .topic(card)
            XCTAssertEqual(TopicCards.step(id, step, in: cards(list), inPlay: places), outcome, "\(list): \(card) \(step): \(why)")
        }
    }

    func testTheUnlockedNoTopicSessionMakesAGuestOnUpAndHasNoOtherStep() {
        XCTAssertEqual(TopicCards.stepUnlockedSession(.up), .makeGuest)
        XCTAssertEqual(TopicCards.stepUnlockedSession(.down), .hidden)
    }
}
