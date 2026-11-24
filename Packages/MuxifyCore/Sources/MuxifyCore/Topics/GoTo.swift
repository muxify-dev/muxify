import Foundation

/// What a Go to… row of the topics or the sessions Source leads to. The app maps it to its own row item, and the Host
/// Server sends it as the `target` of a `go_to` row, so a client acts on a row from this value alone.
public enum GoToTarget: Codable, Equatable, Sendable {
    /// An open Topic. Only a live one has a Session to show; a Dormant or Empty one has its Reopen choice or its page.
    case topic(id: String, state: TopicState)
    /// A Settled Topic.
    case settled(id: String)
    /// A Dormant Board Session, by its id: going to it creates its Session again.
    case boardSession(id: String)
    /// A running Session, by its tmux id and its name.
    case session(id: String, name: String)
    /// A Session Path or Worktree with no running Session: going to it starts a Session named `name` in `directory`.
    case sessionPath(directory: String, name: String)
    /// A Tag: not a place, but the filter that lists its Topics. On the wire, its name without the `#`.
    case tag(Tag)

    private enum CodingKeys: String, CodingKey {
        case topic, settled, session, tag
        case boardSession = "board_session"
        case sessionPath = "session_path"
    }

    private enum TagCodingKeys: String, CodingKey { case _0 = "name" }
}

/// Where the user is, for the rows that Go to… marks as current and lists last on an empty query.
public enum GoToLocation: Equatable, Sendable {
    /// The Window that an App Window shows.
    case window(id: String)
    /// The page that an App Window shows in the Terminal's place: a Topic or a Board Session with no live Session.
    case page(TopicGroupID)
    /// The Session that a client without an App Window shows, such as the phone, by its name.
    case session(name: String)
}

/// The Window that going to a Topic or a Session lands on.
public enum EntryWindow {
    /// For a Session: its active Window, else its first.
    public static func ofSession(_ windows: [TmuxWindow]) -> TmuxWindow? {
        windows.first(where: \.isActive) ?? windows.first
    }

    /// The folder that a Session's row shows and copies: where the Session started, else where its entry Window is.
    public static func folder(ofSession windows: [TmuxWindow]) -> String {
        guard let first = windows.first else { return "" }
        return first.sessionPath.isEmpty ? (ofSession(windows) ?? first).path : first.sessionPath
    }
}

/// The rows of Go to…'s topics and sessions Sources, from one read of a machine. The app's Command Palette and the
/// Host Server's `go_to` both build them here, so one state gives one list in both.
public struct GoToInput {
    /// Nil when the topics Source has no rows: Topics are off, or the App Window is not Local.
    public var board: Board?
    /// Every Topic record, for the Settled rows and the kind of a Session's row.
    public var records: [TopicRecord]
    public var windows: [TmuxWindow]
    public var sessionPaths: [SessionPath]
    /// The Agent mark of each Session, by its tmux id.
    public var sessionMarks: [String: AgentMark]
    /// `topics.tags`; nil while Tags are off.
    public var tags: ConfigTags?
    public var visits: [VisitKey: Date]
    public var current: GoToLocation?
    /// The folder that a row's path shows as `~`.
    public var home: String
    public var now: Date

    public init(board: Board?, records: [TopicRecord], windows: [TmuxWindow], sessionPaths: [SessionPath], sessionMarks: [String: AgentMark],
                tags: ConfigTags?, visits: [VisitKey: Date], current: GoToLocation?, home: String, now: Date) {
        self.board = board
        self.records = records
        self.windows = windows
        self.sessionPaths = sessionPaths
        self.sessionMarks = sessionMarks
        self.tags = tags
        self.visits = visits
        self.current = current
        self.home = home
        self.now = now
    }

