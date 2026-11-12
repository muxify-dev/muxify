import Foundation

/// The Topic records and the Open Places in the state database: the `topics` and `open_places` tables, how a record
/// maps to a row, and the one-time import of `topics.json`.
enum TopicTable {
    /// One row for each Topic, keyed by its id. Each scalar field has a column; `sessions` and `tags` are JSON text,
    /// written whole. The slug is not UNIQUE: two Topics made at the same moment may share one.
    static let migration = StateDatabase.Migration(
        """
        CREATE TABLE topics (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT,
            slug TEXT,
            outcome TEXT,
            "order" REAL,
            created_at TEXT,
            settled_at TEXT,
            session_order TEXT,
            pinned INTEGER NOT NULL DEFAULT 0,
            guest INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0,
            note TEXT,
            sessions TEXT NOT NULL DEFAULT '[]',
            tags TEXT NOT NULL DEFAULT '[]'
        )
        """,
        """
        CREATE TABLE open_places (
            id TEXT PRIMARY KEY NOT NULL,
            "order" REAL NOT NULL
        )
        """
    )

    /// The columns of a record besides `id`, in the order `values(of:)` gives them.
    static let columns = ["title", "slug", "outcome", "order", "created_at", "settled_at", "session_order",
                          "pinned", "guest", "unread", "note", "sessions", "tags"]

    private static let quoted = columns.map { "\"\($0)\"" }

    // MARK: - A record as a row

    /// The record's value for each of `columns`.
    static func values(of record: TopicRecord) -> [String: SQLiteValue] {
        [
            "title": SQLiteValue(record.title),
            "slug": SQLiteValue(record.slug),
            "outcome": SQLiteValue(record.outcome),
            "order": SQLiteValue(record.order),
            "created_at": SQLiteValue(record.createdAt),
            "settled_at": SQLiteValue(record.settledAt),
            "session_order": SQLiteValue(record.hasManualSessionOrder ? "manual" : nil),
            "pinned": SQLiteValue(record.isPinned),
            "guest": SQLiteValue(record.isGuest),
            "unread": SQLiteValue(record.isUnread),
            "note": SQLiteValue(record.note),
            "sessions": .text(json(record.sessions)),
            "tags": .text(json(record.tags.sorted().map(\.name))),
        ]
    }

