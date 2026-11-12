import Foundation

/// The Sessions and the Topics list of the Environment, in the order that Muxify shows them, from one read of the
/// records and one tmux snapshot: what `muxify environment show` prints. A client draws each array in the order it
/// comes and sorts nothing, so the card rules stay in MuxifyCore. Every missing value is encoded as null, never left out.
public struct EnvironmentSnapshot: Codable, Hashable, Sendable {
    /// A Tag that the Config defines, with its colour for light and dark appearance.
    public struct DefinedTag: Codable, Hashable, Sendable {
        public struct Color: Codable, Hashable, Sendable {
            /// A system colour name or `#rrggbb`.
            public var light: String
            public var dark: String
        }

        public var name: String
        public var color: Color

        public init(_ definition: TagDefinition) {
            name = definition.tag.name
            switch definition.color {
            case .single(let color): self.color = Color(light: color.text, dark: color.text)
            case .pair(let light, let dark): color = Color(light: light.text, dark: dark.text)
            }
        }
    }

    public struct Window: Codable, Hashable, Sendable {
        public var id: String
        public var index: Int
        public var name: String
        public var active: Bool
        @EncodesNull public var mark: AgentMark?

        private enum CodingKeys: String, CodingKey { case id, index, name, active, mark }
    }

    /// One live Session, as Sessions mode shows it.
    public struct Session: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        /// tmux `session_activity`, in seconds since 1970.
        public var activity: Int
        @EncodesNull public var mark: CardMark?
        /// The open Topic it is in; nil for a No Topic Session, Locked or not.
        @EncodesNull public var topic: String?
        public var windows: [Window]

