import Foundation

/// One card of the Topics list: an open Topic or a Locked Session.
public enum TopicListID: Hashable, Sendable {
    case topic(String)
    case lock(sessionID: String)
}

/// A Locked Session's place in the Topics list (ADR 0018). tmux keeps it in the Session option `@muxify_lock`, in the
/// same order scale as the Topic records.
public struct SessionLock: Hashable, Sendable {
    public static let option = "@muxify_lock"

    public let sessionID: String
    public var order: Double

    public init(sessionID: String, order: Double) {
        self.sessionID = sessionID
        self.order = order
    }

    /// The Locks of the Sessions in `windows`. Only a No Topic Session can be Locked, so a Session in an open Topic
    /// has no Lock, whatever its option says.
    public static func locks(in windows: [TmuxWindow], records: [TopicRecord]) -> [SessionLock] {
        let open = Set(records.filter { $0.settledAt == nil }.map(\.id))
        var seen: Set<String> = []
        return windows.compactMap { window in
            guard seen.insert(window.sessionID).inserted, let order = window.lockOrder,
                  window.topicID.map({ !open.contains($0) }) ?? true else { return nil }
            return SessionLock(sessionID: window.sessionID, order: order)
        }
    }

    public var setOption: [String] { ["set-option", "-t", sessionID, Self.option, String(order)] }

    /// The tmux command that ends the Lock of a Session.
    public static func unsetOption(_ sessionID: String) -> [String] { ["set-option", "-u", "-t", sessionID, option] }
}

public enum TopicListEntry: Equatable, Sendable {
    case topic(TopicRecord)
    case lock(SessionLock)

    /// The open and Settled Topics of `records`, and the Locks of the Sessions in `windows`.
    public static func all(records: [TopicRecord], windows: [TmuxWindow]) -> [TopicListEntry] {
        records.map(TopicListEntry.topic) + SessionLock.locks(in: windows, records: records).map(TopicListEntry.lock)
    }

    public var id: TopicListID {
        switch self {
        case .topic(let record): return .topic(record.id)
        case .lock(let lock): return .lock(sessionID: lock.sessionID)
        }
    }

    public var order: Double? {
        switch self {
        case .topic(let record): return record.order
        case .lock(let lock): return lock.order
        }
    }

    /// A Lock is never Pinned.
    public var isPinned: Bool {
        if case .topic(let record) = self { return record.isPinned }
        return false
    }

    fileprivate var isOpen: Bool {
        if case .topic(let record) = self { return record.settledAt == nil }
        return true
    }

    fileprivate var createdAt: String {
        if case .topic(let record) = self { return record.createdAt ?? "" }
        return ""
    }

    fileprivate var tieBreak: String {
        switch self {
        case .topic(let record): return record.id
        case .lock(let lock): return lock.sessionID
        }
    }

    fileprivate func with(order: Double) -> TopicListEntry {
        switch self {
        case .topic(var record):
            record.order = order
            return .topic(record)
        case .lock(var lock):
            lock.order = order
            return .lock(lock)
        }
    }

    fileprivate func pinned(_ pinned: Bool) -> TopicListEntry {
        guard case .topic(var record) = self else { return self }
        record.isPinned = pinned
        return .topic(record)
    }
}

extension Array where Element == TopicListEntry {
    public var records: [TopicRecord] {
        compactMap { if case .topic(let record) = $0 { return record }; return nil }
    }

    public var locks: [SessionLock] {
        compactMap { if case .lock(let lock) = $0 { return lock }; return nil }
    }
}

public enum TopicInsertPosition: String, CaseIterable, Sendable {
    case top, bottom
}

/// Where a new Topic goes in the Topics list, and a Topic that Reopen or Start Fresh brings back. The Config gives it
/// once, so no caller asks two settings.
public enum TopicArrival: Equatable, Sendable {
    /// Without `topics.in_play`: the `topics.insert_position` end of the cards with the Topic's Pin.
    case end(TopicInsertPosition)
    /// With `topics.in_play`: right after the first `inPlay` cards that are not Pinned, or last when there are fewer.
    /// A Pinned Topic has no Bench, so it goes last among the Pinned Topics, as Pin puts it.
    case topOfBench(inPlay: Int)