    /// The Go to… list of `sources`. `others` gives the sections of a Source that is not built here, and `payload`
    /// makes a row's payload from its target. With `tagFilter`, only the Topics that have the Tag: open and Settled.
    public func list<Payload>(_ sources: [PaletteSource], query: String, tagFilter: Tag? = nil, rules: PickRules, order: PaletteOrder,
                              payload: (GoToTarget) -> Payload,
                              others: (PaletteSource) -> [PickSectionInput<Payload>] = { _ in [] }) -> PickList<Payload> {
        let query = FuzzyQuery(query)
        let ranksSetAside = order == .grouped && !query.isEmpty
        let sections = sections(sources, tagFilter: tagFilter, ranksSetAside: ranksSetAside, payload: payload, others: others)
        return FuzzyRanker.list(sections, query: query, rules: rules, order: order)
    }

    /// The rows before any query, in the order of `sources`, then the Settled Topics, which are set aside: last with
    /// an empty query, and after an equal match for a query. With `ranksSetAside`, they join the open Topics' section.
    /// The Tags follow the Topics, for a query only: a Tag is not a place, but a filter that leads to places.
    public func sections<Payload>(_ sources: [PaletteSource], tagFilter: Tag? = nil, ranksSetAside: Bool = false,
                                  payload: (GoToTarget) -> Payload,
                                  others: (PaletteSource) -> [PickSectionInput<Payload>] = { _ in [] }) -> [PickSectionInput<Payload>] {
        if let tagFilter { return topicSections(only: tagFilter, ranksSetAside: ranksSetAside).map { $0.mapPayload(payload) } }
        let laterTopics = sources.contains(.topics) && !ranksSetAside ? settledSections(only: nil) : []
        return sources.flatMap { source -> [PickSectionInput<Payload>] in
            switch source {
            case .topics:
                let topics = ranksSetAside ? topicSections(only: nil, ranksSetAside: true) : openTopicSection(only: nil).map { [$0] } ?? []
                return (topics + (tagSection.map { [$0] } ?? [])).map { $0.mapPayload(payload) }
            case .sessions:
                return [PickSectionInput(id: "sessions", title: "Sessions", rule: .ranked(showsWhenEmpty: true),
                                         candidates: sessionCandidates, currentLast: true).mapPayload(payload)]
            case .windows, .agents, .commands:
                return others(source)
            }
        } + laterTopics.map { $0.mapPayload(payload) }
    }

    // MARK: Topics

    private var activeTopic: TopicGroupID? {
        switch current {
        case .window(let id)?: return windows.first { $0.id == id }.flatMap { board?.group(of: $0) }
        case .session(let name)?: return windows.first { $0.sessionName == name }.flatMap { board?.group(of: $0) }
        case .page(let group)?: return group
        case nil: return nil
        }
    }

    private func topicSections(only tag: Tag?, ranksSetAside: Bool) -> [PickSectionInput<GoToTarget>] {
        let open = openTopicSection(only: tag)
        let later = settledSections(only: tag)
        guard ranksSetAside, var open else { return (open.map { [$0] } ?? []) + later }
        open.candidates += later.flatMap(\.candidates)
        return [open]
    }

    private func openTopicSection(only tag: Tag?) -> PickSectionInput<GoToTarget>? {
        guard let board else { return nil }
        let members = Dictionary(grouping: windows, by: board.group(of:))
        let active = activeTopic
        let cards = board.entries.compactMap(\.card).filter { card in tag.map { tag in card.tags.contains { $0.tag == tag } } ?? true }
        return PickSectionInput(id: "topics", title: "Topics", rule: .ranked(showsWhenEmpty: true),
                                candidates: cards.compactMap { topicCandidate($0, members: members[$0.id] ?? [], isCurrent: active == $0.id) },
                                currentLast: true)
    }

    private var tagSection: PickSectionInput<GoToTarget>? {
        guard board != nil, let definitions = tags?.definitions else { return nil }
        return .tags(definitions.compactMap { definition in
            let count = records.filter { $0.tags.contains(definition.tag) }.count
            guard count > 0 else { return nil }
            return PickCandidate(id: "tag-" + definition.tag.name, kind: .tag, title: definition.tag.description, fields: [.hidden(definition.tag.name)],
                                 trailing: count == 1 ? "1 Topic" : "\(count) Topics",
                                 pick: .available(.tag(definition.tag)), titlePlace: .tag)
        }, showsWhenEmpty: false)
    }

