import Foundation
import XCTest
@testable import MuxifyCore

/// The records file as another writer leaves it, and as the tests read it back, without the store.
extension MuxifyPaths {
    /// Writes the records file with these entries, each a JSON text, valid record or not.
    func seedTopicRecords(entries: [String], openPlaces: String = "[]") throws {
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{\"records\":[\(entries.joined(separator: ","))],\"open_places\":\(openPlaces)}".utf8).write(to: topicRecords)
    }

    func seedTopicRecords(_ records: TopicRecord...) throws {
        try seedTopicRecords(entries: records.map { String(decoding: try TopicStore.encoded($0), as: UTF8.self) })
    }

    /// Writes the folder of an older Muxify: `topics/<name>` with this text, for each name.
    func seedLegacyTopicsFolder(_ files: [String: String]) throws {
        try FileManager.default.createDirectory(at: legacyTopicsFolder, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: legacyTopicsFolder.appendingPathComponent(name)) }
    }

    /// The records file as JSON, through `JSONSerialization`: a `JSONValue` holds no number past the range of `Decimal`.
    private func storedFile() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: topicRecords)) as? [String: Any])
    }

    /// The entries of the records file, each as JSON, in file order.
    func storedTopicEntries() throws -> [JSONValue] {
        try JSONDecoder().decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(storedFile()["records"])))
    }

    func storedOpenPlaces() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(storedFile()["open_places"])))
    }

    /// The first entry of the records file whose `id` is this one, as JSON; nil when no entry has it.
    func storedTopicRecord(_ id: String) throws -> [String: JSONValue]? {
        let entries = try XCTUnwrap(storedFile()["records"] as? [Any])
        guard let entry = entries.first(where: { ($0 as? [String: Any])?["id"] as? String == id }) else { return nil }
        return try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: entry))
    }
}