    public init(inPlay: Int?, insertPosition: TopicInsertPosition) {
        self = inPlay.map { .topOfBench(inPlay: $0) } ?? .end(insertPosition)
    }

    /// The index in `zone`, the cards with the Topic's Pin without the Topic, where it goes.
    func index(in zone: [TopicListEntry], pinned: Bool) -> Int {
        switch self {
        case .end(.top): return 0
        case .end(.bottom): return zone.count
        case .topOfBench(let inPlay): return pinned ? zone.count : min(inPlay, zone.count)
        }
    }
}

extension Config.Topics {
    public var arrival: TopicArrival { TopicArrival(inPlay: inPlay, insertPosition: insertPosition) }
}

public enum TopicPlacement: Equatable, Sendable {
    case before(TopicListID)
    case after(TopicListID)

    public var anchorID: TopicListID {
        switch self {
        case .before(let id), .after(let id): return id
        }
    }
}

/// The order of the Topics list. Topics and Locked Sessions share it, and a Lock moves, renumbers and clamps by the
/// rules of a Topic that is not Pinned. Each change returns only the entries it changed.
public enum TopicOrder {
    public enum Failure: Error, CustomStringConvertible {
        case sourceUnavailable, anchorUnavailable
        /// Replace from Bench: the card to replace is not In Play, or the card to take its place is not Benched.
        case notInPlay, notBenched
        /// Choose In Play: a Pinned Topic is neither In Play nor Benched, and each place takes one card.
        case pinned, chosenTwice

        public var description: String {
            switch self {
            case .sourceUnavailable: return "The Topic is no longer open."
            case .anchorUnavailable: return "The Topic at the drop position is no longer open."
            case .notInPlay: return "The card to replace is not In Play."
            case .notBenched: return "The card to put In Play is not on the Bench."
            case .pinned: return "A Pinned Topic is neither In Play nor on the Bench."
            case .chosenTwice: return "A card is chosen twice."
            }
        }
    }

