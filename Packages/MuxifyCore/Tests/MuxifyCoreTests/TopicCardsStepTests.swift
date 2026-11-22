import XCTest
@testable import MuxifyCore

final class TopicCardsStepTests: XCTestCase {
    private func topic(_ id: String, order: Double) -> TopicRecord {
        var record = TopicRecord(id: id, title: id)
        record.order = order
        return record
    }

    private let places = 2

    private var cards: [BoardCard] {
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
    /// `~name` is a Board Session, a Guest after the Guests line `+`, `_` is the Open Place, and `|` only marks the
    /// Bench line.
    private func cards(_ list: String) -> [BoardCard] {
        let words = list.split(separator: " ").filter { $0 != "|" }
        let guestsLine = words.firstIndex(of: "+") ?? words.endIndex
        return words.enumerated().filter { $1 != "+" }.map { order, card in
            if card == "_" { return .openPlace(OpenPlace(id: "open", order: Double(order))) }
            if card.hasPrefix("~") {
                return .session(BoardSession(id: String(card.dropFirst()), order: Double(order), isGuest: order > guestsLine))
            }
            var record = topic(String(card).replacingOccurrences(of: "📌", with: "").replacingOccurrences(of: "(G)", with: ""), order: Double(order))
            record.isPinned = card.hasPrefix("📌")
            record.isGuest = card.hasSuffix("(G)")
            return .topic(record)
        }
    }

    /// Each step that the Board can take with a shown Bench, with two places.
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
            ("a b + ~s | c", "~s", .up, .trade(.topic("b")), "with every place full, a Board Session trades with the last place"),
            ("a _ + ~s | c", "~s", .up, .fill(openPlace: "open"), "a Board Session fills the Open Place as a Topic does"),
            ("a + ~s |", "~s", .up, .takePlace, "with room in the places, a Board Session takes the next place"),
            ("a b + c(G) ~s | d", "~s", .up, .reorder(.before(.topic("c"))), "a Board Session steps among the Guests"),
            ("a b + ~s | c", "~s", .down, .bench, "Down from the last Guest is Bench, which takes a Board Session off the Board"),
            ("~s a + | c", "~s", .down, .reorder(.after(.topic("a"))), "a Board Session in a place steps among the places"),
            ("a ~s + | c", "~s", .down, .toGuests, "Down from the last place makes a Board Session the top Guest"),
            ("a ~s + b(G) | c", "b", .up, .trade(.session("s")), "a Guest trades with a Board Session in the last place"),
        ]
        for (list, card, step, outcome, why) in cases {
            let id: BoardCardID = card.hasPrefix("~") ? .session(String(card.dropFirst())) : .topic(card)
            XCTAssertEqual(TopicCards.step(id, step, in: cards(list), inPlay: places), outcome, "\(list): \(card) \(step): \(why)")
        }
    }

    func testANoTopicSessionWithoutACardMakesAGuestOnUpAndHasNoOtherStep() {
        XCTAssertEqual(TopicCards.stepSessionWithoutCard(.up), .makeGuest)
        XCTAssertEqual(TopicCards.stepSessionWithoutCard(.down), .hidden)
    }
}
