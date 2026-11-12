import MuxifyCore
import XCTest

final class ClearBrowserHistoryTests: XCTestCase {
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(_ directory: TestDirectory) -> BrowserHistory {
        BrowserHistory(paths: MuxifyPaths(environment: ["XDG_STATE_HOME": directory.url.appendingPathComponent("state").path],
                                          home: "/nonexistent"), writeDelay: 0)
    }

    private func record(_ history: BrowserHistory, _ page: String, ago: [TimeInterval]) {
        for interval in ago.sorted(by: >) {
            history.record(url: URL(string: page)!, title: "", visit: .link, topic: nil, at: now - interval)
        }
    }

    private func rowKeys(_ history: BrowserHistory) throws -> [String] {
        try history.store.entries().map(\.key).sorted()
    }

    @MainActor func testTheCommandListsTheRangesAndAllTimeInRedDeletesEveryRow() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify-clear-history.yaml"), browserHistory: history,
                                   defaults: isolatedDefaults())
        defer { store.palette.close() }
        XCTAssertFalse(store.palette.commands.contains(.clearBrowserHistory), "nothing to clear while it is off and has no rows")

        history.setEnabled(true)
        history.record(url: URL(string: "https://example.com")!, title: "Example", visit: .typed, topic: nil)
        history.flush()
        XCTAssertTrue(store.palette.commands.contains(.clearBrowserHistory))

        store.palette.run(.clearBrowserHistory)
        let rows = store.palette.results.rows
        XCTAssertEqual(rows.map(\.title.text), ["Last hour", "Last 6 hours", "Last day", "Last 3 days", "Last 7 days", "All time"])
        XCTAssertEqual(rows.filter(\.isDestructive).map(\.title.text), ["All time"])
        XCTAssertTrue(history.store.hasEntries, "the step clears nothing before a choice")

        store.palette.perform(.jumpTo, on: try XCTUnwrap(rows.last))
        history.flush()
        XCTAssertNil(store.palette.flow, "the choice closes the palette")
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertEqual(try rowKeys(history), [])
        XCTAssertEqual(history.suggestions(for: "example", live: LiveRows(), activeTopic: nil), [.search("example")])
    }

    func testARangeRemovesOnlyItsVisits() throws {
        let ago = [30 * minute, 3 * hour, 2 * day, 10 * day]
        let expected: [(ClearRange, [TimeInterval])] = [
            (.lastHour, [3 * hour, 2 * day]), (.last6Hours, [2 * day]), (.lastDay, [2 * day]),
            (.last3Days, []), (.last7Days, []),
        ]
        for (range, kept) in expected {
            let directory = try TestDirectory()
            let history = history(directory)
            history.setEnabled(true)
            record(history, "https://example.com", ago: ago)
            history.clear(range, now: now)
            let entry = try XCTUnwrap(history.entries["https://example.com"], "\(range)")
            XCTAssertEqual(entry.recent.map(\.at), kept.sorted(by: >).map { now - $0 }, "\(range)")
            XCTAssertEqual(entry.folded?.at, now - 10 * day, "\(range) keeps the visit of 10 days ago")
            let score = ([10 * day] + kept).reduce(0) { $0 + pow(0.5, $1 / HistoryEntry.halfLife) }
            XCTAssertEqual(entry.score(at: now), score, accuracy: 1e-9, "\(range)")
            XCTAssertEqual(entry.lastVisit, now - (kept.min() ?? 10 * day), "\(range)")
        }
    }

    func testAnEntryThatARangeEmptiesLeavesTheSuggestionsAndTheTable() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        record(history, "https://fresh.test/page", ago: [10 * minute])
        record(history, "https://kept.test/page", ago: [2 * hour])
        history.clear(.lastHour, now: now)
        history.flush()
        XCTAssertEqual(Set(history.entries.keys), ["https://kept.test/page"])
        XCTAssertEqual(history.suggestions(for: "fresh", live: LiveRows(), activeTopic: nil, now: now), [.search("fresh")])
        XCTAssertEqual(try rowKeys(history), ["https://kept.test/page"])
    }

    func testARangeClearsTheTableWhileBrowserHistoryIsOff() throws {
        let directory = try TestDirectory()
        let on = history(directory)
        on.setEnabled(true)
        record(on, "https://fresh.test/page", ago: [10 * minute])
        record(on, "https://kept.test/page", ago: [2 * day])
        on.flush()

        let off = history(directory)
        off.clear(.lastDay, now: now)
        off.flush()
        XCTAssertTrue(off.entries.isEmpty, "off keeps nothing in memory")
        XCTAssertEqual(try rowKeys(off), ["https://kept.test/page"])
        off.clear(.last3Days, now: now)
        off.flush()
        XCTAssertEqual(try rowKeys(off), [], "a clear that leaves no entry leaves no row")
        XCTAssertFalse(off.canClear)
    }

    func testAScoreFromAnOldFileGoesWhenItsLastVisitIsInTheRange() throws {
        var entry = HistoryEntry(key: "k", url: "https://a.test", title: "", folded: .init(score: 5, at: now - 20 * minute), topics: [])
        entry.removeVisits(since: now - 2 * hour)
        XCTAssertNil(entry.lastVisit, "the one score holds a visit of the range, so it cannot stay")
    }

    func testAPendingWriteDoesNotBringTheRowsBackAfterAClear() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        history.record(url: URL(string: "https://example.com")!, title: "", visit: .link, topic: nil)
        history.clear(.allTime)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        history.flush()
        XCTAssertEqual(try rowKeys(history), [])
    }

    func testARangeAndAllTimeRemoveTheRowsOfAnotherProcessToo() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        let other = self.history(directory)
        history.setEnabled(true)
        other.setEnabled(true)
        record(history, "https://fresh.test/page", ago: [10 * minute])
        record(history, "https://mixed.test/page", ago: [10 * minute, 2 * day])
        record(other, "https://other-fresh.test/page", ago: [20 * minute])
        record(other, "https://other-kept.test/page", ago: [3 * hour])
        history.flush()
        other.flush()

        history.clear(.lastHour, now: now)
        history.flush()
        XCTAssertEqual(try rowKeys(history), ["https://mixed.test/page", "https://other-kept.test/page"],
                       "the rows of the visits of the last hour go, also those that only the other process loaded")
        let mixed = try XCTUnwrap(try history.store.entries().first { $0.key == "https://mixed.test/page" })
        XCTAssertEqual(mixed.recent.map(\.at), [now - 2 * day], "a row keeps its visits before the range")

        history.clear(.allTime, now: now)
        history.flush()
        XCTAssertEqual(try rowKeys(history), [], "All time deletes every row")
    }
}
