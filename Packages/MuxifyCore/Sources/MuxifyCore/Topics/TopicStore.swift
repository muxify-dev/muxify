import Foundation
import Darwin

/// What the records file holds at one moment.
public struct TopicContents: Equatable, Sendable {
    /// The valid Topic records, in id order.
    public var records: [TopicRecord]
    /// One line for each entry that is not a valid record, and for a file of the old folder that cannot be read.
    public var problems: [String]
    /// The Open Places of the Topics list.
    public var openPlaces: [OpenPlace] = []
    /// An older Muxify left Snoozes or a running Zen: `TopicStore.upgrade` removes them.
    public var needsUpgrade = false
    /// The entries of `records` in the file that are not valid records, as the file has them. A write puts them back,
    /// so a record with one bad field is never lost.
    var invalidEntries: [JSONValue] = []
    /// An `open_places` value that is not a list of Open Places. A write puts it back until it changes the Open Places.
    var unreadableOpenPlaces: JSONValue?

    public init(records: [TopicRecord], problems: [String], openPlaces: [OpenPlace] = [], needsUpgrade: Bool = false) {
        self.records = records
        self.problems = problems
        self.openPlaces = openPlaces
        self.needsUpgrade = needsUpgrade
    }
}

/// The Topic records on disk: one file, `topics.json`, that holds every record and the Open Places. It keeps no
/// state: every read and write goes to the file, under the record lock, so the app and the command line tool can
/// both write. A write replaces the file with one rename, so it makes one new file, whatever it changed, and a
/// reader opens one file.
public struct TopicStore: Sendable {
    public let paths: MuxifyPaths
    /// The Config's `topics.in_play`. A write that takes a card out of an In Play place leaves an Open Place by it.
    public let inPlay: Int?
    private let lockTimeout: TimeInterval
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(paths: MuxifyPaths, inPlay: Int? = nil, lockTimeout: TimeInterval = 10) {
        self.init(paths: paths, inPlay: inPlay, lockTimeout: lockTimeout) { data, url in try data.write(to: url, options: .atomic) }
    }

    /// `writeData` writes the records file; tests replace it to count the writes or to fail one.
    init(paths: MuxifyPaths, inPlay: Int? = nil, lockTimeout: TimeInterval = 10,
         writeData: @escaping @Sendable (Data, URL) throws -> Void) {
        self.paths = paths
        self.inPlay = inPlay
        self.lockTimeout = lockTimeout
        self.writeData = writeData
    }

    public enum Failure: Error, CustomStringConvertible {
        /// The records file exists, but it is not a JSON object with a `records` array. A write would replace every
        /// record with nothing, so no write happens until the file reads again.
        case unreadableFile(String, String)

        public var description: String {
            switch self {
            case .unreadableFile(let path, let reason): return "\(path) is not a Topic records file (\(reason)), so Muxify did not write to it."
            }
        }
    }

    /// Reads under a shared lock, so a read never sees half of a write. Without a state folder there is
    /// nothing to read, and the read creates nothing.
    public func read() throws -> TopicContents {
        guard FileManager.default.fileExists(atPath: paths.state.path) else { return TopicContents(records: [], problems: []) }
        return try FileLock.withLock(paths.recordLock, .shared, rank: .record, timeout: lockTimeout) { readSource().contents }
    }

    /// Changes whenever the records file changes: its inode, its modification time and its size. Before the first
    /// write moves the records into the file, it follows the files of the old folder. It takes no lock, so a
    /// watcher can poll it often.
    public func stamp() -> String {
        if let stamp = Self.stamp(of: paths.topicRecords) { return stamp }
        return LegacyFolder(paths: paths).stamp()
    }

    private static func stamp(of url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return "\(info.st_ino):\(nanoseconds):\(info.st_size)"
    }

