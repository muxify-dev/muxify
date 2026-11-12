import Foundation
import WebKit
import MuxifyCore

/// The time whose visits Clear Browser History removes.
enum ClearRange: CaseIterable {
    case lastHour, last6Hours, lastDay, last3Days, last7Days, allTime

    var title: String {
        switch self {
        case .lastHour: "Last hour"
        case .last6Hours: "Last 6 hours"
        case .lastDay: "Last day"
        case .last3Days: "Last 3 days"
        case .last7Days: "Last 7 days"
        case .allTime: "All time"
        }
    }

    /// Nil for All time. No duration is longer than `HistoryEntry.recentSpan`, so a range removes exactly its visits.
    var duration: TimeInterval? {
        switch self {
        case .lastHour: 3_600
        case .last6Hours: 6 * 3_600
        case .lastDay: 86_400
        case .last3Days: 3 * 86_400
        case .last7Days: HistoryEntry.recentSpan
        case .allTime: nil
        }
    }
}

/// How a load that Browser History records was started.
enum HistoryVisit {
    /// From the address field or a Suggestion.
    case typed
    case link

    var weight: Double {
        switch self {
        case .typed: 2
        case .link: 1
        }
    }

    private static let schemes: Set<String> = ["http", "https", "file"]
    private static let secretQueryKeys: Set<String> = ["token", "access_token", "code", "sig", "signature", "password", "key"]

    /// False for `about:blank` and other pages that are not places, and for a URL whose query or fragment holds a
    /// secret. A sign-in that returns its token to the page puts it in the fragment (`#access_token=`).
    static func isRecordable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return false }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var fragment = URLComponents()
        fragment.percentEncodedQuery = components?.percentEncodedFragment
        let names = ((components?.queryItems ?? []) + (fragment.queryItems ?? [])).map { $0.name.lowercased() }
        return !names.contains(where: secretQueryKeys.contains)
    }
}

/// What a Tab knows of its main-frame loads, to tell Browser History which ones are the user's visits. A load gets
/// its origin from the navigation action just before it starts; a server redirect keeps the origin of its load.
struct HistoryLoads {
    enum Origin { case typed, link, skipped }

    /// Set by the Tab before a load of its own: `.typed` from the address field, `.skipped` for a restored page.
    var next: Origin?
    private var decided = Origin.skipped
    private var started: [ObjectIdentifier?: Origin] = [:]

    /// A main-frame navigation action that WebKit goes on with.
    mutating func decide(_ type: WKNavigationType, byAgent: Bool) {
        decided = byAgent || type == .reload ? .skipped : next ?? .link
        next = nil
    }

    mutating func start(_ navigation: ObjectIdentifier?) {
        started[navigation] = decided
        decided = .skipped
    }

    mutating func fail(_ navigation: ObjectIdentifier?) {
        started[navigation] = nil
    }

    /// The visit to record for a finished load, nil for none. A load while a Browser command runs is the Agent's.
    mutating func finish(_ navigation: ObjectIdentifier?, byAgent: Bool) -> HistoryVisit? {
        guard let origin = started.removeValue(forKey: navigation), !byAgent else { return nil }
        switch origin {
        case .typed: return .typed
        case .link: return .link
        case .skipped: return nil
        }
    }
}

/// Browser History: one store for the whole app, kept in memory and written to the state database a short time after
/// each change. A write upserts the History entries that changed since the last one and deletes those that went, so
/// another Muxify process's entries stay. Used on the main thread only. While `browser.history` is off it records
/// nothing and never reads the table.
final class BrowserHistory {
    static let shared = BrowserHistory(paths: MuxifyPaths())
    static let capacity = 10_000

    let store: BrowserHistoryStore
    private let capacity: Int
    private let writeDelay: TimeInterval
    private(set) var isEnabled = false
    private(set) var entries: [String: HistoryEntry] = [:] {
        didSet { cachedIndex = nil }
    }
    private var cachedIndex: HistoryIndex?
    private var writeScheduled = false
    /// The keys whose entries changed, and those that went by the cap, since the last write.
    private var changedKeys: Set<String> = []
    private var removedKeys: Set<String> = []
    /// Writes and clears of the table, in the order they were asked for.
    private let io = DispatchQueue(label: "dev.muxify.browser-history", qos: .utility)

