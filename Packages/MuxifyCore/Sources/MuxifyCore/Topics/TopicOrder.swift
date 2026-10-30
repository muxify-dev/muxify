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

/// What a write of the Topics list changes in tmux: a Lock gets a new order, or a Lock ends.
public enum SessionLockChange: Equatable, Sendable {
    case set(SessionLock)
    case end(sessionID: String)

    public var sessionID: String {
        switch self {
        case .set(let lock): return lock.sessionID
        case .end(let sessionID): return sessionID
        }
    }

    public var command: [String] {
        switch self {
        case .set(let lock): return lock.setOption
        case .end(let sessionID): return SessionLock.unsetOption(sessionID)
        }
    }
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

    /// Whether the card is a Guest while `topics.in_play` is set. A Locked Session is always a Guest then.
    public var isGuest: Bool {
        switch self {
        case .topic(let record): return record.isGuest && !record.isPinned
        case .lock: return true
        }
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

    /// A Pinned Topic is not In Play, so Pin also ends its Guest mark.
    fileprivate func pinned(_ pinned: Bool) -> TopicListEntry {
        guard case .topic(var record) = self else { return self }
        record.isPinned = pinned
        if pinned { record.isGuest = false }
        return .topic(record)
    }

    fileprivate func guest(_ guest: Bool) -> TopicListEntry {
        guard case .topic(var record) = self else { return self }
        record.isGuest = guest
        return .topic(record)
    }
}

/// The cards that are not Pinned, cut at the Bench line. In Play is every Guest and the first `limit` other cards;
/// the Bench is the other cards. Each part keeps the order of the list. While the list is in the order that
/// `TopicOrder` writes, In Play is the first `limit` + Guests cards.
public struct InPlayCut<Card> {
    public let inPlay: [Card]
    public let bench: [Card]