    /// Runs `body` on the records as they are now, under the exclusive record lock, and writes the file when
    /// `body` changed something. `locks` are the Locked Sessions as tmux has them now: a write that changes the
    /// order places the Topics among them. The first write after an update moves the records out of the old
    /// folder, one file for each Topic, into the file.
    @discardableResult
    public func write<T>(locks: [SessionLock] = [], _ body: (inout TopicTransaction) throws -> T) throws -> T {
        try FileLock.withLock(paths.recordLock, .exclusive, rank: .record, timeout: lockTimeout) {
            let source = readSource()
            if case .unreadable(let reason) = source.origin { throw Failure.unreadableFile(paths.topicRecords.path, reason) }
            let contents = source.contents
            var transaction = TopicTransaction(records: contents.records, takenIDs: Set(contents.invalidEntries.compactMap { $0["id"]?.string }),
                                               inPlay: inPlay)
            transaction.locks = locks
            transaction.openPlaces = contents.openPlaces
            let result = try body(&transaction)
            let openPlaces: JSONValue
            if let kept = contents.unreadableOpenPlaces, transaction.openPlaces == contents.openPlaces { openPlaces = kept }
            else { openPlaces = try Self.value(of: transaction.openPlaces) }
            for record in transaction.records { _ = try Self.encoded(record) }
            let file = RecordsFile(records: Self.sorted(transaction.records).map { TopicEntry.record($0, raw: nil) }
                                        + contents.invalidEntries.map { TopicEntry.invalid($0, problem: "") },
                                   openPlaces: openPlaces)
            let data = try Self.encoder.encode(file)
            // No file and nothing to put in one: a write that changed nothing makes no empty file.
            let empty = source.data == nil && file.records.isEmpty && transaction.openPlaces.isEmpty
            if data != source.data, !empty {
                try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
                try writeData(data, paths.topicRecords)
            }
            if case .legacyFolder(let folder, let migrated) = source.origin { folder.remove(migrated) }
            return result
        }
    }

    // MARK: - The file

