import XCTest
@testable import MuxifyCore

final class BenchTests: XCTestCase {
    private func topic(_ id: String, order: Double, pinned: Bool = false) -> TopicRecord {
        var record = TopicRecord(id: id, title: id)
        record.order = order
        record.isPinned = pinned
        return record
    }

    private func window(_ id: String, lock: Double? = nil) -> TmuxWindow {
        var window = TmuxWindow(id: "@" + id, sessionID: "$" + id, sessionName: "session-" + id, index: 0,
                                name: "shell", paneTitle: "shell", path: "/tmp", command: "zsh", isActive: true,
                                paneCount: 1, hasBell: false, sessionActivity: 0, agent: "", storedBrowser: .init(), openRequests: [])
        window.lockOrder = lock
        return window
    }

    /// A Pinned Topic, then a, b, c and d in that order, and a Session in No Topic.
    private var records: [TopicRecord] {
        [topic("pinned", order: 9, pinned: true), topic("a", order: 0), topic("b", order: 1), topic("c", order: 2), topic("d", order: 3)]
    }
    private var windows: [TmuxWindow] { [window("1")] }

    /// The Topics model as the Sidebar builds it, at the Location of a Topic id, a Window id ("@…") or nowhere.
    private func model(inPlay: Int?, benchShown: Bool = false, at place: String? = nil,
                       records: [TopicRecord]? = nil, windows: [TmuxWindow]? = nil,
                       benchPeek: TopicsModel.BenchPeek? = nil) -> TopicsModel {
        var config = Config()
        config.topics.inPlay = inPlay
        let location: Location? = place.map { place in
            place.hasPrefix("@") ? .window(WindowID(rawValue: place)!) : .emptyTopic(.topic(place))
        }
        return TopicsModel(records: records ?? self.records, windows: windows ?? self.windows, config: config,
                           selection: TopicSelection(), location: location, benchShown: benchShown, benchPeek: benchPeek)
    }

    private func shown(_ model: TopicsModel) -> [String] { model.list.map(\.id) }

    private func cards(_ model: TopicsModel) -> [QuickSwitchTarget] {
        QuickSwitchTargets(model: model, sessions: [], windows: [], tabIDs: []).cards
    }

    func testWithoutInPlayTheListIsEveryCardThenTheNoTopicSessionAndHasNoBench() {
        let off = model(inPlay: nil, at: "@1")
        XCTAssertEqual(shown(off), ["topic-pinned", "topic-a", "topic-b", "topic-c", "topic-d", "no-topic"])
        XCTAssertEqual(off.list.compactMap(\.cardID?.quickSwitchTarget), off.rows.compactMap(\.id.quickSwitchTarget))
        XCTAssertNil(off.isBenchShown)
        XCTAssertEqual(shown(model(inPlay: 4)), ["topic-pinned", "topic-a", "topic-b", "topic-c", "topic-d"],
                       "with no card left for the Bench, the list has no Bench line")
        XCTAssertNil(model(inPlay: 4).isBenchShown)
    }