    private func settledSections(only tag: Tag?) -> [PickSectionInput<GoToTarget>] {
        guard let board else { return [] }
        let settled = records.filter { $0.settledAt != nil && (tag.map($0.tags.contains) ?? true) }
            .sorted { ($0.settledAt ?? "", $0.id) > ($1.settledAt ?? "", $1.id) }
            .map { settledCandidate($0, labels: board.labels) }
        return [PickSectionInput(id: "settled", title: "Settled", rule: .ranked(showsWhenEmpty: true), candidates: settled)]
    }

    private func age(_ key: VisitKey) -> String? {
        visits[key].map { VisitAge.short(since: $0, now: now) }
    }

    private func topicCandidate(_ card: Board.Card, members: [TmuxWindow], isCurrent: Bool) -> PickCandidate<GoToTarget>? {
        switch card.subject {
        case .session(let session):
            return dormantSessionCandidate(card, id: session.id)
        case .topic(let record):
            let age = age(.topic(card.id))
            let idle: String? = card.state == .dormant ? "Dormant" : card.state == .empty ? "Empty" : nil
            let trailing = card.sessions.isEmpty ? [card.state == .dormant ? "Reopen" : "Empty", age].compactMap { $0 }.joined(separator: " · ")
                : isCurrent ? "Active" : age ?? ""
            let sessionNames = card.sessions.compactMap { id in members.first { $0.sessionID == id }?.sessionName }
            return PickCandidate(
                id: card.id.accessibilityID, kind: .topic, symbol: card.state == .live ? "◆" : "◇", title: card.label,
                fields: [.typeWord(idle?.lowercased() ?? "topic")] + sessionNames.map { .label(SessionNaming.base(of: $0, topic: record)) }
                    + SearchField.tags(card.tags),
                note: record.note, trailing: trailing, mark: card.mark,
                lastVisit: visits[.topic(card.id)], isCurrent: isCurrent, unopened: card.state != .live,
                activity: members.map(\.sessionActivity).max() ?? 0,
                pick: .available(.topic(id: record.id, state: card.state)))
        }
    }

    private func dormantSessionCandidate(_ card: Board.Card, id: String) -> PickCandidate<GoToTarget>? {
        guard card.state == .dormant else { return nil }
        return PickCandidate(
            id: card.id.accessibilityID, kind: .session, symbol: "□", title: card.label,
            fields: [.typeWord("dormant"), .typeWord("session")], trailing: "Reopen", mark: card.mark,
            lastVisit: visits[.session(name: card.label)], unopened: true,
            pick: .available(.boardSession(id: id)))
    }

    private func settledCandidate(_ record: TopicRecord, labels: TopicLabels) -> PickCandidate<GoToTarget> {
        let id = TopicGroupID.topic(record.id)
        let settledOn = record.settledDate?.formatted(date: .abbreviated, time: .omitted) ?? record.settledAt
        return PickCandidate(
            id: id.accessibilityID, kind: .settled, symbol: "✓", title: labels.label(of: record),
            fields: [.typeWord("settled")] + SearchField.tags(tags?.shown(record.tags) ?? []),
            note: [record.note, settledOn].compactMap { $0 }.joined(separator: " · "),
            trailing: ["Reopen", age(.topic(id))].compactMap { $0 }.joined(separator: " · "), mark: CardMark(unread: record.isUnread, agent: nil),
            lastVisit: visits[.topic(id)], isSetAside: true,
            pick: .available(.settled(id: record.id)))
    }

    // MARK: Sessions and Session Paths