    /// `topics.json`: a `records` array of entries and the `open_places` array.
    private struct RecordsFile: Codable {
        var records: [TopicEntry]
        var openPlaces: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case records, openPlaces = "open_places"
        }
    }

    /// One entry of `records`: a record, or a value that is not a valid record, with why, and goes back into the
    /// file as it is. A record read from the file keeps its `raw` value, so a second record with the same id goes
    /// back as it is too.
    private enum TopicEntry: Codable {
        case record(TopicRecord, raw: JSONValue?)
        case invalid(JSONValue, problem: String)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            // A `JSONValue` holds no number past the range of `Decimal`, so a record with such an `order` has no raw value.
            let raw = try? value.decode(JSONValue.self)
            do { self = .record(try value.decode(TopicRecord.self), raw: raw) }
            catch {
                guard let raw else { throw error }
                self = .invalid(raw, problem: "\(error)")
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .record(let record, _): try record.encode(to: encoder)
            case .invalid(let value, _): try value.encode(to: encoder)
            }
        }
    }

    /// Where a read found the records.
    private enum Origin {
        /// The records file, or no state at all.
        case file
        /// The old folder, one file for each Topic: the next write moves the records into the file and removes the
        /// files it read.
        case legacyFolder(LegacyFolder, migrated: [URL])
        /// The records file exists, but it is not a records file.
        case unreadable(String)
    }

    private struct Source {
        var contents: TopicContents
        /// The bytes of the records file, so a write that leaves them as they are writes nothing.
        var data: Data?
        var origin: Origin
    }

    private func readSource() -> Source {
        var source = readFileOrFolder()
        source.contents.needsUpgrade = source.contents.needsUpgrade || FileManager.default.fileExists(atPath: paths.legacyZenFile.path)
        return source
    }

    private func readFileOrFolder() -> Source {
        let folder = LegacyFolder(paths: paths)
        guard let data = try? Data(contentsOf: paths.topicRecords) else {
            if folder.exists {
                let read = folder.read()
                return Source(contents: read.contents, data: nil, origin: .legacyFolder(folder, migrated: read.migrated))
            }
            return Source(contents: TopicContents(records: [], problems: []), data: nil, origin: .file)
        }
        let file: RecordsFile
        do { file = try JSONDecoder().decode(RecordsFile.self, from: data) } catch {
            let reason = "\(error)"
            return Source(contents: TopicContents(records: [], problems: ["\(paths.topicRecords.path): \(reason)"]), data: data, origin: .unreadable(reason))
        }
        var contents = Self.contents(of: file.records, openPlaces: file.openPlaces, in: paths.topicRecords.path)
        if folder.exists {
            contents.problems.append("\(folder.url.path): the records moved to \(paths.topicRecords.lastPathComponent), and the folder keeps files that Muxify could not read. Remove the folder by hand.")
        }
        return Source(contents: contents, data: data, origin: .file)
    }

    /// The valid records in id order, each id once, and the other entries as they are. A second entry with the id
    /// of a record is not a record: it is kept as it is, so no write loses it.
    private static func contents(of entries: [TopicEntry], openPlaces: JSONValue?, in path: String) -> TopicContents {
        var records: [TopicRecord] = []
        var invalid: [JSONValue] = []
        var problems: [String] = []
        var seen: Set<String> = []
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .record(let record, let raw):
                if seen.insert(record.id).inserted { records.append(record) }
                else {
                    invalid.append(raw ?? .null)
                    problems.append("\(path): records[\(index)]: a second record with the id \(record.id)")
                }
            case .invalid(let value, let problem):
                invalid.append(value)
                problems.append("\(path): records[\(index)]: \(problem)")
            }
        }
        var contents = TopicContents(records: sorted(records), problems: problems)
        contents.invalidEntries = invalid
        switch openPlaces {
        case nil, .null?: break
        case let value?:
            do { contents.openPlaces = try JSONDecoder().decode([OpenPlace].self, from: JSONEncoder().encode(value)) }
            catch {
                contents.unreadableOpenPlaces = value
                problems.append("\(path): open_places: \(error)")
            }
        }
        contents.problems = problems
        contents.needsUpgrade = records.contains { $0.unknownFields[SnoozeUpgrade.field] != nil }
        return contents
    }

    /// Id order, by bytes, so every read lists the records the same way.
    private static func sorted(_ records: [TopicRecord]) -> [TopicRecord] {
        records.sorted { Array($0.id.utf8).lexicographicallyPrecedes(Array($1.id.utf8)) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func value<T: Encodable>(of item: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
    }

    /// Also checks that the id is a filename, for records made in memory.
    static func encoded(_ record: TopicRecord) throws -> Data {
        let data = try encoder.encode(record)
        _ = try JSONDecoder().decode(TopicRecord.self, from: data)
        return data
    }

    // MARK: - The old folder

    /// The records as an older Muxify kept them: `topics/<id>.json` for each Topic and `topics/open-places`.
    /// A read before the first write reads them from here, so nothing disappears after an update.
    private struct LegacyFolder {
        static let openPlacesFile = "open-places"
        let paths: MuxifyPaths
        var url: URL { paths.legacyTopicsFolder }
        var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

        /// `.json` files in name order, as the records were listed before.
        private func files() -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { Array($0.lastPathComponent.utf8).lexicographicallyPrecedes(Array($1.lastPathComponent.utf8)) }
        }

        func stamp() -> String {
            (files() + [url.appendingPathComponent(Self.openPlacesFile)]).map { file in
                file.lastPathComponent + "@" + (TopicStore.stamp(of: file) ?? "-")
            }.joined(separator: "|")
        }

        /// A file that is a record, or JSON of another shape, becomes an entry, and `migrated` names it. A file that is
        /// not JSON is a problem, and it stays in the folder: a write cannot put it into the records file without a
        /// loss.
        func read() -> (contents: TopicContents, migrated: [URL]) {
            var entries: [TopicEntry] = []
            var problems: [String] = []
            var migrated: [URL] = []
            for file in files() {
                let data = try? Data(contentsOf: file)
                let value = data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                let problem: String
                do {
                    let record = try JSONDecoder().decode(TopicRecord.self, from: data ?? Data())
                    if record.id == file.deletingPathExtension().lastPathComponent {
                        entries.append(.record(record, raw: value))
                        migrated.append(file)
                        continue
                    }
                    problem = "filename must match the Topic id"
                } catch {
                    problem = "\(error)"
                }
                guard let value else {
                    problems.append("\(file.path): not JSON, so it stays in the folder")
                    continue
                }
                entries.append(.invalid(value, problem: problem))
                migrated.append(file)
            }
            let placesFile = url.appendingPathComponent(Self.openPlacesFile)
            var openPlaces: JSONValue?
            if let data = try? Data(contentsOf: placesFile) {
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    openPlaces = value
                    migrated.append(placesFile)
                } else {
                    problems.append("\(placesFile.path): not JSON, so it stays in the folder")
                }
            }
            var contents = TopicStore.contents(of: entries, openPlaces: openPlaces, in: url.path)
            contents.problems = problems + contents.problems
            return (contents, migrated)
        }

        /// After the write that moved the records: removes the files it read, the folder once it is empty, and the
        /// staging folders of a writer that crashed before the update.
        func remove(_ migrated: [URL]) {
            let manager = FileManager.default
            for file in migrated { try? manager.removeItem(at: file) }
            if (try? manager.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try? manager.removeItem(at: url) }
            for name in (try? manager.contentsOfDirectory(atPath: paths.state.path)) ?? [] where name.hasPrefix(".topics-") {
                try? manager.removeItem(at: paths.state.appendingPathComponent(name))
            }
        }
    }
}

