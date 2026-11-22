import XCTest
@testable import MuxifyCore

/// The cases of the In Play design, with `topics.in_play` 3. A Sidebar is written as its cards in order: `📌name` is
/// Pinned, `_` is an Open Place, `name(G)` is a Guest Topic, `~name` is a Board Session and `~name(G)` one in the Guests,
/// `🔒name` is a Board Session that an older Muxify kept among the Topics as a Guest, `+` is the Guests line and `|` is
/// the Bench line.
final class GuestTests: XCTestCase {
    private let limit = 3

    /// The transaction for `sidebar`, with each card in the order that it has there.
    private func transaction(_ sidebar: String, inPlay: Int = 3) -> TopicTransaction {
        var records: [TopicRecord] = [], boardSessions: [BoardSession] = [], places: [OpenPlace] = []
        for (order, card) in sidebar.split(separator: " ").filter({ $0 != "|" && $0 != "+" }).enumerated() {
            var name = String(card)
            if name == "_" {
                places.append(OpenPlace(order: Double(order)))
                continue
            }
            let guest = name.hasSuffix("(G)")
            if guest { name.removeLast(3) }
            if name.hasPrefix("~") || name.hasPrefix("🔒") {
                boardSessions.append(BoardSession(id: String(name.dropFirst()), order: Double(order), isGuest: guest || name.hasPrefix("🔒")))
                continue
            }
            let pinned = name.hasPrefix("📌")
            if pinned { name.removeFirst() }
            var record = TopicRecord(id: name, title: name)
            record.order = Double(order)
            record.isPinned = pinned
            record.isGuest = guest
            records.append(record)
        }
        var transaction = TopicTransaction(records: records, inPlay: inPlay)
        transaction.boardSessions = boardSessions
        transaction.openPlaces = places
        return transaction
    }

    private func sidebar(_ transaction: TopicTransaction, inPlay: Int = 3) -> String {
        let all = transaction.entries
        let pinned = TopicOrder.sorted(all).filter(\.isPinned).map { "📌" + name($0) }
        let cut = TopicOrder.cut(all, inPlay: inPlay)
        let sections = [cut.places, cut.guests, cut.bench].map { $0.map(name) }
        return (pinned + sections[0] + ["+"] + sections[1] + ["|"] + sections[2]).joined(separator: " ")
    }

    private func name(_ entry: BoardCard) -> String {
        switch entry {
        case .topic(let record): return record.id + (entry.isGuest ? "(G)" : "")
        case .session(let session): return "~" + session.id + (entry.isGuest ? "(G)" : "")
        case .openPlace: return "_"
        }
    }

    /// The order on disk is the order that the Sidebar shows, so a read after a restart shows the same Sidebar.
    private func assertWrittenInOrder(_ transaction: TopicTransaction, file: StaticString = #filePath, line: UInt = #line) {
        let zone = TopicOrder.sorted(transaction.entries).filter { !$0.isPinned }
        let cut = TopicOrder.cut(transaction.entries, inPlay: limit)
        XCTAssertEqual(zone.map(\.id), (cut.places + cut.guests + cut.bench).map(\.id), file: file, line: line)
    }

    private func settling(_ id: String, in transaction: inout TopicTransaction) throws {
        let before = transaction.records.first { $0.id == id }!
        var after = before
        after.settledAt = "2026-10-30T00:00:00Z"
        try transaction.apply(TopicRecordChange(before: before, after: after))
    }

    func testMakeAGuestPutsTheCardAtTheEndOfTheGuests() throws {
        var a = transaction("📌notes payments auth-bug docs + scratch(G) | infra release")
        try a.makeGuest(.topic("infra"), inPlay: limit)
        XCTAssertEqual(sidebar(a), "📌notes payments auth-bug docs + scratch(G) infra(G) | release")
        assertWrittenInOrder(a)

        var b = transaction("payments auth-bug docs + infra(G) | release")
        b.addToBoard(BoardSession(id: "scratch", order: 0, isGuest: true, session: .object(["name": .string("scratch")])))
        let locked = b.entries
        b.addToBoard(BoardSession(id: "scratch", order: 0, isGuest: true))
        XCTAssertEqual(b.entries, locked, "a Board Session keeps its place and its Remembered Session")
        XCTAssertEqual(sidebar(b), "payments auth-bug docs + infra(G) ~scratch(G) | release", "a new Board Session is the last Guest")
        assertWrittenInOrder(b)

        var inPlay = transaction("payments auth-bug docs + | infra")
        XCTAssertThrowsError(try inPlay.makeGuest(.topic("docs"), inPlay: limit), "a card In Play cannot be made a Guest")
        var session = transaction("payments ~scratch docs + | infra")
        XCTAssertThrowsError(try session.makeGuest(.session("scratch"), inPlay: limit), "nor a Board Session in a place")
    }

