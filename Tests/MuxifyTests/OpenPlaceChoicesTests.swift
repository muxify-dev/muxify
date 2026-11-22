import XCTest
@testable import MuxifyCore
import MuxifyTestSupport

final class OpenPlaceChoicesTests: XCTestCase {
    private func topic(_ id: String, order: Double, title: String? = nil, guest: Bool = false, pinned: Bool = false,
                       note: String? = nil) -> TopicRecord {
        var record = TopicRecord(id: id, title: title ?? id)
        record.order = order
        record.isGuest = guest
        record.isPinned = pinned
        record.note = note
        return record
    }

    /// In Play (2 places): "a" and an Open Place. Guests: the Topics "g2" and "g1" and a Guest Session. Bench: "c", "b"
    /// and "d", which the Sidebar hides. A Pinned Topic is neither.
    private func model() -> BoardModel {
        var config = Config()
        config.topics.inPlay = 2
        let records = [
            topic("pinned", order: 9, pinned: true),
            topic("a", order: 0, title: "Alpha"),
            topic("g2", order: 2, title: "Repro seed 4411", guest: true, note: "then bisect"),
            topic("c", order: 3, title: "Settings window polish", note: "font row clips"),
            topic("g1", order: 4, title: "Guest one", guest: true),
            topic("b", order: 5, title: "Browser history decay"),
            topic("d", order: 6, title: "Diagnostics rollover"),
        ]
        let windows: [TmuxWindow] = [
            .fixture(id: "@1", sessionID: "$1", sessionName: "deploy-scripts", topicID: "d"),
            .fixture(id: "@2", sessionID: "$2", sessionName: "scratch", savedSessionID: "$2"),
        ]
        return BoardModel(records: records, openPlaces: [OpenPlace(id: "open", order: 1)], boardSessions: [BoardSession(id: "$2", order: 2.5)],
                           windows: windows, config: config,
                           selection: TopicSelection(), location: .openPlace("open"))
    }

    private func ids(_ choices: OpenPlaceChoices, _ section: OpenPlaceChoices.Section? = nil) -> [String] {
        (section.map(choices.choices(in:)) ?? choices.choices).map(\.id)
    }

    func testThePageListsTheGuestTopicsThenTheWholeBenchInTheOrderOfTheTopicsList() {
        let topics = model()
        XCTAssertEqual(topics.isBenchShown, false, "the Sidebar hides the Bench")
        let choices = OpenPlaceChoices(topics.split, query: "")
        XCTAssertEqual(ids(choices, .guests), ["g2", "g1"], "the Guest Topics, without the Guest Session")
        XCTAssertEqual(ids(choices, .bench), ["c", "b", "d"], "the whole Bench, also while the Sidebar hides it")
        XCTAssertEqual(ids(choices), ["g2", "g1", "c", "b", "d"], "never ranked, and no In Play or Pinned Topic")
        XCTAssertEqual(choices.total, 5)
    }

    func testAQueryHidesTheRowsThatDoNotMatchAndKeepsTheOrderOfTheOthers() {
        let topics = model()
        let all = ids(OpenPlaceChoices(topics.split, query: ""))
        let kept = ids(OpenPlaceChoices(topics.split, query: "e"))
        XCTAssertGreaterThan(kept.count, 2)
        XCTAssertEqual(kept, all.filter(kept.contains), "the rows that stay keep the list order, not a rank by match")
        let narrow = OpenPlaceChoices(topics.split, query: "rollover")
        XCTAssertEqual(ids(narrow), ["d"])
        XCTAssertEqual(narrow.total, 5, "the count of every Topic stays for the page's header")
        XCTAssertFalse(narrow.choices[0].title.marks.isEmpty, "the row marks what matched in its title")

        let byNote = OpenPlaceChoices(topics.split, query: "clips")
        XCTAssertEqual(ids(byNote), ["c"], "the Topic Note matches")
        XCTAssertFalse(byNote.choices[0].note?.marks.isEmpty ?? true)

        let bySession = OpenPlaceChoices(topics.split, query: "deploy")
        XCTAssertEqual(ids(bySession), ["d"], "a Session's name matches")
        XCTAssertEqual(bySession.choices[0].matchedSessions.count, 1)

        let none = OpenPlaceChoices(topics.split, query: "zzzz")
        XCTAssertTrue(none.choices.isEmpty)
        XCTAssertTrue(none.choices(in: .guests).isEmpty && none.choices(in: .bench).isEmpty, "a section with no row has none")
    }

    func testTheSelectionFallsToTheFirstRowAndMovesRoundTheEnds() {
        let choices = OpenPlaceChoices(model().split, query: "")
        XCTAssertEqual(choices.selected(nil)?.id, "g2", "the first row is selected on arrival")
        XCTAssertEqual(choices.selected("b")?.id, "b")
        XCTAssertEqual(OpenPlaceChoices(model().split, query: "rollover").selected("b")?.id, "d",
                       "a row that the query hides gives the selection to the first row")
        XCTAssertEqual(choices.moving(from: "g2", by: 1)?.id, "g1", "down goes from the Guests into the Bench in order")
        XCTAssertEqual(choices.moving(from: "g1", by: 1)?.id, "c")
        XCTAssertEqual(choices.moving(from: "g2", by: -1)?.id, "d", "up from the first row goes to the last")
    }

    func testTheOpenPlacePageIsTheLocationOfItsPlaceAndATopicStepGoesBesideIt() {
        let topics = model()
        XCTAssertNil(topics.activeTopic, "an Open Place page has no Active Topic")
        XCTAssertEqual(topics.place(ofOpenPlace: "open"), 2)
        XCTAssertEqual(topics.openPlaceID(at: 2), "open")
        let targets = QuickSwitchTargets(model: topics, sessions: [], windows: [], tabIDs: [])
        XCTAssertEqual(targets.step(.topic, .next, from: .openPlace(2)), .topic("g2"), "the card under the Open Place")
        XCTAssertEqual(targets.step(.topic, .previous, from: .openPlace(2)), .topic("a"), "the card over the Open Place")
    }
}