    /// The Pinned Topics first, then the others; each part in its own hand-set order.
    public static func sorted(_ entries: [TopicListEntry]) -> [TopicListEntry] {
        entries.filter(\.isOpen).sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.tieBreak < $1.tieBreak
        }
    }

    /// A move stays among the entries with the same pin: an anchor in the other part puts the entry at the edge of its own.
    public static func moving(_ id: TopicListID, to placement: TopicPlacement, in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        let original = sorted(entries)
        guard let source = original.first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
        guard let anchor = original.first(where: { $0.id == placement.anchorID }) else { throw Failure.anchorUnavailable }
        let zone = original.filter { $0.isPinned == source.isPinned }
        let target: TopicPlacement
        if anchor.isPinned == source.isPinned { target = placement }
        else { target = source.isPinned ? .after(zone.last!.id) : .before(zone.first!.id) }
        guard id != target.anchorID else { return [] }
        var ordered = zone.filter { $0.id != id }
        let anchorIndex = ordered.firstIndex { $0.id == target.anchorID }!
        let index: Int
        switch target {
        case .before: index = anchorIndex
        case .after: index = anchorIndex + 1
        }
        ordered.insert(source, at: index)
        guard ordered.map(\.id) != zone.map(\.id) else { return [] }
        return placing(source, at: index, in: ordered, others: original.filter { $0.isPinned != source.isPinned })
    }

    /// Pin puts the Topic last among the Pinned Topics; Unpin puts it first among the others.
    public static func pinning(_ id: String, _ pinned: Bool, in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        let original = sorted(entries)
        guard let found = original.first(where: { $0.id == .topic(id) }) else { throw Failure.sourceUnavailable }
        guard found.isPinned != pinned else { return [] }
        let source = found.pinned(pinned)
        var zone = original.filter { $0.isPinned == pinned }
        let index = pinned ? zone.count : 0
        zone.insert(source, at: index)
        return placing(source, at: index, in: zone, others: original.filter { $0.isPinned != pinned && $0.id != source.id })
    }

    /// Places a new or returning Topic where `arrival` puts it among the entries with its pin.
    public static func inserting(_ record: TopicRecord, at arrival: TopicArrival, in entries: [TopicListEntry]) -> [TopicListEntry] {
        let original = sorted(entries).filter { $0.id != .topic(record.id) }
        let source = TopicListEntry.topic(record)
        var zone = original.filter { $0.isPinned == record.isPinned }
        let index = arrival.index(in: zone, pinned: record.isPinned)
        zone.insert(source, at: index)
        return placing(source, at: index, in: zone, others: original.filter { $0.isPinned != record.isPinned })
    }

    /// Choose In Play: `chosen` go first among the entries that are not Pinned, in this order. So they fill the In Play
    /// places, and the ones after the last place lead the Bench. The other entries keep their order under them.
    public static func choosingInPlay(_ chosen: [TopicListID], in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        let original = sorted(entries)
        guard Set(chosen).count == chosen.count else { throw Failure.chosenTwice }
        let first = try chosen.map { id in
            guard let entry = original.first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
            guard !entry.isPinned else { throw Failure.pinned }
            return entry
        }
        return normalized(first + original.filter { !$0.isPinned && !chosen.contains($0.id) })
    }

    /// Replace from Bench: `benched` takes the place of `card`, and `card` goes to the end of the Bench. The first
    /// `inPlay` entries that are not Pinned are In Play; the others are Benched.
    public static func replacingFromBench(_ card: TopicListID, with benched: TopicListID, inPlay: Int,
                                          in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        var zone = sorted(entries).filter { !$0.isPinned }
        guard let place = zone.firstIndex(where: { $0.id == card }), place < inPlay else { throw Failure.notInPlay }
        guard let index = zone.firstIndex(where: { $0.id == benched }), index >= inPlay else { throw Failure.notBenched }
        let replaced = zone[place]
        let incoming = zone.remove(at: index)
        zone[place] = incoming
        zone.append(replaced)
        return normalized(zone)
    }

    /// Locks the Session last among the entries that are not Pinned.
    static func appendingLock(of sessionID: String, in entries: [TopicListEntry]) -> [TopicListEntry] {
        let original = sorted(entries)
        // NaN is never an index, so a renumber gives the new Lock its order too.
        let source = TopicListEntry.lock(SessionLock(sessionID: sessionID, order: .nan))
        let zone = original.filter { !$0.isPinned } + [source]
        return placing(source, at: zone.count - 1, in: zone, others: original.filter(\.isPinned))
    }

    /// Gives `source`, at `index` in `zone`, an order between its neighbors there, or renumbers every open entry
    /// when no order fits between them.
    private static func placing(_ source: TopicListEntry, at index: Int, in zone: [TopicListEntry], others: [TopicListEntry]) -> [TopicListEntry] {
        if let value = rank(between: index > 0 ? rank(zone[index - 1]) : nil,
                            and: index + 1 < zone.count ? rank(zone[index + 1]) : nil) {
            return [source.with(order: value)]
        }
        let renumbered = normalized(source.isPinned ? zone + others : others + zone)
        return renumbered.contains { $0.id == source.id } ? renumbered : renumbered + [source]
    }

    private static func rank(_ entry: TopicListEntry) -> Double {
        guard let order = entry.order, order.isFinite else { return 0 }
        return order
    }

    private static func rank(between lower: Double?, and upper: Double?) -> Double? {
        let candidate: Double
        switch (lower, upper) {
        case (nil, nil): return -1
        case (nil, let upper?): candidate = upper - 1 < upper ? upper - 1 : upper.nextDown
        case (let lower?, nil): candidate = lower + 1 > lower ? lower + 1 : lower.nextUp
        case (let lower?, let upper?):
            guard lower < upper else { return nil }
            let midpoint = lower / 2 + upper / 2
            candidate = midpoint > lower && midpoint < upper ? midpoint : lower.nextUp
        }
        guard candidate.isFinite, lower.map({ candidate > $0 }) ?? true,
              upper.map({ candidate < $0 }) ?? true else { return nil }
        return candidate
    }

    private static func normalized(_ entries: [TopicListEntry]) -> [TopicListEntry] {
        entries.enumerated().compactMap { index, entry in
            guard entry.order != Double(index) else { return nil }
            return entry.with(order: Double(index))
        }
    }
}
