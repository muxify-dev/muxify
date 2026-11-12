import Foundation

/// Browser History in the state database: the `browser_history` table, how a History entry maps to a row, and the
/// one-time import of the `browser-history.json` an older Muxify wrote.
enum BrowserHistoryTable {
    /// One row for each History entry, keyed by its key. `folded_score` and `folded_at` are both NULL for an entry
    /// with no folded score. Times are seconds since 1970. `recent` is JSON text, a list of `{"at", "weight"}`
    /// oldest first; `topics` is JSON text, a list of Topic ids.
    static let migration = StateDatabase.Migration(
        """
        CREATE TABLE browser_history (
            key TEXT PRIMARY KEY NOT NULL,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            folded_score REAL,
            folded_at REAL,
            recent TEXT NOT NULL DEFAULT '[]',
            topics TEXT NOT NULL DEFAULT '[]'
        )
        """
    )

    private static let columns = "key, url, title, folded_score, folded_at, recent, topics"

    /// Every History entry. A `recent` or `topics` value that is not the JSON it should be reads as empty, so a row
    /// that `sqlite3` changed by hand still reads.
    static func entries(_ connection: SQLiteConnection) throws -> [HistoryEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try connection.query("SELECT \(columns) FROM browser_history") { row in
            let folded = row.isNull(3) || row.isNull(4)
                ? nil : HistoryEntry.Folded(score: row.double(3), at: Date(timeIntervalSince1970: row.double(4)))
            let recent = row.text(5).flatMap { try? decoder.decode([HistoryEntry.Visit].self, from: Data($0.utf8)) } ?? []
            let topics = row.text(6).flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
            return HistoryEntry(key: row.text(0) ?? "", url: row.text(1) ?? "", title: row.text(2) ?? "", folded: folded,
                                recent: recent, topics: Set(topics))
        }
    }

    /// Inserts the entry, or replaces the row with its key. With `replacing` false, a row with its key stays as it is.
    static func write(_ entry: HistoryEntry, replacing: Bool = true, _ connection: SQLiteConnection) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let recent = String(decoding: try encoder.encode(entry.recent), as: UTF8.self)
        let topics = String(decoding: try encoder.encode(entry.topics.sorted()), as: UTF8.self)
        let conflict = replacing
            ? """
              UPDATE SET url = excluded.url, title = excluded.title, folded_score = excluded.folded_score,
                  folded_at = excluded.folded_at, recent = excluded.recent, topics = excluded.topics
              """
            : "NOTHING"
        try connection.execute(
            "INSERT INTO browser_history (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(key) DO \(conflict)",
            entry.key, entry.url, entry.title, entry.folded?.score, entry.folded?.at.timeIntervalSince1970, recent, topics)
    }

    /// Writes `changed` and deletes the rows of `removed`, in one transaction. Every other row stays as it is.
    static func save(_ changed: [HistoryEntry], removing removed: Set<String>, _ connection: SQLiteConnection) throws {
        try connection.transaction {
            for key in removed.sorted() { try connection.execute("DELETE FROM browser_history WHERE key = ?", key) }
            for entry in changed { try write(entry, connection) }
        }
    }

    /// Removes the visits at or after `since` from every row, in one transaction, and deletes a row with no visit left.
    /// With no `since`, for All time, it deletes every row.
    static func clear(since: Date?, _ connection: SQLiteConnection) throws {
        guard let since else {
            try connection.execute("DELETE FROM browser_history")
            return
        }
        try connection.transaction {
            for entry in try entries(connection) {
                var cleared = entry
                cleared.removeVisits(since: since)
                if cleared.lastVisit == nil {
                    try connection.execute("DELETE FROM browser_history WHERE key = ?", entry.key)
                } else if cleared != entry {
                    try write(cleared, connection)
                }
            }
        }
    }

    // MARK: - The import

    /// Moves the History entries of `browser-history.json`, in its current shape or the older `{score, lastVisit}`
    /// one, into the table and renames the file to `browser-history.json.migrated`. A row the table has for a key
    /// stays. A file that does not decode stays where it is with a problem line, and nothing is imported from it.
    static func importFile(_ connection: SQLiteConnection, _ paths: MuxifyPaths, report: (String) -> Void) throws {
        let url = paths.browserHistory
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        let entries: [HistoryEntry]
        do { entries = try JSONDecoder().decode([HistoryEntry].self, from: data) } catch {
            report("\(url.path) is not a Browser History file, so Muxify imported nothing from it and left it in place: \(error)")
            return
        }
        for entry in entries { try write(entry, replacing: false, connection) }
        let migrated = url.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: migrated)
        try FileManager.default.moveItem(at: url, to: migrated)
    }
}

/// Browser History in the state database: the `browser_history` table (`BrowserHistoryTable`), one row for each
/// History entry. The app keeps the entries in memory and writes behind; a write touches only the rows it names, so
/// two processes that record different pages keep both.
public struct BrowserHistoryStore: Sendable {
    public let paths: MuxifyPaths
    private let database: StateConnection

    public init(paths: MuxifyPaths) {
        self.paths = paths
        database = StateConnection(paths: paths)
    }

    /// Every History entry. Without a state folder there is nothing to read, and the read creates nothing.
    public func entries() throws -> [HistoryEntry] {
        try database.use(creating: false) { try BrowserHistoryTable.entries($0) } ?? []
    }

    /// Writes `changed` in the place of the rows with their keys, and deletes the rows of `removed`, in one
    /// transaction. It never rewrites the table.
    public func save(_ changed: [HistoryEntry], removing removed: Set<String>) throws {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        _ = try database.use(creating: !changed.isEmpty) { try BrowserHistoryTable.save(changed, removing: removed, $0) }
    }

    /// Removes the visits at or after `since` from every row, and every row with no `since`.
    public func clear(since: Date?) throws {
        _ = try database.use(creating: false) { try BrowserHistoryTable.clear(since: since, $0) }
    }

    /// True when the table has a row. False when it cannot be read.
    public var hasEntries: Bool {
        (try? database.use(creating: false) { try $0.query("SELECT 1 FROM browser_history LIMIT 1") { _ in true }.isEmpty == false }) == true
    }
}
