import Foundation

/// One card of the Board: an open Topic, a Board Session or an Open Place.
public enum BoardCardID: Hashable, Sendable {
    case topic(String)
    /// A Board Session, by its id: the row id of the `board_sessions` table.
    case session(String)
    case openPlace(String)
}

/// A Board Session: the row of the `board_sessions` table that gives a No Topic Session a card on the Board. It keeps
/// the card's order, in the same scale as the Topic records, its Pin, its Guest mark, and the Session's Remembered Session, in
/// the shape of one entry of a Topic record's `sessions`. The live Session points at it with `@muxify_session_id`, so a
/// tmux restart does not end it: with no such Session, the Board Session is Dormant, and Reopen creates its Session again.
public struct BoardSession: Codable, Equatable, Sendable {
    /// The tmux option where an older Muxify kept the order of a Session's card, its Lock. Muxify reads it once, to
    /// import that card as a Board Session among the Guests.
    public static let legacyOption = "@muxify_lock"

    public let id: String
    public var order: Double
    /// The card is Pinned, as a Pinned Topic is: above every card that is not Pinned, and neither In Play nor a Guest.
    public var isPinned: Bool
    /// The card is among the Guests; else it holds an In Play place. A Board Session never waits on the Bench.
    public var isGuest: Bool
    public var session: JSONValue

    public init(id: String, order: Double, isPinned: Bool = false, isGuest: Bool, session: JSONValue = .object([:])) {
        self.id = id
        self.order = order
        self.isPinned = isPinned
        self.isGuest = isGuest
        self.session = session
    }

    /// The Session's name when Muxify last saw it live.
    public var name: String { session["name"]?.string ?? id }

    /// The Windows of the live Board Session: those of the first Session that points at this row and is in no open
    /// Topic, `open`. A Session in an open Topic is never a Board Session, whatever its `@muxify_session_id` says.
    public func windows(in windows: [TmuxWindow], open: Set<String>) -> [TmuxWindow] {
        let linked = windows.filter { $0.savedSessionID == id && $0.topicID.map { !open.contains($0) } ?? true }
        guard let first = linked.first else { return [] }
        return linked.filter { $0.sessionID == first.sessionID }
    }

    private enum CodingKeys: String, CodingKey { case id, order, isPinned = "pinned", isGuest = "guest", session }

    /// As every key of the `environment` subscription, each one but the id decodes when it is missing.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), order: try values.decodeIfPresent(Double.self, forKey: .order) ?? 0,
                  isPinned: try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
                  isGuest: try values.decodeIfPresent(Bool.self, forKey: .isGuest) ?? false,
                  session: try values.decodeIfPresent(JSONValue.self, forKey: .session) ?? .object([:]))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(order, forKey: .order)
        // An optional key: absent is false, so the row of a card that is not Pinned reads as before.
        if isPinned { try values.encode(isPinned, forKey: .isPinned) }
        try values.encode(isGuest, forKey: .isGuest)
        try values.encode(session, forKey: .session)
    }
}

/// An Open Place: an In Play place that no card fills, after a card in an In Play place left it. It has its order on the
/// Board, so the other places keep their positions until the user fills it. The state database keeps it in the
/// `open_places` table, beside the `topics` table.
public struct OpenPlace: Codable, Hashable, Sendable {
    public let id: String
    public var order: Double

    public init(id: String = UUID().uuidString.lowercased(), order: Double) {
        self.id = id
        self.order = order
    }
}

public enum BoardCard: Equatable, Sendable {
    case topic(TopicRecord)
    case session(BoardSession)
    case openPlace(OpenPlace)

    /// The open and Settled Topics of `records`, the Board Sessions, live or Dormant, and the Open Places.
    public static func all(records: [TopicRecord], boardSessions: [BoardSession] = [], openPlaces: [OpenPlace] = []) -> [BoardCard] {
        records.map(BoardCard.topic) + boardSessions.map(BoardCard.session) + openPlaces.map(BoardCard.openPlace)
    }

    public var id: BoardCardID {
        switch self {
        case .topic(let record): return .topic(record.id)
        case .session(let session): return .session(session.id)
        case .openPlace(let place): return .openPlace(place.id)
        }
    }

