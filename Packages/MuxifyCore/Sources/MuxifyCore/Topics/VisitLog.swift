import Foundation

/// What a visit is to. No Topic is a Topic key too.
public enum VisitKey: Hashable, Sendable {
    case topic(TopicGroupID)
    case session(name: String)
    /// A SessionChoice directory's real path.
    case directory(String)

    public var stored: String {
        switch self {
        case .topic(.topic(let id)): return "topic:" + id
        // A Board Session is a No Topic Session, and its Session visits are kept by name.
        case .topic(.noTopic), .topic(.session): return "topic:-"
        case .session(let name): return "session:" + name
        case .directory(let path): return "path:" + path
        }
    }

    public init?(stored: String) {
        guard let colon = stored.firstIndex(of: ":") else { return nil }
        let value = String(stored[stored.index(after: colon)...])
        switch stored[..<colon] {
        case "topic": self = .topic(value == "-" ? .noTopic : .topic(value))
        case "session": self = .session(name: value)
        case "path": self = .directory(value)
        default: return nil
        }
    }
}

/// The visit times of one machine's Topics, Sessions and SessionPaths, as `VisitStore` keeps them in the state
/// database. One App Window holds one, for its Environment.
public struct VisitLog: Equatable {
    /// The table keeps only this many of the newest visits of a machine, so it cannot grow without bound.
    public static let capacity = 2000

    public private(set) var times: [VisitKey: Date]
    /// The keys the last `record` stamped; the same look at the same place is not a new visit.
    private var lastRecorded: Set<VisitKey> = []

    public init(times: [VisitKey: Date] = [:]) {
        self.times = times
    }

    public func last(_ key: VisitKey) -> Date? { times[key] }

    /// One visit: the Window's group, its Session, and the SessionPath or Worktree that holds the Session's
    /// start directory. Returns the keys it stamped, for the caller to save: none when the same place was recorded
    /// last. `folders` resolves the Session's path on the machine that runs it.
    public mutating func record(_ window: TmuxWindow, group: TopicGroupID, sessionPaths: [SessionPath], folders: FolderResolver, at now: Date) -> Set<VisitKey> {
        var keys: Set<VisitKey> = [.topic(group), .session(name: window.sessionName)]
        if let choice = SessionChoice.containing(folders.folder(window.sessionPath), in: sessionPaths) {
            keys.insert(.directory(choice.directory.real))
        }
        guard keys != lastRecorded else { return [] }
        lastRecorded = keys
        for key in keys { times[key] = now }
        return keys
    }

    /// Takes the visits another writer saved, such as the Host CLI for the phone. The newer time of a key stays, so
    /// a visit this log has not saved yet is not lost.
    public mutating func merge(_ stored: [VisitKey: Date]) {
        times.merge(stored) { max($0, $1) }
    }
}

/// "now", "2m", "1h", "3d" for a right column.
public enum VisitAge {
    public static func short(since: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(since))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
