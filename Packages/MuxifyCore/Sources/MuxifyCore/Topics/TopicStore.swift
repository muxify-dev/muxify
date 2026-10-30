import Foundation
import Darwin

/// What the record files hold at one moment.
public struct TopicContents: Equatable, Sendable {
    /// The valid Topic records, in file name order.
    public var records: [TopicRecord]
    /// One line for each file that is not a valid record.
    public var problems: [String]
    /// An older Muxify left Snoozes or a running Zen: `TopicStore.upgrade` removes them.
    public var needsUpgrade = false
}

/// The Topic records on disk. It keeps no state: every read and write goes to the files,
/// under the record lock, so the app and the command line tool can both write.
public struct TopicStore: Sendable {
    public let paths: MuxifyPaths
    private let lockTimeout: TimeInterval
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(paths: MuxifyPaths, lockTimeout: TimeInterval = 10) {
        self.init(paths: paths, lockTimeout: lockTimeout) { data, url in try data.write(to: url, options: .atomic) }
    }

    /// `writeData` writes one record file; tests replace it to fail part of the way.
    init(paths: MuxifyPaths, lockTimeout: TimeInterval = 10, writeData: @escaping @Sendable (Data, URL) throws -> Void) {
        self.paths = paths
        self.lockTimeout = lockTimeout
        self.writeData = writeData
    }

    /// Reads under a shared lock, so a read never sees half of a write. Without a state folder there is
    /// nothing to read, and the read creates nothing.
    public func read() throws -> TopicContents {
        guard FileManager.default.fileExists(atPath: paths.state.path) else { return TopicContents(records: [], problems: []) }
        return try FileLock.withLock(paths.recordLock, .shared, rank: .record, timeout: lockTimeout) { readFiles() }
    }

