import XCTest
import MuxifyCore

/// `TopicRef.resolve` is the one rule by which the service and the command line tool find a Topic from what a user typed.
final class TopicRefTests: XCTestCase {
    private func record(_ id: String, title: String? = nil, slug: String? = nil, settled: Bool = false) -> TopicRecord {
        var record = TopicRecord(id: id, title: title, slug: slug)
        if settled { record.settledAt = "2026-10-01T09:00:00Z" }
        return record
    }

    func testANameIsAnIdFirstThenASlugOrATitle() throws {
        let records = [record("a1", title: "Ship", slug: "ship"), record("ship", title: "Docs", slug: "docs")]
        XCTAssertEqual(try TopicRef.named("ship").resolve(in: records).id, "ship", "an id wins over another Topic's slug")
        XCTAssertEqual(try TopicRef.named("Ship").resolve(in: records).id, "a1")
        XCTAssertEqual(try TopicRef.named("docs").resolve(in: records).id, "ship")
        XCTAssertEqual(try TopicRef.id("a1").resolve(in: records).id, "a1")
        XCTAssertThrowsError(try TopicRef.id("Ship").resolve(in: records)) { error in
            guard case TopicRequestError.topicUnavailable("Ship") = error else { return XCTFail("\(error)") }
        }
    }

    func testANameThatTwoOpenTopicsHaveIsAmbiguous() {
        let records = [record("a1", title: "Fix", slug: "fix"), record("b2", title: "Fix", slug: "fix-2")]
        XCTAssertThrowsError(try TopicRef.named("Fix").resolve(in: records)) { error in
            guard case TopicRequestError.topicAmbiguous("Fix") = error else { return XCTFail("\(error)") }
        }
    }

    func testANameMatchesTheLabelThatTheCardShows() throws {
        let records = [record("a1", slug: "untitled-3"), record("b2", title: "")]
        XCTAssertEqual(try TopicRef.named("Untitled 3").resolve(in: records).id, "a1", "the N of its slug")
        XCTAssertEqual(try TopicRef.named("Untitled 1").resolve(in: records).id, "b2", "the lowest free N")
        XCTAssertThrowsError(try TopicRef.named("Untitled 1").resolve(in: records + [record("c3", title: "Untitled 1")])) { error in
            guard case TopicRequestError.topicAmbiguous("Untitled 1") = error else { return XCTFail("\(error)") }
        }
    }

    func testASettledTopicIsFoundOnlyWhenTheRequestAllowsIt() throws {
        let records = [record("a1", title: "Old", slug: "old", settled: true), record("b2", title: "Fix", slug: "fix")]
        XCTAssertThrowsError(try TopicRef.named("old").resolve(in: records, open: true)) { error in
            guard case TopicRequestError.topicUnavailable("old") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try TopicRef.id("a1").resolve(in: records, open: true))
        XCTAssertEqual(try TopicRef.named("old").resolve(in: records, open: false).id, "a1")
        XCTAssertEqual(try TopicRef.id("a1").resolve(in: records, open: false).id, "a1")
        let reused = records + [record("c3", title: "Old", slug: "old-2")]
        XCTAssertEqual(try TopicRef.named("Old").resolve(in: reused, open: true).id, "c3", "a Settled Topic makes no open name ambiguous")
    }
}
