import Foundation
import WebKit
import MuxifyCore

/// One page in Browser History (ADR 0059).
struct HistoryEntry: Codable, Equatable {
    /// A visit of the last `recentSpan`, kept on its own so that Clear Browser History can remove it.
    struct Visit: Codable, Equatable {
        let at: Date
        let weight: Double
    }

    /// The visits before the recent ones, as one score at the time of the newest of them.
    struct Folded: Codable, Equatable {
        let score: Double
        let at: Date
    }

    /// `BrowserTab.matchKey` of the URL.
    var key: String
    var url: String
    var title: String
    var folded: Folded?
    /// Oldest first.
    var recent: [Visit]
    /// The Topics of the Windows where the user loaded the page.
    var topics: Set<String>

    static let halfLife: TimeInterval = 14 * 86_400
    static let recentSpan: TimeInterval = 7 * 86_400

    init(key: String, url: String, title: String, folded: Folded? = nil, recent: [Visit] = [], topics: Set<String>) {
        self.key = key
        self.url = url
        self.title = title
        self.folded = folded
        self.recent = recent
        self.topics = topics
    }

    /// The sum of the weights of every visit, each halved for each `halfLife` since that visit.
    func score(at now: Date) -> Double {
        let base = folded.map { Self.decay($0.score, from: $0.at, to: now) } ?? 0
        return recent.reduce(base) { $0 + Self.decay($1.weight, from: $1.at, to: now) }
    }

    /// Nil when no visit is left, after a clear.
    var lastVisit: Date? { recent.last?.at ?? folded?.at }

    mutating func add(_ visit: Visit) {
        recent.append(visit)
        fold(before: visit.at - Self.recentSpan)
    }

    /// Moves the recent visits before `cutoff` into the folded score.
    mutating func fold(before cutoff: Date) {
        while let oldest = recent.first, oldest.at < cutoff {
            recent.removeFirst()
            let base = folded.map { Self.decay($0.score, from: $0.at, to: oldest.at) } ?? 0
            folded = Folded(score: base + oldest.weight, at: oldest.at)
        }
    }

    /// Removes the visits at or after `since`. A folded score that holds such a visit goes as a whole, because it
    /// cannot tell its visits apart. Only a file from before the recent visits were kept has one.
    mutating func removeVisits(since: Date) {
        recent.removeAll { $0.at >= since }
        if let folded, folded.at >= since { self.folded = nil }
    }

    private static func decay(_ score: Double, from then: Date, to now: Date) -> Double {
        score * pow(0.5, max(0, now.timeIntervalSince(then)) / halfLife)
    }

    private enum CodingKeys: String, CodingKey { case key, url, title, folded, recent, topics }
    /// The shape of a file from before the recent visits were kept: one score at the last visit.
    private enum ScoreAtLastVisitKeys: String, CodingKey { case score, lastVisit }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        topics = try container.decode(Set<String>.self, forKey: .topics)
        recent = try container.decodeIfPresent([Visit].self, forKey: .recent) ?? []
        folded = try container.decodeIfPresent(Folded.self, forKey: .folded)
        let old = try decoder.container(keyedBy: ScoreAtLastVisitKeys.self)
        if folded == nil, recent.isEmpty, let score = try old.decodeIfPresent(Double.self, forKey: .score) {
            folded = Folded(score: score, at: try old.decode(Date.self, forKey: .lastVisit))
        }
    }
}

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

/// Browser History: one store for the whole app, kept in memory and written to one file a short time after each
/// change. Used on the main thread only. While `browser.history` is off it records nothing and never reads the file.
final class BrowserHistory {
    static let shared = BrowserHistory(file: MuxifyPaths().browserHistory)
    static let capacity = 10_000

    let file: URL
    private let capacity: Int
    private let writeDelay: TimeInterval
    private(set) var isEnabled = false
    private(set) var entries: [String: HistoryEntry] = [:] {
        didSet { cachedIndex = nil }
    }
    private var cachedIndex: HistoryIndex?
    private var writeScheduled = false
    /// Writes and removals of the file, in the order they were asked for.
    private let io = DispatchQueue(label: "dev.muxify.browser-history", qos: .utility)

    init(file: URL, capacity: Int = BrowserHistory.capacity, writeDelay: TimeInterval = 2) {
        self.file = file
        self.capacity = capacity
        self.writeDelay = writeDelay
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            isEnabled = true
            entries = Self.read(file)
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
        if entries.count > capacity,
           let lowest = entries.values.filter({ $0.key != key }).min(by: { $0.score(at: now) < $1.score(at: now) }) {
            entries[lowest.key] = nil
        }
        changed()
    }

    /// A page changed its title after its load, as a single-page app does for each of its views.
    func updateTitle(of url: String, to title: String) {
        let key = BrowserTab.matchKey(url)
        guard isEnabled, !title.isEmpty, let entry = entries[key], entry.title != title else { return }
        entries[key]?.title = title
        changed()
    }

    /// While it is on, or while the file of an earlier time stays.
    var canClear: Bool { isEnabled || FileManager.default.fileExists(atPath: file.path) }

    /// Forgets the visits of `range` and writes the file at once, also while Browser History is off. An entry with no
    /// visit left goes. All time removes the file.
    func clear(_ range: ClearRange, now: Date = Date()) {
        writeScheduled = false
        guard let duration = range.duration else {
            entries = [:]
            save([])
            return
        }
        let since = now - duration
        func cleared(_ entries: [String: HistoryEntry]) -> [String: HistoryEntry] {
            entries.compactMapValues { entry in
                var entry = entry
                entry.removeVisits(since: since)
                return entry.lastVisit == nil ? nil : entry
            }
        }
        if isEnabled {
            entries = cleared(entries)
            save(Array(entries.values))
        } else {
            save(Array(cleared(Self.read(file)).values))
        }
    }

    /// Writes a pending change now and waits for the file, as the app quits.
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
        save(Array(entries.values))
    }

    /// With no entries it removes the file, so that Clear Browser History is not offered while Browser History is off.
    private func save(_ list: [HistoryEntry]) {
        let file = file
        guard !list.isEmpty else {
            io.async { try? FileManager.default.removeItem(at: file) }
            return
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(list.sorted { $0.key < $1.key })
        } catch {
            Diagnostics.report("cannot encode Browser History: \(error)")
            return
        }
        io.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                Diagnostics.report("cannot write Browser History to \(file.path): \(error)")
            }
        }
    }

    private static func read(_ file: URL) -> [String: HistoryEntry] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        do {
            let cutoff = Date() - HistoryEntry.recentSpan
            let list = try JSONDecoder().decode([HistoryEntry].self, from: data).map { entry in
                var entry = entry
                entry.fold(before: cutoff)
                return entry
            }
            return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            Diagnostics.report("cannot read Browser History from \(file.path): \(error)")
            return [:]
        }
    }
}