    public var order: Double? {
        switch self {
        case .topic(let record): return record.order
        case .session(let session): return session.order
        case .openPlace(let place): return place.order
        }
    }

    public var isPinned: Bool {
        switch self {
        case .topic(let record): return record.isPinned
        case .session(let session): return session.isPinned
        case .openPlace: return false
        }
    }

    /// The Guest mark as the card stores it. Only the cut says if a card is among the Guests: a Board Session without
    /// the mark is there too when it is past the last place.
    var hasGuestMark: Bool {
        switch self {
        case .topic(let record): return record.isGuest && !record.isPinned
        case .session(let session): return session.isGuest && !session.isPinned
        case .openPlace: return false
        }
    }

    /// Where the card goes in the cut at the Bench line.
    public var slot: InPlaySlot {
        switch self {
        case .openPlace: return .openPlace
        case _ where hasGuestMark: return .guest
        case .topic: return .regular
        case .session: return .session
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
        case .session(let session): return session.id
        case .openPlace(let place): return place.id
        }
    }

    fileprivate func with(order: Double) -> BoardCard {
        switch self {
        case .topic(var record):
            record.order = order
            return .topic(record)
        case .session(var session):
            session.order = order
            return .session(session)
        case .openPlace(var place):
            place.order = order
            return .openPlace(place)
        }
    }

    /// A Pinned card is not In Play, so Pin also ends its Guest mark.
    fileprivate func pinned(_ pinned: Bool) -> BoardCard {
        switch self {
        case .topic(var record):
            record.isPinned = pinned
            if pinned { record.isGuest = false }
            return .topic(record)
        case .session(var session):
            session.isPinned = pinned
            if pinned { session.isGuest = false }
            return .session(session)
        case .openPlace:
            return self
        }
    }

    fileprivate func guest(_ guest: Bool) -> BoardCard {
        switch self {
        case .topic(var record):
            record.isGuest = guest
            return .topic(record)
        case .session(var session):
            session.isGuest = guest
            return .session(session)
        case .openPlace:
            return self
        }
    }
}

/// What a card is to the cut at the Bench line.
public enum InPlaySlot: Equatable, Sendable {
    /// A Topic that is not a Guest: it takes an In Play place, or waits on the Bench.
    case regular
    /// A Board Session that is not a Guest: it takes an In Play place. The Bench holds only Topics, so past the last
    /// place, after a smaller `topics.in_play` or a move of another card, it is among the Guests.
    case session
    /// A Topic or a Board Session with the Guest mark: In Play above the limit, in the Guests section.
    case guest
    /// An In Play place that no card fills.
    case openPlace
}

/// The cards that are not Pinned, cut into three sections. The places are the first `limit` cards that are not Guests,
/// Open Places included; the Guests are every Guest and each Board Session past the last place; the Bench is the other
/// Topics. An Open Place past the last place holds no place, so no section has it. Each section keeps the order of the
/// list, and a Guest's position among the others has no effect.
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
            case .session: if places.count < limit { places.append(card) } else { guests.append(card) }
            }
        }
        self.places = places
        self.guests = guests
        self.bench = bench
    }
}

extension Array where Element == BoardCard {
    public var records: [TopicRecord] {
        compactMap { if case .topic(let record) = $0 { return record }; return nil }
    }

    public var boardSessions: [BoardSession] {
        compactMap { if case .session(let session) = $0 { return session }; return nil }
    }

    public var openPlaces: [OpenPlace] {
        compactMap { if case .openPlace(let place) = $0 { return place }; return nil }
    }
}

extension Array where Element == TopicRecord {
    /// The ids of the records that are not Settled: a Session in one of these Topics is never a Board Session.
    var openTopicIDs: Set<String> { Set(filter { $0.settledAt == nil }.map(\.id)) }
}

extension Array where Element == BoardSession {
    /// Each live Board Session, by its Session's tmux id. `open` are the open Topics. A Session points at one Board
    /// Session id, so no two Board Sessions share a Session.
    func bySession(in windows: [TmuxWindow], open: Set<String>) -> [String: BoardSession] {
        var boardSessions: [String: BoardSession] = [:]
        for boardSession in self {
            if let session = boardSession.windows(in: windows, open: open).first?.sessionID { boardSessions[session] = boardSession }
        }
        return boardSessions
    }
}

