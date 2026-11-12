import Foundation

/// The Topic records and the Open Places at one moment.
public struct TopicContents: Equatable, Sendable {
    /// The Topic records, in id order.
    public var records: [TopicRecord]
    /// The Open Places of the Topics list.
    public var openPlaces: [OpenPlace] = []

    public init(records: [TopicRecord], openPlaces: [OpenPlace] = []) {
        self.records = records
        self.openPlaces = openPlaces
    }
}

/// The Topic records in the state database: the `topics` and `open_places` tables (`TopicTable`). It keeps no records
/// of its own: every read and write goes to the database, so the app and the command line tool can both write. Each
/// store has its own connection, which its copies share.
public struct TopicStore: Sendable {
    public let paths: MuxifyPaths
    /// The Config's `topics.in_play`. A write that takes a card out of an In Play place leaves an Open Place by it.
    public let inPlay: Int?
    private let database: Database

    public init(paths: MuxifyPaths, inPlay: Int? = nil) {
        self.paths = paths
        self.inPlay = inPlay
        database = Database(paths: paths)
    }

    public enum Failure: Error, CustomStringConvertible {
        /// A record made in memory that the table cannot hold: an id that is not a filename, or an order that is not
        /// a finite number.
        case invalidRecord(String, String)

        public var description: String {
            switch self {
            case .invalidRecord(let id, let reason): return "The Topic record \(id) is not valid: \(reason)."
            }
        }
    }

    /// The records and the Open Places as the database has them now. Without a state folder there is nothing to read,
    /// and the read creates nothing.
    public func read() throws -> TopicContents {
        try database.use(creating: false) { try TopicTable.contents($0) } ?? TopicContents(records: [])
    }

    /// Moves whenever another connection, in this process or another, commits a change to the database, and stays
    /// the same otherwise; a write through this store does not move it. Nil until there is a state folder, and when
    /// the database cannot be read. It is one `PRAGMA data_version`, so a watcher can poll it often.
    public func changeToken() -> Int? {
        try? database.use(creating: false) { connection in
            try connection.query("PRAGMA data_version") { $0.int(0) }.first
        } ?? nil
    }

    /// Runs `body` on the records as they are now, in one database transaction, and writes what `body` changed:
    /// a new record is inserted, a removed one deleted, and a changed one updates only the columns that differ, so a
    /// field that another writer changed meanwhile keeps its value unless `body` changed it too. A write that changes
    /// nothing writes nothing. `locks` are the Locked Sessions as tmux has them now: a write that changes the order
    /// places the Topics among them.
    @discardableResult
    public func write<T>(locks: [SessionLock] = [], _ body: (inout TopicTransaction) throws -> T) throws -> T {
        try database.use(creating: true) { connection in
            try connection.transaction {
                let start = try TopicTable.contents(connection)
                var transaction = TopicTransaction(records: start.records, inPlay: inPlay)
                transaction.locks = locks
                transaction.openPlaces = start.openPlaces
                let result = try body(&transaction)
                try TopicTable.save(from: start, to: TopicContents(records: transaction.records, openPlaces: transaction.openPlaces),
                                    connection)
                return result
            }
        }!
    }

    /// Checks a record made in memory before it goes into the table.
    static func check(_ record: TopicRecord) throws {
        guard TopicRecord.isValidID(record.id) else { throw Failure.invalidRecord(record.id, "the id must be a filename") }
        if let order = record.order, !order.isFinite { throw Failure.invalidRecord(record.id, "the order must be a finite number") }
    }

    /// The store's one connection, opened at its first use. A lock keeps one use at a time, since a transaction
    /// belongs to the connection.
    private final class Database: @unchecked Sendable {
        let paths: MuxifyPaths
        private let lock = NSRecursiveLock()
        private var connection: SQLiteConnection?

        init(paths: MuxifyPaths) { self.paths = paths }

