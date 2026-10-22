import Foundation
import MuxifyCore

/// What a visit is to. No Topic is a Topic key too.
enum VisitKey: Hashable {
    case topic(TopicGroupID)
    case session(name: String)
    /// A SessionChoice directory's real path.
    case directory(String)

    var stored: String {
        switch self {
        case .topic(.topic(let id)): return "topic:" + id
        // A Locked Session is a No Topic Session, and its Session visits are kept by name.
        case .topic(.noTopic), .topic(.locked): return "topic:-"
        case .session(let name): return "session:" + name
        case .directory(let path): return "path:" + path
        }
    }

    init?(stored: String) {
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

/// Every visit time, kept across restarts in one UserDefaults key. One writer: WorkspaceStore on the main thread.
struct VisitLog: Equatable {
    static let defaultsKey = "visits"
    /// Only the newest entries are saved, so the key cannot grow without bound.
    static let capacity = 2000

    private(set) var times: [VisitKey: Date] = [:]
    /// The keys the last `record` stamped; the same look at the same place is not a new visit.
    private var lastRecorded: Set<VisitKey> = []

    init() {}

    init(defaults: UserDefaults) {
        for (key, value) in defaults.dictionary(forKey: Self.defaultsKey) ?? [:] {
            guard let key = VisitKey(stored: key), let seconds = value as? Double else { continue }
            let date = Date(timeIntervalSince1970: seconds)
            times[key] = date
        }
    }

    func save(to defaults: UserDefaults) {
        let newest = times.sorted { $0.value > $1.value }.prefix(Self.capacity)
        defaults.set(Dictionary(uniqueKeysWithValues: newest.map { ($0.key.stored, $0.value.timeIntervalSince1970) }),
                     forKey: Self.defaultsKey)
    }

    func last(_ key: VisitKey) -> Date? { times[key] }

    /// One visit: the Window's group, its Session, and the SessionPath or Worktree that holds the Session's
    /// start directory. Returns false when the same place was recorded last, so the caller saves only on a change.
    /// `folders` resolves the Session's path on the machine that runs it.
    mutating func record(_ window: TmuxWindow, group: TopicGroupID, sessionPaths: [SessionPath], folders: FolderResolver, at now: Date) -> Bool {
        var keys: Set<VisitKey> = [.topic(group), .session(name: window.sessionName)]
        if let choice = SessionChoice.containing(folders.folder(window.sessionPath), in: sessionPaths) {
            keys.insert(.directory(choice.directory.real))
        }
        guard keys != lastRecorded else { return false }
        lastRecorded = keys
        for key in keys { times[key] = now }
        return true
    }
}

/// "now", "2m", "1h", "3d" for a right column.
enum VisitAge {
    static func short(since: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(since))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
