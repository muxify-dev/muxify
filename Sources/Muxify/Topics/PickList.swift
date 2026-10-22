import Foundation
import SwiftUI
import MuxifyCore

struct SearchField: Equatable {
    enum Place: Equatable {
        case title
        /// "topic", "snoozed", ...; shown in the detail line only when it matched.
        case typeWord
        /// Always in the detail line: a Settled Topic's outcome, a directory in New Topic.
        case detail
        /// Always in the detail line, never matched: a Topic's repo/folder per Session.
        case label
        /// Shown in the detail line only when it matched: a joined Session name.
        case hidden
        /// A Tag, such as "#backend". Only a word that starts with `#` matches it, and such a word matches nothing
        /// else. Always shown, as a chip after the title, so a row shows which Tags its Topic has.
        case tag
    }

    let text: String
    let place: Place
    /// The colour of a `.tag` field's chip: its Tag's colour in the Config.
    var color: MarkColor? = nil

    static func title(_ text: String) -> SearchField { SearchField(text: text, place: .title) }
    static func typeWord(_ text: String) -> SearchField { SearchField(text: text, place: .typeWord) }
    static func detail(_ text: String) -> SearchField { SearchField(text: text, place: .detail) }
    static func hidden(_ text: String) -> SearchField { SearchField(text: text, place: .hidden) }
    static func label(_ text: String) -> SearchField { SearchField(text: text, place: .label) }
    static func tag(_ definition: TagDefinition) -> SearchField {
        SearchField(text: definition.tag.description, place: .tag, color: definition.color)
    }

    /// The chips of a Topic's Tags in the palette. A Tag the Config no longer defines is not listed (ADR 0034).
    static func tags(_ shown: [ShownTag]) -> [SearchField] { shown.compactMap(\.definition).map(tag) }
}

/// The best field per word, summed over words. Nil when some word matches no field.
struct FieldsMatch: Equatable {
    let score: Int
    /// Per field index, the positions of every word whose best field it is.
    let positions: [Int: [Int]]

    static func best(_ query: FuzzyQuery, in fields: [SearchField]) -> FieldsMatch? {
        var score = 0
        var positions: [Int: [Int]] = [:]
        for word in query.words {
            var best: (index: Int, match: FuzzyMatch)?
            let wantsTag = word.hasPrefix("#")
            for (index, field) in fields.enumerated() where field.place != .label && (field.place == .tag) == wantsTag {
                guard let match = FuzzyMatcher.match(word, in: field.text) else { continue }
                if best.map({ match.score > $0.match.score }) ?? true { best = (index, match) }
            }
            guard let best else { return nil }
            score += best.match.score
            positions[best.index, default: []] += best.match.positions
        }
        return FieldsMatch(score: score, positions: positions.mapValues { Array(Set($0)).sorted() })
    }
}

struct Highlighted: Equatable {
    let text: String
    /// Character offsets into `text`.
    let marks: [Int]

    static func plain(_ text: String) -> Highlighted { Highlighted(text: text, marks: []) }

    /// The marked characters in bold and the accent color.
    var attributed: AttributedString {
        var attributed = AttributedString(text)
        let count = text.count
        for mark in marks where mark < count {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: mark)
            let end = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].inlinePresentationIntent = .stronglyEmphasized
            attributed[start..<end].foregroundColor = .accentColor
        }
        return attributed
    }
}

enum Pick<Payload: Equatable>: Equatable {
    case available(Payload)
    case blocked(reason: String)

    var payload: Payload? {
        if case .available(let payload) = self { return payload }
        return nil
    }

    var reason: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}

struct PickCandidate<Payload: Equatable> {
    /// The accessibility id suffix, stable across queries.
    let id: String
    var symbol: String? = nil
    let title: String
    var fields: [SearchField] = []
    /// Plain detail text, never matched: "until Mon 9:00", "4 Windows".
    var note: String? = nil
    /// The right column: "2m", "Reopen · 2d", "Active".
    var trailing = ""
    /// The Agent mark that the row's Sidebar card shows.
    var mark: RowMark? = nil
    var lastVisit: Date? = nil
    /// The Active Topic or the current Session: first after the Pinned rows on an empty query.
    var isCurrent = false
    /// A Pinned Topic: first on an empty query, in candidate order.
    var isPinned = false
    /// A SessionPath or Worktree with no Session yet. On a tie it goes after the rows you can go to.
    var unopened = false
    /// The Session's last activity in tmux, which breaks a tie after the last visit.
    var activity = 0
    let pick: Pick<Payload>
    /// The text ⌃Y types where the Focus was before the picker opened, as pop's Yank does. A terminal gets it as one shell word.
    var paste: String? = nil
    /// The id of the Topic that ⌃S Snoozes.
    var snooze: String? = nil
    /// `.tag` when the title is a Tag, such as "#backend", so only a `#` word matches it.
    var titlePlace: SearchField.Place = .title

    /// The title first: on an equal score the field listed first takes the word, so a title hit wins.
    var searchFields: [SearchField] { [SearchField(text: title, place: titlePlace)] + fields }
}

struct PickRow<Payload: Equatable>: Identifiable, Equatable {
    let id: String
    let symbol: String?
    let title: Highlighted
    let detail: Highlighted
    /// The Tags of the row's Topic, each with the marks of the query.
    var tags: [RowTag] = []
    let trailing: String
    let mark: RowMark?
    let pick: Pick<Payload>
    let paste: String?
    let snooze: String?
}

