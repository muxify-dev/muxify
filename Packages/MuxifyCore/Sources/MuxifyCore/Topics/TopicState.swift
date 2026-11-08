import Foundation

/// What an open Topic has in tmux now: live Sessions, or none and remembered ones that Reopen makes again (Dormant),
/// or none at all (Empty).
public enum TopicState: String, Codable, Hashable, Sendable {
    case live, dormant, empty

    public init(record: TopicRecord, hasLiveSession: Bool) {
        self = hasLiveSession ? .live : record.sessions.isEmpty ? .empty : .dormant
    }
}
