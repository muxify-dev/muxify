import Foundation
import XCTest
@testable import MuxifyCore

/// The Topic records as another writer leaves them, and as the tests read them back, without the store: SQL on a
/// connection of the test's own to the state database, or `topics.json` as an older Muxify left it.
extension MuxifyPaths {
    /// Runs `body` on a connection of its own to the state database, which it opens, so the schema is there.
    func withStateDatabase<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try body(StateDatabase.open(self))
    }

    /// Writes `topics.json` with these entries, each a JSON text, valid record or not, as an older Muxify left it.
    /// The next open of the state database imports it.
    func seedTopicRecordsFile(entries: [String], openPlaces: String = "[]") throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{\"records\":[\(entries.joined(separator: ","))],\"open_places\":\(openPlaces)}".utf8).write(to: topicRecords)
    }

    /// Inserts a row for each record, as another writer does.
    func seedTopicRecords(_ records: TopicRecord...) throws {
        try withStateDatabase { connection in
            for record in records {
                func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
                try connection.execute("""
                    INSERT INTO topics (id, title, slug, outcome, "order", created_at, settled_at, session_order, pinned, guest,
                                        unread, note, sessions, tags)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, record.id, record.title, record.slug, record.outcome, record.order, record.createdAt, record.settledAt,
                    record.hasManualSessionOrder ? "manual" : nil, record.isPinned, record.isGuest, record.isUnread, record.note,
                    try json(record.sessions), try json(record.tags.sorted().map(\.name)))
            }
        }
    }

    /// Every row of `topics`, each column by name, in id order.
    func storedTopicRows() throws -> [[String: SQLiteValue]] {
        try withStateDatabase { connection in
            let names = try connection.query("SELECT name FROM pragma_table_info('topics') ORDER BY cid") { $0.text(0) ?? "" }
            return try connection.query("SELECT * FROM topics ORDER BY id") { row in
                Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, row.value(Int32($0))) })
            }
        }
    }

    /// The row of `topics` with this id, each column by name; nil when there is none.
    func storedTopicRecord(_ id: String) throws -> [String: SQLiteValue]? {
        try storedTopicRows().first { $0["id"] == .text(id) }
    }

    /// The JSON text of a column, such as `sessions` or `tags`, as a value.
    func storedJSON(_ id: String, _ column: String) throws -> JSONValue? {
        guard let text = try storedTopicRecord(id)?[column]?.text else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The rows of `open_places`, in the order they were added.
    func storedOpenPlaces() throws -> [OpenPlace] {
        try withStateDatabase { connection in
            try connection.query(#"SELECT id, "order" FROM open_places ORDER BY rowid"#) { OpenPlace(id: $0.text(0) ?? "", order: $0.double(1)) }
        }
    }
}
