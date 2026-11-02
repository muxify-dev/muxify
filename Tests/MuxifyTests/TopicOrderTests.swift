import XCTest
@testable import MuxifyCore

final class TopicOrderTests: XCTestCase {
    private func record(_ id: String, order: Double?) -> TopicRecord {
        var record = TopicRecord(id: id, title: id, slug: "untitled-" + id)
        record.order = order
        record.createdAt = "1970-01-01T00:00:00Z"
        record.unknownFields = ["future": .object(["id": .string(id)])]
        record.sessions = [.object(["repository_path": .string("/work/app"), "future_session": .integer(42)])]
        return record
    }

    private func applying(_ edits: [TopicListEntry], to entries: [TopicListEntry]) -> [TopicListEntry] {
        entries.map { entry in edits.first { $0.id == entry.id } ?? entry }
            + edits.filter { edit in !entries.contains { $0.id == edit.id } }
    }

    /// Each entry's Topic id, or `lock:` and its Session ID.
    private func ids(_ entries: [TopicListEntry]) -> [String] {
        entries.map {
            switch $0.id {
            case .topic(let id): return id
            case .lock(let sessionID): return "lock:" + sessionID
            case .openPlace(let id): return "open:" + id
            }
        }
    }

    private func shown(_ entries: [TopicListEntry]) -> [String] { ids(TopicOrder.sorted(entries)) }

    func testADraggedCardPassesAnotherWhenThePointerPassesItsMiddle() {
        // a at 0–40, b at 46–146, c at 152–192.
        let layout = StackLayout(heights: [.item("a"): 40, .item("b"): 100, .item("c"): 40], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .item("b"), .item("c")]
        XCTAssertEqual(layout.top(of: .item("c"), in: order), 152)
        XCTAssertNil(layout.placement(of: "c", at: 97, in: order), "the pointer at 97 has not passed b's middle at 96")
        XCTAssertEqual(layout.placement(of: "c", at: 95, in: order), .before("b"))
        XCTAssertEqual(layout.placement(of: "c", at: 19, in: order), .before("a"), "the pointer at 19 passed a's middle at 20")
        XCTAssertEqual(layout.placement(of: "a", at: 97, in: order), .after("b"), "the pointer at 97 passed b's middle")
        XCTAssertEqual(layout.placement(of: "a", at: 400, in: order), .after("c"), "below every card goes last")
        XCTAssertNil(layout.placement(of: "b", at: 171, in: order), "a tall card passes a short one only at its middle")
        XCTAssertEqual(layout.placement(of: "b", at: 173, in: order), .after("c"))
        XCTAssertNil(layout.placement(of: "b", at: 60, in: order), "a card dropped on itself stays")
        XCTAssertNil(layout.placement(of: "d", at: 60, in: order))
    }

    func testAShortCardAndATallCardCrossAtTheSamePointer() {
        // s at 0–40 or t at 0–300, then the line, then c.
        for height: CGFloat in [40, 300] {
            let layout = StackLayout(heights: [.item("x"): height, .fixed("line"): 20, .item("c"): 40], spacing: 6)
            let order: [StackSlot<String>] = [.item("x"), .fixed("line"), .item("c")]
            let line = layout.top(of: .fixed("line"), in: order) + 10
            XCTAssertNil(layout.landing(of: "x", at: line - 1, in: order, dividers: ["line"]),
                         "a card \(height) high is not across before the pointer passes the line's middle")
            XCTAssertEqual(layout.landing(of: "x", at: line + 1, in: order, dividers: ["line"]), .across(trade: nil),
                           "a card \(height) high is across once the pointer passes the line's middle")
        }
    }

