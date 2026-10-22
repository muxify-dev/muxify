import Foundation
import MuxifyCore

extension SessionChoice {
    /// The search fields that let typing the folder name find a row whose title is an alias.
    var nameFields: [SearchField] { displayName == name ? [] : [.hidden(name)] }
}

extension SessionPathRows {
    /// One header-less section, ranked by name then directory, then the row's last visit, then Config order.
    static func list(_ rows: [SessionPathRow], query: String, visits: VisitLog) -> PickList<SessionChoice> {
        FuzzyRanker.list([PickSectionInput(id: "sessionPaths", rule: .ranked(showsWhenEmpty: true), candidates: rows.map { row in
            PickCandidate(id: row.id, title: row.choice.displayName, fields: [.detail(row.choice.directory.path)] + row.choice.nameFields,
                          note: row.note, lastVisit: visits.last(.directory(row.choice.directory.real)),
                          pick: .available(row.choice))
        })], query: FuzzyQuery(query))
    }
}
