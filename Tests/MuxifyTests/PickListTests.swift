import XCTest
import MuxifyCore

final class PickListTests: XCTestCase {
    private func candidate(_ id: String, _ title: String, kind: RowKind = .topic, note: String? = nil, visit: TimeInterval? = nil,
                           current: Bool = false, blocked: String? = nil) -> PickCandidate<String> {
        PickCandidate(id: id, kind: kind, title: title, note: note, lastVisit: visit.map { Date(timeIntervalSince1970: $0) },
                      isCurrent: current, pick: blocked.map { .blocked(reason: $0) } ?? .available(id))
    }

    private func list(_ candidates: [PickCandidate<String>], _ query: String, rule: SectionRule = .ranked(showsWhenEmpty: true),
                       title: String? = nil, currentLast: Bool = false, shorterTitleFirst: Bool = true) -> PickList<String> {
        FuzzyRanker.list([PickSectionInput(id: "s", title: title, rule: rule, candidates: candidates, currentLast: currentLast,
                                           shorterTitleFirst: shorterTitleFirst)], query: FuzzyQuery(query), rules: .standard)
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
        let sett = try XCTUnwrap(FuzzyMatcher.match("sett", in: "Settle GS drops", scheme: .history))
        let gs = try XCTUnwrap(FuzzyMatcher.match("gs", in: "Settle GS drops", scheme: .history))
        XCTAssertEqual(both.score, sett.score + gs.score)
    }

    func testAWordSpreadThinlyOverALongTextDoesNotMatch() {
        let path: [SearchField] = [.title("muxify/unify-app-focus-and-move-its"),
                                   .detail("~/.local/state/muxify/worktrees/muxify/unify-app-focus-and-move-its")]
        XCTAssertNotNil(FuzzyMatcher.match("claude", in: path[1].text), "fzf alone matches it, letter by letter")
        XCTAssertNil(FieldsMatch.best(FuzzyQuery("claude"), in: path))
        XCTAssertNotNil(FieldsMatch.best(FuzzyQuery("mfs"), in: [.title("muxify-focus-something")]), "initials still match")
        XCTAssertNotNil(FieldsMatch.best(FuzzyQuery("ify"), in: [.title("muxify")]), "a part of a word still matches")
        XCTAssertNotNil(FieldsMatch.best(FuzzyQuery("x"), in: [.title("muxify")]), "one letter matches anywhere")
    }

    func testEverySeparatorEarnsTheSameBonus() throws {
        let words: [SearchField] = [.title("fix game")], slashed: [SearchField] = [.title("fix/game")], dashed: [SearchField] = [.title("fix-game")]
        let scores = try [words, slashed, dashed].map { try XCTUnwrap(FieldsMatch.best(FuzzyQuery("game"), in: $0)).score }
        XCTAssertEqual(Set(scores).count, 1, "a Topic title with spaces does not beat a Session name with / or -: \(scores)")
    }

    func testRankingIsScoreThenShorterTitleThenLastVisitThenCandidateOrder() {
        let candidates = [
            candidate("old", "alpha one", visit: 10),
            candidate("never", "alpha two"),
            candidate("new", "alpha three", visit: 20),
            candidate("exact", "alpha"),
            candidate("twin", "alpha 1"),
            candidate("other", "beta"),
        ]
        XCTAssertEqual(list(candidates, "alpha").rows.map(\.id), ["exact", "twin", "old", "never", "new"],
                       "fzf scores a prefix like the exact name, so the shorter title wins, then the visit, then the candidate order")
        XCTAssertEqual(list(candidates, "alpha", shorterTitleFirst: false).rows.map(\.id), ["new", "old", "never", "exact", "twin"],
                       "a section whose candidate order means something skips the length tiebreak")
        XCTAssertEqual(list(candidates, "alpha").rows.first?.title, Highlighted(text: "alpha", marks: [0, 1, 2, 3, 4]))
        XCTAssertEqual(list(candidates, "").rows.map(\.id), ["new", "old", "never", "exact", "twin", "other"],
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
        let candidates = [candidate("other", "alpha bet", visit: 20), first, second, candidate("active", "alpha cur", visit: 5, current: true)]
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

    func testShowListsOnlyItsKindsOfRankedRowsAndEveryFixedRow() {
        let sections = [
            PickSectionInput(id: "ranked", rule: .ranked(showsWhenEmpty: true), candidates: [
                candidate("loose", "alpha loose", kind: .session), candidate("member", "alpha member", kind: .topicSession),
                candidate("topic", "alpha topic"),
            ]),
            PickSectionInput(id: "fixed", rule: .fixed, candidates: [candidate("new", "New Topic", kind: .command)]),
        ]
        let rules = PickRules(show: [.session, .topic])
        for query in ["", "alpha"] {
            XCTAssertEqual(FuzzyRanker.list(sections, query: FuzzyQuery(query), rules: rules).rows.map(\.id), ["loose", "topic", "new"],
                           "a Topic Session is left out, and the fixed row stays though show leaves out command, for \(query.debugDescription)")
        }
        XCTAssertEqual(FuzzyRanker.list(sections, query: FuzzyQuery(""), rules: .standard).rows.map(\.id), ["loose", "member", "topic", "new"],
                       "a list with no rules of its own lists every kind")
    }

    func testAShadowedRowShowsOnlyWhileTheRowThatShadowsItIsLeftOut() {
        var path = candidate("path", "notes", kind: .sessionPath)
        path.shadowedBy = "running"
        let sections = [PickSectionInput(id: "s", rule: .ranked(showsWhenEmpty: true),
                                         candidates: [candidate("running", "notes", kind: .topicSession), path])]
        XCTAssertEqual(FuzzyRanker.list(sections, query: FuzzyQuery("notes"), rules: .standard).rows.map(\.id), ["running"],
                       "a Session Path whose Session is listed is redundant")
        XCTAssertEqual(FuzzyRanker.list(sections, query: FuzzyQuery("notes"), rules: PickRules(show: [.session, .sessionPath])).rows.map(\.id),
                       ["path"], "with its Session's row left out, the path comes back")
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
        let row = list([PickCandidate(id: "t", kind: .snoozed, title: "Fix drops", fields: Array(fields.dropFirst()), note: "until Mon 9:00", pick: .available("t"))], "snoo cap").rows[0]
        XCTAssertEqual(row.detail.marks, [0, 1, 2, 3, 36, 37, 38])
        XCTAssertEqual(row.title, Highlighted(text: "Fix drops", marks: []))
    }
}