        private enum CodingKeys: String, CodingKey { case id, name, activity, mark, topic, windows }
    }

    /// An open Topic as its card shows it.
    public struct Topic: Codable, Hashable, Sendable {
        public var id: String
        /// What the card shows: the title, else "Untitled N".
        public var label: String
        @EncodesNull public var note: String?
        /// The names only, in Config order, then those that the Config no longer defines, A→Z. With Tags off, none.
        public var tags: [Tag]
        public var state: TopicState

        private enum CodingKeys: String, CodingKey { case id, label, note, tags, state }
    }

    /// One card of the Topics list. Each card has `sessions`: the Topic's own Session order, the one Locked Session,
    /// or none for an Open Place.
    public enum Card: Codable, Hashable, Sendable {
        case topic(Topic, mark: CardMark?, sessions: [String])
        /// A Locked Session.
        case session(String, mark: CardMark?)
        /// Only in the In Play places.
        case openPlace(id: String)

        private enum Kind: String, Codable { case topic, session, openPlace = "open_place" }
        private enum CodingKeys: String, CodingKey { case kind, mark, topic, sessions, id }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .topic:
                self = .topic(try values.decode(Topic.self, forKey: .topic), mark: try values.decodeIfPresent(CardMark.self, forKey: .mark),
                              sessions: try values.decode([String].self, forKey: .sessions))
            case .session:
                let sessions = try values.decode([String].self, forKey: .sessions)
                guard sessions.count == 1 else {
                    throw DecodingError.dataCorruptedError(forKey: .sessions, in: values, debugDescription: "expected one Session")
                }
                self = .session(sessions[0], mark: try values.decodeIfPresent(CardMark.self, forKey: .mark))
            case .openPlace:
                self = .openPlace(id: try values.decode(String.self, forKey: .id))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .topic(let topic, let mark, let sessions):
                try values.encode(Kind.topic, forKey: .kind)
                try values.encode(mark, forKey: .mark)
                try values.encode(topic, forKey: .topic)
                try values.encode(sessions, forKey: .sessions)
            case .session(let session, let mark):
                try values.encode(Kind.session, forKey: .kind)
                try values.encode(mark, forKey: .mark)
                try values.encode([session], forKey: .sessions)
            case .openPlace(let id):
                try values.encode(Kind.openPlace, forKey: .kind)
                try values.encode(id, forKey: .id)
                try values.encode([String](), forKey: .sessions)
            }
        }
    }

    /// The cards that are not Pinned, cut into the In Play sections. `kind` stays on the wire for the readers that
    /// knew a second kind.
    public enum Unpinned: Codable, Hashable, Sendable {
        /// The places in place order (place number = index + 1), the Guests, and the Bench, top first.
        case inPlay(limit: Int, places: [Card], guests: [Card], bench: [Card])

        private enum Kind: String, Codable { case inPlay = "in_play" }
        private enum CodingKeys: String, CodingKey { case kind, limit, places, guests, bench }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .inPlay:
                self = .inPlay(limit: try values.decode(Int.self, forKey: .limit), places: try values.decode([Card].self, forKey: .places),
                               guests: try values.decode([Card].self, forKey: .guests), bench: try values.decode([Card].self, forKey: .bench))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .inPlay(let limit, let places, let guests, let bench):
                try values.encode(Kind.inPlay, forKey: .kind)
                try values.encode(limit, forKey: .limit)
                try values.encode(places, forKey: .places)
                try values.encode(guests, forKey: .guests)
                try values.encode(bench, forKey: .bench)
            }
        }
    }

    /// The Tags that the Config defines, in Config order.
    public var tags: [DefinedTag]
    /// Every live Session once, in tmux order: Sessions mode.
    public var sessions: [Session]
    /// The Pinned Topics, in the order the user gave.
    public var pinned: [Card]
    public var unpinned: Unpinned
    /// The Sessions in no open Topic and not Locked, in tmux order. They have no card in the Sidebar.
    public var noTopic: [String]

    /// Every card in list order: the Pinned cards, then the others.
    public var cards: [Card] {
        switch unpinned {
        case .inPlay(_, let places, let guests, let bench): return pinned + places + guests + bench
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tags, sessions, pinned, unpinned
        case noTopic = "no_topic"
    }

    public init(contents: TopicContents, tmux: TmuxSnapshot, topics: Config.Topics, notifications: Config.Notifications) {
        let marks = AgentMarks(tmux.agents, notifications: notifications)
        let list = TopicsList(records: contents.records, openPlaces: contents.openPlaces, windows: tmux.windows, marks: marks, topics: topics)
        let firsts = TopicSessionOrder.firstWindows(tmux.windows, record: nil, order: topics.sessionOrder)
        func topic(of window: TmuxWindow) -> String? {
            if case .topic(let id) = list.group(of: window) { return id }
            return nil
        }

        tags = topics.tags?.definitions.map(DefinedTag.init) ?? []
        sessions = firsts.map { window in
            Session(id: window.sessionID, name: window.sessionName, activity: window.sessionActivity,
                    mark: marks.sessions[window.sessionID].map(CardMark.agent), topic: topic(of: window),
                    windows: tmux.windows.filter { $0.sessionID == window.sessionID }.sorted { $0.index < $1.index }.map { member in
                        Window(id: member.id, index: member.index, name: member.name, active: member.isActive, mark: marks.windows[member.id])
                    })
        }
        pinned = list.pinned.map(Card.init)
        let cut = list.inPlay.cut
        unpinned = .inPlay(limit: list.inPlay.limit, places: cut.places.map(Card.init), guests: cut.guests.map(Card.init),
                           bench: cut.bench.map(Card.init))
        noTopic = firsts.filter { list.group(of: $0) == .noTopic }.map(\.sessionID)
    }
}

extension EnvironmentSnapshot.Card {
    init(_ entry: TopicsList.Entry) {
        switch entry {
        case .openPlace(let id): self = .openPlace(id: id)
        case .card(let card): self.init(card)
        }
    }

    init(_ card: TopicsList.Card) {
        switch card.subject {
        case .locked(let lock):
            self = .session(lock.sessionID, mark: card.mark)
        case .topic(let record):
            let topic = EnvironmentSnapshot.Topic(id: record.id, label: card.label, note: record.note, tags: card.tags.map(\.tag),
                                                  state: card.state)
            self = .topic(topic, mark: card.mark, sessions: card.sessions)
        }
    }
}

extension MarkColor.Single {
    /// As the Config writes it: a system colour name, or `#rrggbb`.
    var text: String {
        switch self {
        case .system(let name): return name.rawValue
        case .rgb(let red, let green, let blue): return String(format: "#%02x%02x%02x", red, green, blue)
        }
    }
}