        /// Nil without a connection when `creating` is false and there is no state folder yet.
        func use<T>(creating: Bool, _ body: (SQLiteConnection) throws -> T) throws -> T? {
            lock.lock()
            defer { lock.unlock() }
            if connection == nil {
                guard creating || FileManager.default.fileExists(atPath: paths.state.path) else { return nil }
                connection = try StateDatabase.open(paths)
            }
            return try body(connection!)
        }
    }
}

/// The records as one write found them in its transaction. Its changes are written when the write's body returns.
public struct TopicTransaction {
    public private(set) var records: [TopicRecord]
    /// The Locked Sessions, which share the records' order. A change of order that moves or renumbers them returns
    /// the Locks it changed, and the caller writes them to tmux.
    public internal(set) var locks: [SessionLock] = []
    /// The Open Places, which share the records' order.
    public internal(set) var openPlaces: [OpenPlace] = []
    /// The Config's `topics.in_play`: with it, the Locked Sessions are Guests, and a regular card that leaves an In Play
    /// place leaves an Open Place.
    public let inPlay: Int?

    init(records: [TopicRecord], inPlay: Int? = nil) {
        self.records = records
        self.inPlay = inPlay
    }

    public enum Failure: Error, CustomStringConvertible {
        case topicUnavailable(String)

        public var description: String {
            switch self {
            case .topicUnavailable: return "The Topic is no longer in the Topic records."
            }
        }
    }

    public var entries: [TopicListEntry] {
        records.map(TopicListEntry.topic) + locks.map(TopicListEntry.lock) + openPlaces.map(TopicListEntry.openPlace)
    }

    /// Adds a new Topic where `arrival` puts it, or in the place of the Lock of `lockedSessionID`, which then ends. With
    /// `in_play`, that Lock is a Guest, so the Topic gets the Guest mark. An id that a record has is taken. The plan that makes the Topic ends the Lock in tmux, so the result leaves it out.
    @discardableResult
    public mutating func create(_ record: TopicRecord, arrival: TopicArrival = .end(.bottom), replacingLockOf lockedSessionID: String? = nil) throws -> [SessionLockChange] {
        try TopicStore.check(record)
        guard !records.contains(where: { $0.id == record.id }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        if let lock = locks.first(where: { $0.sessionID == lockedSessionID }) {
            var placed = record
            placed.order = lock.order
            placed.isGuest = inPlay != nil
            return put(TopicListChange([.topic(placed)], endedLocks: [lock.sessionID])).filter { $0 != .end(sessionID: lock.sessionID) }
        }
        return put(TopicOrder.inserting(record, at: arrival, in: entries))
    }

    public mutating func update(_ id: String, _ mutate: (inout TopicRecord) throws -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure.topicUnavailable(id) }
        var record = records[index]
        try mutate(&record)
        try TopicStore.check(record)
        records[index] = record
    }

    /// Writes what a plan changed from the record it read, onto the record as it is now: for each column,
    /// `after` when it differs from `before`, else the value in the database. A Tag that another writer set while
    /// the plan ran stays. When two writers change one column, the last write wins for that column. A Topic that is
    /// not in the database is created only when the plan read no previous record, as `create` does.
    @discardableResult
    public mutating func apply(_ change: TopicRecordChange, arrival: TopicArrival = .end(.bottom), replacingLockOf lockedSessionID: String? = nil) throws -> [SessionLockChange] {
        guard let current = records.first(where: { $0.id == change.after.id }) else {
            guard change.before == nil else { throw Failure.topicUnavailable(change.after.id) }
            return try create(change.after, arrival: arrival, replacingLockOf: lockedSessionID)
        }
        let before = TopicTable.values(of: change.before ?? TopicRecord(id: current.id))
        let after = TopicTable.values(of: change.after)
        var merged = TopicTable.values(of: current)
        for column in TopicTable.columns where after[column] != before[column] {
            merged[column] = after[column]
        }
        let record = TopicTable.record(id: current.id, merged)
        try TopicStore.check(record)
        if current.settledAt != nil, record.settledAt == nil {
            return put(TopicOrder.inserting(record, at: arrival, in: entries))
        }
        return put([.topic(record)])
    }