    func testATallCardIsAcrossTheBenchLineOnlyWhenThePointerIs() {
        // t at 0–300, the line at 306–326 with its middle at 316, c at 332–372.
        let layout = StackLayout(heights: [.item("t"): 300, .fixed("line"): 20, .item("c"): 40], spacing: 6)
        let order: [StackSlot<String>] = [.item("t"), .fixed("line"), .item("c")]
        XCTAssertNil(layout.landing(of: "t", at: 306, in: order, dividers: ["line"]),
                     "10 points above the line's middle, the pointer has not crossed, though t's bottom has")
        XCTAssertEqual(layout.landing(of: "t", at: 326, in: order, dividers: ["line"]), .across(trade: nil))
    }

    func testAcrossTheLineACardTradesWithTheCardUnderThePointer() {
        // a at 0–40, the line at 46–66, b at 72–172, c at 178–218.
        let layout = StackLayout(heights: [.item("a"): 40, .fixed("line"): 20, .item("b"): 100, .item("c"): 40], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .fixed("line"), .item("b"), .item("c")]
        func landing(_ probe: CGFloat) -> DropLanding<String>? { layout.landing(of: "a", at: probe, in: order, dividers: ["line"]) }
        XCTAssertEqual(landing(70), .across(trade: nil), "past the line, the pointer is on no card yet")
        XCTAssertEqual(landing(80), .across(trade: "b"), "on b's top, above its middle at 122, it trades with b")
        XCTAssertEqual(landing(170), .across(trade: "b"), "on b's bottom, past its middle, it still trades with b")
        XCTAssertEqual(landing(175), .across(trade: "b"), "in the gap after b, the nearest card it reached is b")
        XCTAssertEqual(landing(180), .across(trade: "c"), "on c's top, above its middle at 198, it trades with c")
        XCTAssertEqual(landing(500), .across(trade: "c"), "past every card it trades with the last")
    }

    func testADraggedCardStopsAtTheEndsOfItsListAndAtTheTopOfTheView() {
        let layout = StackLayout(heights: [.item("a"): 40, .item("b"): 100, .item("c"): 40], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .item("b"), .item("c")]
        XCTAssertEqual(layout.bounded(-30, of: "b", in: order), -30, "within the list it follows the pointer")
        XCTAssertEqual(layout.bounded(1000, of: "b", in: order), 46, "it stops at the bottom of the last card")
        XCTAssertEqual(layout.bounded(-1000, of: "b", in: order), -46, "it stops at the top of the first card")
        XCTAssertEqual(layout.bounded(-1000, of: "b", in: order, headroom: 20), -20, "it stops at the top of the view first")
        XCTAssertEqual(layout.bounded(-1000, of: "b", in: order, headroom: -15), 0, "a card already past the top does not go up")
        XCTAssertEqual(layout.bounded(30, of: "b", in: order, headroom: -15), 30, "it still goes down")
    }

    func testADraggedCardPassesAFixedLineButDoesNotLandOnIt() {
        // a at 0–40, the line at 46–66, b at 72–112, c at 118–158.
        let layout = StackLayout(heights: [.item("a"): 40, .fixed("line"): 20, .item("b"): 40, .item("c"): 40], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .fixed("line"), .item("b"), .item("c")]
        XCTAssertNil(layout.placement(of: "a", at: 80, in: order), "the pointer at 80 is past the line, above b's middle at 92")
        XCTAssertEqual(layout.placement(of: "a", at: 93, in: order), .after("b"))
        XCTAssertNil(layout.placement(of: "b", at: 27, in: order), "the pointer at 27 is above the line, below a's middle at 20")
        XCTAssertEqual(layout.placement(of: "b", at: 19, in: order), .before("a"))
        XCTAssertEqual(layout.bounded(-1000, of: "b", in: [.fixed("line"), .item("b"), .item("c")]), 0,
                       "it stops at the top of the first card, not of the line above it")
    }

    func testAPlacementKeepsTheFixedSlotsInTheirPlaces() {
        let order: [StackSlot<String>] = [.item("a"), .fixed("line"), .item("b"), .item("c")]
        XCTAssertEqual(DropPlacement.after("b").placing("a", in: order), [.item("b"), .fixed("line"), .item("a"), .item("c")])
        XCTAssertEqual(DropPlacement.before("a").placing("c", in: order), [.item("c"), .fixed("line"), .item("a"), .item("b")])
        XCTAssertEqual(DropPlacement.after("x").placing("a", in: order), order, "an anchor that left keeps the list")
    }