    /// The record that a row holds. A `sessions` or `tags` value that is not a JSON array reads as empty, and a tag
    /// that is not a Tag is left out, so a row that `sqlite3` changed by hand still reads.
    static func record(id: String, _ values: [String: SQLiteValue]) -> TopicRecord {
        var record = TopicRecord(id: id, title: values["title"]?.text, slug: values["slug"]?.text)
        record.outcome = values["outcome"]?.text
        record.order = values["order"]?.real
        record.createdAt = values["created_at"]?.text
        record.settledAt = values["settled_at"]?.text
        record.hasManualSessionOrder = values["session_order"]?.text == "manual"
        record.isPinned = values["pinned"]?.isTrue ?? false
        record.isGuest = values["guest"]?.isTrue ?? false
        record.isUnread = values["unread"]?.isTrue ?? false
        record.note = values["note"]?.text
        record.sessions = decoded([JSONValue].self, values["sessions"]) ?? []
        record.tags = Set((decoded([JSONValue].self, values["tags"]) ?? []).compactMap { $0.string.flatMap(Tag.init(typed:)) })
        return record
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A `JSONValue` and an array of names always encode.
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    private static func decoded<T: Decodable>(_ type: T.Type, _ value: SQLiteValue?) -> T? {
        value?.text.flatMap { try? JSONDecoder().decode(type, from: Data($0.utf8)) }
    }

    // MARK: - Reads and writes

    /// Every record in id order, by bytes, and the Open Places in the order they were added.
    static func contents(_ connection: SQLiteConnection) throws -> TopicContents {
        let records = try connection.query("SELECT id, \(quoted.joined(separator: ", ")) FROM topics ORDER BY id") { row in
            record(id: row.text(0) ?? "", Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, row.value(Int32($0 + 1))) }))
        }
        let openPlaces = try connection.query(#"SELECT id, "order" FROM open_places ORDER BY rowid"#) { row in
            OpenPlace(id: row.text(0) ?? "", order: row.double(1))
        }
        return TopicContents(records: records, openPlaces: openPlaces)
    }

    static func insert(_ record: TopicRecord, _ connection: SQLiteConnection) throws {
        let values = values(of: record)
        let marks = Array(repeating: "?", count: columns.count + 1).joined(separator: ", ")
        let statement = try connection.prepare("INSERT INTO topics (id, \(quoted.joined(separator: ", "))) VALUES (\(marks))")
        try statement.bind([record.id] + columns.map { values[$0] })
        while try statement.step() {}
    }

    /// Writes what changed from `start` to `end`: new records and Open Places are inserted, removed ones deleted, and a
    /// changed record updates only the columns whose values differ. Nothing changed writes nothing.
    static func save(from start: TopicContents, to end: TopicContents, _ connection: SQLiteConnection) throws {
        let before = Dictionary(start.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(end.records.map(\.id))
        for id in before.keys.sorted() where !after.contains(id) {
            try connection.execute("DELETE FROM topics WHERE id = ?", id)
        }
        for record in end.records {
            guard let old = before[record.id] else {
                try insert(record, connection)
                continue
            }
            let was = values(of: old), now = values(of: record)
            let changed = columns.filter { was[$0] != now[$0] }
            guard !changed.isEmpty else { continue }
            let sets = changed.map { "\"\($0)\" = ?" }.joined(separator: ", ")
            let statement = try connection.prepare("UPDATE topics SET \(sets) WHERE id = ?")
            try statement.bind(changed.map { now[$0] } + [record.id])
            while try statement.step() {}
        }
        let places = Dictionary(start.openPlaces.map { ($0.id, $0.order) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(end.openPlaces.map(\.id))
        for id in places.keys.sorted() where !kept.contains(id) {
            try connection.execute("DELETE FROM open_places WHERE id = ?", id)
        }
        for place in end.openPlaces {
            switch places[place.id] {
            case nil: try connection.execute(#"INSERT INTO open_places (id, "order") VALUES (?, ?)"#, place.id, place.order)
            case place.order?: continue
            default: try connection.execute(#"UPDATE open_places SET "order" = ? WHERE id = ?"#, place.order, place.id)
            }
        }
    }

    // MARK: - The import

    /// `topics.json` as an older Muxify wrote it: an object with a `records` array and an `open_places` array.
    private struct RecordsFile: Decodable {
        let records: [Entry]
        let openPlaces: Places?

        private enum CodingKeys: String, CodingKey {
            case records, openPlaces = "open_places"
        }
    }

    /// One entry of `records`: a record, or why it is not one, with its id when it has a string id.
    private struct Entry: Decodable {
        let record: Result<TopicRecord, Error>
        let id: String?

        private enum Key: String, CodingKey { case id }

        init(from decoder: Decoder) throws {
            record = Result { try TopicRecord(from: decoder) }
            id = try? decoder.container(keyedBy: Key.self).decode(String.self, forKey: .id)
        }
    }

    /// The `open_places` value: the Open Places, or why it is not a list of them.
    private struct Places: Decodable {
        let places: Result<[OpenPlace], Error>

        init(from decoder: Decoder) throws {
            places = Result { try [OpenPlace](from: decoder) }
        }
    }

    /// Moves `topics.json` into the tables, when it is there, then renames it to `topics.json.migrated`. An entry that
    /// is not a valid record, or that repeats an id, stays behind with a problem line that names it. A file that is not
    /// a records file stays in place, and nothing moves.
    static func importRecordsFile(_ connection: SQLiteConnection, _ paths: MuxifyPaths, report: (String) -> Void) throws {
        let url = paths.topicRecords
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        let file: RecordsFile
        do { file = try JSONDecoder().decode(RecordsFile.self, from: data) } catch {
            report("\(url.path) is not a Topic records file, so Muxify imported nothing from it and left it in place: \(error)")
            return
        }
        var seen = Set(try connection.query("SELECT id FROM topics") { $0.text(0) ?? "" })
        for (index, entry) in file.records.enumerated() {
            let name = "\(url.path): records[\(index)]" + (entry.id.map { " (id \($0))" } ?? "")
            switch entry.record {
            case .failure(let error):
                report("\(name) is not a valid Topic record, so Muxify did not import it: \(error)")
            case .success(let record):
                guard seen.insert(record.id).inserted else {
                    report("\(name) repeats the id of an earlier record, so Muxify did not import it")
                    continue
                }
                try insert(record, connection)
            }
        }
        switch file.openPlaces?.places {
        case .success(let places)?:
            for place in places {
                try connection.execute(#"INSERT OR IGNORE INTO open_places (id, "order") VALUES (?, ?)"#, place.id, place.order)
            }
        case .failure(let error)?:
            report("\(url.path): open_places is not a list of Open Places, so Muxify did not import them: \(error)")
        case nil:
            break
        }
        let migrated = url.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: migrated)
        try FileManager.default.moveItem(at: url, to: migrated)
    }
}
