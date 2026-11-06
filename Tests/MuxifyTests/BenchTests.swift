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
                       records: [TopicRecord]? = nil, windows: [TmuxWindow]? = nil, openPlaces: [OpenPlace] = [],
                       benchPeek: TopicsModel.BenchPeek? = nil) -> TopicsModel {
        var config = Config()
        config.topics.inPlay = inPlay
        let location: Location? = place.map { place in
            place.hasPrefix("@") ? .window(WindowID(rawValue: place)!) : .emptyTopic(.topic(place))
        }
        return TopicsModel(records: records ?? self.records, openPlaces: openPlaces, windows: windows ?? self.windows, config: config,
                           selection: TopicSelection(), location: location, benchShown: benchShown, benchPeek: benchPeek)
    }

    private func shown(_ model: TopicsModel) -> [String] { model.list.map(\.id) }

    func testAnOpenPlaceKeepsItsCardNumberSoTheCardsUnderItKeepTheirs() {
        let open = model(inPlay: 3, at: "@1", openPlaces: [OpenPlace(id: "o", order: 0.5)])
        XCTAssertEqual(shown(open), ["topic-pinned", "topic-a", "open-place-2", "topic-b", "bench-line", "no-topic"])
        let targets = QuickSwitchTargets(model: open, sessions: [], windows: [], tabIDs: [])
        XCTAssertEqual(targets.cards, [.topic("pinned"), .topic("a"), nil, .topic("b")])
        XCTAssertNil(targets.target(for: .card(3)), "Select Card 3 goes somewhere from an Open Place")
        XCTAssertEqual(targets.target(for: .card(4)), .topic("b"))
        XCTAssertEqual(targets.step(.topic, .next, from: .topic("a")), .topic("b"), "Next Topic stops on the Open Place")
    }

    func testTheNextTopicIsTheNextCardThatShowsElseTheFirstInPlayCard() {
        // In Play: a, b. Bench: c, d.
        XCTAssertEqual(model(inPlay: 2, at: "a").nextTopic(after: .topic("a")), .topic("b"), "the next In Play card")
        XCTAssertEqual(model(inPlay: 2, at: "b").nextTopic(after: .topic("b")), .topic("a"),
                       "the last In Play card goes to the first, not to the hidden Bench")
        XCTAssertEqual(model(inPlay: 2, benchShown: true, at: "b").nextTopic(after: .topic("b")), .topic("c"),
                       "a shown Bench shows the next card")
        XCTAssertEqual(model(inPlay: 2, at: "d").nextTopic(after: .topic("d")), .topic("a"),
                       "a Benched card under a hidden Bench goes to the first In Play card")
        let open = model(inPlay: 3, at: "b", openPlaces: [OpenPlace(id: "o", order: 0.5)])
        XCTAssertEqual(open.nextTopic(after: .topic("b")), .topic("a"), "an Open Place is no Next Topic")
        XCTAssertEqual(model(inPlay: 4, at: "d").nextTopic(after: .topic("d")), .topic("a"),
                       "with an empty Bench and no Bench line, the last In Play card still goes to the first")
        let pinnedBetween = [topic("a", order: 0), topic("pinned", order: 1, pinned: true), topic("c", order: 2)]
        XCTAssertEqual(model(inPlay: 1, at: "a", records: pinnedBetween).nextTopic(after: .topic("a")), .topic("c"),
                       "with no other In Play card, a Benched card, not the Pinned Topic next in the order")
        XCTAssertEqual(model(inPlay: 1, at: "a", records: Array(pinnedBetween.prefix(2))).nextTopic(after: .topic("a")), .noTopic,
                       "with only a Pinned Topic left, no Topic")
        XCTAssertEqual(model(inPlay: nil, at: "d").nextTopic(after: .topic("d")), .topic("c"), "without In Play, the nearest card above")
        XCTAssertEqual(model(inPlay: 2, at: "@1", windows: [window("1", lock: 5)]).nextTopic(after: .locked("$1")), .topic("a"),
                       "a Guest Session, the last card that shows, goes to the first In Play card")
        let onlyInPlay = model(inPlay: 1, at: "a")
        XCTAssertEqual(onlyInPlay.nextTopic(after: .topic("a")), .topic("b"), "with no other card In Play, a Benched card")
        XCTAssertFalse(onlyInPlay.shows(.topic("b")), "which Bench does not open, because the Bench hides it")
    }

    func testMoveUpAndMoveDownEnableAtTheLinesAndTheHiddenBenchEnablesUpFromEveryBenchedCard() {
        let hidden = model(inPlay: 2)
        XCTAssertFalse(hidden.steps(of: TopicGroupID.topic("pinned")).canMove(.up), "a Pinned card stays among the Pinned cards")
        XCTAssertFalse(hidden.steps(of: TopicGroupID.topic("a")).canMove(.up), "the first place has no Up")
        XCTAssertEqual(hidden.steps(of: TopicGroupID.topic("b")).down, .toGuests, "the last place goes to the Guests")
        for card in ["c", "d"] {
            XCTAssertTrue(hidden.steps(of: TopicGroupID.topic(card)).canMove(.up), "Up from the Benched \(card) is Make a Guest")
            XCTAssertEqual(hidden.steps(of: TopicGroupID.topic(card)).up, .makeGuest)
            XCTAssertFalse(hidden.steps(of: TopicGroupID.topic(card)).canMove(.down), "no card shows below the Bench")
        }

        let shown = model(inPlay: 2, benchShown: true)
        XCTAssertEqual(shown.steps(of: TopicGroupID.topic("c")).up, .makeGuest)
        XCTAssertEqual(shown.steps(of: TopicGroupID.topic("d")).up, .reorder(.before(.topic("c"))))
        XCTAssertTrue(shown.steps(of: TopicGroupID.topic("c")).canMove(.down))
        XCTAssertFalse(shown.steps(of: TopicGroupID.topic("d")).canMove(.down))
    }

    func testAGuestSessionCannotMoveUpFromTheTopOfTheGuestsAndMovesDownToTheBench() {
        let topics = model(inPlay: 2, windows: [window("1", lock: 5)])
        XCTAssertEqual(topics.steps(of: .locked("$1")).up, .refused(.guestSession))
        XCTAssertFalse(topics.steps(of: .locked("$1")).canMove(.up))
        XCTAssertEqual(topics.steps(of: .locked("$1")).down, .bench)
        XCTAssertEqual(topics.steps(of: TopicGroupID.topic("b")).down, .toGuests)
    }

    func testWithoutInPlayAStepStaysAmongTheCardsWithTheSamePin() {
        let topics = model(inPlay: nil)
        XCTAssertEqual(topics.steps(of: TopicGroupID.topic("b")).up, .reorder(.before(.topic("a"))))
        XCTAssertEqual(topics.steps(of: TopicGroupID.topic("d")).down, .atEnd)
        XCTAssertFalse(topics.steps(of: TopicGroupID.topic("pinned")).canMove(.up))
    }

    private func cards(_ model: TopicsModel) -> [QuickSwitchTarget?] {
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

    func testAGuestIsInPlayAndDoesNotCountTowardInPlay() {
        let lock = model(inPlay: 2, windows: [window("2", lock: 0.5)])
        XCTAssertEqual(shown(lock), ["topic-pinned", "topic-a", "topic-b", "guests-line", "locked-$2", "bench-line"],
                       "a Locked Session is a Guest, under the Guests line and never between two places")
        XCTAssertEqual(lock.rows.filter(\.isGuest).map(\.id), [.locked("$2")])
        XCTAssertEqual(CheckAction.chooseInPlay(places: 2).listed(lock).map(\.id), [.topic("a"), .topic("b"), .topic("c"), .topic("d")],
                       "Choose In Play does not list a Guest Session")
        XCTAssertEqual(shown(model(inPlay: nil, windows: [window("2", lock: 0.5)])),
                       ["topic-pinned", "topic-a", "locked-$2", "topic-b", "topic-c", "topic-d"])

        var records = self.records
        records[4].isGuest = true
        let topic = model(inPlay: 2, records: records)
        XCTAssertEqual(shown(topic), ["topic-pinned", "topic-a", "topic-b", "guests-line", "topic-d", "bench-line"],
                       "a Guest Topic is In Play, also when the order puts it after a Benched card")
        XCTAssertEqual(topic.split(inPlay: 2).bench.map(\.id), [.topic("c")])
        XCTAssertFalse(model(inPlay: nil, records: records).rows.contains(where: \.isGuest), "without in_play the mark has no effect")
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

    func testAShownBenchShowsTheLocationsCardAtItsPlaceInTheList() {
        let topics = model(inPlay: 2, benchShown: true, at: "d")
        XCTAssertEqual(shown(topics), ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-c", "topic-d"],
                       "nothing reorders for display")
        XCTAssertEqual(topics.benchedLocation, .topic("d"))
        XCTAssertEqual(model(inPlay: 2, at: "d").benchedLocation, .topic("d"), "the hidden Bench shows the Location's card")
        XCTAssertNil(model(inPlay: 2, benchShown: true, at: "a").benchedLocation, "an In Play card is not on the Bench")
        XCTAssertNil(model(inPlay: 2, benchShown: true, at: "@1").benchedLocation, "the opened No Topic Session is not on the Bench")
    }

    func testTheListSplitsIntoTheTopThatStaysAndTheBenchedCardsThatScroll() {
        let topics = model(inPlay: 2, benchShown: true, at: "@1")
        XCTAssertEqual(topics.listParts.top.map(\.id), ["topic-pinned", "topic-a", "topic-b", "bench-line", "no-topic"])
        XCTAssertEqual(topics.listParts.bench?.map(\.id), ["topic-c", "topic-d"])
        XCTAssertEqual(topics.benchCardIDs, [.topic("c"), .topic("d")])
        XCTAssertTrue(topics.isBenched(.topic("c")))
        XCTAssertFalse(topics.isBenched(.topic("a")))
        XCTAssertEqual(model(inPlay: 2).listParts.bench?.map(\.id), [], "a hidden Bench away from the Location shows no card")
        let off = model(inPlay: nil, at: "@1")
        XCTAssertNil(off.listParts.bench, "without a Bench line every item is at the top")
        XCTAssertEqual(off.listParts.top.map(\.id), shown(off))
        XCTAssertEqual(off.benchCardIDs, [])
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
        XCTAssertEqual(locked.dragSlots(around: "locked-$2"),
                       [.item(.topic("a")), .item(.topic("b")), .fixed("guests-line"), .item(.lock(sessionID: "$2")), .fixed("bench-line")],
                       "a Locked Session is a Guest, so it is In Play, also when its order is after the Bench")
    }

    func testUnderTheShownLineTheBenchedCardsReorderAmongEachOtherAroundTheLocationsCard() {
        let records = records + [topic("e", order: 4)]
        let topics = model(inPlay: 2, benchShown: true, at: "d", records: records)
        XCTAssertEqual(shown(topics), ["topic-pinned", "topic-a", "topic-b", "bench-line", "topic-c", "topic-d", "topic-e"])
        let unpinned: [StackSlot<TopicListID>] = [.item(.topic("a")), .item(.topic("b")), .fixed("bench-line"),
                                                  .item(.topic("c")), .item(.topic("d")), .item(.topic("e"))]
        XCTAssertEqual(topics.dragSlots(around: "topic-c"), unpinned, "the Location's card is a place to land as each other card")
        XCTAssertEqual(topics.dragSlots(around: "topic-d"), unpinned)
        XCTAssertEqual(topics.dragSlots(around: "topic-a"), unpinned)
    }

    func testHintsNumberOnlyTheCardsThatShowInTheirOrder() {
        let hidden = model(inPlay: 2, at: "d")
        XCTAssertEqual(cards(hidden), [.topic("pinned"), .topic("a"), .topic("b"), .topic("d")])
        let targets = QuickSwitchTargets(model: hidden, sessions: [], windows: [], tabIDs: [])
        XCTAssertEqual(targets.target(for: .card(4)), .topic("d"))
        XCTAssertNil(targets.target(for: .card(5)), "past the cards that show, a card key does nothing")
        XCTAssertEqual(targets.step(.topic, .next, from: .topic("b")), .topic("d"), "a Topic step skips the hidden Bench")
        XCTAssertEqual(targets.step(.topic, .next, from: .topic("d")), .topic("pinned"), "and wraps after the cards that show")
        XCTAssertEqual(hidden.nextTopic(after: .topic("b")), .topic("d"), "the Next Topic after Settle is the next card that shows")
        XCTAssertEqual(cards(model(inPlay: 2, benchShown: true, at: "@1")),
                       [.topic("pinned"), .topic("a"), .topic("b"), .topic("c"), .topic("d")])
        let shownAtD = model(inPlay: 2, benchShown: true, at: "d")
        XCTAssertEqual(cards(shownAtD), [.topic("pinned"), .topic("a"), .topic("b"), .topic("c"), .topic("d")],
                       "a shown Bench numbers its cards in list order, also with the Location on it")
        XCTAssertEqual(QuickSwitchTargets(model: shownAtD, sessions: [], windows: [], tabIDs: []).target(for: .card(4)), .topic("c"))
    }

    func testSessionsModeHasNoBench() {
        var config = Config()
        config.topics.inPlay = 1
        let sessions = TopicsModel(records: records, windows: windows, config: config, selection: TopicSelection(), mode: .sessions)
        XCTAssertNil(sessions.isBenchShown)
    }
}