    func testACardThatCrossesTheDividerTradesWithTheCardThePointerReached() {
        // a at 0–40, b at 46–86, the line at 92–112 with its middle at 102, c at 118–158, d at 164–204.
        let layout = StackLayout(heights: [.item("a"): 40, .item("b"): 40, .fixed("line"): 20, .item("c"): 40, .item("d"): 40],
                                 spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .item("b"), .fixed("line"), .item("c"), .item("d")]
        func landing(_ id: String, _ probe: CGFloat) -> DropLanding<String>? {
            layout.landing(of: id, at: probe, in: order, dividers: ["line"])
        }
        XCTAssertEqual(landing("a", 70), .place(.after("b")), "on its own side it reorders")
        XCTAssertEqual(landing("a", 101), .place(.after("b")), "the pointer at 101 has not passed the line's middle")
        XCTAssertEqual(landing("a", 103), .across(trade: nil), "the pointer at 103 passed the line and is on no card")
        XCTAssertEqual(landing("a", 120), .across(trade: "c"), "the pointer at 120 is on c")
        XCTAssertEqual(landing("a", 160), .across(trade: "c"), "in the gap after c, the nearest card it reached is c")
        XCTAssertEqual(landing("a", 170), .across(trade: "d"))
        XCTAssertEqual(landing("a", 300), .across(trade: "d"), "past every card it trades with the last")
        XCTAssertEqual(landing("d", 30), .across(trade: "a"), "a Benched card trades up the same way")
        XCTAssertNil(landing("c", 103), "the pointer at 103 is still under the line's middle")
        XCTAssertEqual(landing("c", 101), .across(trade: nil), "the pointer at 101 passed the line and is on no card")
        XCTAssertEqual(landing("c", 88), .across(trade: nil), "in the gap above the line, it reached no card yet")
        XCTAssertEqual(landing("c", 80), .across(trade: "b"))
        XCTAssertEqual(layout.landing(of: "a", at: 160, in: order, dividers: []), .place(.after("c")),
                       "a list without a divider only reorders")
    }

    func testATallBenchedCardTradesWithASmallFirstCard() {
        // a at 0–40, the line at 46–66 with its middle at 56, t at 72–272.
        let layout = StackLayout(heights: [.item("a"): 40, .fixed("line"): 20, .item("t"): 200], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .fixed("line"), .item("t")]
        let highest = layout.bounded(-1000, of: "t", in: order, dividers: ["line"])
        XCTAssertEqual(highest, -72, "t stops with its top at the top of a")
        XCTAssertEqual(layout.landing(of: "t", at: 0, in: order, dividers: ["line"]), .across(trade: "a"),
                       "the pointer, held on t, is at a's top")
    }

    func testWithADividerACardCanGoPastTheLineThatEndsItsList() {
        let layout = StackLayout(heights: [.item("a"): 40, .item("b"): 40, .fixed("line"): 20], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .item("b"), .fixed("line")]
        XCTAssertEqual(layout.bounded(1000, of: "a", in: order), 46, "without a divider it stops at the bottom of the last card")
        XCTAssertEqual(layout.bounded(1000, of: "a", in: order, dividers: ["line"]), 72, "its bottom reaches the bottom of the line")
        XCTAssertEqual(layout.landing(of: "a", at: 112, in: order, dividers: ["line"]), .across(trade: nil),
                       "the pointer, held on a, is at a's bottom, past the line's middle")
    }

    func testADraggedCardStopsAtTheBottomOfTheView() {
        let layout = StackLayout(heights: [.item("a"): 40, .item("b"): 100, .item("c"): 40], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .item("b"), .item("c")]
        XCTAssertEqual(layout.bounded(1000, of: "b", in: order, footroom: 20), 20, "it stops at the bottom of the view first")
        XCTAssertEqual(layout.bounded(1000, of: "b", in: order, footroom: -15), 0, "a card already past the bottom does not go down")
        XCTAssertEqual(layout.bounded(-30, of: "b", in: order, footroom: -15), -30, "it still goes up")
    }

