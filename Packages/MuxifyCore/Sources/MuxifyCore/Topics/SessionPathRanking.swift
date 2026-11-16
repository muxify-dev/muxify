import Foundation

extension SessionChoice {
    /// The search fields that let typing the folder name find a row whose title is an alias.
    public var nameFields: [SearchField] { displayName == name ? [] : [.hidden(name)] }
}

extension PickCandidate {
    /// The row of a Session Path or Worktree in a list of Sessions, such as Go to…. The app and the Host CLI both
    /// make it here, so the same folders, query and visits give the same order in both.
    public static func sessionPath(_ choice: SessionChoice, lastVisit: Date?, home: String, shadowedBy: String? = nil,
                                   pick: Pick<Payload>) -> PickCandidate {
        PickCandidate(
            id: "session-path:\(choice.directory.path)", kind: choice.isWorktree ? .worktree : .sessionPath, shadowedBy: shadowedBy,
            symbol: "□", title: choice.displayName,
            fields: [.typeWord(choice.isWorktree ? "worktree" : "session"), .detail(Paths.tildify(choice.directory.path, home: home))] + choice.nameFields,
            trailing: "↩ open", lastVisit: lastVisit, unopened: true, pick: pick, paste: choice.directory.path)
    }
}

/// A Session Path or Worktree row, with the last visit to its folder on this machine.
public struct RankedSessionPath: Equatable, Sendable {
    public let row: SessionPathRow
    public let lastVisit: Date?
}

public enum SessionPathRanking {
    /// `rows` in the order Go to… gives them: for a query, the rows that match it, best first, with the `tiebreak`
    /// rules between equal matches; for an empty query, every row, the last visited first, and the rows never
    /// visited after them in the order of `rows`.
    public static func rank(_ rows: [SessionPathRow], query: String, visits: [VisitKey: Date], tiebreak: [PaletteTiebreak],
                            home: String) -> [RankedSessionPath] {
        let ranked = rows.map { RankedSessionPath(row: $0, lastVisit: visits[.directory($0.choice.directory.real)]) }
        let candidates = ranked.enumerated().map { index, row in
            PickCandidate.sessionPath(row.row.choice, lastVisit: row.lastVisit, home: home, pick: .available(index))
        }
        let section = PickSectionInput(id: "sessions", rule: .ranked(showsWhenEmpty: true), candidates: candidates, currentLast: true)
        return FuzzyRanker.list([section], query: FuzzyQuery(query), rules: PickRules(tiebreak: tiebreak))
            .rows.compactMap(\.pick.payload).map { ranked[$0] }
    }
}