    func testAGuestNeverSitsBetweenThePlaces() throws {
        let interleaved = transaction("payments infra(G) auth-bug ~scratch(G) docs release")
        XCTAssertEqual(sidebar(interleaved), "payments auth-bug docs + infra(G) ~scratch(G) | release")
    }

    func testARegularCardThatLeavesAPlaceLeavesAnOpenPlaceAndNoBenchedCardMovesUp() throws {
        var settled = transaction("payments auth-bug docs + infra(G) | release ci")
        try settling("auth-bug", in: &settled)
        XCTAssertEqual(sidebar(settled), "payments _ docs + infra(G) | release ci", "Settle")
        assertWrittenInOrder(settled)

        var forgotten = transaction("payments auth-bug docs + ~scratch(G) | release")
        try forgotten.forget(["payments"])
        XCTAssertEqual(sidebar(forgotten), "_ auth-bug docs + ~scratch(G) | release", "Forget")

        var pinned = transaction("📌notes payments auth-bug docs + | release")
        try pinned.pin("docs", true)
        XCTAssertEqual(sidebar(pinned), "📌notes 📌docs payments auth-bug _ + | release", "Pin")

        var two = transaction("payments auth-bug docs + | release")
        try settling("payments", in: &two)
        try settling("docs", in: &two)
        XCTAssertEqual(sidebar(two), "_ auth-bug _ + | release", "each place stays open")
    }

    func testAGuestThatLeavesLeavesNoOpenPlace() throws {
        var settled = transaction("payments auth-bug docs + infra(G) ~scratch(G) | release")
        try settling("infra", in: &settled)
        XCTAssertEqual(sidebar(settled), "payments auth-bug docs + ~scratch(G) | release", "Settle of a Guest")

        var ended = transaction("payments auth-bug docs + ~scratch(G) | release")
        ended.takeOffBoard("scratch")
        XCTAssertEqual(sidebar(ended), "payments auth-bug docs + | release", "a Board Session in the Guests that ends")
        XCTAssertEqual(ended.boardSessions, [], "its row goes")

        var pinned = transaction("payments auth-bug docs + infra(G) | release")
        try pinned.pin("infra", true)
        XCTAssertEqual(sidebar(pinned), "📌infra payments auth-bug docs + | release", "Pin ends the mark")
    }

    func testAnOpenPlaceIsWrittenWithTheRecordsAndSurvivesARead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
        let store = TopicStore(paths: paths, inPlay: limit)
        for (order, id) in ["payments", "auth-bug", "docs", "release"].enumerated() {
            var record = TopicRecord(id: id, title: id)
            record.order = Double(order)
            try store.write { try $0.create(record); try $0.apply(.bench, to: .topic(id)) }
        }
        try store.write { transaction in
            let before = transaction.records.first { $0.id == "auth-bug" }!
            var after = before
            after.settledAt = "2026-10-30T00:00:00Z"
            try transaction.apply(TopicRecordChange(before: before, after: after))
        }
        let read = try store.read()
        let cut = TopicOrder.cut(BoardCard.all(records: read.records, openPlaces: read.openPlaces), inPlay: limit)
        XCTAssertEqual(cut.places.map(\.slot), [.regular, .openPlace, .regular], "a new read shows the Open Place")
        XCTAssertEqual(cut.bench.map(\.id), [.topic("release")])