    func testTheCardsAfterTheLastFixedSlotStandWhereTheirAreaScrolledThem() {
        var layout = StackLayout(heights: [.item("a"): 40, .item("b"): 40, .fixed("line"): 20, .item("c"): 40, .item("d"): 40],
                                 spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .item("b"), .fixed("line"), .item("c"), .item("d")]
        XCTAssertEqual(layout.landing(of: "a", at: 105, in: order, dividers: ["line"]), .across(trade: nil),
                       "unscrolled, the pointer at 105 is over no card")
        XCTAssertEqual(layout.landing(of: "d", at: 64, in: order, dividers: ["line"]), .across(trade: "b"))
        layout.areaScroll = 50
        XCTAssertEqual(layout.top(of: .fixed("line"), in: order), 92)
        XCTAssertEqual(layout.top(of: .item("b"), in: order), 46)
        XCTAssertEqual(layout.top(of: .item("c"), in: order), 68)
        XCTAssertEqual(layout.landing(of: "a", at: 105, in: order, dividers: ["line"]), .across(trade: "c"),
                       "the pointer at 105 is on c, which the scroll brought up")
        XCTAssertEqual(layout.landing(of: "d", at: 34, in: order, dividers: ["line"]), .across(trade: "a"),
                       "the pointer at 34 is on a")
        XCTAssertEqual(layout.placement(of: "c", at: 135, in: order), .after("d"), "the pointer at 135 passed d's middle at 134")
        XCTAssertEqual(layout.top(of: .item("b"), in: [.item("a"), .item("b")]), 46, "a list without a fixed slot has no area")
    }

    func testACardCrossesEitherLineOfThreeSectionsAndReordersOnlyInItsOwn() {
        // a 0–40, b 46–86, guests 92–112, g 118–158, h 164–204, bench 210–230, c 236–276.
        let layout = StackLayout(heights: [.item("a"): 40, .item("b"): 40, .fixed("guests"): 20, .item("g"): 40, .item("h"): 40,
                                           .fixed("bench"): 20, .item("c"): 40], spacing: 6)
        let order: [StackSlot<String>] = [.item("a"), .item("b"), .fixed("guests"), .item("g"), .item("h"), .fixed("bench"), .item("c")]
        let lines = ["guests", "bench"]
        XCTAssertEqual(layout.landing(of: "g", at: 185, in: order, dividers: lines), .place(.after("h")),
                       "inside the Guests, a drag reorders")
        XCTAssertEqual(layout.landing(of: "g", at: 20, in: order, dividers: lines), .across(trade: "a"),
                       "up across the Guests line, it trades with a place")
        XCTAssertEqual(layout.landing(of: "h", at: 250, in: order, dividers: lines), .across(trade: "c"),
                       "down across the Bench line, it trades with a Benched card")
        XCTAssertEqual(layout.landing(of: "b", at: 260, in: order, dividers: lines), .across(trade: "c"),
                       "a place passes both lines to the Bench")
        XCTAssertEqual(layout.landing(of: "a", at: 67, in: order, dividers: lines), .place(.after("b")),
                       "a place reorders among the places")
    }

    @MainActor private func tradingDrag() -> (ListDrag<String>, [StackSlot<String>]) {
        let drag = ListDrag<String>(spacing: 6, tradesAcross: ["line"])
        let all: [StackSlot<String>] = [.item("a"), .item("b"), .fixed("line"), .item("c"), .item("d")]
        drag.measure(.fixed("line"), height: 20)
        for id in ["a", "b", "c", "d"] { drag.measure(id, ItemPlace(height: 40, visibleTop: 1000, footroom: 1000, windowTop: 0)) }
        for id in ["a", "b", "c", "d"] { drag.show(all, at: id) }
        return (drag, all)
    }

