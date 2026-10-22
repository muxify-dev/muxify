import XCTest

final class PickListTests: XCTestCase {
    private func candidate(_ id: String, _ title: String, note: String? = nil, visit: TimeInterval? = nil,
                           current: Bool = false, blocked: String? = nil) -> PickCandidate<String> {
        PickCandidate(id: id, title: title, note: note, lastVisit: visit.map { Date(timeIntervalSince1970: $0) },
                      isCurrent: current, pick: blocked.map { .blocked(reason: $0) } ?? .available(id))
    }

    private func list(_ candidates: [PickCandidate<String>], _ query: String, rule: SectionRule = .ranked(showsWhenEmpty: true),
                       title: String? = nil, currentLast: Bool = false) -> PickList<String> {
        FuzzyRanker.list([PickSectionInput(id: "s", title: title, rule: rule, candidates: candidates, currentLast: currentLast)], query: FuzzyQuery(query))
    }

    func testEachWordTakesItsBestFieldAndTheTitleWinsATie() throws {
        let fields: [SearchField] = [.title("Settle GS drops"), .typeWord("settled"), .detail("game_server/main"), .hidden("reward cap")]
        let both = try XCTUnwrap(FieldsMatch.best(FuzzyQuery("sett gs"), in: fields))
        XCTAssertEqual(both.positions[0], [0, 1, 2, 3, 7, 8], "both words land on the title: a strong title hit beats the type word")
        let typeWord = try XCTUnwrap(FieldsMatch.best(FuzzyQuery("snoo"), in: [.title("Snooze alarm"), .typeWord("snoozed")]))
        XCTAssertEqual(typeWord.positions.keys.sorted(), [0], "an equal score goes to the field listed first")
        let hidden = try XCTUnwrap(FieldsMatch.best(FuzzyQuery("cap"), in: fields))
        XCTAssertEqual(hidden.positions, [3: [7, 8, 9]])
        XCTAssertNil(FieldsMatch.best(FuzzyQuery("sett zzz"), in: fields), "every word must match some field")
        let sett = try XCTUnwrap(FuzzyMatcher.match("sett", in: "Settle GS drops"))
        let gs = try XCTUnwrap(FuzzyMatcher.match("gs", in: "Settle GS drops"))
        XCTAssertEqual(both.score, sett.score + gs.score)
    }

    func testRankingIsScoreThenLastVisitThenCandidateOrder() {
        let candidates = [
            candidate("old", "alpha one", visit: 10),
            candidate("never", "alpha two"),
            candidate("new", "alpha three", visit: 20),
            candidate("exact", "alpha"),
            candidate("other", "beta"),
        ]
        XCTAssertEqual(list(candidates, "alpha").rows.map(\.id), ["new", "old", "never", "exact"],
                       "fzf scores a prefix like the exact name, so the visit decides, then the candidate order")
        XCTAssertEqual(list(candidates, "alpha").rows.last?.title, Highlighted(text: "alpha", marks: [0, 1, 2, 3, 4]))
        XCTAssertEqual(list(candidates, "").rows.map(\.id), ["new", "old", "never", "exact", "other"],
                       "an empty query lists the newest visit first, then candidate order")
    }

    func testCurrentRowGoesFirstOnlyWhenNothingIsTyped() {
        let candidates = [candidate("other", "alpha beta", visit: 20), candidate("active", "alpha", visit: 10, current: true)]
        XCTAssertEqual(list(candidates, "").rows.map(\.id), ["active", "other"], "the current row leads even when visited earlier")
        XCTAssertEqual(list(candidates, "beta").rows.map(\.id), ["other"])
    }

    func testCurrentUnopenedTopicAppearsOnlyOnceAfterLiveTopics() {
        var empty = candidate("empty", "Empty", visit: 30, current: true)
        empty.unopened = true
        let candidates = [empty, candidate("live", "Live", visit: 10)]
        XCTAssertEqual(list(candidates, "", currentLast: true).rows.map(\.id), ["live", "empty"])
    }

    func testPinnedRowsGoFirstInCandidateOrderOnlyWhenNothingIsTyped() {
        var first = candidate("first-pin", "alpha pin", visit: 10), second = candidate("second-pin", "beta pin", visit: 30)
        first.isPinned = true
        second.isPinned = true
        let candidates = [candidate("other", "alpha beta", visit: 20), first, second, candidate("active", "alpha", visit: 5, current: true)]
        XCTAssertEqual(list(candidates, "").rows.map(\.id), ["first-pin", "second-pin", "active", "other"],
                       "Pinned rows keep candidate order, before the current row")
        XCTAssertEqual(list(candidates, "alpha").rows.map(\.id), ["other", "first-pin", "active"], "a typed query ranks by match, then visit")
    }

    func testSectionsHideOnAnEmptyQueryOrStayFixedAndEmptyOnesDropOut() {
        let hidden = list([candidate("a", "alpha")], "", rule: .ranked(showsWhenEmpty: false), title: "SessionPaths")
        XCTAssertEqual(hidden.sections, [])
        let shown = list([candidate("a", "alpha")], "al", rule: .ranked(showsWhenEmpty: false), title: "SessionPaths")
        XCTAssertEqual(shown.sections.map(\.title), ["SessionPaths"])
        let fixed = list([candidate("new", "New Topic"), candidate("b", "beta", current: true)], "zzz", rule: .fixed)
        XCTAssertEqual(fixed.rows.map(\.id), ["new", "b"], "a fixed section is neither filtered nor sorted")
        XCTAssertEqual(list([candidate("a", "alpha")], "zzz").sections, [])
    }

    func testBlockedRowShowsItsReasonAndHasNoPayload() {
        let rows = list([candidate("taken", "alpha", blocked: "Taken by Fix drops"), candidate("free", "alpha2")], "")
        XCTAssertNil(rows.payload(of: "taken"))
        XCTAssertEqual(rows.payload(of: "free"), "free")
        XCTAssertNil(rows.payload(of: "missing"))
        XCTAssertEqual(rows.rows.first?.pick, .blocked(reason: "Taken by Fix drops"))
    }

    func testDetailShowsMatchedTypeWordThenDetailsThenMatchedHiddenThenNote() {
        let fields: [SearchField] = [.title("Fix drops"), .typeWord("snoozed"), .detail("game_server/main"), .hidden("reward cap")]
        XCTAssertEqual(FuzzyRanker.detail(fields, note: "until Mon 9:00", match: nil),
                       Highlighted(text: "game_server/main · until Mon 9:00", marks: []))
        let match = FieldsMatch.best(FuzzyQuery("snoo cap"), in: fields)
        XCTAssertEqual(FuzzyRanker.detail(fields, note: "until Mon 9:00", match: match),
                       Highlighted(text: "snoozed · game_server/main · reward cap · until Mon 9:00", marks: [0, 1, 2, 3, 36, 37, 38]))
        let row = list([PickCandidate(id: "t", title: "Fix drops", fields: Array(fields.dropFirst()), note: "until Mon 9:00", pick: .available("t"))], "snoo cap").rows[0]
        XCTAssertEqual(row.detail.marks, [0, 1, 2, 3, 36, 37, 38])
        XCTAssertEqual(row.title, Highlighted(text: "Fix drops", marks: []))
    }
}