public enum TopicPlacement: Equatable, Sendable {
    case before(BoardCardID)
    case after(BoardCardID)

    public var anchorID: BoardCardID {
        switch self {
        case .before(let id), .after(let id): return id
        }
    }
}

/// What a change of the Board writes: the cards with a new order or a new mark, the Board Sessions whose cards leave
/// the Board, and the Open Places that close. The change fills or opens the place of each card that leaves.
public struct BoardChange: Equatable, Sendable {
    public var entries: [BoardCard]
    public var endedSessions: [String]
    public var closedPlaces: [String]

    public init(_ entries: [BoardCard], endedSessions: [String] = [], closedPlaces: [String] = []) {
        self.entries = entries
        self.endedSessions = endedSessions
        self.closedPlaces = closedPlaces
    }
}

/// The order of the Board. Topics, Board Sessions and Open Places share it, and a Board Session moves, renumbers and
/// clamps by the rules of a Topic that is not Pinned. Each change returns only the entries it changed.
///
/// The Sidebar shows the cards that are not Pinned in three sections (`InPlayCut`): the In Play places, the Guests,
/// and the Bench. The changes that take an `inPlay` limit write the order in these sections, so the order of the Board
/// is the order that the Sidebar shows. The Bench holds only Topics: a change that would send a Board Session there
/// takes its card off the Board.
public enum TopicOrder {
    public enum Failure: Error, CustomStringConvertible {
        case sourceUnavailable, anchorUnavailable
        /// Replace from Bench: the card to replace is not In Play, or the card to take its place is not Benched.
        case notInPlay, notBenched
        /// Choose In Play: a Pinned card is neither In Play nor Benched, and each place takes one card.
        case pinned, chosenTwice
        /// Fill an Open Place: the place is not an Open Place, or the card is not a Guest or a Benched Topic.
        case notOpenPlace, cannotFill
        /// Bench: the card is not In Play.
        case notInPlayTopic

        public var description: String {
            switch self {
            case .sourceUnavailable: return "The card is no longer on the Board."
            case .anchorUnavailable: return "The card at the drop position is no longer on the Board."
            case .notInPlay: return "The card to replace is not In Play."
            case .notBenched: return "The card to put In Play is not on the Bench."
            case .pinned: return "A Pinned card is neither In Play nor on the Bench."
            case .chosenTwice: return "A card is chosen twice."
            case .notOpenPlace: return "The In Play place is not an Open Place."
            case .cannotFill: return "Only a Guest or a Benched Topic can fill an Open Place."
            case .notInPlayTopic: return "The card is not In Play: it is on the Bench, or Pinned."
            }
        }
    }