    @MainActor func testALiftedCardStaysUnderThePointerWhenTheListScrollsUnderIt() {
        let (drag, _) = tradingDrag()
        drag.press("c")
        drag.lift("c", pressedAt: 22)
        drag.follow("c", translation: 26, pointer: 500)
        XCTAssertEqual(drag.translation, 26)
        XCTAssertEqual(drag.pointer, 500)
        XCTAssertNil(drag.placement, "the pointer at 166 has not passed d's middle at 184")
        drag.measure("c", ItemPlace(height: 40, visibleTop: 980, footroom: 1020, windowTop: -20))
        XCTAssertEqual(drag.translation, 46, "its place went up 20, so it goes down 20 more from its place")
        XCTAssertEqual(drag.placement, .after("d"), "with no new pointer event, the pointer at 186 passed d's middle")
        drag.measure("c", ItemPlace(height: 40, visibleTop: 980, footroom: 10, windowTop: -20))
        XCTAssertEqual(drag.translation, 46, "a place that did not move changes nothing")
        drag.end("c", onTap: {}, onDrop: { _ in }, onTrade: { _ in })
        XCTAssertNil(drag.pointer, "let go, the list no longer scrolls for it")
    }

    @MainActor func testALiftedCardLandsAgainWhenTheAreaUnderItScrolls() {
        let (drag, _) = tradingDrag()
        drag.press("a")
        drag.lift("a", pressedAt: 20)
        drag.follow("a", translation: 85)
        XCTAssertTrue(drag.isAcross)
        XCTAssertNil(drag.tradeTarget, "the pointer at 105 is over no card")
        drag.scrollArea(by: 50)
        XCTAssertEqual(drag.tradeTarget, "c", "with no new pointer event, the scrolled Bench brought c under a")
        XCTAssertEqual(drag.tradeGhostOffset(of: "c"), -68, "c shows itself in a's place, 68 points above where it shows")
    }

    @MainActor func testADropOnATradeTargetPassesTheTwoItemsToEachOthersPlaces() {
        let (drag, all) = tradingDrag()
        drag.press("a")
        drag.lift("a", pressedAt: 20)
        drag.follow("a", translation: 120)
        XCTAssertEqual(drag.tradeTarget, "c")
        XCTAssertNil(drag.placement, "across the line no card makes room")
        XCTAssertEqual(drag.shift(of: .item("b"), in: all), 0)
        XCTAssertEqual(drag.tradeGhostOffset(of: "c"), -118, "c shows itself in a's place, 118 points above its own")
        XCTAssertNil(drag.tradeGhostOffset(of: "d"))
        drag.end("a", onTap: {}, onDrop: { _ in XCTFail("a trade is no placement") }, onTrade: { _ in })
        XCTAssertEqual(drag.phase, .trading("a", with: "c"))
        XCTAssertEqual(drag.tradePath(of: "a")?.to, 118, "a goes down to c's place")
        XCTAssertEqual(drag.tradePath(of: "c")?.to, -118, "c goes up to a's place")
        XCTAssertNil(drag.tradePath(of: "b"), "no other item moves")
        drag.show([.item("a"), .item("b"), .fixed("line"), .item("c"), .item("d")], at: "a")
        XCTAssertEqual(drag.phase, .trading("a", with: "c"), "it waits until the list shows a in c's place")
        drag.show([.item("c"), .item("b"), .fixed("line"), .item("a"), .item("d")], at: "a")
        XCTAssertEqual(drag.phase, .idle)
    }

    @MainActor func testALiftedCardLandsWhereThePointerPressedIt() {
        for (pressedAt, landing) in [(CGFloat(2), DropLanding<String>.place(.after("b"))), (38, .across(trade: "c"))] {
            let (drag, _) = tradingDrag()
            drag.press("a")
            drag.lift("a", pressedAt: pressedAt)
            drag.follow("a", translation: 85)
            XCTAssertEqual(drag.landing, landing, "pressed \(pressedAt) below a's top, the pointer is at \(pressedAt + 85)")
        }
    }

