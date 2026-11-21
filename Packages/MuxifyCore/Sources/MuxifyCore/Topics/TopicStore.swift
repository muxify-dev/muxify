import Foundation

/// The Topic records, the Open Places and the Locks at one moment.
public struct TopicContents: Equatable, Sendable {
    /// The Topic records, in id order.
    public var records: [TopicRecord]
    /// The Open Places of the Topics list.
    public var openPlaces: [OpenPlace] = []
    /// The Locks, live or Dormant, in id order.
    public var locks: [SessionLock] = []

    public init(records: [TopicRecord], openPlaces: [OpenPlace] = [], locks: [SessionLock] = []) {
        self.records = records
        self.openPlaces = openPlaces
        self.locks = locks
    }
}

/// The Topic records in the state database: the `topics`, `open_places` and `guest_sessions` tables (`TopicTable`). It
/// keeps no records of its own: every read and write goes to the database, so the app and the command line tool can
/// both write. Each store has its own connection, which its copies share.
public struct TopicStore: Sendable {
    public let paths: MuxifyPaths
    /// The Config's `topics.in_play`. A write that takes a card out of an In Play place leaves an Open Place by it.
    public let inPlay: Int
    /// The Request that the command line runs through this store. Each write puts its `started` row in the ledger, in
    /// the transaction of the records, so the row is there exactly when the records changed. Nil in the app.
    public let request: PendingRequest?
    private let database: StateConnection

    public init(paths: MuxifyPaths, inPlay: Int = Config.Topics.defaultInPlay, request: PendingRequest? = nil) {
        self.paths = paths
        self.inPlay = inPlay
        self.request = request
        database = StateConnection(paths: paths)
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

    /// The records, the Open Places and the Locks as the database has them now. Without a state folder there is nothing
    /// to read, and the read creates nothing.
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
    /// nothing writes nothing.
    @discardableResult
    public func write<T>(_ body: (inout TopicTransaction) throws -> T) throws -> T {
        try database.use(creating: true) { connection in
            try connection.transaction {
                let start = try TopicTable.contents(connection)
                var transaction = TopicTransaction(records: start.records, inPlay: inPlay)
                transaction.locks = start.locks
                transaction.openPlaces = start.openPlaces
                let result = try body(&transaction)
                try TopicTable.save(from: start, to: TopicContents(records: transaction.records, openPlaces: transaction.openPlaces,
                                                                   locks: transaction.locks), connection)
                if let request { try RequestTable.start(request, now: Date(), connection) }
                return result
            }
        }!
    }

    /// Checks a record made in memory before it goes into the table.
    static func check(_ record: TopicRecord) throws {
        guard TopicRecord.isValidID(record.id) else { throw Failure.invalidRecord(record.id, "the id must be a filename") }
        if let order = record.order, !order.isFinite { throw Failure.invalidRecord(record.id, "the order must be a finite number") }
    }
}

/// The records as one write found them in its transaction. Its changes are written when the write's body returns.
public struct TopicTransaction {
    public private(set) var records: [TopicRecord]
    /// The Locks, live or Dormant, which share the records' order.
    public internal(set) var locks: [SessionLock] = []
    /// The Open Places, which share the records' order.
    public internal(set) var openPlaces: [OpenPlace] = []
    /// The Config's `topics.in_play`: a regular card that leaves an In Play place leaves an Open Place.
    public let inPlay: Int

    init(records: [TopicRecord], inPlay: Int = Config.Topics.defaultInPlay) {
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

    /// Adds a new Topic as a Guest: at the end of the Guests, or in the place of the Lock `replacedLock`, which then
    /// ends. A Pinned record goes last among the Pinned Topics. An id that a record has is taken.
    public mutating func create(_ record: TopicRecord, replacingLock replacedLock: String? = nil) throws {
        try TopicStore.check(record)
        guard !records.contains(where: { $0.id == record.id }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        if let lock = locks.first(where: { $0.id == replacedLock }) {
            var placed = record
            placed.order = lock.order
            placed.isGuest = true
            return put(TopicListChange([.topic(placed)], endedLocks: [lock.id]))
        }
        if record.isPinned { return put(TopicOrder.inserting(record, inPlay: inPlay, in: entries)) }
        put(TopicOrder.insertingGuest(record, inPlay: inPlay, in: entries))
    }

    public mutating func update(_ id: String, _ mutate: (inout TopicRecord) throws -> Void) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw Failure.topicUnavailable(id) }
        var record = records[index]
        try mutate(&record)
        try TopicStore.check(record)
        records[index] = record
    }

