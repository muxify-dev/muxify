import Foundation

/// The Board from one read of the records and one tmux snapshot, with every card rule applied once: each card's
/// Sessions, mark, label, state, Tags and Guest flag, and the In Play cut. `muxify environment show` encodes it and the
/// Sidebar draws it, so the two cannot disagree.
public struct Board {
    /// A Topic or a Board Session, live or Dormant, as its card shows it.
    public struct Card {
        public enum Subject {
            case topic(TopicRecord)
            case session(BoardSession)
        }

        public let subject: Subject
        /// The Topic's label, or the Board Session's name: its live Session's, else the one it had when last seen.
        public let label: String
        /// The Topic Unread mark or the strongest Agent mark of its Sessions.
        public let mark: CardMark?
        /// The live Sessions in the Topic's Session order; for a Board Session, its live Session, or none when Dormant.
        public let sessions: [String]
        /// A Board Session is live or Dormant, never Empty.
        public let state: TopicState
        /// In Config order, then the Tags the Config no longer defines. None with Tags off, and none on a Board Session.
        public let tags: [ShownTag]
        /// The card is in the Guests section of the cut: a Topic with the Guest mark, or a Board Session with the mark or
        /// past the last place.
        public let isGuest: Bool

        public var id: TopicGroupID {
            switch subject {
            case .topic(let record): return .topic(record.id)
            case .session(let session): return .session(session.id)
            }
        }

        public var record: TopicRecord? {
            if case .topic(let record) = subject { return record }
            return nil
        }

        public var isPinned: Bool {
            switch subject {
            case .topic(let record): return record.isPinned
            case .session(let session): return session.isPinned
            }
        }
    }

    public enum Entry {
        case card(Card)
        /// Only In Play shows it.
        case openPlace(id: String)

        public var id: BoardCardID {
            switch self {
            case .openPlace(let id): return .openPlace(id)
            case .card(let card):
                switch card.subject {
                case .topic(let record): return .topic(record.id)
                case .session(let session): return .session(session.id)
                }
            }
        }

        public var card: Card? {
            if case .card(let card) = self { return card }
            return nil
        }
    }

    /// Every card and Open Place in list order, the Pinned cards first, as `TopicCards.order` gives them.
    public let entries: [Entry]
    /// The same cards as `TopicCards` takes them, for Move Up and Move Down.
    public let order: [BoardCard]
    /// `topics.in_play` and the cards that are not Pinned, cut into the places, the Guests and the Bench.
    public let inPlay: (limit: Int, cut: InPlayCut<Entry>)
    public let labels: TopicLabels
    /// The id of each live Board Session, by the Session's tmux id.
    public let boardSessionsBySession: [String: String]
    private let openTopicIDs: Set<String>

    /// The tmux ids of the live Board Sessions.
    public var sessionIDsOnBoard: Set<String> { Set(boardSessionsBySession.keys) }

    public var pinned: [Card] { entries.compactMap(\.card).filter(\.isPinned) }

    public init(records: [TopicRecord], openPlaces: [OpenPlace], boardSessions: [BoardSession] = [], windows: [TmuxWindow], marks: AgentMarks,
                topics: Config.Topics) {
        let order = TopicCards.order(records: records, boardSessions: boardSessions, openPlaces: openPlaces)
        let cut = TopicOrder.cut(order, inPlay: topics.inPlay)
        let guests = Set(cut.guests.map(\.id))
        let open = Set(order.records.map(\.id))
        let boardSessionsBySession = order.boardSessions.bySession(in: windows, open: open).mapValues(\.id)
        let labels = TopicLabels(records)
        let members = Dictionary(grouping: windows) { TopicGroupID($0, open: open, boardSessions: boardSessionsBySession) }
        let entries = order.map { entry -> Entry in
            switch entry {
            case .openPlace(let place):
                return .openPlace(id: place.id)
            case .session(let boardSession):
                let windows = members[.session(boardSession.id)] ?? []
                let sessions = TopicSessionOrder.firstWindows(windows, record: nil, order: topics.sessionOrder).map(\.sessionID)
                return .card(Card(subject: .session(boardSession), label: windows.first?.sessionName ?? boardSession.name,
                                  mark: marks.card(sessions: sessions).map(CardMark.agent), sessions: sessions,
                                  state: sessions.isEmpty ? .dormant : .live, tags: [], isGuest: guests.contains(entry.id)))
            case .topic(let record):
                let sessions = TopicSessionOrder.firstWindows(members[.topic(record.id)] ?? [], record: record, order: topics.sessionOrder)
                    .map(\.sessionID)
                return .card(Card(subject: .topic(record), label: labels.label(of: record),
                                  mark: CardMark(unread: record.isUnread, agent: marks.card(sessions: sessions)), sessions: sessions,
                                  state: TopicState(record: record, hasLiveSession: !sessions.isEmpty),
                                  tags: topics.tags?.shown(record.tags) ?? [],
                                  isGuest: guests.contains(entry.id)))
            }
        }
        self.entries = entries
        self.order = order
        let entriesByID = Dictionary(zip(order.map(\.id), entries), uniquingKeysWith: { first, _ in first })
        inPlay = (topics.inPlay, cut.compactMap { entriesByID[$0.id] })
        self.labels = labels
        self.boardSessionsBySession = boardSessionsBySession
        openTopicIDs = open
    }

    /// The card that the Window's Session is on.
    public func group(of window: TmuxWindow) -> TopicGroupID {
        TopicGroupID(window, open: openTopicIDs, boardSessions: boardSessionsBySession)
    }
}
