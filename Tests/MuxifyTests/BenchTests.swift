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
                       records: [TopicRecord]? = nil, windows: [TmuxWindow]? = nil) -> TopicsModel {
        var config = Config()
        config.topics.inPlay = inPlay
        let location: Location? = place.map { place in
            place.hasPrefix("@") ? .window(WindowID(rawValue: place)!) : .emptyTopic(.topic(place))
        }
        return TopicsModel(records: records ?? self.records, windows: windows ?? self.windows, config: config,
                           selection: TopicSelection(), location: location, benchShown: benchShown)
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

    func testADragMovesACardAmongTheCardsWithItsPinAndPastTheShownBenchLine() {
        let topics = model(inPlay: 2, benchShown: true, at: "@1")
        let unpinned = ["topic-a", "topic-b", "bench-line", "no-topic", "topic-c", "topic-d"]
        XCTAssertEqual(topics.dragItems(around: "topic-a").map(\.id), unpinned)
        XCTAssertEqual(topics.dragItems(around: "topic-d").map(\.id), unpinned)
        XCTAssertEqual(topics.dragItems(around: "bench-line").map(\.id), unpinned, "the line slides with the cards it is between")
        XCTAssertEqual(topics.dragItems(around: "topic-pinned").map(\.id), ["topic-pinned"])
    }

    func testWhileTheBenchIsHiddenADragKeepsACardOnItsSideOfTheLine() {
        let topics = model(inPlay: 2, at: "d")
        XCTAssertEqual(topics.dragItems(around: "topic-a").map(\.id), ["topic-a", "topic-b"])
        XCTAssertEqual(topics.dragItems(around: "topic-d").map(\.id), ["topic-d"])
        XCTAssertEqual(topics.dragItems(around: "bench-line").map(\.id), [])
    }

    func testHintsNumberOnlyTheCardsThatShowInTheirOrder() {
        let hidden = model(inPlay: 2, at: "d")
        XCTAssertEqual(cards(hidden), [.topic("pinned"), .topic("a"), .topic("b"), .topic("d")])
        let targets = QuickSwitchTargets(model: hidden, sessions: [], windows: [], tabIDs: [])
        XCTAssertEqual(targets.target(for: .card(4)), .topic("d"))
        XCTAssertNil(targets.target(for: .card(5)), "past the cards that show, a card key does nothing")
        XCTAssertEqual(targets.step(.topic, .next, from: .topic("b")), .topic("d"), "a Topic step skips the hidden Bench")
        XCTAssertEqual(targets.step(.topic, .next, from: .topic("d")), .topic("pinned"), "and wraps after the cards that show")
        XCTAssertEqual(hidden.nextTopic(after: "b"), .topic("c"), "the Next Topic after Snooze or Settle still uses every card")
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
