import WebKit
import XCTest

final class BrowserHistoryTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(_ directory: TestDirectory, capacity: Int = BrowserHistory.capacity) -> BrowserHistory {
        BrowserHistory(file: directory.url.appendingPathComponent("state/browser-history.json"), capacity: capacity, writeDelay: 0)
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testAScoreHalvesEachFourteenDays() {
        let entry = HistoryEntry(key: "k", url: "https://a.test", title: "", recent: [.init(at: start, weight: 4)], topics: [])
        XCTAssertEqual(entry.score(at: start), 4)
        XCTAssertEqual(entry.score(at: start + 14 * day), 2, accuracy: 1e-9)
        XCTAssertEqual(entry.score(at: start + 28 * day), 1, accuracy: 1e-9)
    }

    func testATypedVisitWeighsTwoALinkOneAndTheOldScoreDecaysFirst() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        history.record(url: url("https://example.com/a"), title: "A", visit: .typed, topic: nil, at: start)
        history.record(url: url("https://example.com/a#part"), title: "", visit: .link, topic: nil, at: start)
        let entry = try XCTUnwrap(history.entries["https://example.com/a"])
        XCTAssertEqual(entry.score(at: start), 3, "one History entry for the URL with and without its fragment")
        XCTAssertEqual(entry.title, "A", "an empty title keeps the one the entry has")
        history.record(url: url("https://example.com/a"), title: "A", visit: .typed, topic: nil, at: start + 14 * day)
        XCTAssertEqual(history.entries["https://example.com/a"]?.score(at: start + 14 * day) ?? 0, 3 * 0.5 + 2, accuracy: 1e-9)
    }

    /// The score of each visit apart, summed, is the score that decays the old sum at each visit and adds the weight.
    func testTheScoreOfTheVisitsEqualsTheScoreThatDecaysAtEachVisit() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        let visits: [(TimeInterval, HistoryVisit)] = [(0, .typed), (0.5, .link), (3, .link), (9, .typed), (9.2, .link), (20, .link), (40, .typed)]
        var expected = 0.0
        var last = start
        for (days, visit) in visits {
            let at = start + days * day
            expected = expected * pow(0.5, at.timeIntervalSince(last) / HistoryEntry.halfLife) + visit.weight
            last = at
            history.record(url: url("https://example.com"), title: "", visit: visit, topic: nil, at: at)
        }
        let now = start + 45 * day
        let entry = try XCTUnwrap(history.entries["https://example.com"])
        XCTAssertNotNil(entry.folded, "the visits before the last 7 days are folded")
        XCTAssertEqual(entry.score(at: now), expected * pow(0.5, now.timeIntervalSince(last) / HistoryEntry.halfLife), accuracy: 1e-9)
    }

    func testAVisitOlderThanSevenDaysFoldsIntoTheScoreAtEachRecord() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        for days in [0.0, 1, 7.5, 8] {
            history.record(url: url("https://example.com"), title: "", visit: .link, topic: nil, at: start + days * day)
        }
        let entry = try XCTUnwrap(history.entries["https://example.com"])
        XCTAssertEqual(entry.recent.map(\.at), [start + 1 * day, start + 7.5 * day, start + 8 * day], "only the visit of day 0 is 7 days before day 8")
        XCTAssertEqual(entry.folded, HistoryEntry.Folded(score: 1, at: start))
    }

    func testAFileFromBeforeTheRecentVisitsDecodesAsOneFoldedScore() throws {
        let json = #"[{"key":"https://a.test","url":"https://a.test","title":"A","score":3.5,"lastVisit":800000000,"topics":["t"]}]"#
        let entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries, [HistoryEntry(key: "https://a.test", url: "https://a.test", title: "A",
                                              folded: .init(score: 3.5, at: Date(timeIntervalSinceReferenceDate: 800_000_000)), topics: ["t"])])
        let reencoded = try JSONDecoder().decode([HistoryEntry].self, from: JSONEncoder().encode(entries))
        XCTAssertEqual(reencoded, entries, "the new shape reads back the same")
    }

    func testAnEntryKeepsEveryTopicOfItsVisits() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        history.record(url: url("https://example.com"), title: "", visit: .link, topic: "one", at: start)
        history.record(url: url("https://example.com"), title: "", visit: .link, topic: nil, at: start)
        history.record(url: url("https://example.com"), title: "", visit: .link, topic: "two", at: start)
        XCTAssertEqual(history.entries["https://example.com"]?.topics, ["one", "two"])
    }

    func testOverTheCapTheLowestDecayedScoreGoes() throws {
        let directory = try TestDirectory()
        let history = history(directory, capacity: 2)
        history.setEnabled(true)
        history.record(url: url("https://old.test"), title: "", visit: .typed, topic: nil, at: start)
        history.record(url: url("https://kept.test"), title: "", visit: .link, topic: nil, at: start + 20 * day)
        history.record(url: url("https://new.test"), title: "", visit: .link, topic: nil, at: start + 20 * day)
        XCTAssertEqual(Set(history.entries.keys), ["https://kept.test", "https://new.test"],
                       "2 decayed over 20 days is below a link of now")
    }

    func testOnlyPagesThatArePlacesWithoutSecretsAreRecordable() {
        XCTAssertTrue(HistoryVisit.isRecordable(url("https://example.com/search?q=swift")))
        XCTAssertTrue(HistoryVisit.isRecordable(url("http://localhost:5173/")))
        XCTAssertTrue(HistoryVisit.isRecordable(URL(fileURLWithPath: "/tmp/page.html")))
        XCTAssertFalse(HistoryVisit.isRecordable(url("about:blank")))
        XCTAssertFalse(HistoryVisit.isRecordable(url("data:text/html,hi")))
        for key in ["token", "access_token", "code", "sig", "signature", "password", "key", "Token"] {
            XCTAssertFalse(HistoryVisit.isRecordable(url("https://example.com/cb?state=1&\(key)=secret")), key)
        }
        XCTAssertTrue(HistoryVisit.isRecordable(url("https://example.com/?keyboard=1")), "only the whole key name counts")
        XCTAssertFalse(HistoryVisit.isRecordable(url("https://app.test/callback#access_token=secret&state=1")), "a token in the fragment")
        XCTAssertTrue(HistoryVisit.isRecordable(url("https://docs.test/guide#install")), "a plain fragment")
    }

    func testRecordingSkipsAboutBlankAndSecretURLs() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        history.record(url: url("about:blank"), title: "", visit: .typed, topic: nil, at: start)
        history.record(url: url("https://example.com/login?code=abc"), title: "", visit: .link, topic: nil, at: start)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testAFinishedLoadIsTypedFromTheFieldAndALinkOtherwise() {
        let first = ObjectIdentifier(NSObject()), second = ObjectIdentifier(NSObject())
        var loads = HistoryLoads()
        loads.next = .typed
        loads.decide(.other, byAgent: false)
        loads.start(first)
        loads.decide(.other, byAgent: false)
        XCTAssertEqual(loads.finish(first, byAgent: false), .typed, "a server redirect keeps the origin of its load")
        loads.decide(.linkActivated, byAgent: false)
        loads.start(second)
        XCTAssertEqual(loads.finish(second, byAgent: false), .link)
    }

    func testAReloadARestoredPageAndAFailedLoadAreNotVisits() {
        let navigation = ObjectIdentifier(NSObject())
        var loads = HistoryLoads()
        loads.decide(.reload, byAgent: false)
        loads.start(navigation)
        XCTAssertNil(loads.finish(navigation, byAgent: false), "a reload")
        loads.next = .skipped
        loads.decide(.other, byAgent: false)
        loads.start(navigation)
        XCTAssertNil(loads.finish(navigation, byAgent: false), "a restored page")
        loads.decide(.linkActivated, byAgent: false)
        loads.start(navigation)
        loads.fail(navigation)
        XCTAssertNil(loads.finish(navigation, byAgent: false), "a failed load")
        XCTAssertNil(loads.finish(ObjectIdentifier(NSObject()), byAgent: false), "a finish without a start, as a same-document navigation")
    }

    func testALoadThatABrowserCommandStartsOrOutlivesIsNotAVisit() {
        let navigation = ObjectIdentifier(NSObject())
        var loads = HistoryLoads()
        loads.next = .typed
        loads.decide(.other, byAgent: true)
        loads.start(navigation)
        XCTAssertNil(loads.finish(navigation, byAgent: false), "started while a Browser command runs")
        loads.decide(.linkActivated, byAgent: false)
        loads.start(navigation)
        XCTAssertNil(loads.finish(navigation, byAgent: true), "finished while a Browser command runs")
    }

    func testATitleChangeUpdatesTheEntryOfThePage() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        history.record(url: url("https://app.test/"), title: "Inbox", visit: .link, topic: nil, at: start)
        history.updateTitle(of: "https://app.test", to: "Inbox (3)")
        history.updateTitle(of: "https://other.test", to: "Other")
        XCTAssertEqual(history.entries["https://app.test"]?.title, "Inbox (3)")
        XCTAssertNil(history.entries["https://other.test"], "a title change never adds a History entry")
    }

    func testEntriesStayAcrossALaunch() throws {
        let directory = try TestDirectory()
        let first = history(directory)
        first.setEnabled(true)
        first.record(url: url("https://example.com/a"), title: "A", visit: .typed, topic: "t", at: start)
        first.flush()
        let second = history(directory)
        second.setEnabled(true)
        XCTAssertEqual(second.entries, first.entries)
    }

    func testWhileOffNothingIsRecordedAndTheFileIsNeitherReadNorWritten() throws {
        let directory = try TestDirectory()
        let off = history(directory)
        off.record(url: url("https://example.com"), title: "", visit: .typed, topic: nil, at: start)
        off.flush()
        XCTAssertTrue(off.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.file.path), "off writes no file")

        let on = history(directory)
        on.setEnabled(true)
        on.record(url: url("https://example.com"), title: "", visit: .typed, topic: nil, at: start)
        on.flush()
        let unread = history(directory)
        XCTAssertTrue(unread.entries.isEmpty, "off does not read the file")
        on.setEnabled(false)
        XCTAssertTrue(on.entries.isEmpty, "turning it off drops the entries from memory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: on.file.path), "turning it off keeps the file")
    }

    func testWhileOffTheAddressFieldSuggestsNothingNotEvenTheOpenTabsPortsOrSearch() throws {
        let history = history(try TestDirectory())
        let live = LiveRows(tabs: [.init(id: UUID(), url: "https://example.com/", title: "Example")], ports: [3000])
        XCTAssertEqual(history.suggestions(for: "ex", live: live, activeTopic: nil, now: start), [])
        XCTAssertEqual(history.suggestions(for: "loc", live: live, activeTopic: nil, now: start), [])

        history.setEnabled(true)
        XCTAssertEqual(history.suggestions(for: "ex", live: live, activeTopic: nil, now: start).first?.url, "https://example.com/")
    }
}