        try store.write { try $0.fillOpenPlace(read.openPlaces[0].id, with: .topic("release"), inPlay: limit) }
        XCTAssertEqual(try store.read().openPlaces, [], "a filled Open Place closes")
        XCTAssertEqual(try paths.storedOpenPlaces(), [])
    }

    func testABoardSessionKeepsItsSectionThroughARead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TopicStore(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent"), inPlay: limit)
        try store.write { $0.addToBoard(BoardSession(id: "scratch", order: 0, isGuest: false)) }
        XCTAssertEqual(try store.read().boardSessions.map(\.isGuest), [true], "Make a Guest of a Session makes a Guest")
        try store.write { try $0.apply(.takePlace, to: .session("scratch")) }
        XCTAssertEqual(try store.read().boardSessions.map(\.isGuest), [false], "the guest column keeps its place")
        try store.write { try $0.apply(.toGuests, to: .session("scratch")) }
        XCTAssertEqual(try store.read().boardSessions.map(\.isGuest), [true])
        XCTAssertEqual(try store.read().openPlaces.count, 1, "it left an Open Place")
    }

    func testAnOpenPlaceClosesPastTheLastPlace() throws {
        var fewer = transaction("payments _ docs _ release", inPlay: 2)
        XCTAssertEqual(sidebar(fewer, inPlay: 2), "payments _ + | docs release")
        try fewer.move(.topic("release"), to: .before(.topic("docs")))
        XCTAssertEqual(fewer.openPlaces.count, 1, "the Open Place past the last place closes at the next write")
    }

    func testFillAnOpenPlaceWithAGuestOrABenchedTopic() throws {
        var guest = transaction("payments _ docs + infra(G) ~scratch(G) | release")
        let place = guest.openPlaces[0].id
        try guest.fillOpenPlace(place, with: .topic("infra"), inPlay: limit)
        XCTAssertEqual(sidebar(guest), "payments infra docs + ~scratch(G) | release", "the Guest loses its mark")
        XCTAssertEqual(guest.openPlaces, [])

        var benched = transaction("payments _ docs + infra(G) | release ci")
        try benched.fillOpenPlace(benched.openPlaces[0].id, with: .topic("ci"), inPlay: limit)
        XCTAssertEqual(sidebar(benched), "payments ci docs + infra(G) | release")

        var session = transaction("payments _ docs + ~scratch(G) | release")
        try session.fillOpenPlace(session.openPlaces[0].id, with: .session("scratch"), inPlay: limit)
        XCTAssertEqual(sidebar(session), "payments ~scratch docs + | release", "a Board Session fills a place as a Topic does")
        var inPlay = transaction("payments _ docs + | release")
        XCTAssertThrowsError(try inPlay.fillOpenPlace(inPlay.openPlaces[0].id, with: .topic("docs"), inPlay: limit))
    }

    func testBenchTopicLeavesAnOpenPlaceForAPlaceAndNoneForAGuest() throws {
        var place = transaction("payments auth-bug docs + infra(G) | release")
        try place.bench(.topic("auth-bug"), inPlay: limit)
        XCTAssertEqual(sidebar(place), "payments _ docs + infra(G) | auth-bug release", "it keeps its Sessions; its place is open")
        assertWrittenInOrder(place)

        var guest = transaction("payments auth-bug docs + infra(G) ~scratch(G) | release")
        try guest.bench(.topic("infra"), inPlay: limit)
        XCTAssertEqual(sidebar(guest), "payments auth-bug docs + ~scratch(G) | infra release", "as Bench of a Guest Session")

        var benched = transaction("payments auth-bug docs + | release")
        XCTAssertThrowsError(try benched.bench(.topic("release"), inPlay: limit), "a Benched Topic is not In Play")
        var pinned = transaction("📌notes payments + | release")
        XCTAssertThrowsError(try pinned.bench(.topic("notes"), inPlay: limit), "a Pinned Topic is not In Play")
    }

    func testATradeAcrossTheGuestsLineMovesTheMarkToTheCardThatLeaves() throws {
        var guest = transaction("payments auth-bug docs + infra(G) ci(G) | release")
        try guest.trade(.topic("infra"), with: .topic("auth-bug"))
        XCTAssertEqual(sidebar(guest), "payments infra docs + auth-bug(G) ci(G) | release", "no other card moves")
        assertWrittenInOrder(guest)

        var open = transaction("payments _ docs + infra(G) | release")
        try open.trade(.topic("infra"), with: open.openPlaces.map { .openPlace($0.id) }[0])
        XCTAssertEqual(sidebar(open), "payments infra docs + | release", "a Guest dropped on an Open Place fills it")

        var into = transaction("payments auth-bug docs + ~scratch(G) | release")
        try into.trade(.session("scratch"), with: .topic("docs"))
        XCTAssertEqual(sidebar(into), "payments auth-bug ~scratch + docs(G) | release", "a Board Session takes the place")
        try into.trade(.topic("docs"), with: .session("scratch"))
        XCTAssertEqual(sidebar(into), "payments auth-bug docs + ~scratch(G) | release", "and gives it back")
    }

    func testATradeAcrossTheBenchLineKeepsWorking() throws {
        var place = transaction("payments auth-bug docs + infra(G) | release ci")
        try place.trade(.topic("auth-bug"), with: .topic("ci"))
        XCTAssertEqual(sidebar(place), "payments ci docs + infra(G) | release auth-bug")

        var guest = transaction("payments auth-bug docs + infra(G) | release ci")
        try guest.trade(.topic("infra"), with: .topic("release"))
        XCTAssertEqual(sidebar(guest), "payments auth-bug docs + release(G) | infra ci", "the card that comes into the Guests is a Guest")

        var session = transaction("payments auth-bug docs + ~scratch(G) | release ci")
        try session.trade(.session("scratch"), with: .topic("release"))
        XCTAssertEqual(sidebar(session), "payments auth-bug docs + release(G) | ci", "the Bench holds only Topics")
        XCTAssertEqual(session.boardSessions, [], "the Board Session leaves the Board")

        var placed = transaction("payments ~scratch docs + | release ci")
        try placed.trade(.session("scratch"), with: .topic("release"))
        XCTAssertEqual(sidebar(placed), "payments release docs + | ci", "the Topic takes the place, and no Open Place is left")
        XCTAssertEqual(placed.boardSessions, [])
        XCTAssertEqual(placed.openPlaces, [])

        var open = transaction("payments _ docs + | release ci")
        try open.trade(.topic("ci"), with: open.openPlaces.map { .openPlace($0.id) }[0])
        XCTAssertEqual(sidebar(open), "payments ci docs + | release", "a Benched card dropped on an Open Place fills it")
    }

    /// The outcomes of Move Up and Move Down that only a step has (`TopicCards.step`), applied to the list.
    func testAStepAppliesItsOutcome() throws {
        let cases: [(sidebar: String, card: String, outcome: TopicCards.Outcome, after: String)] = [
            ("payments auth-bug docs + | release", "payments", .reorder(.after(.topic("auth-bug"))), "auth-bug payments docs + | release"),
            ("payments auth-bug docs + infra(G) | release", "docs", .toGuests, "payments auth-bug _ + docs(G) infra(G) | release"),
            ("payments auth-bug docs + infra(G) | release", "infra", .trade(.topic("docs")), "payments auth-bug infra + docs(G) | release"),
            ("payments auth-bug + infra(G) |", "infra", .takePlace, "payments auth-bug infra + |"),
            ("payments auth-bug ~scratch + infra(G) | release", "~scratch", .toGuests, "payments auth-bug _ + ~scratch(G) infra(G) | release"),
            ("payments _ docs + ~scratch(G) | release", "~scratch", .fill(openPlace: "open"), "payments ~scratch docs + | release"),
            ("payments auth-bug docs + ~scratch(G) | release", "~scratch", .trade(.topic("docs")), "payments auth-bug ~scratch + docs(G) | release"),
            ("payments auth-bug + ~scratch(G) |", "~scratch", .takePlace, "payments auth-bug ~scratch + |"),
            ("payments auth-bug docs + infra(G) ~scratch(G) | release", "~scratch", .bench, "payments auth-bug docs + infra(G) | release"),
        ]
        for (start, card, outcome, after) in cases {
            var list = transaction(start)
            if case .fill = outcome, let open = list.openPlaces.first {
                list.openPlaces = [OpenPlace(id: "open", order: open.order)]
            }
            try list.apply(outcome, to: card.hasPrefix("~") ? .session(String(card.dropFirst())) : .topic(card))
            XCTAssertEqual(sidebar(list), after, "\(outcome) of \(card) in \(start)")
            assertWrittenInOrder(list)
        }
    }

    func testADragInsideASectionReordersAndTheMarkStaysOnItsCard() throws {
        var guests = transaction("payments auth-bug docs + infra(G) ci(G) | release")
        try guests.move(.topic("ci"), to: .before(.topic("infra")))
        XCTAssertEqual(sidebar(guests), "payments auth-bug docs + ci(G) infra(G) | release")

        var places = transaction("payments _ docs + infra(G) | release")
        try places.move(.topic("docs"), to: .before(.topic("payments")))
        XCTAssertEqual(sidebar(places), "docs payments _ + infra(G) | release", "an Open Place keeps its slot among the places")
    }

    func testReplaceFromBenchOnAGuestGivesTheMarkToTheCardThatComesIn() throws {
        var e = transaction("payments auth-bug docs + infra(G) | release ci")
        try e.replaceFromBench(.topic("infra"), with: .topic("ci"), inPlay: limit)
        XCTAssertEqual(sidebar(e), "payments auth-bug docs + ci(G) | release infra")

        var place = transaction("payments auth-bug docs + infra(G) | release ci")
        try place.replaceFromBench(.topic("docs"), with: .topic("release"), inPlay: limit)
        XCTAssertEqual(sidebar(place), "payments auth-bug release + infra(G) | ci docs")

        var session = transaction("payments ~scratch docs + ~tmp(G) | release ci")
        try session.replaceFromBench(.session("scratch"), with: .topic("ci"), inPlay: limit)
        try session.replaceFromBench(.session("tmp"), with: .topic("release"), inPlay: limit)
        XCTAssertEqual(sidebar(session), "payments ci docs + release(G) |", "a replaced Board Session leaves the Board")
        XCTAssertEqual(session.boardSessions, [])
    }

    func testANewTopicFromABoardSessionTakesItsPlaceAndItsSection() throws {
        var j = transaction("payments auth-bug docs + ~scratch(G) | release")
        try j.create(TopicRecord(id: "scratch-fix", title: "scratch-fix"), replacingSession: "scratch")
        XCTAssertEqual(sidebar(j), "payments auth-bug docs + scratch-fix(G) | release")
        XCTAssertEqual(j.boardSessions, [], "the Topic takes the card off the Board")

        var placed = transaction("payments ~scratch docs + infra(G) | release")
        try placed.create(TopicRecord(id: "scratch-fix", title: "scratch-fix"), replacingSession: "scratch")
        XCTAssertEqual(sidebar(placed), "payments scratch-fix docs + infra(G) | release", "from a place, the Topic takes the place")
        XCTAssertEqual(placed.openPlaces, [], "and leaves no Open Place")

        var none = transaction("payments auth-bug docs + ~scratch(G) | release")
        try none.create(TopicRecord(id: "new", title: "new"), replacingSession: "gone")
        XCTAssertEqual(sidebar(none), "payments auth-bug docs + ~scratch(G) new(G) | release", "a Topic from no card goes where a new Topic goes")
    }

    func testABoardSessionThatLeavesAPlaceLeavesOneOpenPlace() throws {
        var benched = transaction("payments ~scratch docs + infra(G) | release")
        try benched.bench(.session("scratch"), inPlay: limit)
        XCTAssertEqual(sidebar(benched), "payments _ docs + infra(G) | release", "Bench takes it off the Board, not to the Bench")
        XCTAssertEqual(benched.boardSessions, [])
        XCTAssertEqual(benched.openPlaces.count, 1)
        assertWrittenInOrder(benched)

        var ended = transaction("payments ~scratch docs + infra(G) | release")
        ended.takeOffBoard("scratch")
        XCTAssertEqual(sidebar(ended), "payments _ docs + infra(G) | release", "its Session went into a Topic or ended")

        var moved = transaction("payments ~scratch docs + | release")
        let before = moved.records.first { $0.id == "docs" }!
        try moved.apply(TopicRecordChange(before: before, after: before), endingSession: "scratch")
        XCTAssertEqual(sidebar(moved), "payments _ docs + | release", "its Session moved into an open Topic")
    }

    func testABoardSessionIsNeverOnTheBench() throws {
        let fewer = transaction("payments docs ~scratch + infra(G) | release", inPlay: 2)
        XCTAssertEqual(sidebar(fewer, inPlay: 2), "payments docs + ~scratch infra(G) | release",
                       "past the last place, after a smaller in_play, it is among the Guests")

        var pushed = transaction("payments docs ~scratch + | release")
        try pushed.move(.topic("release"), to: .before(.topic("payments")))
        XCTAssertEqual(sidebar(pushed), "release payments docs + ~scratch |", "a drag across the Bench line does not bench it")
    }

    func testANewTopicIsTheLastGuestAndLeavesAnOpenPlaceOpen() throws {
        var full = transaction("payments _ docs + infra(G) | release")
        try full.create(TopicRecord(id: "new", title: "new"))
        XCTAssertEqual(sidebar(full), "payments _ docs + infra(G) new(G) | release")

        var short = transaction("payments + infra(G) |")
        try short.create(TopicRecord(id: "new", title: "new"))
        XCTAssertEqual(sidebar(short), "payments + infra(G) new(G) |", "with a free place, it is still a Guest")
    }

    func testChooseInPlayFillsThePlacesFromTheCheckedCardsAndGuests() throws {
        let start = "payments auth-bug docs + infra(G) ~scratch(G) | release ci"
        var same = transaction(start)
        try same.chooseInPlay([.topic("payments"), .topic("auth-bug"), .topic("docs")], inPlay: limit)
        XCTAssertEqual(sidebar(same), start)

        var guest = transaction(start)
        try guest.chooseInPlay([.topic("infra"), .topic("payments"), .topic("release"), .topic("docs")], inPlay: limit)
        XCTAssertEqual(sidebar(guest), "infra payments release + ~scratch(G) | docs auth-bug ci",
                       "a chosen Guest loses its mark; a checked card not chosen leads the Bench; an unchecked card goes to the Bench")
        assertWrittenInOrder(guest)

        var kept = transaction("payments auth-bug docs + infra(G) ci(G) | release")
        try kept.chooseInPlay([.topic("payments"), .topic("auth-bug"), .topic("release"), .topic("infra")], inPlay: limit)
        XCTAssertEqual(sidebar(kept), "payments auth-bug release + infra(G) ci(G) | docs", "a Guest not chosen stays a Guest")

        var few = transaction(start)
        try few.chooseInPlay([.topic("docs")], inPlay: limit)
        XCTAssertEqual(sidebar(few), "docs _ _ + infra(G) ~scratch(G) | payments auth-bug release ci",
                       "the places that no checked card fills are Open Places")

        var refill = transaction("payments _ docs + infra(G) | release")
        try refill.chooseInPlay([.topic("payments"), .topic("release"), .topic("docs")], inPlay: limit)
        XCTAssertEqual(sidebar(refill), "payments release docs + infra(G) |")
        XCTAssertEqual(refill.openPlaces, [], "the old Open Place closes")

        var session = transaction(start)
        try session.chooseInPlay([.session("scratch")], inPlay: limit)
        XCTAssertEqual(sidebar(session), "~scratch _ _ + infra(G) | payments auth-bug docs release ci", "a Board Session takes a place")

        var unchecked = transaction("payments ~scratch docs + ~tmp(G) | release")
        try unchecked.chooseInPlay([.topic("payments"), .topic("docs"), .topic("release")], inPlay: limit)
        XCTAssertEqual(sidebar(unchecked), "payments docs release + ~tmp(G) |",
                       "a Board Session that held a place and gets none leaves the Board; a Guest stays")
        XCTAssertEqual(unchecked.boardSessions.map(\.id), ["tmp"])

        var late = transaction("payments ~scratch docs + | release")
        try late.chooseInPlay([.topic("payments"), .topic("docs"), .topic("release"), .session("scratch")], inPlay: limit)
        XCTAssertEqual(sidebar(late), "payments docs release + |", "chosen past the places, it does not lead the Bench")
    }

    func testTheGatherPutsEachLockThatWasAmongTheTopicsInTheGuests() throws {
        var s1 = transaction("payments 🔒scratch auth-bug docs infra 🔒tmp")
        XCTAssertFalse(TopicOrder.isInSections(s1.entries, inPlay: limit))
        s1.gatherGuests(inPlay: limit)
        XCTAssertEqual(sidebar(s1), "payments auth-bug docs + ~scratch(G) ~tmp(G) | infra")
        assertWrittenInOrder(s1)
        let gathered = s1.entries
        s1.gatherGuests(inPlay: limit)
        XCTAssertEqual(s1.entries, gathered, "a second gather changes nothing")

        var moved = transaction("payments auth-bug docs + ~scratch(G) | infra release")
        try moved.move(.topic("release"), to: .before(.topic("infra")))
        XCTAssertTrue(TopicOrder.isInSections(moved.entries, inPlay: limit))
        let before = moved.entries
        moved.gatherGuests(inPlay: limit)
        XCTAssertEqual(moved.entries, before, "a list in its sections is not numbered again")
    }
}