    /// Changes the Tags of the open Topic `id`, and nothing else in it. The app and the CLI both change Tags here,
    /// so an `add` or a `remove` applies to the Tags as they are in the database now.
    public mutating func changeTags(of id: String, _ change: TopicTagChange) throws {
        guard let index = records.firstIndex(where: { $0.id == id && $0.settledAt == nil }) else { throw Failure.topicUnavailable(id) }
        records[index].tags = change.applied(to: records[index].tags)
    }

    /// Sets the Topic Note of the open Topic `id`, and nothing else in it. Nil, or text with no words, clears it. The
    /// Note is one line, so its lines join with a space.
    public mutating func setNote(of id: String, _ note: String?) throws {
        guard let index = records.firstIndex(where: { $0.id == id && $0.settledAt == nil }) else { throw Failure.topicUnavailable(id) }
        let line = (note ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        records[index].note = line.isEmpty ? nil : line
    }

    @discardableResult
    public mutating func forget(_ ids: [String]) throws -> [SessionLockChange] {
        if let missing = ids.first(where: { id in !records.contains { $0.id == id } }) { throw Failure.topicUnavailable(missing) }
        let before = entries
        let forgotten = Set(ids)
        records.removeAll { forgotten.contains($0.id) }
        return put(TopicListChange([]), from: before)
    }

    @discardableResult
    public mutating func move(_ id: TopicListID, to placement: TopicPlacement) throws -> [SessionLockChange] {
        put(try TopicOrder.moving(id, to: placement, in: entries))
    }

    @discardableResult
    public mutating func trade(_ id: TopicListID, with other: TopicListID) throws -> [SessionLockChange] {
        put(try TopicOrder.trading(id, with: other, inPlay: inPlay, in: entries))
    }

    /// Writes what one step of a card does (`TopicCards.step`), with the operation that each effect already has.
    /// `atEnd` and `hidden` change nothing, and `refused` throws its failure.
    @discardableResult
    public mutating func apply(_ outcome: TopicCards.Outcome, to id: TopicListID) throws -> [SessionLockChange] {
        func topicID() throws -> String {
            guard case .topic(let topic) = id else { throw TopicOrder.Failure.guestSession }
            return topic
        }
        func limit() throws -> Int {
            guard let inPlay else { throw TopicOrder.Failure.notInPlay }
            return inPlay
        }
        switch outcome {
        case .reorder(let placement): return try move(id, to: placement)
        case .toGuests: return put(try TopicOrder.sendingToGuests(topicID(), inPlay: limit(), in: entries))
        case .fill(let place): return try fillOpenPlace(place, with: topicID(), inPlay: limit())
        case .trade(let other): return try trade(id, with: other)
        case .takePlace: return put(try TopicOrder.takingNextPlace(topicID(), inPlay: limit(), in: entries))
        case .bench:
            guard case .lock(let sessionID) = id else { return try bench(topicID(), inPlay: limit()) }
            return unlock(sessionID)
        case .makeGuest:
            guard case .lock(let sessionID) = id else { return try makeGuest(topicID(), inPlay: limit()) }
            return lock(sessionID)
        case .refused(let failure): throw failure
        case .atEnd, .hidden: return []
        }
    }

    @discardableResult
    public mutating func pin(_ id: String, _ pinned: Bool) throws -> [SessionLockChange] {
        put(try TopicOrder.pinning(id, pinned, inPlay: inPlay, in: entries))
    }

    @discardableResult
    public mutating func chooseInPlay(_ chosen: [TopicListID], inPlay: Int) throws -> [SessionLockChange] {
        put(try TopicOrder.choosingInPlay(chosen, inPlay: inPlay, in: entries))
    }

    /// Bench of a Topic: the In Play Topic goes to the top of the Bench. From a place it leaves an Open Place there.
    @discardableResult
    public mutating func bench(_ id: String, inPlay: Int) throws -> [SessionLockChange] {
        put(try TopicOrder.benching(id, inPlay: inPlay, in: entries))
    }

    /// The Guest Topic or Benched Topic `id` fills the Open Place `place`.
    @discardableResult
    public mutating func fillOpenPlace(_ place: String, with id: String, inPlay: Int) throws -> [SessionLockChange] {
        put(try TopicOrder.fillingOpenPlace(place, with: id, inPlay: inPlay, in: entries))
    }

    @discardableResult
    public mutating func replaceFromBench(_ card: TopicListID, with benched: TopicListID, inPlay: Int) throws -> [SessionLockChange] {
        put(try TopicOrder.replacingFromBench(card, with: benched, inPlay: inPlay, in: entries))
    }

    @discardableResult
    public mutating func makeGuest(_ id: String, inPlay: Int) throws -> [SessionLockChange] {
        put(try TopicOrder.makingGuest(id, inPlay: inPlay, in: entries))
    }

    /// Writes the order in the three sections, as the Config's `in_play` does to the Locks when it is set.
    @discardableResult
    public mutating func gatherGuests(inPlay: Int) -> [SessionLockChange] {
        put(TopicOrder.gatheringGuests(inPlay: inPlay, in: entries))
    }

    /// Locks the Session last among the Topics that are not Pinned, or with `in_play` at the end of In Play, where it is
    /// a Guest. A Session that is already Locked keeps its place.
    @discardableResult
    public mutating func lock(_ sessionID: String) -> [SessionLockChange] {
        guard !locks.contains(where: { $0.sessionID == sessionID }) else { return [] }
        return put(TopicOrder.appendingLock(of: sessionID, inPlay: inPlay, in: entries))
    }

    /// Ends the Lock of the Session. With `in_play` it is a Guest that leaves, so it leaves no Open Place.
    @discardableResult
    public mutating func unlock(_ sessionID: String) -> [SessionLockChange] {
        guard locks.contains(where: { $0.sessionID == sessionID }) else { return [] }
        return put(TopicListChange([], endedLocks: [sessionID]))
    }

    @discardableResult
    private mutating func put(_ changed: [TopicListEntry]) -> [SessionLockChange] {
        put(TopicListChange(changed))
    }

    /// Writes the change into the transaction and returns what tmux must change. A Settled or Pinned Topic loses its
    /// Guest mark. When a regular card left an In Play place since `before`, it leaves an Open Place there
    /// (`TopicOrder.keepingPlaces`).
    private mutating func put(_ change: TopicListChange, from before: [TopicListEntry]? = nil) -> [SessionLockChange] {
        let before = before ?? entries
        let written = apply(change)
        return merging(written, apply(TopicOrder.keepingPlaces(from: before, in: entries, inPlay: inPlay)))
    }

    private mutating func apply(_ change: TopicListChange) -> [SessionLockChange] {
        for var record in change.entries.records {
            if record.settledAt != nil || record.isPinned { record.isGuest = false }
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            else { records.append(record) }
        }
        for lock in change.entries.locks {
            if let index = locks.firstIndex(where: { $0.sessionID == lock.sessionID }) { locks[index] = lock }
            else { locks.append(lock) }
        }
        for place in change.entries.openPlaces {
            if let index = openPlaces.firstIndex(where: { $0.id == place.id }) { openPlaces[index] = place }
            else { openPlaces.append(place) }
        }
        locks.removeAll { change.endedLocks.contains($0.sessionID) }
        openPlaces.removeAll { change.closedPlaces.contains($0.id) }
        return change.entries.locks.map(SessionLockChange.set) + change.endedLocks.map { SessionLockChange.end(sessionID: $0) }
    }

    /// One change for each Session: the later one wins.
    private func merging(_ first: [SessionLockChange], _ second: [SessionLockChange]) -> [SessionLockChange] {
        first.filter { change in !second.contains { $0.sessionID == change.sessionID } } + second
    }
}

/// A plan's record: `before` is the record the plan read, nil for a new Topic, and `after` is what it made.
public struct TopicRecordChange: Sendable {
    public var before: TopicRecord?
    public var after: TopicRecord

    public init(before: TopicRecord?, after: TopicRecord) {
        self.before = before
        self.after = after
    }
}
