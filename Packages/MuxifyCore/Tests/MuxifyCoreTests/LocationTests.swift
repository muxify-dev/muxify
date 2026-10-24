import XCTest
@testable import MuxifyCore

final class LocationTests: XCTestCase {
    func testLocationKeepsTheTopicChangeJSON() throws {
        let fixtures: [(Location, String)] = [
            (.window(WindowID(rawValue: "@7")!), #"{"window":{"id":"@7"}}"#),
            (.emptyTopic(.topic("topic-1")), #"{"empty_topic":{"id":"topic-1"}}"#),
            (.emptyTopic(.noTopic), #"{"empty_topic":{"no_topic":true}}"#),
        ]
        XCTAssertThrowsError(try JSONEncoder().encode(Location.emptyTopic(.locked("$2"))))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (location, json) in fixtures {
            XCTAssertEqual(String(decoding: try encoder.encode(location), as: UTF8.self), json)
            XCTAssertEqual(try JSONDecoder().decode(Location.self, from: Data(json.utf8)), location)
            let change = TopicChange(topicID: nil, shown: location)
            let encoded = try encoder.encode(change)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"created":false,"shown":\#(json)}"#)
            XCTAssertEqual(try JSONDecoder().decode(TopicChange.self, from: encoded), change)
        }
    }
}