    /// The Pinned cards first, then the others; each part in its own hand-set order.
    public static func sorted(_ entries: [BoardCard]) -> [BoardCard] {
        entries.filter(\.isOpen).sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.tieBreak < $1.tieBreak
        }
    }

    /// The open cards that are not Pinned, cut into the In Play places, the Guests and the Bench.
    public static func cut(_ entries: [BoardCard], inPlay: Int) -> InPlayCut<BoardCard> {
        InPlayCut(sorted(entries).filter { !$0.isPinned }, limit: inPlay, slot: \.slot)
    }

    /// A move stays among the entries with the same pin: an anchor in the other part puts the entry at the edge of its own.
    public static func moving(_ id: BoardCardID, to placement: TopicPlacement, in entries: [BoardCard]) throws -> [BoardCard] {
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

    /// Pin puts the card, a Topic or a Board Session, last among the Pinned cards and ends its Guest mark. Unpin puts
    /// it at the end of the Guests with the Guest mark, also when an In Play place is free, so no other card moves.
    public static func pinning(_ id: BoardCardID, _ pinned: Bool, inPlay: Int, in entries: [BoardCard]) throws -> BoardChange {
        guard let found = sorted(entries).first(where: { $0.id == id }), found.slot != .openPlace else { throw Failure.sourceUnavailable }
        guard found.isPinned != pinned else { return BoardChange([]) }
        guard pinned else { return appendingGuest(found.pinned(false), inPlay: inPlay, in: entries) }
        return BoardChange(inserting(found.pinned(true), inPlay: inPlay, in: entries))
    }

    /// Places a Topic that Reopen or Start Fresh brings back at the top of the Bench. A Pinned Topic has no Bench, so
    /// it goes last among the Pinned cards.
    public static func inserting(_ record: TopicRecord, inPlay: Int, in entries: [BoardCard]) -> [BoardCard] {
        inserting(.topic(record), inPlay: inPlay, in: entries)
    }

    private static func inserting(_ source: BoardCard, inPlay: Int, in entries: [BoardCard]) -> [BoardCard] {
        let original = sorted(entries).filter { $0.id != source.id }
        var zone = original.filter { $0.isPinned == source.isPinned }
        let index = source.isPinned ? zone.count : topOfBench(in: zone, inPlay: inPlay)
        zone.insert(source, at: index)
        return placing(source, at: index, in: zone, others: original.filter { $0.isPinned != source.isPinned })
    }

    /// The index in `zone`, the cards that are not Pinned, where a returning Topic goes: right after the last
    /// In Play place while there are fewer places than `inPlay`, else right before the first Benched card, or last when
    /// there is none. A Guest does not count toward `inPlay`.
    static func topOfBench(in zone: [BoardCard], inPlay: Int) -> Int {
        let regulars = zone.indices.filter { zone[$0].slot != .guest }
        if regulars.count > inPlay { return regulars[inPlay] }
        return regulars.count < inPlay ? regulars.last.map { $0 + 1 } ?? 0 : zone.count
    }

    /// Choose In Play: the first `inPlay` of `chosen` fill the In Play places in this order, and the places after the
    /// last of them are Open Places. A Guest that fills a place loses its Guest mark. Of the other cards that held a
    /// place or wait on the Bench, the chosen Topics lead the Bench, and the other Topics follow in their order. A
    /// Board Session among them leaves the Board, since the Bench holds only Topics. Each Guest that takes no place
    /// stays a Guest, chosen or not.
    public static func choosingInPlay(_ chosen: [BoardCardID], inPlay: Int, in entries: [BoardCard]) throws -> BoardChange {
        let original = layout(entries, inPlay: inPlay)
        guard Set(chosen).count == chosen.count else { throw Failure.chosenTwice }
        let cards = try chosen.map { id in
            guard let entry = sorted(entries).first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
            guard !entry.isPinned else { throw Failure.pinned }
            return entry
        }
        let cut = cut(entries, inPlay: inPlay)
        let placed = Array(cards.prefix(inPlay))
        let isGuest = Set(cut.guests.map(\.id))
        let leading = cards.dropFirst(inPlay).filter { !isGuest.contains($0.id) && $0.slot != .openPlace }
        let taken = Set((placed + leading).map(\.id))
        let open = (placed.count..<inPlay).map { _ in BoardCard.openPlace(OpenPlace(order: .nan)) }
        let guests = cut.guests.filter { !taken.contains($0.id) }
        let others = (cut.places + cut.bench).filter { $0.slot != .openPlace && !taken.contains($0.id) }
        let (bench, ended) = landingOnBench(leading + others)
        return rewriting(placed.map { $0.guest(false) } + open + guests + bench, from: original, endedSessions: ended)
    }

    /// Replace from Bench: `benched` takes the position of `card`, and `card` goes to the end of the Bench. Each card
    /// takes the mark of its new section: a Benched Topic that takes a Guest's position becomes a Guest, a Guest Topic
    /// goes to the Bench without its mark, and a Board Session leaves the Board. On an Open Place, `benched` fills it.
    public static func replacingFromBench(_ card: BoardCardID, with benched: BoardCardID, inPlay: Int,
                                          in entries: [BoardCard]) throws -> BoardChange {
        let original = layout(entries, inPlay: inPlay)
        let cut = cut(entries, inPlay: inPlay)
        guard let position = cut.inPlay.firstIndex(where: { $0.id == card }) else { throw Failure.notInPlay }
        guard let incoming = cut.bench.first(where: { $0.id == benched }) else { throw Failure.notBenched }
        let replaced = cut.inPlay[position]
        var inPlay = cut.inPlay
        inPlay[position] = incoming.guest(position >= cut.places.count)
        let (bench, ended) = landingOnBench([replaced])
        return rewriting(inPlay + cut.bench.filter { $0.id != benched } + bench, from: original, endedSessions: ended)
    }

    /// A trade: two cards that are not Pinned exchange their positions, and no other card moves. Each card takes the
    /// mark of the section it lands in: a Guest that comes into a place loses its Guest mark, and a card that comes
    /// into the Guests section gets it. A Board Session that would land on the Bench leaves the Board. An Open Place
    /// that leaves the places closes, so a trade with one fills it.
    public static func trading(_ card: BoardCardID, with other: BoardCardID, inPlay: Int,
                               in entries: [BoardCard]) throws -> BoardChange {
        let all = sorted(entries)
        guard let source = all.first(where: { $0.id == card }) else { throw Failure.sourceUnavailable }
        guard let anchor = all.first(where: { $0.id == other }) else { throw Failure.anchorUnavailable }
        guard !source.isPinned, !anchor.isPinned else { throw Failure.pinned }
        let cut = cut(entries, inPlay: inPlay)
        enum Section { case places, guests, bench }
        func section(_ id: BoardCardID) -> Section {
            if cut.places.contains(where: { $0.id == id }) { return .places }
            return cut.guests.contains(where: { $0.id == id }) ? .guests : .bench
        }
        var ended: [String] = []
        func landing(_ entry: BoardCard, in section: Section) -> BoardCard? {
            switch (entry, section) {
            case (.session(let session), .bench): ended.append(session.id); return nil
            case (.openPlace, .guests), (.openPlace, .bench): return nil
            default: return entry.guest(section == .guests)
            }
        }
        let sourceLanded = landing(source, in: section(other)), anchorLanded = landing(anchor, in: section(card))
        let original = cut.places + cut.guests + cut.bench
        let zone = original.compactMap { entry -> BoardCard? in
            switch entry.id {
            case card: return anchorLanded
            case other: return sourceLanded
            default: return entry
            }
        }
        return rewriting(zone, from: original, endedSessions: ended)
    }

    /// Make a Guest: the Benched Topic goes to the end of the Guests with the Guest mark, and no other card moves. A
    /// Board Session is never on the Bench, so it is never a card that this takes. Unpin puts a card there the same way.
    public static func makingGuest(_ id: BoardCardID, inPlay: Int, in entries: [BoardCard]) throws -> BoardChange {
        guard let entry = sorted(entries).first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
        guard !entry.isPinned else { throw Failure.pinned }
        let cut = cut(entries, inPlay: inPlay)
        guard cut.bench.contains(where: { $0.id == entry.id }) else { throw Failure.notBenched }
        return appendingGuest(entry, inPlay: inPlay, in: entries)
    }

    /// A new Topic: it goes to the end of the Guests with the Guest mark, as Make a Guest puts a Benched Topic there.
    /// It takes no place, also when one is free, so no other card moves.
    static func insertingGuest(_ record: TopicRecord, inPlay: Int, in entries: [BoardCard]) -> BoardChange {
        appendingGuest(.topic(record), inPlay: inPlay, in: entries)
    }

    private static func appendingGuest(_ entry: BoardCard, inPlay: Int, in entries: [BoardCard]) -> BoardChange {
        let cut = cut(entries, inPlay: inPlay)
        return rewriting(cut.places + cut.guests + [entry.guest(true)] + cut.bench.filter { $0.id != entry.id },
                         from: layout(entries, inPlay: inPlay))
    }

    /// Bench: the In Play card leaves In Play. A Topic goes to the top of the Bench without a Guest mark, and a Board
    /// Session leaves the Board. A card in a place leaves an Open Place there; a Guest leaves none, so the Guests
    /// section gets shorter.
    public static func benching(_ id: BoardCardID, inPlay: Int, in entries: [BoardCard]) throws -> BoardChange {
        guard let entry = sorted(entries).first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
        let cut = cut(entries, inPlay: inPlay)
        let places = cut.places.map { $0.id == entry.id ? .openPlace(OpenPlace(order: .nan)) : $0 }
        guard places != cut.places || cut.guests.contains(where: { $0.id == entry.id }) else { throw Failure.notInPlayTopic }
        let (bench, ended) = landingOnBench([entry])
        return rewriting(places + cut.guests.filter { $0.id != entry.id } + bench + cut.bench,
                         from: layout(entries, inPlay: inPlay), endedSessions: ended)
    }

    /// Move Down from the last place: the card becomes the top Guest, and an Open Place stays at its place.
    public static func sendingToGuests(_ id: BoardCardID, inPlay: Int, in entries: [BoardCard]) throws -> BoardChange {
        guard let entry = sorted(entries).first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
        let cut = cut(entries, inPlay: inPlay)
        guard cut.places.contains(where: { $0.id == entry.id }) else { throw Failure.notInPlayTopic }
        let places = cut.places.map { $0.id == entry.id ? .openPlace(OpenPlace(order: .nan)) : $0 }
        return rewriting(places + [entry.guest(true)] + cut.guests + cut.bench, from: layout(entries, inPlay: inPlay))
    }

    /// Move Up from the top Guest, with room in the places and no Open Place: the Guest takes the next place, without
    /// its Guest mark.
    public static func takingNextPlace(_ id: BoardCardID, inPlay: Int, in entries: [BoardCard]) throws -> BoardChange {
        guard let entry = sorted(entries).first(where: { $0.id == id }) else { throw Failure.sourceUnavailable }
        let cut = cut(entries, inPlay: inPlay)
        guard cut.guests.contains(where: { $0.id == entry.id }), cut.places.count < inPlay else { throw Failure.cannotFill }
        return rewriting(cut.places + [entry.guest(false)] + cut.guests.filter { $0.id != entry.id } + cut.bench,
                         from: layout(entries, inPlay: inPlay))
    }

    /// Fill an Open Place: a Guest or a Benched Topic takes the place, without a Guest mark. It is a trade with the
    /// Open Place, so no other card moves.
    public static func fillingOpenPlace(_ place: String, with id: BoardCardID, inPlay: Int, in entries: [BoardCard]) throws -> BoardChange {
        let cut = cut(entries, inPlay: inPlay)
        guard cut.places.contains(where: { $0.id == .openPlace(place) }) else { throw Failure.notOpenPlace }
        guard (cut.guests + cut.bench).contains(where: { $0.id == id }) else { throw Failure.cannotFill }
        return try trading(.openPlace(place), with: id, inPlay: inPlay, in: entries)
    }

    /// The order after a change that took cards out of the Board, such as Settle, Forget, Pin or the end of a Board
    /// Session: each card that left an In Play place `before` leaves an Open Place there, so no other card moves. A
    /// Guest that leaves leaves no Open Place. `handled` are the cards whose places the change filled or opened itself.
    /// Each Open Place past the last place closes.
    public static func keepingPlaces(from before: [BoardCard], in after: [BoardCard], inPlay: Int,
                                     handled: Set<BoardCardID> = []) -> BoardChange {
        let zone = sorted(after).filter { !$0.isPinned }
        let ids = Set(zone.map(\.id))
        let left = cut(before, inPlay: inPlay).places.enumerated().filter { _, entry in
            entry.slot != .openPlace && !ids.contains(entry.id) && !handled.contains(entry.id)
        }.map(\.offset)
        guard !left.isEmpty else {
            let held = Set(InPlayCut(zone, limit: inPlay, slot: \.slot).places.map(\.id))
            return BoardChange([], closedPlaces: zone.openPlaces.map(\.id).filter { !held.contains(.openPlace($0)) })
        }
        var placeHolders = zone.filter { $0.slot != .guest }
        for index in left { placeHolders.insert(.openPlace(OpenPlace(order: .nan)), at: min(index, placeHolders.count)) }
        let cut = InPlayCut(placeHolders, limit: inPlay, slot: \.slot)
        let pastLastPlace = Set(cut.guests.map(\.id))
        return rewriting(cut.places + zone.filter { $0.hasGuestMark || pastLastPlace.contains($0.id) } + cut.bench, from: zone)
    }

    /// The order in the three sections, as the Sidebar shows them: each Board Session that an older Muxify kept among
    /// the Topics goes to the Guests. A list in that order does not change.
    public static func gatheringGuests(inPlay: Int, in entries: [BoardCard]) -> BoardChange {
        guard !isInSections(entries, inPlay: inPlay) else { return BoardChange([]) }
        let zone = sorted(entries).filter { !$0.isPinned }
        return rewriting(layout(entries, inPlay: inPlay), from: zone)
    }

    /// Whether the cards that are not Pinned are in the order of the three sections, as the Sidebar shows them.
    public static func isInSections(_ entries: [BoardCard], inPlay: Int) -> Bool {
        sorted(entries).filter { !$0.isPinned }.map(\.id) == layout(entries, inPlay: inPlay).map(\.id)
    }

    /// Puts a new Board Session at the end of the Guests, with the Guest mark.
    static func appendingBoardSession(_ session: BoardSession, inPlay: Int, in entries: [BoardCard]) -> [BoardCard] {
        var session = session
        // NaN is never an index, so a renumber gives the new Board Session its order too.
        session.order = .nan
        session.isGuest = true
        let source = BoardCard.session(session)
        let cut = cut(entries, inPlay: inPlay)
        return normalized(cut.places + cut.guests + [source] + cut.bench, from: layout(entries, inPlay: inPlay))
    }

    /// The cards that a change sends to the Bench: each Topic goes there without its Guest mark, and each Board
    /// Session leaves the Board, since the Bench holds only Topics.
    private static func landingOnBench(_ cards: [BoardCard]) -> (bench: [BoardCard], ended: [String]) {
        var bench: [BoardCard] = [], ended: [String] = []
        for card in cards {
            switch card {
            case .session(let session): ended.append(session.id)
            case .topic: bench.append(card.guest(false))
            case .openPlace: break
            }
        }
        return (bench, ended)
    }

    /// The open cards that are not Pinned, in the three sections, with each Open Place past the last place.
    private static func layout(_ entries: [BoardCard], inPlay: Int) -> [BoardCard] {
        let zone = sorted(entries).filter { !$0.isPinned }
        let cut = InPlayCut(zone, limit: inPlay, slot: \.slot)
        let shown = Set((cut.places + cut.guests + cut.bench).map(\.id))
        return cut.places + cut.guests + cut.bench + zone.filter { !shown.contains($0.id) }
    }

    /// `zone` numbered 0, 1, 2…: the entries that changed from `original`, and each Open Place of `original` that
    /// `zone` does not hold any more.
    private static func rewriting(_ zone: [BoardCard], from original: [BoardCard], endedSessions: [String] = []) -> BoardChange {
        let kept = Set(zone.map(\.id))
        return BoardChange(normalized(zone, from: original), endedSessions: endedSessions,
                           closedPlaces: original.openPlaces.map(\.id).filter { !kept.contains(.openPlace($0)) })
    }

    /// Gives `source`, at `index` in `zone`, an order between its neighbors there, or renumbers every open entry
    /// when no order fits between them.
    private static func placing(_ source: BoardCard, at index: Int, in zone: [BoardCard], others: [BoardCard]) -> [BoardCard] {
        if let value = rank(between: index > 0 ? rank(zone[index - 1]) : nil,
                            and: index + 1 < zone.count ? rank(zone[index + 1]) : nil) {
            return [source.with(order: value)]
        }
        let renumbered = normalized(source.isPinned ? zone + others : others + zone)
        return renumbered.contains { $0.id == source.id } ? renumbered : renumbered + [source]
    }

    private static func rank(_ entry: BoardCard) -> Double {
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
    private static func normalized(_ entries: [BoardCard], from original: [BoardCard]? = nil) -> [BoardCard] {
        let original = original ?? entries
        return entries.enumerated().compactMap { index, entry in
            let placed = entry.with(order: Double(index))
            return original.contains(placed) ? nil : placed
        }
    }
}
