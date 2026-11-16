import Foundation

public struct SearchField: Equatable {
    public enum Place: Equatable {
        case title
        /// "topic", "settled", ...; shown in the detail line only when it matched.
        case typeWord
        /// Always in the detail line: a directory in New Topic.
        case detail
        /// Always in the detail line, never matched: a Topic's repo/folder per Session.
        case label
        /// Shown in the detail line only when it matched: a joined Session name.
        case hidden
        /// A Tag, such as "#backend". Only a word that starts with `#` matches it, and such a word matches nothing
        /// else. Always shown, as a chip after the title, so a row shows which Tags its Topic has.
        case tag
    }

    public let text: String
    public let place: Place
    /// The colour of a `.tag` field's chip: its Tag's colour in the Config.
    public var color: MarkColor? = nil

    public init(text: String, place: Place, color: MarkColor? = nil) {
        self.text = text
        self.place = place
        self.color = color
    }

    public static func title(_ text: String) -> SearchField { SearchField(text: text, place: .title) }
    public static func typeWord(_ text: String) -> SearchField { SearchField(text: text, place: .typeWord) }
    public static func detail(_ text: String) -> SearchField { SearchField(text: text, place: .detail) }
    public static func hidden(_ text: String) -> SearchField { SearchField(text: text, place: .hidden) }
    public static func label(_ text: String) -> SearchField { SearchField(text: text, place: .label) }
    public static func tag(_ definition: TagDefinition) -> SearchField {
        SearchField(text: definition.tag.description, place: .tag, color: definition.color)
    }

    /// The chips of a Topic's Tags in the palette. A Tag the Config no longer defines is not listed (ADR 0034).
    public static func tags(_ shown: [ShownTag]) -> [SearchField] { shown.compactMap(\.definition).map(tag) }
}

/// The best field per word, summed over words. Nil when some word matches no field at its minimum score.
public struct FieldsMatch: Equatable {
    public let score: Int
    /// Per field index, the positions of every word whose best field it is.
    public let positions: [Int: [Int]]

    public init(score: Int, positions: [Int: [Int]]) {
        self.score = score
        self.positions = positions
    }

    public static func best(_ query: FuzzyQuery, in fields: [SearchField]) -> FieldsMatch? {
        var score = 0
        var positions: [Int: [Int]] = [:]
        for (word, minimum) in zip(query.words, query.minimumScores) {
            var best: (index: Int, match: FuzzyMatch)?
            let wantsTag = word.hasPrefix("#")
            for (index, field) in fields.enumerated() where field.place != .label && (field.place == .tag) == wantsTag {
                guard let match = FuzzyMatcher.match(word, in: field.text, scheme: .history), match.score >= minimum else { continue }
                if best.map({ match.score > $0.match.score }) ?? true { best = (index, match) }
            }
            guard let best else { return nil }
            score += best.match.score
            positions[best.index, default: []] += best.match.positions
        }
        return FieldsMatch(score: score, positions: positions.mapValues { Array(Set($0)).sorted() })
    }
}

public struct Highlighted: Equatable {
    public let text: String
    /// Character offsets into `text`.
    public let marks: [Int]

    public init(text: String, marks: [Int]) {
        self.text = text
        self.marks = marks
    }

    public static func plain(_ text: String) -> Highlighted { Highlighted(text: text, marks: []) }
}

public enum Pick<Payload: Equatable>: Equatable {
    case available(Payload)
    case blocked(reason: String)

    public var payload: Payload? {
        if case .available(let payload) = self { return payload }
        return nil
    }

    public var reason: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}

