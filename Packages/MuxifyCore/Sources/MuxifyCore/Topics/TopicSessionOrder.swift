import Foundation

public enum SessionOrder: String, CaseIterable, Sendable {
    case oldestFirst = "oldest_first"
    case newestFirst = "newest_first"
}

public struct TopicSessionKey: Equatable, Sendable {
    public let sessionID: String
    public let recordID: String
    public let created: Int

    public init(of window: TmuxWindow) {
        sessionID = window.sessionID
        recordID = window.sessionRecordID
        created = window.sessionCreated
    }
}

/// One order for the Sidebar, palette and restoration record. Paths never identify Sessions.
public enum TopicSessionOrder {
    public static func ordered<Item>(_ items: [Item], record: TopicRecord?, order: SessionOrder,
                                     key: (Item) -> TopicSessionKey) -> [Item] {
        let positions = Dictionary((record?.sessions ?? []).enumerated().compactMap { index, entry in
            entry["id"]?.string.map { ($0, index) }
        }, uniquingKeysWith: { first, _ in first })
        return items.sorted { lhs, rhs in
            let a = key(lhs), b = key(rhs)
            if record?.hasManualSessionOrder == true {
                switch (positions[a.recordID], positions[b.recordID]) {
                case let (a?, b?) where a != b: return a < b
                case (.some, nil): return order == .oldestFirst
                case (nil, .some): return order == .newestFirst
                default: break
                }
            }
            if a.created != b.created { return order == .oldestFirst ? a.created < b.created : a.created > b.created }
            return a.sessionID < b.sessionID
        }
    }
}

extension TopicRecord {
    mutating func recordingNewSession(_ entry: [String: JSONValue], order: SessionOrder) {
        sessions.removeAll { $0["id"] == entry["id"] }
        if hasManualSessionOrder && order == .newestFirst { sessions.insert(.object(entry), at: 0) }
        else { sessions.append(.object(entry)) }
    }
}