    init(paths: MuxifyPaths, capacity: Int = BrowserHistory.capacity, writeDelay: TimeInterval = 2) {
        store = BrowserHistoryStore(paths: paths)
        self.capacity = capacity
        self.writeDelay = writeDelay
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            isEnabled = true
            entries = read()
        } else {
            flush()
            isEnabled = false
            entries = [:]
        }
    }

    /// Made at the first query after a change, so a burst of loads and title changes makes it once.
    private var index: HistoryIndex {
        if let cachedIndex { return cachedIndex }
        let index = HistoryIndex(entries)
        cachedIndex = index
        return index
    }

    /// None while it is off, so the address field works as it did before Browser History: no list, no completion.
    func suggestions(for query: String, live: LiveRows, activeTopic: String?, now: Date = Date()) -> [Suggestion] {
        guard isEnabled else { return [] }
        return SuggestionRanker.rank(query, index: index, live: live, activeTopic: activeTopic, now: now)
    }

    func record(url: URL, title: String, visit: HistoryVisit, topic: String?, at now: Date = Date()) {
        guard isEnabled, HistoryVisit.isRecordable(url) else { return }
        let key = BrowserTab.matchKey(url.absoluteString)
        var entry = entries[key] ?? HistoryEntry(key: key, url: url.absoluteString, title: "", topics: [])
        entry.add(HistoryEntry.Visit(at: now, weight: visit.weight))
        entry.url = url.absoluteString
        if !title.isEmpty { entry.title = title }
        if let topic { entry.topics.insert(topic) }
        entries[key] = entry
        changedKeys.insert(key)
        removedKeys.remove(key)
        if entries.count > capacity,
           let lowest = entries.values.filter({ $0.key != key }).min(by: { $0.score(at: now) < $1.score(at: now) }) {
            entries[lowest.key] = nil
            changedKeys.remove(lowest.key)
            removedKeys.insert(lowest.key)
        }
        changed()
    }

    /// A page changed its title after its load, as a single-page app does for each of its views.
    func updateTitle(of url: String, to title: String) {
        let key = BrowserTab.matchKey(url)
        guard isEnabled, !title.isEmpty, let entry = entries[key], entry.title != title else { return }
        entries[key]?.title = title
        changedKeys.insert(key)
        changed()
    }

    /// While it is on, or while the table keeps History entries of an earlier time.
    var canClear: Bool { isEnabled || store.hasEntries }

    /// Forgets the visits of `range` in memory and in the table at once, also while Browser History is off. An entry
    /// with no visit left goes. All time deletes every row.
    func clear(_ range: ClearRange, now: Date = Date()) {
        // The pending changes reach the table first, so that the clear there covers them as it does in memory.
        write()
        let since = range.duration.map { now - $0 }
        if isEnabled {
            entries = since.map { since in
                entries.compactMapValues { entry in
                    var entry = entry
                    entry.removeVisits(since: since)
                    return entry.lastVisit == nil ? nil : entry
                }
            } ?? [:]
        }
        let store = store
        io.async {
            do {
                try store.clear(since: since)
            } catch {
                Diagnostics.report("cannot clear Browser History in \(store.paths.stateDatabase.path): \(error)")
            }
        }
    }

    /// Writes a pending change now and waits for the database, as the app quits.
    func flush() {
        write()
        io.sync {}
    }

    private func changed() {
        guard !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay) { [weak self] in self?.write() }
    }

    private func write() {
        guard writeScheduled else { return }
        writeScheduled = false
        let changed = changedKeys.sorted().compactMap { entries[$0] }
        let removed = removedKeys
        changedKeys = []
        removedKeys = []
        let store = store
        io.async {
            do {
                try store.save(changed, removing: removed)
            } catch {
                Diagnostics.report("cannot write Browser History to \(store.paths.stateDatabase.path): \(error)")
            }
        }
    }

    /// The entries of the table, with the visits before the last 7 days folded. A table that cannot be read gives no
    /// entry for this run, and a problem line: the writes of this run then touch only the pages it records.
    private func read() -> [String: HistoryEntry] {
        io.sync {}
        do {
            let cutoff = Date() - HistoryEntry.recentSpan
            let list = try store.entries().map { entry in
                var entry = entry
                entry.fold(before: cutoff)
                return entry
            }
            return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            Diagnostics.report("cannot read Browser History from \(store.paths.stateDatabase.path), so this run starts with none: \(error)")
            return [:]
        }
    }
}