public struct PickCandidate<Payload: Equatable> {
    /// The accessibility id suffix, stable across queries.
    public let id: String
    /// `show` keeps or drops the row; the view picks its icon by it.
    public let kind: RowKind
    /// The id of a row that makes this one redundant: while that row is listed, this one is not. A Session Path names
    /// the row of the Session with its launch name, so `show` without that Session's kind lists the path again.
    public var shadowedBy: String? = nil
    public var symbol: String? = nil
    public let title: String
    /// A choice that removes what it cannot bring back, such as All time in Clear Browser History: its title is red.
    public var isDestructive = false
    public var fields: [SearchField] = []
    /// Plain detail text, never matched: "until Mon 9:00", "4 Windows".
    public var note: String? = nil
    /// The right column: "2m", "Reopen · 2d", "Active".
    public var trailing = ""
    /// The Agent mark that the row's Sidebar card shows.
    public var mark: CardMark? = nil
    public var lastVisit: Date? = nil
    /// The Active Topic or the current Session: first after the Pinned rows on an empty query.
    public var isCurrent = false
    /// A Pinned Topic: first on an empty query, in candidate order.
    public var isPinned = false
    /// A SessionPath or Worktree with no Session yet. On a tie it goes after the rows you can go to.
    public var unopened = false
    /// The Session's last activity in tmux, which breaks a tie after the last visit.
    public var activity = 0
    /// A Settled Topic: seldom the place to go, so it goes after an equal match.
    public var isSetAside = false
    public let pick: Pick<Payload>
    /// The text ⌃Y types where the Focus was before the picker opened, as pop's Yank does. A terminal gets it as one shell word.
    public var paste: String? = nil
    /// `.tag` when the title is a Tag, such as "#backend", so only a `#` word matches it.
    public var titlePlace: SearchField.Place = .title

    public init(id: String, kind: RowKind, shadowedBy: String? = nil, symbol: String? = nil, title: String, isDestructive: Bool = false,
                fields: [SearchField] = [], note: String? = nil, trailing: String = "", mark: CardMark? = nil, lastVisit: Date? = nil,
                isCurrent: Bool = false, isPinned: Bool = false, unopened: Bool = false, activity: Int = 0, isSetAside: Bool = false,
                pick: Pick<Payload>, paste: String? = nil, titlePlace: SearchField.Place = .title) {
        self.id = id
        self.kind = kind
        self.shadowedBy = shadowedBy
        self.symbol = symbol
        self.title = title
        self.isDestructive = isDestructive
        self.fields = fields
        self.note = note
        self.trailing = trailing
        self.mark = mark
        self.lastVisit = lastVisit
        self.isCurrent = isCurrent
        self.isPinned = isPinned
        self.unopened = unopened
        self.activity = activity
        self.isSetAside = isSetAside
        self.pick = pick
        self.paste = paste
        self.titlePlace = titlePlace
    }

    /// The title first: on an equal score the field listed first takes the word, so a title hit wins.
    public var searchFields: [SearchField] { [SearchField(text: title, place: titlePlace)] + fields }
}

public struct PickRow<Payload: Equatable>: Identifiable, Equatable {
    public let id: String
    public let kind: RowKind
    public let symbol: String?
    public let title: Highlighted
    public var isDestructive = false
    public let detail: Highlighted
    /// The Tags of the row's Topic, each with the marks of the query.
    public var tags: [RowTag] = []
    public let trailing: String
    public let mark: CardMark?
    public let pick: Pick<Payload>
    public let paste: String?

    public init(id: String, kind: RowKind, symbol: String?, title: Highlighted, isDestructive: Bool = false, detail: Highlighted,
                tags: [RowTag] = [], trailing: String, mark: CardMark?, pick: Pick<Payload>, paste: String?) {
        self.id = id
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.isDestructive = isDestructive
        self.detail = detail
        self.tags = tags
        self.trailing = trailing
        self.mark = mark
        self.pick = pick
        self.paste = paste
    }
}

/// A Tag chip after a row's title.
public struct RowTag: Equatable {
    public let text: Highlighted
    public let color: MarkColor?

    public init(text: Highlighted, color: MarkColor?) {
        self.text = text
        self.color = color
    }
}

public struct PickSection<Payload: Equatable>: Identifiable, Equatable {
    public let id: String
    /// The header; nil draws none.
    public let title: String?
    public let rows: [PickRow<Payload>]