    @MainActor func testAPointerAboveTheViewLandsOnlyAmongTheCardsInView() {
        let (drag, _) = tradingDrag()
        drag.measure("d", ItemPlace(height: 40, visibleTop: 30, footroom: 1000, windowTop: 0))
        drag.press("d")
        drag.lift("d", pressedAt: 20)
        drag.follow("d", translation: -1000)
        XCTAssertEqual(drag.translation, -29.64, accuracy: 0.01, "d stops with its top at the top of the view")
        XCTAssertEqual(drag.landing, .place(.before("c")),
                       "the pointer, held on d, is at d's top, above c's middle, not on a card out of view")
    }

    func testAPlacementMovesTheItemNextToItsAnchor() {
        XCTAssertEqual(DropPlacement.before("a").placing("c", in: ["a", "b", "c"]), ["c", "a", "b"])
        XCTAssertEqual(DropPlacement.after("c").placing("a", in: ["a", "b", "c"]), ["b", "c", "a"])
        XCTAssertEqual(DropPlacement.after("x").placing("a", in: ["a", "b"]), ["a", "b"], "an anchor that left keeps the list")
    }

    func testMovesUseOnlyTheMovedRankWhenThereIsAFiniteGap() throws {
        let entries = [record("a", order: 0), record("b", order: 1), record("c", order: 2), record("d", order: 3)].map(TopicListEntry.topic)
        let cases: [(String, TopicPlacement, [String])] = [
            ("a", .after(.topic("d")), ["b", "c", "d", "a"]),
            ("d", .before(.topic("a")), ["d", "a", "b", "c"]),
            ("d", .after(.topic("b")), ["a", "b", "d", "c"]),
            ("a", .before(.topic("c")), ["b", "a", "c", "d"]),
        ]
        for (source, placement, expected) in cases {
            let edits = try TopicOrder.moving(.topic(source), to: placement, in: entries)
            XCTAssertEqual(ids(edits), [source])
            XCTAssertEqual(shown(applying(edits, to: entries)), expected)
            var original = entries.records.first { $0.id == source }!
            original.order = edits[0].order
            XCTAssertEqual(edits.records[0], original)
            XCTAssertTrue(edits[0].order!.isFinite)
        }
        XCTAssertTrue(try TopicOrder.moving(.topic("a"), to: .before(.topic("a")), in: entries).isEmpty)
        XCTAssertTrue(try TopicOrder.moving(.topic("a"), to: .before(.topic("b")), in: entries).isEmpty)
        XCTAssertTrue(try TopicOrder.moving(.topic("d"), to: .after(.topic("c")), in: entries).isEmpty)
    }

    func testEqualAbsentAndExhaustedRanksNormalizeOnlyOpenRecords() throws {
        let cases: [[Double?]] = [[0, 0, 0, 0], [nil, nil, nil, nil], [0, 1, Double(1).nextUp, 2]]
        for ranks in cases {
            let entries = zip(["a", "b", "c", "d"], ranks).map { TopicListEntry.topic(record($0, order: $1)) }
            let reordered = applying(try TopicOrder.moving(.topic("d"), to: .before(.topic("c")), in: entries), to: entries)
            XCTAssertEqual(shown(reordered), ["a", "b", "d", "c"])
            XCTAssertTrue(reordered.allSatisfy { $0.order?.isFinite == true })
            for old in entries.records {
                var expected = old
                expected.order = reordered.records.first { $0.id == old.id }!.order
                XCTAssertEqual(reordered.records.first { $0.id == old.id }, expected)
            }
        }
        var settled = record("settled", order: -100)
        settled.settledAt = "1970-01-01T00:00:00Z"
        let entries = [record("a", order: 0), record("b", order: 0), record("c", order: 0), settled].map(TopicListEntry.topic)
        let edits = try TopicOrder.moving(.topic("c"), to: .before(.topic("b")), in: entries)
        XCTAssertEqual(shown(applying(edits, to: entries)), ["a", "c", "b"])
        XCTAssertFalse(ids(edits).contains("settled"))
        XCTAssertEqual(applying(edits, to: entries).records.first { $0.id == "settled" }, settled)
        XCTAssertThrowsError(try TopicOrder.moving(.topic("settled"), to: .before(.topic("a")), in: entries))
        XCTAssertThrowsError(try TopicOrder.moving(.topic("a"), to: .before(.topic("settled")), in: entries))
        XCTAssertThrowsError(try TopicOrder.moving(.topic("missing"), to: .before(.topic("a")), in: entries))
        XCTAssertThrowsError(try TopicOrder.moving(.topic("a"), to: .after(.topic("missing")), in: entries))
    }