    /// Changes whenever a record file changes, in content or by a folder swap. It takes no lock, so a watcher can
    /// poll it often.
    public func stamp() -> String {
        files().map { url in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return url.lastPathComponent + "@-" }
            let nanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
            return "\(url.lastPathComponent)@\(info.st_ino):\(nanoseconds):\(info.st_size)"
        }.joined(separator: "|")
    }

    /// Runs `body` on the files as they are now, under the exclusive record lock, and writes what it changed.
    /// One changed record replaces its file; several replace the whole folder at once. `locks` are the Locked
    /// Sessions as tmux has them now: a write that changes the order places the Topics among them.
    @discardableResult
    public func write<T>(locks: [SessionLock] = [], _ body: (inout TopicTransaction) throws -> T) throws -> T {
        try FileLock.withLock(paths.recordLock, .exclusive, rank: .record, timeout: lockTimeout) {
            removeOrphanStagingFolders()
            let contents = readFiles()
            var transaction = TopicTransaction(records: contents.records, topics: paths.topics)
            transaction.locks = locks
            let result = try body(&transaction)
            let changed = try transaction.records.filter { record in
                let old = contents.records.first { $0.id == record.id }
                return try old.map { try Self.encoded($0) } != Self.encoded(record)
            }
            let removed = contents.records.filter { old in !transaction.records.contains { $0.id == old.id } }.map(\.id)
            if !removed.isEmpty { try swapFolder(with: changed, removing: removed) }
            else if changed.count == 1 { try writeFile(changed[0]) } else if changed.count > 1 { try swapFolder(with: changed) }
            return result
        }
    }

    // MARK: - Files

    private func readFiles() -> TopicContents {
        var records: [TopicRecord] = []
        var problems: [String] = []
        for url in files() {
            do {
                let record = try JSONDecoder().decode(TopicRecord.self, from: Data(contentsOf: url))
                guard url.deletingPathExtension().lastPathComponent == record.id else {
                    problems.append("\(url.path): filename must match the Topic id")
                    continue
                }
                records.append(record)
            } catch {
                problems.append("\(url.path): \(error)")
            }
        }
        let needsUpgrade = FileManager.default.fileExists(atPath: paths.legacyZenFile.path)
            || records.contains { $0.unknownFields[SnoozeUpgrade.field] != nil }
        return TopicContents(records: records, problems: problems, needsUpgrade: needsUpgrade)
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: paths.topics, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { Array($0.lastPathComponent.utf8).lexicographicallyPrecedes(Array($1.lastPathComponent.utf8)) }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Also checks that the id is a filename, for records made in memory.
    static func encoded(_ record: TopicRecord) throws -> Data {
        let data = try encoder.encode(record)
        _ = try JSONDecoder().decode(TopicRecord.self, from: data)
        return data
    }

    private func writeFile(_ record: TopicRecord) throws {
        try FileManager.default.createDirectory(at: paths.topics, withIntermediateDirectories: true)
        try writeData(Self.encoded(record), paths.topics.appendingPathComponent(record.id + ".json"))
    }

    /// Copies the folder, writes the changed records into the copy, and swaps it in with one rename, so a reader
    /// sees all of the changes or none of them.
    private func swapFolder(with records: [TopicRecord], removing ids: [String] = []) throws {
        let writes = try records.map { ($0, try Self.encoded($0)) }
        let files = FileManager.default
        let directory = paths.topics
        try files.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let staging = paths.state.appendingPathComponent(".topics-" + UUID().uuidString, isDirectory: true)
        var committed = false
        do {
            if files.fileExists(atPath: directory.path) { try files.copyItem(at: directory, to: staging) }
            else { try files.createDirectory(at: staging, withIntermediateDirectories: false) }
            for id in ids { try files.removeItem(at: staging.appendingPathComponent(id + ".json")) }
            for (record, data) in writes {
                try writeData(data, staging.appendingPathComponent(record.id + ".json"))
            }
            if files.fileExists(atPath: directory.path) {
                let result = directory.path.withCString { current in
                    staging.path.withCString { replacement in
                        renameatx_np(AT_FDCWD, current, AT_FDCWD, replacement, UInt32(RENAME_SWAP))
                    }
                }
                guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                committed = true
                try? files.removeItem(at: staging)
            } else {
                try files.moveItem(at: staging, to: directory)
                committed = true
            }
        } catch {
            if !committed { try? files.removeItem(at: staging) }
            throw error
        }
    }

    /// A staging folder that exists while this process holds the record lock was left by a writer that crashed.
    private func removeOrphanStagingFolders() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.state.path)) ?? []
        for name in names where name.hasPrefix(".topics-") {
            try? FileManager.default.removeItem(at: paths.state.appendingPathComponent(name))
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
    private let topics: URL

    init(records: [TopicRecord], topics: URL) {
        self.records = records
        self.topics = topics
    }

    public enum Failure: Error, CustomStringConvertible {
        case topicUnavailable(String)

        public var description: String {
            switch self {
            case .topicUnavailable: return "The Topic is no longer in the Topic records."
            }
        }
    }

    private var entries: [TopicListEntry] { records.map(TopicListEntry.topic) + locks.map(TopicListEntry.lock) }

    /// Adds a new Topic where `arrival` puts it, or in the place of the Lock of `lockedSessionID`, which then ends. A
    /// file of that name that is not a valid record is not replaced.
    @discardableResult
    public mutating func create(_ record: TopicRecord, arrival: TopicArrival = .end(.bottom), replacingLockOf lockedSessionID: String? = nil) throws -> [SessionLock] {
        _ = try TopicStore.encoded(record)
        guard !FileManager.default.fileExists(atPath: topics.appendingPathComponent(record.id + ".json").path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        if let index = locks.firstIndex(where: { $0.sessionID == lockedSessionID }) {
            var placed = record
            placed.order = locks.remove(at: index).order
            return put([.topic(placed)])
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
    public mutating func apply(_ change: TopicRecordChange, arrival: TopicArrival = .end(.bottom), replacingLockOf lockedSessionID: String? = nil) throws -> [SessionLock] {
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

    public mutating func forget(_ id: String) throws {
        guard records.contains(where: { $0.id == id }) else { throw Failure.topicUnavailable(id) }
        records.removeAll { $0.id == id }
    }

    @discardableResult
    public mutating func move(_ id: TopicListID, to placement: TopicPlacement) throws -> [SessionLock] {
        put(try TopicOrder.moving(id, to: placement, in: entries))
    }

    @discardableResult
    public mutating func trade(_ id: TopicListID, with other: TopicListID) throws -> [SessionLock] {
        put(try TopicOrder.trading(id, with: other, in: entries))
    }

    @discardableResult
    public mutating func pin(_ id: String, _ pinned: Bool) throws -> [SessionLock] {
        put(try TopicOrder.pinning(id, pinned, in: entries))
    }

    @discardableResult
    public mutating func chooseInPlay(_ chosen: [TopicListID]) throws -> [SessionLock] {
        put(try TopicOrder.choosingInPlay(chosen, in: entries))
    }

    @discardableResult
    public mutating func replaceFromBench(_ card: TopicListID, with benched: TopicListID, inPlay: Int) throws -> [SessionLock] {
        put(try TopicOrder.replacingFromBench(card, with: benched, inPlay: inPlay, in: entries))
    }

    /// Locks the Session last among the Topics that are not Pinned. A Session that is already Locked keeps its place.
    @discardableResult
    public mutating func lock(_ sessionID: String) -> [SessionLock] {
        guard !locks.contains(where: { $0.sessionID == sessionID }) else { return [] }
        return put(TopicOrder.appendingLock(of: sessionID, in: entries))
    }

    /// Returns the Locks among `changed`.
    @discardableResult
    private mutating func put(_ changed: [TopicListEntry]) -> [SessionLock] {
        for record in changed.records {
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
            else { records.append(record) }
        }
        for lock in changed.locks {
            if let index = locks.firstIndex(where: { $0.sessionID == lock.sessionID }) { locks[index] = lock }
            else { locks.append(lock) }
        }
        return changed.locks
    }

    private static func fields(_ record: TopicRecord) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(record))
    }

    /// Ends the old Zen as it ended before: each Topic it Snoozed gets its earlier `snoozed_until` back. Then each
    /// open Topic that is not Pinned and has a Snooze goes where `arrival` puts a returning Topic, in the order it would
    /// wake. Last, no record keeps `snoozed_until`, so a second run changes nothing.
    mutating func upgradeSnoozes(endingZen zen: SnoozeUpgrade.Zen?, arrival: TopicArrival) throws -> [SessionLock] {
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
        return locks.filter { moved.contains($0.sessionID) }
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
