import XCTest
@testable import MuxifyCore

/// The cases of the Guest design (ADR 0061), with `topics.in_play` 3. A Sidebar is written as its cards in order:
/// `📌name` is Pinned, `name(G)` is a Guest Topic, `~name(G)` is a Guest Session, `🔒name` is a Locked Session without
/// `in_play`, and `|` is the Bench line.
final class GuestTests: XCTestCase {
    private let limit = 3

    /// The transaction for `sidebar`, with each card in the order that it has there.
    private func transaction(_ sidebar: String, inPlay: Int? = 3) -> TopicTransaction {
        var records: [TopicRecord] = [], locks: [SessionLock] = []
        for (order, card) in sidebar.split(separator: " ").filter({ $0 != "|" }).enumerated() {
            var name = String(card)
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
        return transaction
    }

    private func entries(_ transaction: TopicTransaction) -> [TopicListEntry] {
        transaction.records.map(TopicListEntry.topic) + transaction.locks.map(TopicListEntry.lock)
    }

    private func sidebar(_ transaction: TopicTransaction, inPlay: Int? = 3) -> String {
        let all = entries(transaction)
        let pinned = TopicOrder.sorted(all).filter(\.isPinned).map { "📌" + name($0, inPlay: inPlay) }
        guard let inPlay else { return (pinned + TopicOrder.sorted(all).filter { !$0.isPinned }.map { name($0, inPlay: nil) }).joined(separator: " ") }
        let cut = TopicOrder.cut(all, inPlay: inPlay)
        return (pinned + cut.inPlay.map { name($0, inPlay: inPlay) } + ["|"] + cut.bench.map { name($0, inPlay: inPlay) })
            .joined(separator: " ")
    }

    private func name(_ entry: TopicListEntry, inPlay: Int?) -> String {
        switch entry {
        case .topic(let record): return record.id + (inPlay != nil && entry.isGuest ? "(G)" : "")
        case .lock(let lock): return (inPlay != nil ? "~" : "🔒") + lock.sessionID + (inPlay != nil ? "(G)" : "")
        }
    }

    private func settling(_ id: String, in transaction: inout TopicTransaction) throws {
        let before = transaction.records.first { $0.id == id }!
        var after = before
        after.settledAt = "2026-10-30T00:00:00Z"
        try transaction.apply(TopicRecordChange(before: before, after: after))
    }

    func testMakeAGuestPutsTheCardAtTheEndOfInPlayAndSendsNoCardToTheBench() throws {
        var a = transaction("📌notes payments auth-bug docs | infra release")
        try a.makeGuest("infra", inPlay: limit)
        XCTAssertEqual(sidebar(a), "📌notes payments auth-bug docs infra(G) | release", "A")

        var b = transaction("payments auth-bug docs | infra")
        XCTAssertEqual(b.lock("scratch").map(\.sessionID), ["scratch"])
        XCTAssertEqual(sidebar(b), "payments auth-bug docs ~scratch(G) | infra", "B: with in_play, a Lock is a Guest")

        var n = transaction("payments auth-bug docs | infra")
        try n.makeGuest("infra", inPlay: limit)
        XCTAssertEqual(sidebar(n), "payments auth-bug docs infra(G) |", "N")

        var inPlay = transaction("payments auth-bug docs | infra")
        XCTAssertThrowsError(try inPlay.makeGuest("docs", inPlay: limit), "a card In Play cannot be made a Guest")
    }

    func testATradeAcrossTheLineGivesTheGuestMarkToTheCardThatComesIn() throws {
        var c = transaction("payments auth-bug docs infra(G) | release ci")
        try c.trade(.topic("infra"), with: .topic("release"))
        XCTAssertEqual(sidebar(c), "payments auth-bug docs release(G) | infra ci", "C")

        var c2 = transaction("payments auth-bug docs ~scratch(G) | release ci")
        let ended = try c2.trade(.lock(sessionID: "scratch"), with: .topic("release"))
        XCTAssertEqual(sidebar(c2), "payments auth-bug docs release(G) | ci", "C2 and S3: the Session cannot wait on the Bench")
        XCTAssertTrue(ended.contains(.end(sessionID: "scratch")))

        var m = transaction("payments auth-bug docs infra(G) ~scratch(G) | release")
        try m.trade(.topic("auth-bug"), with: .topic("release"))
        XCTAssertEqual(sidebar(m), "payments release docs infra(G) ~scratch(G) | auth-bug", "M: a regular trade does not touch the Guests")
    }

    func testADragInInPlayReordersAndTheMarkStaysOnItsCard() throws {
        var d = transaction("payments auth-bug docs infra(G) | release")
        try d.move(.topic("infra"), to: .before(.topic("payments")))
        XCTAssertEqual(sidebar(d), "infra(G) payments auth-bug docs | release", "D")
    }

    func testReplaceFromBenchOnAGuestGivesTheMarkToTheCardThatComesIn() throws {
        var e = transaction("payments auth-bug docs infra(G) | release ci")
        try e.replaceFromBench(.topic("infra"), with: .topic("ci"), inPlay: limit)
        XCTAssertEqual(sidebar(e), "payments auth-bug docs ci(G) | release infra", "E")
    }

    func testAGuestThatLeavesMakesInPlayShorterAndNoBenchedCardMovesUp() throws {
        var f = transaction("payments auth-bug docs infra(G) | release")
        try settling("infra", in: &f)
        XCTAssertEqual(sidebar(f), "payments auth-bug docs | release", "F")

        var h = transaction("payments auth-bug docs infra(G) | release")
        try h.endGuest("infra", inPlay: limit)
        XCTAssertEqual(sidebar(h), "payments auth-bug docs | infra release", "H: End Guest puts it at the top of the Bench")

        var h2 = transaction("payments auth-bug docs ~scratch(G) | release")
        XCTAssertEqual(h2.unlock("scratch"), [.end(sessionID: "scratch")])
        XCTAssertEqual(sidebar(h2), "payments auth-bug docs | release", "H2: End Guest of a Session Unlocks it")

        let i = transaction("payments auth-bug docs ~scratch(G) | release")
        var ended = i
        ended.locks = []
        XCTAssertEqual(sidebar(ended), "payments auth-bug docs | release", "I: the mark ends with the Session")

        var k = transaction("📌notes payments auth-bug docs infra(G) | release")
        try k.pin("infra", true)
        XCTAssertEqual(sidebar(k), "📌notes 📌infra payments auth-bug docs | release", "K: Pin ends the mark")
        try k.pin("infra", false)
        XCTAssertEqual(sidebar(k), "📌notes payments auth-bug docs | infra release", "K: Unpin puts it at the top of the Bench")

        var others = transaction("payments infra(G) auth-bug ~scratch(G) docs | release")
        try others.endGuest("infra", inPlay: limit)
        XCTAssertEqual(sidebar(others), "payments auth-bug ~scratch(G) docs | infra release",
                       "the other Guest keeps its position 3")
    }

    func testAGuestKeepsItsPositionWhenARegularCardLeaves() throws {
        var g = transaction("payments auth-bug docs infra(G) | release ci")
        try settling("auth-bug", in: &g)
        XCTAssertEqual(sidebar(g), "payments docs release infra(G) | ci", "G")

        var g2 = transaction("infra(G) payments auth-bug docs | release")
        try settling("payments", in: &g2)
        XCTAssertEqual(sidebar(g2), "infra(G) auth-bug docs release |", "G2")

        var forgotten = transaction("payments auth-bug infra(G) docs ~scratch(G) | release")
        let moved = try forgotten.forget("infra")
        XCTAssertEqual(sidebar(forgotten), "payments auth-bug docs ~scratch(G) | release",
                       "Forget is a leave too: the Guest past the new end of In Play goes to the end")
        XCTAssertEqual(moved, [.set(SessionLock(sessionID: "scratch", order: 3))], "the moved Lock goes to tmux")
    }

    func testANewTopicFromAGuestSessionTakesItsPlaceAndItsMark() throws {
        var j = transaction("payments auth-bug docs ~scratch(G) | release")
        let changes = try j.create(TopicRecord(id: "scratch-fix", title: "scratch-fix"), replacingLockOf: "scratch")
        XCTAssertEqual(sidebar(j), "payments auth-bug docs scratch-fix(G) | release", "J")
        XCTAssertFalse(changes.contains(.end(sessionID: "scratch")), "the plan ends the Lock in tmux")
    }

    func testChooseInPlayLeavesTheGuestsAtTheirPositions() throws {
        let start = "payments auth-bug docs infra(G) ~scratch(G) | release ci"
        var l1 = transaction(start)
        try l1.chooseInPlay([.topic("payments"), .topic("auth-bug"), .topic("docs")], inPlay: limit)
        XCTAssertEqual(sidebar(l1), start, "L1")

        var l2 = transaction("infra(G) payments auth-bug docs | release ci")
        try l2.chooseInPlay([.topic("release"), .topic("payments"), .topic("ci")], inPlay: limit)
        XCTAssertEqual(sidebar(l2), "infra(G) release payments ci | auth-bug docs", "L2: places 1 to 3 are positions 2 to 4")

        var l3 = transaction("payments ~scratch(G) auth-bug infra(G) docs | release")
        try l3.chooseInPlay([.topic("release"), .topic("payments"), .topic("auth-bug")], inPlay: limit)
        XCTAssertEqual(sidebar(l3), "release ~scratch(G) payments infra(G) auth-bug | docs", "L3")

        var s4 = transaction("payments auth-bug docs ~scratch(G) infra(G) | release")
        try s4.chooseInPlay([.topic("payments"), .topic("docs"), .topic("release")], inPlay: limit)
        XCTAssertEqual(sidebar(s4), "payments docs release ~scratch(G) infra(G) | auth-bug", "S4")
        XCTAssertThrowsError(try s4.chooseInPlay([.lock(sessionID: "scratch")], inPlay: limit), "a Guest cannot fill a place")
    }

    func testSettingInPlayMakesEachLockAGuestAtTheEndOfInPlayAndRemovingItKeepsEveryPlace() throws {
        var s1 = transaction("payments 🔒scratch auth-bug docs infra 🔒tmp", inPlay: nil)
        try s1.gatherGuests(inPlay: limit)
        XCTAssertEqual(sidebar(s1), "payments auth-bug docs ~scratch(G) ~tmp(G) | infra", "S1")
        XCTAssertEqual(s1.gatherGuests(inPlay: limit), [], "a second gather changes nothing")

        let s2 = transaction("payments auth-bug docs ~scratch(G) infra(G) | release", inPlay: nil)
        XCTAssertEqual(sidebar(s2, inPlay: nil), "payments auth-bug docs 🔒scratch infra release", "S2")
        XCTAssertTrue(s2.records.first { $0.id == "infra" }!.isGuest, "S2: the mark is kept for the next in_play")
        XCTAssertEqual(sidebar(s2), "payments auth-bug docs ~scratch(G) infra(G) | release", "S2, and back")
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