    func testNewTopicIsFirstAfterMovesAndAtFiniteLimits() throws {
        let original = [record("a", order: 0), record("b", order: 1), record("c", order: 2)].map(TopicListEntry.topic)
        let moved = applying(try TopicOrder.moving(.topic("c"), to: .before(.topic("a")), in: original), to: original)
        let new = TopicRecord(newTopic: "new", title: "New", slug: "new", now: Date())
        let placed = applying(TopicOrder.inserting(new, at: .end(.top), in: moved), to: moved)
        XCTAssertEqual(shown(placed), ["new", "c", "a", "b"])
        let extreme = [record("a", order: -.greatestFiniteMagnitude), record("b", order: .greatestFiniteMagnitude)].map(TopicListEntry.topic)
        let inserted = applying(TopicOrder.inserting(record("new", order: nil), at: .end(.top), in: extreme), to: extreme)
        XCTAssertEqual(shown(inserted), ["new", "a", "b"])
        XCTAssertTrue(inserted.allSatisfy { $0.order?.isFinite == true })
        let bottom = applying(try TopicOrder.moving(.topic("a"), to: .after(.topic("b")), in: extreme), to: extreme)
        XCTAssertEqual(shown(bottom), ["b", "a"])
        XCTAssertTrue(bottom.allSatisfy { $0.order?.isFinite == true })
    }

    func testALockGoesLastAmongTheUnpinnedEntriesAndMovesAsAnUnpinnedTopic() throws {
        var pinned = record("p", order: 9)
        pinned.isPinned = true
        let entries = [pinned, record("a", order: 0), record("b", order: 1)].map(TopicListEntry.topic)
            + [.lock(SessionLock(sessionID: "$1", order: 0.5))]
        XCTAssertEqual(shown(entries), ["p", "a", "lock:$1", "b"])
        let locked = applying(TopicOrder.appendingLock(of: "$2", in: entries), to: entries)
        XCTAssertEqual(shown(locked), ["p", "a", "lock:$1", "b", "lock:$2"])
        let moved = applying(try TopicOrder.moving(.lock(sessionID: "$2"), to: .before(.topic("p")), in: locked), to: locked)
        XCTAssertEqual(shown(moved), ["p", "lock:$2", "a", "lock:$1", "b"], "a Lock is never Pinned, so it stays below the Pinned Topics")
        let prepended = applying(TopicOrder.inserting(record("new", order: nil), at: .end(.top), in: moved), to: moved)
        XCTAssertEqual(shown(prepended), ["p", "new", "lock:$2", "a", "lock:$1", "b"], "a new Topic goes before the Locks too")
    }

    func testARenumberGivesTheLocksTheirNewOrderToo() throws {
        let entries = [record("a", order: 0), record("b", order: Double(0).nextUp)].map(TopicListEntry.topic)
            + [.lock(SessionLock(sessionID: "$1", order: 2))]
        let edits = try TopicOrder.moving(.lock(sessionID: "$1"), to: .before(.topic("b")), in: entries)
        XCTAssertEqual(shown(applying(edits, to: entries)), ["a", "lock:$1", "b"])
        XCTAssertEqual(edits.locks.map(\.sessionID), ["$1"])
        XCTAssertTrue(edits.allSatisfy { $0.order?.isFinite == true })
    }
}