    private var sessionCandidates: [PickCandidate<GoToTarget>] {
        let running = Dictionary(windows.map { ($0.sessionName, "session:\($0.sessionID)") }, uniquingKeysWith: { first, _ in first })
        return runningSessionCandidates + SessionChoice.launches(in: sessionPaths).map { choice in
            .sessionPath(choice, lastVisit: visits[.directory(choice.directory.real)], home: home, shadowedBy: running[choice.name],
                         pick: .available(.sessionPath(directory: choice.directory.path, name: choice.name)))
        }
    }

    private var runningSessionCandidates: [PickCandidate<GoToTarget>] {
        let open = Set(records.filter { $0.settledAt == nil }.map(\.id))
        var order: [String] = []
        var members: [String: [TmuxWindow]] = [:]
        for window in windows {
            if members[window.sessionID] == nil { order.append(window.sessionID) }
            members[window.sessionID, default: []].append(window)
        }
        let currentSession: String?
        switch current {
        case .window(let id)?: currentSession = windows.first { $0.id == id }?.sessionID
        case .session(let name)?: currentSession = windows.first { $0.sessionName == name }?.sessionID
        case .page?, nil: currentSession = nil
        }
        return order.map { id in
            let windows = members[id] ?? []
            let first = windows[0]
            let folder = EntryWindow.folder(ofSession: windows)
            let isCurrent = id == currentSession
            return PickCandidate(
                id: "session:\(id)", kind: first.topicID.map(open.contains) == true ? .topicSession : .session, symbol: "■", title: first.sessionName,
                fields: [.typeWord("session"), .detail("\(windows.count) window\(windows.count == 1 ? "" : "s")"),
                         .detail(Paths.tildify(folder, home: home))],
                trailing: isCurrent ? "Current" : age(.session(name: first.sessionName)) ?? "",
                mark: sessionMarks[id].map(CardMark.agent),
                lastVisit: visits[.session(name: first.sessionName)], isCurrent: isCurrent,
                activity: (EntryWindow.ofSession(windows) ?? first).sessionActivity,
                pick: .available(.session(id: id, name: first.sessionName)),
                paste: folder)
        }
    }
}

/// The Host Server's answer to `go_to`, and what `muxify go-to --json` prints: the Go to… list of the Mac app for the
/// same state, as sections of rows in the order the app lists them.
public struct GoToAnswer: Codable, Equatable, Sendable {
    /// A text with the character offsets that matched the query.
    public struct Text: Codable, Equatable, Sendable {
        public let text: String
        public let marks: [Int]

        public init(_ highlighted: Highlighted) {
            text = highlighted.text
            marks = highlighted.marks
        }
    }

    public struct Row: Codable, Equatable, Sendable {
        /// Stable across queries for one row.
        public let id: String
        /// The Row kind, in the words `show` takes: `topic`, `settled`, `session`, `topic-session`, `session-path`,
        /// `worktree` or `tag`.
        public let kind: String
        public let title: Text
        public let detail: Text
        /// The Tags of the row's Topic, as chips after the title.
        public let tags: [Text]
        /// The right column: "2h", "Reopen · 2d", "Current".
        public let trailing: String
        @EncodesNull public var mark: CardMark?
        public let target: GoToTarget
    }

    public struct Section: Codable, Equatable, Sendable {
        public let id: String
        /// The header; null for the one list of `order: ranked`.
        @EncodesNull public var title: String?
        public let rows: [Row]
    }

    public let sections: [Section]

    public var rows: [Row] { sections.flatMap(\.rows) }

    public init(_ list: PickList<GoToTarget>) {
        sections = list.sections.map { section in
            Section(id: section.id, title: section.title, rows: section.rows.compactMap { row in
                row.pick.payload.map { target in
                    Row(id: row.id, kind: row.kind.rawValue, title: Text(row.title), detail: Text(row.detail),
                        tags: row.tags.map { Text($0.text) }, trailing: row.trailing, mark: row.mark, target: target)
                }
            })
        }
    }
}
