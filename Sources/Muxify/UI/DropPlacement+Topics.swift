import MuxifyCore

extension DropPlacement where ID == BoardCardID {
    /// The placement of a dragged Topic or Board Session card, as the Topic order takes it.
    var topicPlacement: TopicPlacement {
        switch self {
        case .before(let id): return .before(id)
        case .after(let id): return .after(id)
        }
    }
}

extension DropPlacement where ID == String {
    /// The placement of a dragged Session line, by Session ID, as a Topic's Session order takes it.
    var sessionPlacement: TopicSessionPlacement? {
        switch self {
        case .before(let id): return SessionID(rawValue: id).map(TopicSessionPlacement.before)
        case .after(let id): return SessionID(rawValue: id).map(TopicSessionPlacement.after)
        }
    }
}
