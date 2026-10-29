import XCTest

final class SuggestionRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entries(_ scores: [(String, Double)], topics: [String: Set<String>] = [:]) -> [String: HistoryEntry] {
        Dictionary(uniqueKeysWithValues: scores.map { url, score in
            let key = BrowserTab.matchKey(url)
            return (key, HistoryEntry(key: key, url: url, title: "", recent: [.init(at: now, weight: score)], topics: topics[url] ?? []))
        })
    }

    private func rank(_ query: String, _ entries: [String: HistoryEntry], live: LiveRows = LiveRows(), topic: String? = nil) -> [Suggestion] {
        SuggestionRanker.rank(query, index: HistoryIndex(entries), live: live, activeTopic: topic, now: now)
    }

    private let github = [
        ("https://github.com/glebglazov/muxify", 9.1),
        ("https://github.com/glebglazov/muxify/pulls", 4.0),
        ("https://github.com/notifications", 3.2),
        ("https://docs.github.com/en/actions", 1.4),
        ("https://gist.github.com/gg/a1b2", 0.6),
        ("https://gitlab.com/x/y", 0.3),
    ]

    func testAHostThatTheQueryStartsComesBeforeItsPagesAndAWordMatchComesAfterEveryStartMatch() {
        let rows = rank("gi", entries(github))
        XCTAssertEqual(rows.map(\.display), [
            "github.com",
            "github.com/glebglazov/muxify",
            "github.com/glebglazov/muxify/pulls",
            "github.com/notifications",
            "gist.github.com/gg/a1b2",
            "gitlab.com/x/y",
            "docs.github.com/en/actions",
            "gi",
        ])
        XCTAssertEqual(rows.last, .search("gi"), "the search row is last")
        guard case .prefix(let host, _) = rows[0] else { return XCTFail("the first row is \(rows[0]), not the host") }
        XCTAssertEqual(host.url, "https://github.com")
        XCTAssertEqual(Set(host.keys).count, 3, "the host holds its three pages")
    }

    func testAPrefixHoldsTwoOrMorePagesAndAChainOfOneChildFoldsIntoOnePrefix() {
        let prefixes = HistoryPrefix.all(entries(github)).map(\.display).sorted()
        XCTAssertEqual(prefixes, ["github.com", "github.com/glebglazov/muxify"],
                       "github.com/glebglazov folds into muxify; gist, docs and gitlab hold one page each")
    }

    func testThePageOfAPrefixShowsOnceAsThePrefix() {
        let rows = rank("gi", entries(github))
        XCTAssertEqual(rows.filter { $0.url == "https://github.com/glebglazov/muxify" }.count, 1)
        guard case .prefix = rows[1] else { return XCTFail("\(rows[1]) is not the prefix of its pages") }
    }

    func testAnEntryOfTheActiveTopicCountsTwice() {
        let data = entries([("https://a.test/x", 3), ("https://b.test/x", 4)], topics: ["https://a.test/x": ["topic"]])
        XCTAssertEqual(rank("x", data).prefix(2).map(\.display), ["b.test/x", "a.test/x"])
        XCTAssertEqual(rank("x", data, topic: "topic").prefix(2).map(\.display), ["a.test/x", "b.test/x"])
        XCTAssertEqual(rank("x", data, topic: "other").prefix(2).map(\.display), ["b.test/x", "a.test/x"])
    }

    func testAnOpenTabIsATypedVisitOfNowAndTakesThePlaceOfItsEntry() {
        let tab = UUID()
        let data = entries([("https://c.test/page", 1), ("https://d.test/page", 2.5)])
        let rows = rank("page", data, live: LiveRows(tabs: [.init(id: tab, url: "https://c.test/page#top", title: "C")]))
        XCTAssertEqual(rows.first, .tab(id: tab, url: "https://c.test/page#top", title: "C"), "1 + 2 for the open Tab is above 2.5")
        XCTAssertEqual(rows.filter { $0.display == "c.test/page" }.count, 1)
    }

    func testADevServerPortShowsUnlessHistoryHasItsPage() {
        let none = rank("local", [:], live: LiveRows(ports: [5173, 8080]))
        XCTAssertEqual(Set(none.dropLast().map(\.url)), ["http://localhost:5173", "http://localhost:8080"])
        let visited = rank("local", entries([("http://localhost:5173/", 1)]), live: LiveRows(ports: [5173]))
        XCTAssertEqual(visited.dropLast(), [.page(entries([("http://localhost:5173/", 1)]).values.first!)])
    }

    func testAWordThatDoesNotMatchHidesTheRowAndAnEmptyQueryGivesNoRows() {
        XCTAssertEqual(rank("zzz", entries(github)), [.search("zzz")])
        XCTAssertEqual(rank("  ", entries(github)), [])
    }

    func testTheListHoldsEightRowsAtMost() {
        let many = entries((0..<20).map { ("https://site\($0).test/page", Double($0)) })
        let rows = rank("site", many)
        XCTAssertEqual(rows.count, SuggestionRanker.limit)
        XCTAssertEqual(rows.first?.display, "site19.test/page")
        XCTAssertEqual(rows.last, .search("site"))
    }

    func testInlineCompletionAddsTheRestOfAHostOrPathOnly() {
        let rows = rank("gi", entries(github))
        XCTAssertEqual(rows[0].completion(of: "gi"), "github.com")
        XCTAssertEqual(rows[0].completion(of: "GI"), "GIthub.com", "the typed text stays as typed")
        XCTAssertEqual(rows[0].completion(of: "https://gi"), "https://github.com")
        XCTAssertNil(rows[0].completion(of: "github.com"), "nothing to add")
        XCTAssertNil(rows[2].completion(of: "gi"), "a page never completes")
        let www = entries([("https://www.example.com/a", 1), ("https://www.example.com/b", 1)])
        XCTAssertEqual(rank("ex", www).first?.completion(of: "ex"), "example.com")
    }

    func testTheStoreSuggestsAPageRecordedAfterAnEarlierQuery() throws {
        let directory = try TestDirectory()
        let history = BrowserHistory(file: directory.url.appendingPathComponent("browser-history.json"), writeDelay: 0)
        history.setEnabled(true)
        history.record(url: URL(string: "https://alpha.test/one")!, title: "", visit: .link, topic: nil, at: now)
        XCTAssertEqual(history.suggestions(for: "alpha", live: LiveRows(), activeTopic: nil, now: now).map(\.display), ["alpha.test/one", "alpha"])
        history.record(url: URL(string: "https://alpha.test/two")!, title: "", visit: .link, topic: nil, at: now)
        XCTAssertEqual(history.suggestions(for: "alpha", live: LiveRows(), activeTopic: nil, now: now).first?.display, "alpha.test",
                       "the second page makes the host a prefix")
    }

    func testAPageWithAQueryStaysAPageUnderItsPath() {
        let data = entries([("https://news.test/item?id=1", 3), ("https://news.test/item?id=2", 1)])
        let rows = rank("news", data)
        XCTAssertEqual(rows.map(\.display), ["news.test/item", "news.test/item?id=1", "news.test/item?id=2", "news"])
        guard case .prefix(let path, let title) = rows[0] else { return XCTFail("\(rows[0]) is not the path") }
        XCTAssertNil(path.ownKey)
        XCTAssertEqual(title, "", "the path has no page of its own, so no title")
    }

    func testTheSchemeAndWWWThatTheUserTypesStillMatchAndComplete() {
        for typed in ["https://gi", "http://gi", "www.gi", "https://www.gi"] {
            let rows = rank(typed, entries(github))
            XCTAssertEqual(rows.first?.display, "github.com", typed)
        }
        XCTAssertEqual(rank("https://gi", entries(github)).first?.completion(of: "https://gi"), "https://github.com")
        XCTAssertEqual(rank("www.", entries(github)), [.search("www.")])
    }

    func testCaseIsIgnoredOutsideASCIITooAndTheTitleMatches() {
        var data = entries([("https://paper.test/a", 1)])
        data["https://paper.test/a"]?.title = "Économie"
        XCTAssertEqual(rank("écon", data).first?.display, "paper.test/a")
    }
}
