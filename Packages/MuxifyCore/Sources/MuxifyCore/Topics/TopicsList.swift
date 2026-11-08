import Foundation

/// The Topics list from one read of the records and one tmux snapshot, with every card rule applied once: each card's
/// Sessions, mark, label, state, Tags and Guest flag, and the In Play cut. `muxify environment show` encodes it and the
/// Sidebar draws it, so the two cannot disagree.
public struct TopicsList {
    /// A Topic or a Locked Session, as its card shows it.
    public struct Card {
        public enum Subject {
            case topic(TopicRecord)
            case locked(SessionLock)
        }

        public let subject: Subject
        /// The Topic's label, or the Locked Session's name.
        public let label: String
        /// The Topic Unread mark or the strongest Agent mark of its Sessions.
        public let mark: CardMark?
        /// The live Sessions in the Topic's Session order; for a Locked Session, that Session.
        public let sessions: [String]
        /// A Locked Session is always live.
        public let state: TopicState
        /// In Config order, then the Tags the Config no longer defines. None with Tags off, and none on a Locked Session.
        public let tags: [ShownTag]
        /// A Guest, while the Config sets `topics.in_play`: a Topic with the Guest mark, or a Locked Session.
        public let isGuest: Bool

        public var id: TopicGroupID {
            switch subject {
            case .topic(let record): return .topic(record.id)
            case .locked(let lock): return .locked(lock.sessionID)
            }
        }

        public var record: TopicRecord? {
            if case .topic(let record) = subject { return record }
            return nil
        }

        public var isPinned: Bool { record?.isPinned ?? false }
    }

    public enum Entry {
        case card(Card)
        /// Only In Play shows it.
        case openPlace(id: String)

        public var id: TopicListID {
            switch self {
            case .openPlace(let id): return .openPlace(id)
            case .card(let card):
                switch card.subject {
                case .topic(let record): return .topic(record.id)
                case .locked(let lock): return .lock(sessionID: lock.sessionID)
                }
            }
        }

        public var card: Card? {
            if case .card(let card) = self { return card }
            return nil
        }

        fileprivate var slot: InPlaySlot {
            switch self {
            case .card(let card): return card.isGuest ? .guest : .regular
            case .openPlace: return .openPlace
            }
        }
    }

    /// Every card and Open Place in list order, the Pinned Topics first, as `TopicCards.order` gives them.
    public let entries: [Entry]
    /// The same cards as `TopicCards` takes them, for Move Up and Move Down.
    public let order: [TopicListEntry]
    /// `topics.in_play` and the cards that are not Pinned, cut into the places, the Guests and the Bench. Nil while
    /// the Config does not set `topics.in_play`.
    public let inPlay: (limit: Int, cut: InPlayCut<Entry>)?
    public let labels: TopicLabels
    public let lockedSessionIDs: Set<String>
    private let openTopicIDs: Set<String>

    public var pinned: [Card] { entries.compactMap(\.card).filter(\.isPinned) }

    /// The cards that are not Pinned, in list order, with no Open Place: the list without `topics.in_play`.
    public var unpinned: [Card] { entries.compactMap(\.card).filter { !$0.isPinned } }

    public init(records: [TopicRecord], openPlaces: [OpenPlace], windows: [TmuxWindow], marks: AgentMarks, topics: Config.Topics) {
        let order = TopicCards.order(records: records, windows: windows, openPlaces: openPlaces)
        let open = Set(order.records.map(\.id)), locked = Set(order.locks.map(\.sessionID))
        let labels = TopicLabels(records)
        let members = Dictionary(grouping: windows) { TopicGroupID($0, open: open, locked: locked) }
        let entries = order.map { entry -> Entry in
            switch entry {
            case .openPlace(let place):
                return .openPlace(id: place.id)
            case .lock(let lock):
                let windows = members[.locked(lock.sessionID)] ?? []
                let sessions = TopicSessionOrder.firstWindows(windows, record: nil, order: topics.sessionOrder).map(\.sessionID)
                return .card(Card(subject: .locked(lock), label: windows.first?.sessionName ?? lock.sessionID,
                                  mark: marks.card(sessions: sessions).map(CardMark.agent), sessions: sessions, state: .live, tags: [],
                                  isGuest: topics.inPlay != nil))
            case .topic(let record):
                let sessions = TopicSessionOrder.firstWindows(members[.topic(record.id)] ?? [], record: record, order: topics.sessionOrder)
                    .map(\.sessionID)
                return .card(Card(subject: .topic(record), label: labels.label(of: record),
                                  mark: CardMark(unread: record.isUnread, agent: marks.card(sessions: sessions)), sessions: sessions,
                                  state: TopicState(record: record, hasLiveSession: !sessions.isEmpty),
                                  tags: topics.tags?.shown(record.tags) ?? [],
                                  isGuest: topics.inPlay != nil && entry.isGuest))
            }
        }
        self.entries = entries
        self.order = order
        inPlay = topics.inPlay.map { limit in
            (limit, InPlayCut(entries.filter { !($0.card?.isPinned ?? false) }, limit: limit, slot: \.slot))
        }
        self.labels = labels
        lockedSessionIDs = locked
        openTopicIDs = open
    }

    /// The card that the Window's Session is on.
    public func group(of window: TmuxWindow) -> TopicGroupID {
        TopicGroupID(window, open: openTopicIDs, locked: lockedSessionIDs)
    }
}