/// A Tag chip after a row's title.
struct RowTag: Equatable {
    let text: Highlighted
    let color: MarkColor?
}

struct PickSection<Payload: Equatable>: Identifiable, Equatable {
    let id: String
    /// The header; nil draws none.
    let title: String?
    let rows: [PickRow<Payload>]
}

struct PickList<Payload: Equatable>: Equatable {
    /// Never holds an empty section.
    let sections: [PickSection<Payload>]

    static var empty: PickList { PickList(sections: []) }
    var rows: [PickRow<Payload>] { sections.flatMap(\.rows) }

    /// The payload of an available row; nil for a blocked or unknown id.
    func payload(of id: String?) -> Payload? {
        rows.first { $0.id == id }?.pick.payload
    }
}

enum SectionRule {
    /// Fuzzy filter and sort; hidden on an empty query when `showsWhenEmpty` is false.
    case ranked(showsWhenEmpty: Bool)
    /// Never filtered or sorted: the Move form's New Topic row.
    case fixed
}

struct PickSectionInput<Payload: Equatable> {
    let id: String
    var title: String? = nil
    let rule: SectionRule
    let candidates: [PickCandidate<Payload>]
    var currentLast = false
}

/// The one ranking pipeline: match, drop non-matches, sort by score, then a row you can go to before an
/// unopened one, then last visit, then activity, then candidate order; on an empty query only, Pinned rows go
/// first in candidate order, then current rows. Empty sections drop out.
enum FuzzyRanker {
    static func list<Payload>(_ sections: [PickSectionInput<Payload>], query: FuzzyQuery) -> PickList<Payload> {
        PickList(sections: sections.compactMap { section in
            let rows: [PickRow<Payload>]
            switch section.rule {
            case .ranked(let showsWhenEmpty):
                guard showsWhenEmpty || !query.isEmpty else { return nil }
                let ranked = section.candidates.enumerated()
                    .compactMap { index, candidate in FieldsMatch.best(query, in: candidate.searchFields).map { (index, candidate, $0) } }
                    .sorted { lhs, rhs in
                        if lhs.2.score != rhs.2.score { return lhs.2.score > rhs.2.score }
                        if lhs.1.unopened != rhs.1.unopened { return rhs.1.unopened }
                        switch (lhs.1.lastVisit, rhs.1.lastVisit) {
                        case (let left?, let right?) where left != right: return left > right
                        case (.some, nil): return true
                        case (nil, .some): return false
                        default:
                            if lhs.1.activity != rhs.1.activity { return lhs.1.activity > rhs.1.activity }
                            return lhs.0 < rhs.0
                        }
                    }
                let pinned = ranked.filter { $0.1.isPinned }.sorted { $0.0 < $1.0 }
                let others = ranked.filter { !$0.1.isPinned }
                let emptyOrder = section.currentLast
                    ? others.filter { !$0.1.isCurrent && !$0.1.unopened } + others.filter { $0.1.isCurrent && !$0.1.unopened } + others.filter { $0.1.unopened }
                    : others.filter { $0.1.isCurrent } + others.filter { !$0.1.isCurrent }
                let shown = query.isEmpty ? pinned + emptyOrder : ranked
                rows = shown.map { row($0.1, match: query.isEmpty ? nil : $0.2) }
            case .fixed:
                rows = section.candidates.map { row($0, match: nil) }
            }
            guard !rows.isEmpty else { return nil }
            return PickSection(id: section.id, title: section.title, rows: rows)
        })
    }

    private static func row<Payload>(_ candidate: PickCandidate<Payload>, match: FieldsMatch?) -> PickRow<Payload> {
        PickRow(id: candidate.id, symbol: candidate.symbol,
                title: Highlighted(text: candidate.title, marks: match?.positions[0] ?? []),
                detail: detail(candidate.searchFields, note: candidate.note, match: match),
                tags: tags(candidate.searchFields, match: match),
                trailing: candidate.trailing, mark: candidate.mark,
                pick: candidate.pick, paste: candidate.paste, snooze: candidate.snooze)
    }

    /// The Tag fields after the title, and their marks.
    static func tags(_ fields: [SearchField], match: FieldsMatch?) -> [RowTag] {
        fields.enumerated().dropFirst().filter { $0.element.place == .tag }.map { index, field in
            RowTag(text: Highlighted(text: field.text, marks: match?.positions[index] ?? []), color: field.color)
        }
    }

    /// The detail line and its marks: what matched, and what always shows.
    static func detail(_ fields: [SearchField], note: String?, match: FieldsMatch?) -> Highlighted {
        var parts: [Highlighted] = []
        func shown(_ place: SearchField.Place, onlyWhenMatched: Bool) {
            // The first field is the title, which the row shows on its own line.
            for (index, field) in fields.enumerated() where index > 0 && field.place == place {
                let marks = match?.positions[index] ?? []
                if onlyWhenMatched, marks.isEmpty { continue }
                parts.append(Highlighted(text: field.text, marks: marks))
            }
        }
        shown(.typeWord, onlyWhenMatched: true)
        shown(.detail, onlyWhenMatched: false)
        shown(.label, onlyWhenMatched: false)
        shown(.hidden, onlyWhenMatched: true)
        if let note, !note.isEmpty { parts.append(.plain(note)) }
        var text = ""
        var marks: [Int] = []
        for part in parts {
            if !text.isEmpty { text += " · " }
            let offset = text.count
            marks += part.marks.map { $0 + offset }
            text += part.text
        }
        return Highlighted(text: text, marks: marks)
    }
}
