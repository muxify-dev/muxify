import Foundation

/// One card of the Topics list: an open Topic, a Locked Session or an Open Place.
public enum TopicListID: Hashable, Sendable {
    case topic(String)
    case lock(sessionID: String)
    case openPlace(String)
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

/// An Open Place: an In Play place that no card fills, after a regular In Play card left it. It has its order in the
/// Topics list, so the other places keep their positions until the user fills it. The Topic records keep it in the
/// file `open-places` beside them.
public struct OpenPlace: Codable, Hashable, Sendable {
    public let id: String
    public var order: Double

    public init(id: String = UUID().uuidString.lowercased(), order: Double) {
        self.id = id
        self.order = order
    }
}

public enum TopicListEntry: Equatable, Sendable {
    case topic(TopicRecord)
    case lock(SessionLock)
    case openPlace(OpenPlace)

    /// The open and Settled Topics of `records`, the Locks of the Sessions in `windows`, and the Open Places.
    public static func all(records: [TopicRecord], windows: [TmuxWindow], openPlaces: [OpenPlace] = []) -> [TopicListEntry] {
        records.map(TopicListEntry.topic) + SessionLock.locks(in: windows, records: records).map(TopicListEntry.lock)
            + openPlaces.map(TopicListEntry.openPlace)
    }

    public var id: TopicListID {
        switch self {
        case .topic(let record): return .topic(record.id)
        case .lock(let lock): return .lock(sessionID: lock.sessionID)
        case .openPlace(let place): return .openPlace(place.id)
        }
    }

    public var order: Double? {
        switch self {
        case .topic(let record): return record.order
        case .lock(let lock): return lock.order
        case .openPlace(let place): return place.order
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
        case .openPlace: return false
        }
    }

