import XCTest
@testable import MuxifyCore

final class SessionPathRankingTests: XCTestCase {
    private let paths = [SessionPath(path: "/work/alpha", name: "alpha"), SessionPath(path: "/work/beta", name: "beta"),
                         SessionPath(path: "/work/gamma", name: "gamma"),
                         SessionPath(path: "/work/game", name: "game", layout: .bareRepository([Worktree(path: "/work/game/main", branch: "main"),
                                                                                                Worktree(path: "/trees/game-fix", branch: "fix")]))]
    private var rows: [SessionPathRow] { SessionPathRows.build(sessionPaths: paths, windows: [], records: []) }

    private func names(_ query: String, visits: [VisitKey: Date] = [:], tiebreak: [PaletteTiebreak] = PaletteTiebreak.standard) -> [String] {
        SessionPathRanking.rank(rows, query: query, visits: visits, tiebreak: tiebreak, home: "/home/me").map(\.row.choice.name)
    }

    func testAnEmptyQueryListsEveryRowTheLastVisitedFirstAndTheOthersInConfigOrder() {
        XCTAssertEqual(names(""), rows.map(\.choice.name), "with no visit, the order of the Config")
        let visits: [VisitKey: Date] = [.directory("/work/gamma"): Date(timeIntervalSince1970: 300),
                                        .directory("/work/game/main"): Date(timeIntervalSince1970: 400),
                                        .directory("/work/beta"): Date(timeIntervalSince1970: 200),
                                        .session(name: "alpha"): Date(timeIntervalSince1970: 900)]
        XCTAssertEqual(names("", visits: visits), ["game/main", "gamma", "beta", "alpha", "game/game-fix"],
                       "a Session visit is not a visit to the folder")
        let ranked = SessionPathRanking.rank(rows, query: "", visits: visits, tiebreak: PaletteTiebreak.standard, home: "/home/me")
        XCTAssertEqual(ranked.map(\.lastVisit), [400, 300, 200, nil, nil].map { $0.map(Date.init(timeIntervalSince1970:)) })
    }

    func testAQueryKeepsOnlyTheMatchesBestFirstAndTheLastVisitBreaksATie() {
        XCTAssertEqual(names("xyz"), [])
        XCTAssertEqual(names("gam"), ["gamma", "game/main", "game/game-fix"], "an equal match: the shorter title first")
        XCTAssertEqual(names("gam", tiebreak: [.visit]), ["gamma", "game/main", "game/game-fix"], "with no length rule, Config order")
        XCTAssertEqual(names("gam", visits: [.directory("/trees/game-fix"): Date(timeIntervalSince1970: 5)], tiebreak: [.visit]),
                       ["game/game-fix", "gamma", "game/main"])
        XCTAssertEqual(names("worktree"), ["game/game-fix"], "the type word of a Worktree row matches, as in Go to…")
    }

    func testTheOrderIsTheOrderOfTheGoToCandidatesForTheSameRowsQueryAndVisits() {
        let visits: [VisitKey: Date] = [.directory("/work/beta"): Date(timeIntervalSince1970: 200), .directory("/work/alpha"): Date(timeIntervalSince1970: 100)]
        for query in ["", "a", "ga", "work", "be al"] {
            let candidates = rows.map { PickCandidate.sessionPath($0.choice, lastVisit: visits[.directory($0.choice.directory.real)], home: "/home/me",
                                                                 pick: .available($0.choice.name)) }
            let goTo = FuzzyRanker.list([PickSectionInput(id: "sessions", title: "Sessions", rule: .ranked(showsWhenEmpty: true),
                                                          candidates: candidates, currentLast: true)],
                                        query: FuzzyQuery(query), rules: .standard)
            XCTAssertEqual(names(query, visits: visits), goTo.rows.compactMap(\.pick.payload), "query \(query)")
        }
    }
}
