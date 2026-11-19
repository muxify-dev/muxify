import MuxifyCore

/// The rows of the Open Place page: the Topics that can fill an Open Place, the Guest Topics and then the Benched Topics,
/// each in the order of the Topics list. A query hides the rows that do not match and never moves the others, so each
/// Topic stays where the Sidebar has taught the user to find it. A Guest Session has no row: it cannot take a place
/// until it is a Topic.
struct OpenPlaceChoices {
    enum Section: CaseIterable {
        case guests, bench

        var title: String {
            switch self {
            case .guests: "Guests"
            case .bench: "Bench"
            }
        }
    }

    struct Choice: Identifiable {
        let topicID: String
        let section: Section
        let row: TopicsModel.Row
        /// The title, with the marks of the query.
        let title: Highlighted
        /// The Topic Note, with the marks of the query.
        let note: Highlighted?
        /// The names of the Sessions that the query matched, with its marks. None without a query.
        let matchedSessions: [Highlighted]

        var id: String { topicID }
    }

    /// The rows that the query keeps, Guests first.
    let choices: [Choice]
    /// How many Topics can fill the place, before the query hides any.
    let total: Int

    /// `title` gives the title that the row's Sidebar card shows.
    init(_ cut: InPlayCut<TopicsModel.Row>, query: String, title: (TopicsModel.Row) -> String = \.title) {
        let query = FuzzyQuery(query)
        let candidates = [(Section.guests, cut.guests), (.bench, cut.bench)].flatMap { section, rows in
            rows.compactMap { row -> (Section, String, TopicsModel.Row)? in
                guard case .topic(let id) = row.id else { return nil }
                return (section, id, row)
            }
        }
        total = candidates.count
        choices = candidates.compactMap { section, id, row in
            Self.choice(id, section: section, row: row, title: title(row), query: query)
        }
    }

    func choices(in section: Section) -> [Choice] { choices.filter { $0.section == section } }

    /// The row that `id` names while the query keeps it, else the first row.
    func selected(_ id: String?) -> Choice? {
        choices.first { $0.id == id } ?? choices.first
    }

    /// The row `delta` rows from the selected one, round the ends, as the palette moves its selection.
    func moving(from id: String?, by delta: Int) -> Choice? {
        guard !choices.isEmpty else { return nil }
        let current = choices.firstIndex { $0.id == id } ?? 0
        return choices[(current + delta + choices.count) % choices.count]
    }

    /// The fields follow the title in a fixed order, so the marks of each are at a known index: the Note, then each
    /// Session's name, then the Tags.
    private static func choice(_ id: String, section: Section, row: TopicsModel.Row, title: String, query: FuzzyQuery) -> Choice? {
        let note = row.note.flatMap { $0.isEmpty ? nil : $0 }
        let sessions = row.sessions.map(\.baseName)
        let fields = [SearchField.title(title)] + (note.map { [.hidden($0)] } ?? []) + sessions.map(SearchField.hidden)
            + SearchField.tags(row.tags)
        var positions: [Int: [Int]] = [:]
        if !query.isEmpty {
            guard let match = FieldsMatch.best(query, in: fields) else { return nil }
            positions = match.positions
        }
        let noteIndex = 1
        let firstSession = note == nil ? 1 : 2
        let matchedSessions = sessions.enumerated().compactMap { offset, name -> Highlighted? in
            guard let marks = positions[firstSession + offset] else { return nil }
            return Highlighted(text: name, marks: marks)
        }
        return Choice(topicID: id, section: section, row: row, title: Highlighted(text: title, marks: positions[0] ?? []),
                      note: note.map { Highlighted(text: $0, marks: positions[noteIndex] ?? []) },
                      matchedSessions: matchedSessions)
    }
}
