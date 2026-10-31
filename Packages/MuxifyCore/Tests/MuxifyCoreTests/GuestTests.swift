import XCTest
@testable import MuxifyCore

/// The cases of the In Play design, with `topics.in_play` 3. A Sidebar is written as its cards in order: `📌name` is
/// Pinned, `_` is an Open Place, `name(G)` is a Guest Topic, `~name(G)` is a Guest Session, `🔒name` is a Locked Session
/// without `in_play`, `+` is the Guests line and `|` is the Bench line.
final class GuestTests: XCTestCase {
    private let limit = 3

    /// The transaction for `sidebar`, with each card in the order that it has there.
    private func transaction(_ sidebar: String, inPlay: Int? = 3) -> TopicTransaction {
        var records: [TopicRecord] = [], locks: [SessionLock] = [], places: [OpenPlace] = []
        for (order, card) in sidebar.split(separator: " ").filter({ $0 != "|" && $0 != "+" }).enumerated() {
            var name = String(card)
            if name == "_" {
                places.append(OpenPlace(order: Double(order)))
                continue
            }
            let guest = name.hasSuffix("(G)")
            if guest { name.removeLast(3) }
            if name.hasPrefix("~") || name.hasPrefix("🔒") {
                locks.append(SessionLock(sessionID: String(name.dropFirst()), order: Double(order)))
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
        var transaction = TopicTransaction(records: records, topics: URL(fileURLWithPath: "/nonexistent/topics"), inPlay: inPlay)
        transaction.locks = locks
        transaction.openPlaces = places
        return transaction
    }

    private func sidebar(_ transaction: TopicTransaction, inPlay: Int? = 3) -> String {
        let all = transaction.entries
        let pinned = TopicOrder.sorted(all).filter(\.isPinned).map { "📌" + name($0, inPlay: inPlay) }
        guard let inPlay else {
            return (pinned + TopicOrder.sorted(all).filter { !$0.isPinned }.map { name($0, inPlay: nil) }).joined(separator: " ")
        }
        let cut = TopicOrder.cut(all, inPlay: inPlay)
        let sections = [cut.places, cut.guests, cut.bench].map { $0.map { name($0, inPlay: inPlay) } }
        return (pinned + sections[0] + ["+"] + sections[1] + ["|"] + sections[2]).joined(separator: " ")
    }

    private func name(_ entry: TopicListEntry, inPlay: Int?) -> String {
        switch entry {
        case .topic(let record): return record.id + (inPlay != nil && entry.isGuest ? "(G)" : "")
        case .lock(let lock): return (inPlay != nil ? "~" : "🔒") + lock.sessionID + (inPlay != nil ? "(G)" : "")
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
        try a.makeGuest("infra", inPlay: limit)
        XCTAssertEqual(sidebar(a), "📌notes payments auth-bug docs + scratch(G) infra(G) | release")
        assertWrittenInOrder(a)

        var b = transaction("payments auth-bug docs + infra(G) | release")
        XCTAssertEqual(b.lock("scratch").map(\.sessionID), ["scratch"])
        XCTAssertEqual(sidebar(b), "payments auth-bug docs + infra(G) ~scratch(G) | release", "with in_play, a Lock is a Guest")

        var inPlay = transaction("payments auth-bug docs + | infra")
        XCTAssertThrowsError(try inPlay.makeGuest("docs", inPlay: limit), "a card In Play cannot be made a Guest")
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
        try forgotten.forget("payments")
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

        var unlocked = transaction("payments auth-bug docs + ~scratch(G) | release")
        XCTAssertEqual(unlocked.unlock("scratch"), [.end(sessionID: "scratch")])
        XCTAssertEqual(sidebar(unlocked), "payments auth-bug docs + | release", "End Guest of a Session Unlocks it")

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
            try store.write { try $0.create(record) }
        }
        try store.write { transaction in
            let before = transaction.records.first { $0.id == "auth-bug" }!
            var after = before
            after.settledAt = "2026-10-30T00:00:00Z"
            try transaction.apply(TopicRecordChange(before: before, after: after))
        }
        let read = try store.read()
        let cut = TopicOrder.cut(TopicListEntry.all(records: read.records, windows: [], openPlaces: read.openPlaces), inPlay: limit)
        XCTAssertEqual(cut.places.map(\.slot), [.regular, .openPlace, .regular], "a new read shows the Open Place")
        XCTAssertEqual(cut.bench.map(\.id), [.topic("release")])

        try store.write { try $0.fillOpenPlace(read.openPlaces[0].id, with: "release", inPlay: limit) }
        XCTAssertEqual(try store.read().openPlaces, [], "a filled Open Place closes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.topics.appendingPathComponent(TopicStore.openPlacesFile).path))
    }

    func testAnOpenPlaceClosesWithoutInPlayOrPastTheLastPlace() throws {
        var off = transaction("payments _ docs + | release")
        off = TopicTransaction(records: off.records, topics: URL(fileURLWithPath: "/nonexistent/topics"), inPlay: nil)
        off.openPlaces = transaction("payments _ docs + | release").openPlaces
        try off.move(.topic("docs"), to: .before(.topic("payments")))
        XCTAssertEqual(off.openPlaces, [], "without in_play an Open Place holds no place")

        var fewer = transaction("payments _ docs _ release", inPlay: 2)
        XCTAssertEqual(sidebar(fewer, inPlay: 2), "payments _ + | docs release")
        try fewer.move(.topic("release"), to: .before(.topic("docs")))
        XCTAssertEqual(fewer.openPlaces.count, 1, "the Open Place past the last place closes at the next write")
    }

    func testFillAnOpenPlaceWithAGuestOrABenchedTopic() throws {
        var guest = transaction("payments _ docs + infra(G) ~scratch(G) | release")
        let place = guest.openPlaces[0].id
        try guest.fillOpenPlace(place, with: "infra", inPlay: limit)
        XCTAssertEqual(sidebar(guest), "payments infra docs + ~scratch(G) | release", "the Guest loses its mark")
        XCTAssertEqual(guest.openPlaces, [])

        var benched = transaction("payments _ docs + infra(G) | release ci")
        try benched.fillOpenPlace(benched.openPlaces[0].id, with: "ci", inPlay: limit)
        XCTAssertEqual(sidebar(benched), "payments ci docs + infra(G) | release")

        var session = transaction("payments _ docs + ~scratch(G) | release")
        XCTAssertThrowsError(try session.fillOpenPlace(session.openPlaces[0].id, with: "scratch", inPlay: limit),
                             "a Guest Session is no Topic")
        var inPlay = transaction("payments _ docs + | release")
        XCTAssertThrowsError(try inPlay.fillOpenPlace(inPlay.openPlaces[0].id, with: "docs", inPlay: limit))
    }

    func testBenchTopicLeavesAnOpenPlaceForAPlaceAndNoneForAGuest() throws {
        var place = transaction("payments auth-bug docs + infra(G) | release")
        try place.bench("auth-bug", inPlay: limit)
        XCTAssertEqual(sidebar(place), "payments _ docs + infra(G) | auth-bug release", "it keeps its Sessions; its place is open")
        assertWrittenInOrder(place)

        var guest = transaction("payments auth-bug docs + infra(G) ~scratch(G) | release")
        try guest.bench("infra", inPlay: limit)
        XCTAssertEqual(sidebar(guest), "payments auth-bug docs + ~scratch(G) | infra release", "as End Guest")

        var benched = transaction("payments auth-bug docs + | release")
        XCTAssertThrowsError(try benched.bench("release", inPlay: limit), "a Benched Topic is not In Play")
        var pinned = transaction("📌notes payments + | release")
        XCTAssertThrowsError(try pinned.bench("notes", inPlay: limit), "a Pinned Topic is not In Play")
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
        XCTAssertThrowsError(try into.trade(.lock(sessionID: "scratch"), with: .topic("docs")), "a Guest Session takes no place")
        XCTAssertThrowsError(try into.trade(.topic("docs"), with: .lock(sessionID: "scratch")), "nor the other way")
    }

    func testATradeAcrossTheBenchLineKeepsWorking() throws {
        var place = transaction("payments auth-bug docs + infra(G) | release ci")
        try place.trade(.topic("auth-bug"), with: .topic("ci"))
        XCTAssertEqual(sidebar(place), "payments ci docs + infra(G) | release auth-bug")

        var guest = transaction("payments auth-bug docs + infra(G) | release ci")
        try guest.trade(.topic("infra"), with: .topic("release"))
        XCTAssertEqual(sidebar(guest), "payments auth-bug docs + release(G) | infra ci", "the card that comes into the Guests is a Guest")

        var session = transaction("payments auth-bug docs + ~scratch(G) | release ci")
        let ended = try session.trade(.lock(sessionID: "scratch"), with: .topic("release"))
        XCTAssertEqual(sidebar(session), "payments auth-bug docs + release(G) | ci", "the Session cannot wait on the Bench")
        XCTAssertTrue(ended.contains(.end(sessionID: "scratch")))

        var open = transaction("payments _ docs + | release ci")
        try open.trade(.topic("ci"), with: open.openPlaces.map { .openPlace($0.id) }[0])
        XCTAssertEqual(sidebar(open), "payments ci docs + | release", "a Benched card dropped on an Open Place fills it")
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
    }

    func testANewTopicFromAGuestSessionTakesItsPlaceAndItsMark() throws {
        var j = transaction("payments auth-bug docs + ~scratch(G) | release")
        let changes = try j.create(TopicRecord(id: "scratch-fix", title: "scratch-fix"), replacingLockOf: "scratch")
        XCTAssertEqual(sidebar(j), "payments auth-bug docs + scratch-fix(G) | release")
        XCTAssertFalse(changes.contains(.end(sessionID: "scratch")), "the plan ends the Lock in tmux")
    }

    func testANewTopicGoesToTheTopOfTheBenchAndLeavesAnOpenPlaceOpen() throws {
        var full = transaction("payments _ docs + infra(G) | release")
        try full.create(TopicRecord(id: "new", title: "new"), arrival: .topOfBench(inPlay: limit))
        XCTAssertEqual(sidebar(full), "payments _ docs + infra(G) | new release")

        var short = transaction("payments + infra(G) |")
        try short.create(TopicRecord(id: "new", title: "new"), arrival: .topOfBench(inPlay: limit))
        XCTAssertEqual(sidebar(short), "payments new + infra(G) |", "with a free place, it is In Play")
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
        XCTAssertThrowsError(try session.chooseInPlay([.lock(sessionID: "scratch")], inPlay: limit), "a Guest Session takes no place")
    }

    func testSettingInPlayPutsEachLockInTheGuestsAndRemovingItKeepsEveryPlace() throws {
        var s1 = transaction("payments 🔒scratch auth-bug docs infra 🔒tmp", inPlay: nil)
        s1 = { var t = TopicTransaction(records: s1.records, topics: URL(fileURLWithPath: "/nonexistent/topics"), inPlay: limit)
               t.locks = s1.locks; return t }()
        try s1.gatherGuests(inPlay: limit)
        XCTAssertEqual(sidebar(s1), "payments auth-bug docs + ~scratch(G) ~tmp(G) | infra")
        assertWrittenInOrder(s1)
        XCTAssertEqual(s1.gatherGuests(inPlay: limit), [], "a second gather changes nothing")

        let s2 = transaction("payments auth-bug docs ~scratch(G) infra(G) | release", inPlay: nil)
        XCTAssertEqual(sidebar(s2, inPlay: nil), "payments auth-bug docs 🔒scratch infra release")
        XCTAssertTrue(s2.records.first { $0.id == "infra" }!.isGuest, "the mark is kept for the next in_play")
    }

    func testTheGuestMarkIsInTheTopicRecord() throws {
        var record = TopicRecord(id: "infra", title: "infra")
        record.isGuest = true
        let data = try TopicStore.encoded(record)
        XCTAssertEqual(try JSONDecoder().decode([String: JSONValue].self, from: data)["guest"], .bool(true))
        XCTAssertTrue(try JSONDecoder().decode(TopicRecord.self, from: data).isGuest)
        record.isGuest = false
        XCTAssertNil(try JSONDecoder().decode([String: JSONValue].self, from: TopicStore.encoded(record))["guest"])
    }
}