    public init(_ cards: [Card], limit: Int, isGuest: (Card) -> Bool) {
        var inPlay: [Card] = [], bench: [Card] = [], regular = 0
        for card in cards {
            if isGuest(card) {
                inPlay.append(card)
            } else if regular < limit {
                regular += 1
                inPlay.append(card)
            } else {
                bench.append(card)
            }
        }
        self.inPlay = inPlay
        self.bench = bench
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
    /// With `topics.in_play`: right before the first Benched card, or last when there is none. A Guest is In Play and
    /// does not count toward `inPlay`.
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
        case .topOfBench(let inPlay):
            let regulars = zone.indices.filter { !zone[$0].isGuest }
            return !pinned && regulars.count > inPlay ? regulars[inPlay] : zone.count
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

/// What a change of the Topics list writes: the entries with a new order or a new mark, and the Locks that end.
public struct TopicListChange: Equatable, Sendable {
    public var entries: [TopicListEntry]
    public var endedLocks: [String]

    public init(_ entries: [TopicListEntry], endedLocks: [String] = []) {
        self.entries = entries
        self.endedLocks = endedLocks
    }
}

/// The order of the Topics list. Topics and Locked Sessions share it, and a Lock moves, renumbers and clamps by the
/// rules of a Topic that is not Pinned. Each change returns only the entries it changed.
///
/// With `topics.in_play` set, the changes that take an `inPlay` limit also keep the Guests (ADR 0061): In Play is the
/// Guests and the first `inPlay` other cards, and the order that these changes write puts In Play before the Bench.
public enum TopicOrder {
    public enum Failure: Error, CustomStringConvertible {
        case sourceUnavailable, anchorUnavailable
        /// Replace from Bench: the card to replace is not In Play, or the card to take its place is not Benched.
        case notInPlay, notBenched
        /// Choose In Play: a Pinned Topic is neither In Play nor Benched, and each place takes one card.
        case pinned, chosenTwice
        /// Choose In Play: a Guest keeps its place, so it cannot fill one.
        case guest

        public var description: String {
            switch self {
            case .sourceUnavailable: return "The Topic is no longer open."
            case .anchorUnavailable: return "The Topic at the drop position is no longer open."
            case .notInPlay: return "The card to replace is not In Play."
            case .notBenched: return "The card to put In Play is not on the Bench."
            case .pinned: return "A Pinned Topic is neither In Play nor on the Bench."
            case .chosenTwice: return "A card is chosen twice."
            case .guest: return "A Guest is In Play already, and it keeps its place. End Guest first."
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

    /// The open cards that are not Pinned, cut at the Bench line.
    public static func cut(_ entries: [TopicListEntry], inPlay: Int) -> InPlayCut<TopicListEntry> {
        InPlayCut(sorted(entries).filter { !$0.isPinned }, limit: inPlay, isGuest: \.isGuest)
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

    /// Pin puts the Topic last among the Pinned Topics and ends its Guest mark. Unpin puts it first among the others,
    /// or with `inPlay` at the top of the Bench, where a new Topic goes.
    public static func pinning(_ id: String, _ pinned: Bool, inPlay: Int? = nil, in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        let original = sorted(entries)
        guard let found = original.first(where: { $0.id == .topic(id) }) else { throw Failure.sourceUnavailable }
        guard found.isPinned != pinned else { return [] }
        let source = found.pinned(pinned)
        if !pinned, let inPlay, case .topic(let record) = source {
            return inserting(record, at: .topOfBench(inPlay: inPlay), in: entries)
        }
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

    /// Choose In Play: `chosen` fill the In Play places in this order, and the ones after the last place lead the
    /// Bench. A place is a position that no Guest holds, so each Guest keeps its position. The other cards keep their
    /// order under the chosen ones.
    public static func choosingInPlay(_ chosen: [TopicListID], inPlay: Int, in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        let zone = layout(entries, inPlay: inPlay)
        guard Set(chosen).count == chosen.count else { throw Failure.chosenTwice }
        let first = try chosen.map { id in
            guard let entry = sorted(entries).first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
            guard !entry.isPinned else { throw Failure.pinned }
            guard !entry.isGuest else { throw Failure.guest }
            return entry
        }
        let rest = zone.filter { !$0.isGuest && !chosen.contains($0.id) }
        return normalized(laying(guestPositions(in: zone), regulars: first + rest, inPlay: inPlay), from: zone)
    }

    /// Replace from Bench: `benched` takes the place of `card`, and `card` goes to the end of the Bench. When `card` is
    /// a Guest, `benched` takes its Guest mark too: a Guest Topic goes to the Bench without it, and the Lock of a Guest
    /// Session ends.
    public static func replacingFromBench(_ card: TopicListID, with benched: TopicListID, inPlay: Int,
                                          in entries: [TopicListEntry]) throws -> TopicListChange {
        let original = layout(entries, inPlay: inPlay)
        let cut = InPlayCut(original, limit: inPlay, isGuest: \.isGuest)
        guard let place = cut.inPlay.firstIndex(where: { $0.id == card }) else { throw Failure.notInPlay }
        guard cut.bench.contains(where: { $0.id == benched }) else { throw Failure.notBenched }
        var zone = original
        let replaced = zone[place]
        let incoming = zone.remove(at: zone.firstIndex { $0.id == benched }!)
        guard replaced.isGuest else {
            zone[place] = incoming
            zone.append(replaced)
            return TopicListChange(normalized(zone, from: original))
        }
        zone[place] = incoming.guest(true)
        guard case .lock(let lock) = replaced else {
            zone.append(replaced.guest(false))
            return TopicListChange(normalized(zone, from: original))
        }
        return TopicListChange(normalized(zone, from: original), endedLocks: [lock.sessionID])
    }

    /// A trade: two cards that are not Pinned exchange their places, and no other card moves. So across the Bench line,
    /// one goes In Play and the other goes to the Bench, and the line stays under the same number of cards. With
    /// `inPlay`, a Guest that a trade takes to the Bench gives its Guest mark to the card that comes In Play: a Guest
    /// Topic goes to the Bench without it, and the Lock of a Guest Session ends.
    public static func trading(_ card: TopicListID, with other: TopicListID, inPlay: Int? = nil,
                               in entries: [TopicListEntry]) throws -> TopicListChange {
        let all = sorted(entries)
        guard let source = all.first(where: { $0.id == card }) else { throw Failure.sourceUnavailable }
        guard let anchor = all.first(where: { $0.id == other }) else { throw Failure.anchorUnavailable }
        guard !source.isPinned, !anchor.isPinned else { throw Failure.pinned }
        let original = inPlay.map { layout(entries, inPlay: $0) } ?? all.filter { !$0.isPinned }
        var zone = original
        let from = zone.firstIndex { $0.id == card }!, to = zone.firstIndex { $0.id == other }!
        zone.swapAt(from, to)
        guard let inPlay else { return TopicListChange(normalized(zone, from: original)) }
        let inPlayIDs = Set(InPlayCut(original, limit: inPlay, isGuest: \.isGuest).inPlay.map(\.id))
        let crossing = inPlayIDs.contains(card) != inPlayIDs.contains(other)
        // After the swap, the In Play position holds the card that comes in, and the other position the card that leaves.
        let (place, leaving) = inPlayIDs.contains(card) ? (from, to) : (to, from)
        guard crossing, zone[leaving].isGuest else { return TopicListChange(normalized(zone, from: original)) }
        zone[place] = zone[place].guest(true)
        guard case .lock(let lock) = zone[leaving] else {
            zone[leaving] = zone[leaving].guest(false)
            return TopicListChange(normalized(zone, from: original))
        }
        zone.remove(at: leaving)
        return TopicListChange(normalized(zone, from: original), endedLocks: [lock.sessionID])
    }

    /// Make a Guest: the Benched Topic goes to the end of In Play with the Guest mark, and no other card goes to the
    /// Bench.
    public static func makingGuest(_ id: String, inPlay: Int, in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        guard let entry = sorted(entries).first(where: { $0.id == .topic(id) }) else { throw Failure.sourceUnavailable }
        guard !entry.isPinned else { throw Failure.pinned }
        let original = layout(entries, inPlay: inPlay)
        let cut = InPlayCut(original, limit: inPlay, isGuest: \.isGuest)
        guard cut.bench.contains(where: { $0.id == entry.id }) else { throw Failure.notBenched }
        return normalized(cut.inPlay + [entry.guest(true)] + cut.bench.filter { $0.id != entry.id }, from: original)
    }

    /// End Guest: the Topic goes to the top of the Bench without its Guest mark, so In Play is one card shorter. The
    /// other Guests keep their positions. A Topic that is not a Guest does not change.
    public static func endingGuest(_ id: String, inPlay: Int, in entries: [TopicListEntry]) throws -> [TopicListEntry] {
        guard let entry = sorted(entries).first(where: { $0.id == .topic(id) }) else { throw Failure.sourceUnavailable }
        guard entry.isGuest else { return [] }
        let original = layout(entries, inPlay: inPlay)
        let cut = InPlayCut(original, limit: inPlay, isGuest: \.isGuest)
        let others = cut.inPlay.filter { $0.id != entry.id }
        let regulars = others.filter { !$0.isGuest } + [entry.guest(false)] + cut.bench
        return normalized(laying(guestPositions(in: others), regulars: regulars, inPlay: inPlay), from: original)
    }

    /// The order after a change that took cards out of the list, such as Settle, Pin or the end of a Lock: each Guest
    /// that was In Play `before` keeps its position, and a Guest that the change made takes the position it has now. The
    /// other cards fill the other positions in their order, so the top Benched card fills a free place; a Guest past
    /// the new end of In Play goes to the end.
    public static func keepingGuestPlaces(from before: [TopicListEntry], in after: [TopicListEntry], inPlay: Int) -> [TopicListEntry] {
        let was = InPlayCut(sorted(before).filter { !$0.isPinned }, limit: inPlay, isGuest: \.isGuest).inPlay
        let zone = sorted(after).filter { !$0.isPinned }
        let now = guestPositions(in: InPlayCut(zone, limit: inPlay, isGuest: \.isGuest).inPlay).map { position, entry in
            (position: was.firstIndex { $0.id == entry.id && $0.isGuest } ?? position, entry: entry)
        }
        return normalized(laying(now, regulars: zone.filter { !$0.isGuest }, inPlay: inPlay), from: zone)
    }

    /// The Guests go to the end of In Play, in their order: what `topics.in_play` does to the Locked Sessions when the
    /// Config sets it. A list in that order does not change.
    public static func gatheringGuests(inPlay: Int, in entries: [TopicListEntry]) -> [TopicListEntry] {
        let zone = sorted(entries).filter { !$0.isPinned }
        let regulars = zone.filter { !$0.isGuest }
        return normalized(Array(regulars.prefix(inPlay)) + zone.filter(\.isGuest) + regulars.dropFirst(inPlay), from: zone)
    }

    /// Locks the Session last among the entries that are not Pinned, or with `inPlay` at the end of In Play, as a Guest.
    static func appendingLock(of sessionID: String, inPlay: Int? = nil, in entries: [TopicListEntry]) -> [TopicListEntry] {
        // NaN is never an index, so a renumber gives the new Lock its order too.
        let source = TopicListEntry.lock(SessionLock(sessionID: sessionID, order: .nan))
        if let inPlay {
            let original = layout(entries, inPlay: inPlay)
            let cut = InPlayCut(original, limit: inPlay, isGuest: \.isGuest)
            return normalized(cut.inPlay + [source] + cut.bench, from: original)
        }
        let original = sorted(entries)
        let zone = original.filter { !$0.isPinned } + [source]
        return placing(source, at: zone.count - 1, in: zone, others: original.filter(\.isPinned))
    }

    /// The open cards that are not Pinned, In Play first, then the Bench.
    private static func layout(_ entries: [TopicListEntry], inPlay: Int) -> [TopicListEntry] {
        let cut = cut(entries, inPlay: inPlay)
        return cut.inPlay + cut.bench
    }

    /// The position of each Guest among `inPlay`.
    private static func guestPositions(in inPlay: [TopicListEntry]) -> [(position: Int, entry: TopicListEntry)] {
        inPlay.enumerated().filter { $0.element.isGuest }.map { (position: $0.offset, entry: $0.element) }
    }

    /// The cards that are not Pinned, when each Guest holds its position In Play. The first `inPlay` of `regulars` fill
    /// the other positions in their order, and the rest of them are the Bench. A Guest whose position is past the end
    /// of In Play goes to the end of it.
    private static func laying(_ guests: [(position: Int, entry: TopicListEntry)], regulars: [TopicListEntry],
                               inPlay: Int) -> [TopicListEntry] {
        var waiting = guests.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element)[...]
        var places = regulars.prefix(inPlay)
        var laid: [TopicListEntry] = []
        while !waiting.isEmpty || !places.isEmpty {
            if let next = waiting.first, next.position <= laid.count || places.isEmpty {
                laid.append(next.entry)
                waiting = waiting.dropFirst()
            } else {
                laid.append(places.removeFirst())
            }
        }
        return laid + regulars.dropFirst(inPlay)
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

    /// Numbers `entries` 0, 1, 2… and returns those that differ from their entry in `original`: a new order, a new
    /// mark, or an entry that `original` does not have.
    private static func normalized(_ entries: [TopicListEntry], from original: [TopicListEntry]? = nil) -> [TopicListEntry] {
        let original = original ?? entries
        return entries.enumerated().compactMap { index, entry in
            let placed = entry.with(order: Double(index))
            return original.contains(placed) ? nil : placed
        }
    }
}