    public init(id: String, title: String?, rows: [PickRow<Payload>]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

public struct PickList<Payload: Equatable>: Equatable {
    /// Never holds an empty section.
    public let sections: [PickSection<Payload>]

    public init(sections: [PickSection<Payload>]) { self.sections = sections }

    public static var empty: PickList { PickList(sections: []) }
    public var rows: [PickRow<Payload>] { sections.flatMap(\.rows) }

    /// The payload of an available row; nil for a blocked or unknown id.
    public func payload(of id: String?) -> Payload? {
        rows.first { $0.id == id }?.pick.payload
    }
}

public enum SectionRule: Equatable {
    /// Fuzzy filter and sort; hidden on an empty query when `showsWhenEmpty` is false.
    case ranked(showsWhenEmpty: Bool)
    /// Never filtered or sorted: the Move form's New Topic row.
    case fixed
}

public struct PickSectionInput<Payload: Equatable> {
    public let id: String
    public var title: String? = nil
    public let rule: SectionRule
    public var candidates: [PickCandidate<Payload>]
    public var currentLast = false
    /// False for a list whose candidate order means something, such as Commands or Tags in Config order.
    public var shorterTitleFirst = true

    public init(id: String, title: String? = nil, rule: SectionRule, candidates: [PickCandidate<Payload>], currentLast: Bool = false,
                shorterTitleFirst: Bool = true) {
        self.id = id
        self.title = title
        self.rule = rule
        self.candidates = candidates
        self.currentLast = currentLast
        self.shorterTitleFirst = shorterTitleFirst
    }

    /// The `topics.tags` Tags, which keep Config order on a tie.
    public static func tags(_ candidates: [PickCandidate<Payload>], showsWhenEmpty: Bool) -> PickSectionInput {
        PickSectionInput(id: "tags", title: "Tags", rule: .ranked(showsWhenEmpty: showsWhenEmpty), candidates: candidates, shorterTitleFirst: false)
    }
}

/// A candidate that matched the query, and where it stood among all candidates.
private struct Ranked<Payload: Equatable> {
    let index: Int
    let candidate: PickCandidate<Payload>
    let match: FieldsMatch
    /// From its section, and only for a query.
    let shorterTitleFirst: Bool

    func precedes(_ other: Ranked, tiebreak: [PaletteTiebreak]) -> Bool {
        if match.score != other.match.score { return match.score > other.match.score }
        for rule in tiebreak {
            if let first = candidate.precedes(other.candidate, by: rule, length: shorterTitleFirst && other.shorterTitleFirst) { return first }
        }
        return index < other.index
    }
}

private extension PickCandidate {
    /// Nil when the rule ties.
    func precedes(_ other: PickCandidate, by rule: PaletteTiebreak, length: Bool) -> Bool? {
        switch rule {
        case .open: isSetAside == other.isSetAside ? nil : other.isSetAside
        case .running: unopened == other.unopened ? nil : other.unopened
        case .visit: lastVisit == other.lastVisit ? nil : (lastVisit ?? .distantPast) > (other.lastVisit ?? .distantPast)
        case .activity: activity == other.activity ? nil : activity > other.activity
        case .length: !length || title.count == other.title.count ? nil : title.count < other.title.count
        }
    }
}

/// The one ranking pipeline: drop the ranked rows whose kind `show` leaves out, then those a listed row shadows; match,
/// drop non-matches, sort by score, then by each `tiebreak` rule in turn (`length` only for a query, in a section that
/// wants it), then candidate order; on an empty query only, Pinned rows go first in candidate order, then current rows.
/// Empty sections drop out. `ranked` merges the sections into one list. A fixed section keeps every row.
public enum FuzzyRanker {
    /// `rules` has no default, so every ranked list is ranked by its own Config rules.
    public static func list<Payload>(_ sections: [PickSectionInput<Payload>], query: FuzzyQuery, rules: PickRules,
                              order: PaletteOrder = .grouped) -> PickList<Payload> {
        let sections = shown(sections, show: rules.show)
        let tiebreak = rules.tiebreak
        var start = 0
        let ranked = sections.map { section in
            defer { start += section.candidates.count }
            return (section: section, matches: matches(section, query: query, start: start, tiebreak: tiebreak))
        }
        switch order {
        case .grouped:
            return PickList(sections: ranked.compactMap { section, matches in
                let rows = ordered(section, matches, query: query)
                return rows.isEmpty ? nil : PickSection(id: section.id, title: section.title, rows: rows)
            })
        case .ranked:
            let rows = query.isEmpty
                ? ranked.flatMap { ordered($0.section, $0.matches, query: query) }
                : ranked.flatMap(\.matches).sorted { $0.precedes($1, tiebreak: tiebreak) }.map { row($0.candidate, match: $0.match) }
                    + ranked.filter { $0.section.rule == .fixed }.flatMap { ordered($0.section, [], query: query) }
            return PickList(sections: rows.isEmpty ? [] : [PickSection(id: "results", title: nil, rows: rows)])
        }
    }

    /// Rows no rule touches, in candidate order: a step's choices, a confirmation.
    public static func fixed<Payload>(_ candidates: [PickCandidate<Payload>]) -> PickList<Payload> {
        list([PickSectionInput(id: "choices", rule: .fixed, candidates: candidates)], query: FuzzyQuery(""), rules: .standard)
    }

    /// Over every ranked section at once, because a row can shadow one in another section.
    private static func shown<Payload>(_ sections: [PickSectionInput<Payload>], show: Set<RowKind>) -> [PickSectionInput<Payload>] {
        let kept = sections.map { section in
            guard section.rule != .fixed else { return section }
            var section = section
            section.candidates.removeAll { !show.contains($0.kind) }
            return section
        }
        let listed = Set(kept.filter { $0.rule != .fixed }.flatMap { $0.candidates.map(\.id) })
        return kept.map { section in
            guard section.rule != .fixed else { return section }
            var section = section
            section.candidates.removeAll { $0.shadowedBy.map(listed.contains) == true }
            return section
        }
    }

    /// A ranked section's matches in rank order; none for a fixed section, or a hidden one on an empty query.
    private static func matches<Payload>(_ section: PickSectionInput<Payload>, query: FuzzyQuery, start: Int,
                                         tiebreak: [PaletteTiebreak]) -> [Ranked<Payload>] {
        guard case .ranked(let showsWhenEmpty) = section.rule, showsWhenEmpty || !query.isEmpty else { return [] }
        let shorterTitleFirst = section.shorterTitleFirst && !query.isEmpty
        return section.candidates.enumerated()
            .compactMap { index, candidate in
                FieldsMatch.best(query, in: candidate.searchFields)
                    .map { Ranked(index: start + index, candidate: candidate, match: $0, shorterTitleFirst: shorterTitleFirst) }
            }
            .sorted { $0.precedes($1, tiebreak: tiebreak) }
    }

    private static func ordered<Payload>(_ section: PickSectionInput<Payload>, _ ranked: [Ranked<Payload>], query: FuzzyQuery) -> [PickRow<Payload>] {
        guard section.rule != .fixed else { return section.candidates.map { row($0, match: nil) } }
        guard query.isEmpty else { return ranked.map { row($0.candidate, match: $0.match) } }
        let pinned = ranked.filter { $0.candidate.isPinned }.sorted { $0.index < $1.index }
        let others = ranked.map(\.candidate).filter { !$0.isPinned }
        let emptyOrder = section.currentLast
            ? others.filter { !$0.isCurrent && !$0.unopened } + others.filter { $0.isCurrent && !$0.unopened } + others.filter(\.unopened)
            : others.filter(\.isCurrent) + others.filter { !$0.isCurrent }
        return (pinned.map(\.candidate) + emptyOrder).map { row($0, match: nil) }
    }

    private static func row<Payload>(_ candidate: PickCandidate<Payload>, match: FieldsMatch?) -> PickRow<Payload> {
        PickRow(id: candidate.id, kind: candidate.kind, symbol: candidate.symbol,
                title: Highlighted(text: candidate.title, marks: match?.positions[0] ?? []), isDestructive: candidate.isDestructive,
                detail: detail(candidate.searchFields, note: candidate.note, match: match),
                tags: tags(candidate.searchFields, match: match),
                trailing: candidate.trailing, mark: candidate.mark,
                pick: candidate.pick, paste: candidate.paste)
    }

    /// The Tag fields after the title, and their marks.
    public static func tags(_ fields: [SearchField], match: FieldsMatch?) -> [RowTag] {
        fields.enumerated().dropFirst().filter { $0.element.place == .tag }.map { index, field in
            RowTag(text: Highlighted(text: field.text, marks: match?.positions[index] ?? []), color: field.color)
        }
    }

    /// The detail line and its marks: what matched, and what always shows.
    public static func detail(_ fields: [SearchField], note: String?, match: FieldsMatch?) -> Highlighted {
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
