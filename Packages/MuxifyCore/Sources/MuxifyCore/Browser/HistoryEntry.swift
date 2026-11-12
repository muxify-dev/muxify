import Foundation

/// One page in Browser History (ADR 0059).
public struct HistoryEntry: Codable, Equatable, Sendable {
    /// A visit of the last `recentSpan`, kept on its own so that Clear Browser History can remove it.
    public struct Visit: Codable, Equatable, Sendable {
        public let at: Date
        public let weight: Double

        public init(at: Date, weight: Double) {
            self.at = at
            self.weight = weight
        }
    }

    /// The visits before the recent ones, as one score at the time of the newest of them.
    public struct Folded: Codable, Equatable, Sendable {
        public let score: Double
        public let at: Date

        public init(score: Double, at: Date) {
            self.score = score
            self.at = at
        }
    }

    /// `BrowserTab.matchKey` of the URL.
    public var key: String
    public var url: String
    public var title: String
    public var folded: Folded?
    /// Oldest first.
    public var recent: [Visit]
    /// The Topics of the Windows where the user loaded the page.
    public var topics: Set<String>

    public static let halfLife: TimeInterval = 14 * 86_400
    public static let recentSpan: TimeInterval = 7 * 86_400

    public init(key: String, url: String, title: String, folded: Folded? = nil, recent: [Visit] = [], topics: Set<String>) {
        self.key = key
        self.url = url
        self.title = title
        self.folded = folded
        self.recent = recent
        self.topics = topics
    }

    /// The sum of the weights of every visit, each halved for each `halfLife` since that visit.
    public func score(at now: Date) -> Double {
        let base = folded.map { Self.decay($0.score, from: $0.at, to: now) } ?? 0
        return recent.reduce(base) { $0 + Self.decay($1.weight, from: $1.at, to: now) }
    }

    /// Nil when no visit is left, after a clear.
    public var lastVisit: Date? { recent.last?.at ?? folded?.at }

    public mutating func add(_ visit: Visit) {
        recent.append(visit)
        fold(before: visit.at - Self.recentSpan)
    }

    /// Moves the recent visits before `cutoff` into the folded score.
    public mutating func fold(before cutoff: Date) {
        while let oldest = recent.first, oldest.at < cutoff {
            recent.removeFirst()
            let base = folded.map { Self.decay($0.score, from: $0.at, to: oldest.at) } ?? 0
            folded = Folded(score: base + oldest.weight, at: oldest.at)
        }
    }

    /// Removes the visits at or after `since`. A folded score that holds such a visit goes as a whole, because it
    /// cannot tell its visits apart. Only an entry imported from a file of before the recent visits were kept has one.
    public mutating func removeVisits(since: Date) {
        recent.removeAll { $0.at >= since }
        if let folded, folded.at >= since { self.folded = nil }
    }

    private static func decay(_ score: Double, from then: Date, to now: Date) -> Double {
        score * pow(0.5, max(0, now.timeIntervalSince(then)) / halfLife)
    }

    private enum CodingKeys: String, CodingKey { case key, url, title, folded, recent, topics }
    /// The shape of a file from before the recent visits were kept: one score at the last visit.
    private enum ScoreAtLastVisitKeys: String, CodingKey { case score, lastVisit }

    public init(from decoder: Decoder) throws {
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