    /// The app's save of a Topic's remembered Sessions: a plain update of `sessions`, with no check of what another
    /// writer put there since the app's snapshot, so the last write wins. False, and nothing written, when the Topic is
    /// gone from the records: a save never brings a forgotten Topic back.
    public mutating func remember(_ sessions: [JSONValue], of id: String) throws -> Bool {
        guard records.contains(where: { $0.id == id }) else { return false }
        try update(id) { $0.sessions = sessions }
        return true
    }

    /// Writes what a plan changed from the record it read, onto the record as it is now: for each column,
    /// `after` when it differs from `before`, else the value in the database. A Tag that another writer set while
    /// the plan ran stays. When two writers change one column, the last write wins for that column. A Topic that is
    /// not in the database is created only when the plan read no previous record, as `create` does, in the place of
    /// the Lock `endedLock`. When the record is there, that Lock just ends: its Session went into the Topic.
    public mutating func apply(_ change: TopicRecordChange, endingLock endedLock: String? = nil) throws {
        guard let current = records.first(where: { $0.id == change.after.id }) else {
            guard change.before == nil else { throw Failure.topicUnavailable(change.after.id) }
            return try create(change.after, replacingLock: endedLock)
        }
        if let endedLock { unlock(endedLock) }
        let before = TopicTable.values(of: change.before ?? TopicRecord(id: current.id))
        let after = TopicTable.values(of: change.after)
        var merged = TopicTable.values(of: current)
        for column in TopicTable.columns where after[column] != before[column] {
            merged[column] = after[column]
        }
        let record = TopicTable.record(id: current.id, merged)
        try TopicStore.check(record)
        if current.settledAt != nil, record.settledAt == nil {
            return put(TopicOrder.inserting(record, inPlay: inPlay, in: entries))
        }
        put([.topic(record)])
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

    public mutating func forget(_ ids: [String]) throws {
        if let missing = ids.first(where: { id in !records.contains { $0.id == id } }) { throw Failure.topicUnavailable(missing) }
        let before = entries
        let forgotten = Set(ids)
        records.removeAll { forgotten.contains($0.id) }
        put(TopicListChange([]), from: before)
    }

    public mutating func move(_ id: TopicListID, to placement: TopicPlacement) throws {
        put(try TopicOrder.moving(id, to: placement, in: entries))
    }

    public mutating func trade(_ id: TopicListID, with other: TopicListID) throws {
        put(try TopicOrder.trading(id, with: other, inPlay: inPlay, in: entries))
    }

    /// Writes what one step of a card does (`TopicCards.step`), with the operation that each effect already has.
    /// `atEnd` and `hidden` change nothing, and `refused` throws its failure. Make a Guest of a Lock changes nothing:
    /// the Session is a Guest already, and a new Lock comes through `lock`.
    public mutating func apply(_ outcome: TopicCards.Outcome, to id: TopicListID) throws {
        func topicID() throws -> String {
            guard case .topic(let topic) = id else { throw TopicOrder.Failure.guestSession }
            return topic
        }
        switch outcome {
        case .reorder(let placement): return try move(id, to: placement)
        case .toGuests: return put(try TopicOrder.sendingToGuests(topicID(), inPlay: inPlay, in: entries))
        case .fill(let place): return try fillOpenPlace(place, with: topicID(), inPlay: inPlay)
        case .trade(let other): return try trade(id, with: other)
        case .takePlace: return put(try TopicOrder.takingNextPlace(topicID(), inPlay: inPlay, in: entries))
        case .bench:
            guard case .lock(let lock) = id else { return try bench(topicID(), inPlay: inPlay) }
            unlock(lock)
        case .makeGuest:
            guard case .lock = id else { return try makeGuest(topicID(), inPlay: inPlay) }
        case .refused(let failure): throw failure
        case .atEnd, .hidden: break
        }
    }

    public mutating func pin(_ id: String, _ pinned: Bool) throws {
        put(try TopicOrder.pinning(id, pinned, inPlay: inPlay, in: entries))
    }

    public mutating func chooseInPlay(_ chosen: [TopicListID], inPlay: Int) throws {
        put(try TopicOrder.choosingInPlay(chosen, inPlay: inPlay, in: entries))
    }

    /// Bench of a Topic: the In Play Topic goes to the top of the Bench. From a place it leaves an Open Place there.
    public mutating func bench(_ id: String, inPlay: Int) throws {
        put(try TopicOrder.benching(id, inPlay: inPlay, in: entries))
    }

    /// The Guest Topic or Benched Topic `id` fills the Open Place `place`.
    public mutating func fillOpenPlace(_ place: String, with id: String, inPlay: Int) throws {
        put(try TopicOrder.fillingOpenPlace(place, with: id, inPlay: inPlay, in: entries))
    }

    public mutating func replaceFromBench(_ card: TopicListID, with benched: TopicListID, inPlay: Int) throws {
        put(try TopicOrder.replacingFromBench(card, with: benched, inPlay: inPlay, in: entries))
    }

    public mutating func makeGuest(_ id: String, inPlay: Int) throws {
        put(try TopicOrder.makingGuest(id, inPlay: inPlay, in: entries))
    }

    /// Writes the order in the three sections, so each Locked Session that an older Muxify kept among the Topics is a Guest.
    public mutating func gatherGuests(inPlay: Int) {
        put(TopicOrder.gatheringGuests(inPlay: inPlay, in: entries))
    }

    /// Make a Guest of a No Topic Session: its new Lock goes to the end of the Guests. A Lock with that id keeps its
    /// place, so a second Make a Guest of the same Session changes nothing.
    public mutating func lock(_ lock: SessionLock) {
        guard !locks.contains(where: { $0.id == lock.id }) else { return }
        put(TopicOrder.appendingLock(lock, inPlay: inPlay, in: entries))
    }

    /// Ends the Lock. It is a Guest that leaves, so it leaves no Open Place.
    public mutating func unlock(_ id: String) {
        guard locks.contains(where: { $0.id == id }) else { return }
        put(TopicListChange([], endedLocks: [id]))
    }

    /// The import of a Lock that an older Muxify kept in the tmux option `SessionLock.legacyOption`: it keeps the order
    /// that the option had. A Lock with that id stays as it is.
    public mutating func importLock(_ lock: SessionLock) {
        guard !locks.contains(where: { $0.id == lock.id }) else { return }
        locks.append(lock)
    }

    /// Saves a Lock's Remembered Session, with the same rule as `remember(_:of:)`: the last write wins, and False,
    /// with nothing written, when the Lock has ended meanwhile.
    public mutating func remember(_ session: JSONValue, ofLock id: String) -> Bool {
        guard let index = locks.firstIndex(where: { $0.id == id }) else { return false }
        locks[index].session = session
        return true
    }

    private mutating func put(_ changed: [TopicListEntry]) {
        put(TopicListChange(changed))
    }

    /// Writes the change into the transaction. A Settled or Pinned Topic loses its Guest mark. When a regular card left
    /// an In Play place since `before`, it leaves an Open Place there (`TopicOrder.keepingPlaces`).
    private mutating func put(_ change: TopicListChange, from before: [TopicListEntry]? = nil) {
        let before = before ?? entries
        apply(change)
        apply(TopicOrder.keepingPlaces(from: before, in: entries, inPlay: inPlay))
    }

    private mutating func apply(_ change: TopicListChange) {
        for var record in change.entries.records {
            if record.settledAt != nil || record.isPinned { record.isGuest = false }
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            else { records.append(record) }
        }
        for lock in change.entries.locks {
            if let index = locks.firstIndex(where: { $0.id == lock.id }) { locks[index] = lock }
            else { locks.append(lock) }
        }
        for place in change.entries.openPlaces {
            if let index = openPlaces.firstIndex(where: { $0.id == place.id }) { openPlaces[index] = place }
            else { openPlaces.append(place) }
        }
        locks.removeAll { change.endedLocks.contains($0.id) }
        openPlaces.removeAll { change.closedPlaces.contains($0.id) }
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