    /// Where the card goes in the cut at the Bench line.
    public var slot: InPlaySlot {
        if case .openPlace = self { return .openPlace }
        return isGuest ? .guest : .regular
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
        case .openPlace(let place): return place.id
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
        case .openPlace(var place):
            place.order = order
            return .openPlace(place)
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

/// What a card is to the cut at the Bench line.
public enum InPlaySlot: Equatable, Sendable {
    /// A Topic that is not a Guest: it takes an In Play place, or waits on the Bench.
    case regular
    /// A Guest Topic or a Guest Session: In Play above the limit, in the Guests section.
    case guest
    /// An In Play place that no card fills.
    case openPlace
}

/// The cards that are not Pinned, cut into three sections. The places are the first `limit` regular cards and Open
/// Places; the Guests are every Guest; the Bench is the other regular cards. An Open Place past the last place holds no
/// place, so no section has it. Each section keeps the order of the list, and a Guest's position among the others has
/// no effect.
public struct InPlayCut<Card> {
    public let places: [Card]
    public let guests: [Card]
    public let bench: [Card]

    public var inPlay: [Card] { places + guests }

    private init(places: [Card], guests: [Card], bench: [Card]) {
        self.places = places
        self.guests = guests
        self.bench = bench
    }

    public func compactMap<T>(_ transform: (Card) -> T?) -> InPlayCut<T> {
        InPlayCut<T>(places: places.compactMap(transform), guests: guests.compactMap(transform), bench: bench.compactMap(transform))
    }

    public init(_ cards: [Card], limit: Int, slot: (Card) -> InPlaySlot) {
        var places: [Card] = [], guests: [Card] = [], bench: [Card] = []
        for card in cards {
            switch slot(card) {
            case .guest: guests.append(card)
            case .openPlace: if places.count < limit { places.append(card) }
            case .regular: if places.count < limit { places.append(card) } else { bench.append(card) }
            }
        }
        self.places = places
        self.guests = guests
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

    public var openPlaces: [OpenPlace] {
        compactMap { if case .openPlace(let place) = $0 { return place }; return nil }
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
    /// With `topics.in_play`: right after the last In Play place while there are fewer places than `inPlay`, else right
    /// before the first Benched card, or last when there is none. A Guest does not count toward `inPlay`.
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
            guard !pinned else { return zone.count }
            let regulars = zone.indices.filter { zone[$0].slot != .guest }
            if regulars.count > inPlay { return regulars[inPlay] }
            return regulars.count < inPlay ? regulars.last.map { $0 + 1 } ?? 0 : zone.count
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

/// What a change of the Topics list writes: the entries with a new order or a new mark, the Locks that end, and the
/// Open Places that close.
public struct TopicListChange: Equatable, Sendable {
    public var entries: [TopicListEntry]
    public var endedLocks: [String]
    public var closedPlaces: [String]

    public init(_ entries: [TopicListEntry], endedLocks: [String] = [], closedPlaces: [String] = []) {
        self.entries = entries
        self.endedLocks = endedLocks
        self.closedPlaces = closedPlaces
    }
}

/// The order of the Topics list. Topics, Locked Sessions and Open Places share it, and a Lock moves, renumbers and
/// clamps by the rules of a Topic that is not Pinned. Each change returns only the entries it changed.
///
/// With `topics.in_play` set, the Sidebar shows the cards that are not Pinned in three sections (`InPlayCut`): the
/// In Play places, the Guests, and the Bench. The changes that take an `inPlay` limit write the order in these
/// sections, so the order of the list is the order that the Sidebar shows.
public enum TopicOrder {
    public enum Failure: Error, CustomStringConvertible {
        case sourceUnavailable, anchorUnavailable
        /// Replace from Bench: the card to replace is not In Play, or the card to take its place is not Benched.
        case notInPlay, notBenched
        /// Choose In Play: a Pinned Topic is neither In Play nor Benched, and each place takes one card.
        case pinned, chosenTwice
        /// A Guest Session cannot take an In Play place, and an In Play card cannot take the position of one.
        case guestSession
        /// Fill an Open Place: the place is not an Open Place, or the card is not a Guest Topic or a Benched Topic.
        case notOpenPlace, cannotFill
        /// Bench Topic: the Topic is not In Play.
        case notInPlayTopic

        public var description: String {
            switch self {
            case .sourceUnavailable: return "The Topic is no longer open."
            case .anchorUnavailable: return "The Topic at the drop position is no longer open."
            case .notInPlay: return "The card to replace is not In Play."
            case .notBenched: return "The card to put In Play is not on the Bench."
            case .pinned: return "A Pinned Topic is neither In Play nor on the Bench."
            case .chosenTwice: return "A card is chosen twice."
            case .guestSession: return "A Guest Session cannot take an In Play place. Make it a Topic first."
            case .notOpenPlace: return "The In Play place is not an Open Place."
            case .cannotFill: return "Only a Guest Topic or a Benched Topic can fill an Open Place."
            case .notInPlayTopic: return "The Topic is not In Play: it is on the Bench, or Pinned."
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

    /// The open cards that are not Pinned, cut into the In Play places, the Guests and the Bench.
    public static func cut(_ entries: [TopicListEntry], inPlay: Int) -> InPlayCut<TopicListEntry> {
        InPlayCut(sorted(entries).filter { !$0.isPinned }, limit: inPlay, slot: \.slot)
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

    /// Choose In Play: the first `inPlay` of `chosen` fill the In Play places in this order, and the places after the
    /// last of them are Open Places. A Guest Topic that fills a place loses its Guest mark. Of the other chosen cards,
    /// the regular ones lead the Bench, and a Guest stays a Guest. The other cards keep their order in their sections.
    public static func choosingInPlay(_ chosen: [TopicListID], inPlay: Int, in entries: [TopicListEntry]) throws -> TopicListChange {
        let original = layout(entries, inPlay: inPlay)
        guard Set(chosen).count == chosen.count else { throw Failure.chosenTwice }
        let cards = try chosen.map { id in
            guard let entry = sorted(entries).first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
            guard !entry.isPinned else { throw Failure.pinned }
            return entry
        }
        let placed = Array(cards.prefix(inPlay))
        guard !placed.contains(where: { if case .lock = $0 { return true } else { return false } }) else { throw Failure.guestSession }
        let leading = cards.dropFirst(inPlay).filter { $0.slot == .regular }
        let taken = Set((placed + leading).map(\.id))
        let open = (placed.count..<inPlay).map { _ in TopicListEntry.openPlace(OpenPlace(order: .nan)) }
        let guests = original.filter { $0.isGuest && !taken.contains($0.id) }
        let bench = original.filter { $0.slot == .regular && !taken.contains($0.id) }
        return rewriting(placed.map { $0.guest(false) } + open + guests + leading + bench, from: original)
    }

    /// Replace from Bench: `benched` takes the position of `card`, and `card` goes to the end of the Bench. Each card
    /// takes the mark of its new section: a Benched card that takes a Guest's position becomes a Guest, a Guest Topic goes
    /// to the Bench without its mark, and the Lock of a Guest Session ends. On an Open Place, `benched` fills it.
    public static func replacingFromBench(_ card: TopicListID, with benched: TopicListID, inPlay: Int,
                                          in entries: [TopicListEntry]) throws -> TopicListChange {
        let original = layout(entries, inPlay: inPlay)
        let cut = cut(entries, inPlay: inPlay)
        guard let position = cut.inPlay.firstIndex(where: { $0.id == card }) else { throw Failure.notInPlay }
        guard let incoming = cut.bench.first(where: { $0.id == benched }) else { throw Failure.notBenched }
        if case .lock = incoming, position < cut.places.count { throw Failure.guestSession }
        let replaced = cut.inPlay[position]
        var inPlay = cut.inPlay
        inPlay[position] = incoming.guest(position >= cut.places.count)
        var zone = inPlay + cut.bench.filter { $0.id != benched }
        var ended: [String] = []
        switch replaced {
        case .lock(let lock): ended.append(lock.sessionID)
        case .openPlace: break
        case .topic: zone.append(replaced.guest(false))
        }
        return rewriting(zone, from: original, endedLocks: ended)
    }

    /// A trade: two cards that are not Pinned exchange their positions, and no other card moves. With `inPlay`, each
    /// card takes the mark of the section it lands in: a Guest that comes into a place loses its Guest mark, and a card
    /// that comes into the Guests section gets it. A Guest Session cannot take a place, and its Lock ends when it goes
    /// to the Bench. An Open Place that leaves the places closes, so a trade with one fills it.
    public static func trading(_ card: TopicListID, with other: TopicListID, inPlay: Int? = nil,
                               in entries: [TopicListEntry]) throws -> TopicListChange {
        let all = sorted(entries)
        guard let source = all.first(where: { $0.id == card }) else { throw Failure.sourceUnavailable }
        guard let anchor = all.first(where: { $0.id == other }) else { throw Failure.anchorUnavailable }
        guard !source.isPinned, !anchor.isPinned else { throw Failure.pinned }
        guard let inPlay else {
            let original = all.filter { !$0.isPinned }
            var zone = original
            zone.swapAt(zone.firstIndex { $0.id == card }!, zone.firstIndex { $0.id == other }!)
            return TopicListChange(normalized(zone, from: original))
        }
        let cut = cut(entries, inPlay: inPlay)
        enum Section { case places, guests, bench }
        func section(_ id: TopicListID) -> Section {
            if cut.places.contains(where: { $0.id == id }) { return .places }
            return cut.guests.contains(where: { $0.id == id }) ? .guests : .bench
        }
        var ended: [String] = []
        func landing(_ entry: TopicListEntry, in section: Section) throws -> TopicListEntry? {
            switch (entry, section) {
            case (.lock, .places): throw Failure.guestSession
            case (.lock(let lock), .bench): ended.append(lock.sessionID); return nil
            case (.openPlace, .guests), (.openPlace, .bench): return nil
            default: return entry.guest(section == .guests)
            }
        }
        let sourceLanded = try landing(source, in: section(other)), anchorLanded = try landing(anchor, in: section(card))
        let original = cut.places + cut.guests + cut.bench
        let zone = original.compactMap { entry -> TopicListEntry? in
            switch entry.id {
            case card: return anchorLanded
            case other: return sourceLanded
            default: return entry
            }
        }
        return rewriting(zone, from: original, endedLocks: ended)
    }

    /// Make a Guest: the Benched Topic goes to the end of the Guests with the Guest mark, and no other card moves.
    public static func makingGuest(_ id: String, inPlay: Int, in entries: [TopicListEntry]) throws -> TopicListChange {
        guard let entry = sorted(entries).first(where: { $0.id == .topic(id) }) else { throw Failure.sourceUnavailable }
        guard !entry.isPinned else { throw Failure.pinned }
        let cut = cut(entries, inPlay: inPlay)
        guard cut.bench.contains(where: { $0.id == entry.id }) else { throw Failure.notBenched }
        return rewriting(cut.places + cut.guests + [entry.guest(true)] + cut.bench.filter { $0.id != entry.id },
                         from: layout(entries, inPlay: inPlay))
    }

    /// Bench Topic: the In Play Topic goes to the top of the Bench without a Guest mark. A Topic in a place leaves an
    /// Open Place there; a Guest Topic leaves none, so the Guests section gets shorter.
    public static func benching(_ id: String, inPlay: Int, in entries: [TopicListEntry]) throws -> TopicListChange {
        guard let entry = sorted(entries).first(where: { $0.id == .topic(id) }) else { throw Failure.sourceUnavailable }
        let cut = cut(entries, inPlay: inPlay)
        let places = cut.places.map { $0.id == entry.id ? .openPlace(OpenPlace(order: .nan)) : $0 }
        guard places != cut.places || cut.guests.contains(where: { $0.id == entry.id }) else { throw Failure.notInPlayTopic }
        return rewriting(places + cut.guests.filter { $0.id != entry.id } + [entry.guest(false)] + cut.bench,
                         from: layout(entries, inPlay: inPlay))
    }

    /// Fill an Open Place: a Guest Topic or a Benched Topic takes the place, without a Guest mark. It is a trade with
    /// the Open Place, so no other card moves.
    public static func fillingOpenPlace(_ place: String, with id: String, inPlay: Int, in entries: [TopicListEntry]) throws -> TopicListChange {
        let cut = cut(entries, inPlay: inPlay)
        guard cut.places.contains(where: { $0.id == .openPlace(place) }) else { throw Failure.notOpenPlace }
        guard (cut.guests + cut.bench).contains(where: { $0.id == .topic(id) }) else { throw Failure.cannotFill }
        return try trading(.openPlace(place), with: .topic(id), inPlay: inPlay, in: entries)
    }

    /// The order after a change that took cards out of the list, such as Settle, Forget, Pin or the end of a Lock: each
    /// regular card that left an In Play place `before` leaves an Open Place there, so no other card moves. A Guest that
    /// leaves leaves no Open Place. Each Open Place past the last place, or any Open Place without `inPlay`, closes.
    public static func keepingPlaces(from before: [TopicListEntry], in after: [TopicListEntry], inPlay: Int?) -> TopicListChange {
        let zone = sorted(after).filter { !$0.isPinned }
        guard let inPlay else { return TopicListChange([], closedPlaces: zone.openPlaces.map(\.id)) }
        let ids = Set(zone.map(\.id))
        let left = cut(before, inPlay: inPlay).places.enumerated().filter { _, entry in
            if case .topic = entry { return !ids.contains(entry.id) }
            return false
        }.map(\.offset)
        guard !left.isEmpty else {
            let held = Set(InPlayCut(zone, limit: inPlay, slot: \.slot).places.map(\.id))
            return TopicListChange([], closedPlaces: zone.openPlaces.map(\.id).filter { !held.contains(.openPlace($0)) })
        }
        var regulars = zone.filter { $0.slot != .guest }
        for index in left { regulars.insert(.openPlace(OpenPlace(order: .nan)), at: min(index, regulars.count)) }
        let cut = InPlayCut(regulars, limit: inPlay, slot: \.slot)
        return rewriting(cut.places + zone.filter(\.isGuest) + cut.bench, from: zone)
    }

    /// The order in the three sections, as the Sidebar shows it: what `topics.in_play` does to the Locked Sessions when
    /// the Config sets it. A list in that order does not change.
    public static func gatheringGuests(inPlay: Int, in entries: [TopicListEntry]) -> TopicListChange {
        let zone = sorted(entries).filter { !$0.isPinned }
        return rewriting(layout(entries, inPlay: inPlay), from: zone)
    }

    /// Locks the Session last among the entries that are not Pinned, or with `inPlay` at the end of the Guests.
    static func appendingLock(of sessionID: String, inPlay: Int? = nil, in entries: [TopicListEntry]) -> [TopicListEntry] {
        // NaN is never an index, so a renumber gives the new Lock its order too.
        let source = TopicListEntry.lock(SessionLock(sessionID: sessionID, order: .nan))
        if let inPlay {
            let cut = cut(entries, inPlay: inPlay)
            return normalized(cut.places + cut.guests + [source] + cut.bench, from: layout(entries, inPlay: inPlay))
        }
        let original = sorted(entries)
        let zone = original.filter { !$0.isPinned } + [source]
        return placing(source, at: zone.count - 1, in: zone, others: original.filter(\.isPinned))
    }

    /// The open cards that are not Pinned, in the three sections, with each Open Place past the last place.
    private static func layout(_ entries: [TopicListEntry], inPlay: Int) -> [TopicListEntry] {
        let zone = sorted(entries).filter { !$0.isPinned }
        let cut = InPlayCut(zone, limit: inPlay, slot: \.slot)
        let shown = Set((cut.places + cut.guests + cut.bench).map(\.id))
        return cut.places + cut.guests + cut.bench + zone.filter { !shown.contains($0.id) }
    }

    /// `zone` numbered 0, 1, 2…: the entries that changed from `original`, and each Open Place of `original` that
    /// `zone` does not hold any more.
    private static func rewriting(_ zone: [TopicListEntry], from original: [TopicListEntry], endedLocks: [String] = []) -> TopicListChange {
        let kept = Set(zone.map(\.id))
        return TopicListChange(normalized(zone, from: original), endedLocks: endedLocks,
                               closedPlaces: original.openPlaces.map(\.id).filter { !kept.contains(.openPlace($0)) })
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
