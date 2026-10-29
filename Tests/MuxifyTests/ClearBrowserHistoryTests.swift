import XCTest

final class ClearBrowserHistoryTests: XCTestCase {
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(_ directory: TestDirectory) -> BrowserHistory {
        BrowserHistory(file: directory.url.appendingPathComponent("state/browser-history.json"), writeDelay: 0)
    }

    private func record(_ history: BrowserHistory, _ page: String, ago: [TimeInterval]) {
        for interval in ago.sorted(by: >) {
            history.record(url: URL(string: page)!, title: "", visit: .link, topic: nil, at: now - interval)
        }
    }

    private func fileKeys(_ history: BrowserHistory) throws -> [String] {
        try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: history.file)).map(\.key)
    }

    @MainActor func testTheCommandListsTheRangesAndAllTimeInRedRemovesTheFile() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        let store = WorkspaceStore(configStore: ConfigStore(path: "/nonexistent/muxify-clear-history.yaml"), browserHistory: history)
        defer { store.palette.close(restoringFocus: false) }
        XCTAssertFalse(store.palette.commands.contains(.clearBrowserHistory), "nothing to clear while it is off and has no file")

        history.setEnabled(true)
        history.record(url: URL(string: "https://example.com")!, title: "Example", visit: .typed, topic: nil)
        history.flush()
        XCTAssertTrue(store.palette.commands.contains(.clearBrowserHistory))

        store.palette.run(.clearBrowserHistory)
        let rows = store.palette.results.rows
        XCTAssertEqual(rows.map(\.title.text), ["Last hour", "Last 6 hours", "Last day", "Last 3 days", "Last 7 days", "All time"])
        XCTAssertEqual(rows.filter(\.isDestructive).map(\.title.text), ["All time"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.file.path), "the step clears nothing before a choice")

        store.palette.perform(.jumpTo, on: try XCTUnwrap(rows.last))
        history.flush()
        XCTAssertNil(store.palette.flow, "the choice closes the palette")
        XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.file.path))
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

    func testAnEntryThatARangeEmptiesLeavesTheSuggestionsAndTheFile() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        record(history, "https://fresh.test/page", ago: [10 * minute])
        record(history, "https://kept.test/page", ago: [2 * hour])
        history.clear(.lastHour, now: now)
        history.flush()
        XCTAssertEqual(Set(history.entries.keys), ["https://kept.test/page"])
        XCTAssertEqual(history.suggestions(for: "fresh", live: LiveRows(), activeTopic: nil, now: now), [.search("fresh")])
        XCTAssertEqual(try fileKeys(history), ["https://kept.test/page"])
    }

    func testARangeClearsTheFileWhileBrowserHistoryIsOff() throws {
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
        XCTAssertEqual(try fileKeys(off), ["https://kept.test/page"])
        off.clear(.last3Days, now: now)
        off.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: off.file.path), "a clear that leaves no entry removes the file")
        XCTAssertFalse(off.canClear)
    }

    func testAScoreFromAnOldFileGoesWhenItsLastVisitIsInTheRange() throws {
        var entry = HistoryEntry(key: "k", url: "https://a.test", title: "", folded: .init(score: 5, at: now - 20 * minute), topics: [])
        entry.removeVisits(since: now - 2 * hour)
        XCTAssertNil(entry.lastVisit, "the one score holds a visit of the range, so it cannot stay")
    }

    func testAPendingWriteDoesNotBringTheFileBackAfterAClear() throws {
        let directory = try TestDirectory()
        let history = history(directory)
        history.setEnabled(true)
        history.record(url: URL(string: "https://example.com")!, title: "", visit: .link, topic: nil)
        history.clear(.allTime)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        history.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.file.path))
    }
}
