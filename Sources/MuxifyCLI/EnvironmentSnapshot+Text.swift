import MuxifyCore

extension EnvironmentSnapshot {
    /// The text form of `environment show`: a header for each section that has a line, then one tab-separated line
    /// for each Session or card. An In Play place starts with its place number, which `topic fill-place` takes.
    var text: String {
        let names = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let labels = Dictionary(cards.compactMap { card -> (String, String)? in
            if case .topic(let topic, _, _) = card { return (topic.id, topic.label) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        func line(_ fields: [String]) -> String { fields.map(\.oneLineField).joined(separator: "\t") }
        func line(_ card: Card) -> String {
            switch card {
            case .topic(let topic, let mark, let sessions):
                return line(["topic", topic.id, topic.label, topic.state.rawValue, mark?.rawValue ?? "",
                             topic.tags.map(\.description).joined(separator: " "), sessions.map { names[$0] ?? $0 }.joined(separator: ",")])
            case .session(let session, let mark): return line(["session", session, names[session] ?? session, mark?.rawValue ?? ""])
            case .openPlace(let id): return line(["open place", id])
            }
        }
        var sections: [(header: String, lines: [String])] = [
            ("Sessions", sessions.map { line([$0.id, $0.name, $0.mark?.rawValue ?? "", $0.topic.flatMap { labels[$0] } ?? ""]) }),
            ("Pinned", pinned.map(line)),
        ]
        switch unpinned {
        case .inPlay(let limit, let places, let guests, let bench):
            sections.append(("In Play (\(limit))", places.enumerated().map { "\($0 + 1)\t" + line($1) }))
            sections.append(("Guests", guests.map(line)))
            sections.append(("Bench", bench.map(line)))
        }
        sections.append(("No Topic", noTopic.map { line([$0, names[$0] ?? $0]) }))
        return sections.filter { !$0.lines.isEmpty }.map { ([$0.header] + $0.lines).joined(separator: "\n") + "\n" }.joined()
    }
}