    func testPinnedCardsAlwaysShowAndDoNotCountTowardInPlay() {
        let topics = model(inPlay: 2)
        XCTAssertEqual(shown(topics), ["topic-pinned", "topic-a", "topic-b", "bench-line"])
        XCTAssertEqual(topics.isBenchShown, false)
        XCTAssertEqual(topics.rows.map(\.id), [.topic("pinned"), .topic("a"), .topic("b"), .topic("c"), .topic("d")],
                       "the Bench changes what shows, not the order of the cards")
        XCTAssertEqual(shown(model(inPlay: 2, benchShown: true)),
                       ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-c", "topic-d"])
    }

    func testALockedSessionCountsTowardInPlay() {
        let topics = model(inPlay: 2, windows: [window("2", lock: 0.5)])
        XCTAssertEqual(shown(topics), ["topic-pinned", "topic-a", "locked-$2", "bench-line"])
    }

    func testAHiddenBenchShowsOnlyTheLocationsCardUnderTheLine() {
        let topics = model(inPlay: 2, at: "d")
        XCTAssertEqual(shown(topics), ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-d"])
        XCTAssertEqual(topics.isBenchShown, false, "a jump to a Benched card does not show the whole Bench")
    }

    func testTheNoTopicSessionShowsRightUnderTheLineWhetherTheBenchShowsOrNot() {
        XCTAssertEqual(shown(model(inPlay: 2, at: "@1")),
                       ["topic-pinned", "topic-a", "topic-b", "bench-line", "no-topic"])
        XCTAssertEqual(shown(model(inPlay: 2, benchShown: true, at: "@1")),
                       ["topic-pinned", "topic-a", "topic-b", "bench-line", "no-topic", "topic-c", "topic-d"])
    }

    func testTheLocationsBenchedCardStaysRightUnderTheLineWhenTheBenchShows() {
        let topics = model(inPlay: 2, benchShown: true, at: "d")
        XCTAssertEqual(shown(topics), ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-d", "topic-c"],
                       "it does not jump to its place in the Bench when the Bench shows")
        XCTAssertEqual(topics.rows.map(\.id), [.topic("pinned"), .topic("a"), .topic("b"), .topic("c"), .topic("d")],
                       "its place in the list does not change")
    }

    func testADragShowsBenchedCardsOnlyForAMoment() {
        XCTAssertEqual(shown(model(inPlay: 2, benchPeek: .all)),
                       ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-c", "topic-d"],
                       "an In Play card that crosses the hidden line opens the Bench")
        XCTAssertEqual(shown(model(inPlay: 2, at: "b", benchPeek: .card(.topic("c")))),
                       ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-c"],
                       "the card that a trade sent to the hidden Bench shows under the line until it folds in")
        XCTAssertEqual(model(inPlay: 2, benchPeek: .all).isBenchShown, true)
    }

    func testADragReachesTheCardsWithItsPinAndTheLineAndTheNoTopicSessionStayAmongThem() {
        let topics = model(inPlay: 2, benchShown: true, at: "@1")
        let unpinned: [StackSlot<TopicListID>] = [.item(.topic("a")), .item(.topic("b")), .fixed("bench-line"), .fixed("no-topic"),
                                                  .item(.topic("c")), .item(.topic("d"))]
        XCTAssertEqual(topics.dragSlots(around: "topic-a"), unpinned)
        XCTAssertEqual(topics.dragSlots(around: "topic-d"), unpinned)
        XCTAssertEqual(topics.dragSlots(around: "bench-line"), unpinned, "the line slides with the cards it is between")
        XCTAssertEqual(topics.dragSlots(around: "topic-pinned"), [.item(.topic("pinned"))], "a Pinned card trades with none")
    }

    func testWhileTheBenchIsHiddenEveryCardCanReachTheOtherSideOfTheLine() {
        let topics = model(inPlay: 2, at: "d")
        let unpinned: [StackSlot<TopicListID>] = [.item(.topic("a")), .item(.topic("b")), .fixed("bench-line"), .item(.topic("d"))]
        XCTAssertEqual(topics.dragSlots(around: "topic-a"), unpinned, "an In Play card can cross the hidden line")
        XCTAssertEqual(topics.dragSlots(around: "topic-d"), unpinned)
        let locked = model(inPlay: 2, at: "@2", windows: [window("1"), window("2", lock: 4)])
        XCTAssertEqual(locked.dragSlots(around: "locked-$2"), unpinned.dropLast() + [.item(.lock(sessionID: "$2"))],
                       "a Benched Locked Session trades the same way")
    }

    func testUnderTheShownLineTheLocationsCardAndTheOtherBenchedCardsKeepTheirPlacesForEachOther() {
        let records = records + [topic("e", order: 4)]
        let topics = model(inPlay: 2, benchShown: true, at: "d", records: records)
        XCTAssertEqual(shown(topics), ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-d", "topic-c", "topic-e"])
        let inPlay: [StackSlot<TopicListID>] = [.item(.topic("a")), .item(.topic("b")), .fixed("bench-line")]
        XCTAssertEqual(topics.dragSlots(around: "topic-c"), inPlay + [.held(.topic("d")), .item(.topic("c")), .item(.topic("e"))],
                       "a Benched card reorders around the Location's card, which stays under the line")
        XCTAssertEqual(topics.dragSlots(around: "topic-d"), inPlay + [.item(.topic("d")), .held(.topic("c")), .held(.topic("e"))],
                       "the Location's card only trades")
        XCTAssertEqual(topics.dragSlots(around: "topic-a"), inPlay + [.item(.topic("d")), .item(.topic("c")), .item(.topic("e"))],
                       "an In Play card can trade with each of them")
    }

    func testHintsNumberOnlyTheCardsThatShowInTheirOrder() {
        let hidden = model(inPlay: 2, at: "d")
        XCTAssertEqual(cards(hidden), [.topic("pinned"), .topic("a"), .topic("b"), .topic("d")])
        let targets = QuickSwitchTargets(model: hidden, sessions: [], windows: [], tabIDs: [])
        XCTAssertEqual(targets.target(for: .card(4)), .topic("d"))
        XCTAssertNil(targets.target(for: .card(5)), "past the cards that show, a card key does nothing")
        XCTAssertEqual(targets.step(.topic, .next, from: .topic("b")), .topic("d"), "a Topic step skips the hidden Bench")
        XCTAssertEqual(targets.step(.topic, .next, from: .topic("d")), .topic("pinned"), "and wraps after the cards that show")
        XCTAssertEqual(hidden.nextTopic(after: "b"), .topic("c"), "the Next Topic after Settle still uses every card")
        XCTAssertEqual(cards(model(inPlay: 2, benchShown: true, at: "@1")),
                       [.topic("pinned"), .topic("a"), .topic("b"), .topic("c"), .topic("d")])
    }

    func testSessionsModeHasNoBench() {
        var config = Config()
        config.topics.inPlay = 1
        let sessions = TopicsModel(records: records, windows: windows, config: config, selection: TopicSelection(), mode: .sessions)
        XCTAssertNil(sessions.isBenchShown)
    }
}