/// The records as one write found them under the lock. Its changes are written when the write's body returns. It
/// cannot reach the store, so a body cannot take the lock a second time.
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
    /// The ids of the entries that are not valid records: no new Topic takes one, so a write cannot replace the entry.
    private let takenIDs: Set<String>

    init(records: [TopicRecord], takenIDs: Set<String> = [], inPlay: Int? = nil) {
        self.records = records
        self.takenIDs = takenIDs
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
    /// `in_play`, that Lock is a Guest, so the Topic gets the Guest mark. An id that a record or an invalid entry has
    /// is taken. The plan that makes the Topic ends the Lock in tmux, so the result leaves it out.
    @discardableResult
    public mutating func create(_ record: TopicRecord, arrival: TopicArrival = .end(.bottom), replacingLockOf lockedSessionID: String? = nil) throws -> [SessionLockChange] {
        _ = try TopicStore.encoded(record)
        guard !takenIDs.contains(record.id), !records.contains(where: { $0.id == record.id }) else {
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
        _ = try TopicStore.encoded(record)
        records[index] = record
    }

    /// Writes what a plan changed from the record it read, onto the record as it is now: for each JSON key,
    /// `after` when it differs from `before`, else the value on disk. A Tag that another writer set while
    /// the plan ran stays. When two writers change one key, the last write wins for that key. A Topic that is
    /// not on disk is created only when the plan read no previous record, as `create` does.
    @discardableResult
    public mutating func apply(_ change: TopicRecordChange, arrival: TopicArrival = .end(.bottom), replacingLockOf lockedSessionID: String? = nil) throws -> [SessionLockChange] {
        guard let current = records.first(where: { $0.id == change.after.id }) else {
            guard change.before == nil else { throw Failure.topicUnavailable(change.after.id) }
            return try create(change.after, arrival: arrival, replacingLockOf: lockedSessionID)
        }
        let before = try change.before.map(Self.fields) ?? [:]
        let after = try Self.fields(change.after)
        var merged = try Self.fields(current)
        for key in Set(before.keys).union(after.keys) where after[key] != before[key] {
            merged[key] = after[key]
        }
        let record = try JSONDecoder().decode(TopicRecord.self, from: JSONEncoder().encode(merged))
        _ = try TopicStore.encoded(record)
        if current.settledAt != nil, record.settledAt == nil {
            return put(TopicOrder.inserting(record, at: arrival, in: entries))
        }
        return put([.topic(record)])
    }

    /// Changes the Tags of the open Topic `id`, and nothing else in it. The app and the CLI both change Tags here,
    /// so an `add` or a `remove` applies to the Tags as they are on disk now.
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

    @discardableResult
    public mutating func pin(_ id: String, _ pinned: Bool) throws -> [SessionLockChange] {
        put(try TopicOrder.pinning(id, pinned, inPlay: inPlay, in: entries))
    }

    @discardableResult
    public mutating func chooseInPlay(_ chosen: [TopicListID], inPlay: Int) throws -> [SessionLockChange] {
        put(try TopicOrder.choosingInPlay(chosen, inPlay: inPlay, in: entries))
    }

    /// Bench Topic: the In Play Topic goes to the top of the Bench. From a place it leaves an Open Place there.
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

    private static func fields(_ record: TopicRecord) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(record))
    }

    /// Ends the old Zen as it ended before: each Topic it Snoozed gets its earlier `snoozed_until` back. Then each
    /// open Topic that is not Pinned and has a Snooze goes where `arrival` puts a returning Topic, in the order it would
    /// wake. Last, no record keeps `snoozed_until`, so a second run changes nothing.
    mutating func upgradeSnoozes(endingZen zen: SnoozeUpgrade.Zen?, arrival: TopicArrival) throws -> [SessionLockChange] {
        var stored: [String: String] = [:]
        for record in records where record.settledAt == nil {
            if case .string(let value)? = record.unknownFields[SnoozeUpgrade.field] { stored[record.id] = value }
        }
        for change in zen?.changes ?? [] where stored[change.topicID] == zen?.until {
            stored[change.topicID] = change.previous
        }
        let wakes = stored.compactMapValues(SnoozeUpgrade.wake)
        let order = TopicOrder.sorted(entries).filter { !$0.isPinned }
        let returning = order.enumerated().compactMap { offset, entry -> (Date, Int, TopicListID)? in
            guard case .topic(let record) = entry, let wake = wakes[record.id] else { return nil }
            return (wake, offset, entry.id)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
        let rest = order.filter { !returning.contains($0.id) }
        let index = arrival.index(in: rest, pinned: false)
        var anchor: TopicPlacement? = index > 0 ? .after(rest[index - 1].id) : rest.first.map { .before($0.id) }
        var moved: Set<String> = []
        for id in returning {
            if let anchor { moved.formUnion(put(try TopicOrder.moving(id, to: anchor, in: entries)).map(\.sessionID)) }
            anchor = .after(id)
        }
        for index in records.indices { records[index].unknownFields[SnoozeUpgrade.field] = nil }
        return locks.filter { moved.contains($0.sessionID) }.map(SessionLockChange.set)
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
