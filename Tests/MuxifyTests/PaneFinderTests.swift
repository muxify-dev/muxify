import XCTest
import MuxifyCore

final class PaneFinderTests: XCTestCase {
    @MainActor func testClosingBeforeThePaneResolvesDoesNotStartASearch() throws {
        let requests = Requests()
        let finder = requests.finder
        finder.findQuery = "first"
        finder.show()
        XCTAssertEqual(requests.operations, [.resolve(WindowID(rawValue: "@0")!)])

        finder.close()
        try requests.reply(at: 0, .resolved(PaneID(rawValue: "%3")!))

        XCTAssertFalse(finder.isShown)
        XCTAssertEqual(finder.findStatus, .idle)
        XCTAssertEqual(requests.operations.count, 1)
    }

    @MainActor func testNavigationWhileResolvingStartsWithTheCurrentQuery() throws {
        let requests = Requests()
        let finder = requests.finder
        let pane = PaneID(rawValue: "%3")!
        finder.findQuery = "needle"
        finder.show()
        finder.findNext()
        finder.findPrevious()
        try requests.reply(at: 0, .resolved(pane))
        try requests.reply(at: 1, .resolved(pane))
        XCTAssertEqual(requests.operations.count, 3)
        try requests.reply(at: 2, .resolved(pane))
        XCTAssertEqual(requests.operations.last,
                       .search(step: .query, query: "needle", pane: pane, styles: requests.styles, previousTotal: nil))
    }

    @MainActor func testClosingAnAdmittedSearchCancelsItsPaneBeforeTheReply() throws {
        let requests = Requests()
        let finder = requests.finder
        let pane = PaneID(rawValue: "%3")!
        finder.findQuery = "first"
        finder.show()
        try requests.reply(at: 0, .resolved(pane))
        XCTAssertEqual(requests.operations.last,
                       .search(step: .query, query: "first", pane: pane, styles: requests.styles, previousTotal: nil))

        finder.windowID = { "@9" }
        finder.close()
        XCTAssertEqual(requests.operations.last, .cancel(pane))
        try requests.reply(at: 1, .searched(found: true, total: 4, index: 1))

        XCTAssertFalse(finder.isShown)
        XCTAssertEqual(finder.findStatus, .idle)
        XCTAssertEqual(requests.operations.count, 3)
    }

    @MainActor func testAReplyFromTheClosedSearchDoesNotChangeTheReopenedSearch() throws {
        let requests = Requests()
        let finder = requests.finder
        let firstPane = PaneID(rawValue: "%3")!
        let nextPane = PaneID(rawValue: "%8")!
        finder.findQuery = "first"
        finder.show()
        try requests.reply(at: 0, .resolved(firstPane))
        finder.close()

        finder.findQuery = "next"
        finder.show()
        try requests.reply(at: 3, .resolved(nextPane))
        try requests.reply(at: 4, .searched(found: true, total: 7, index: 2))
        try requests.reply(at: 1, .searched(found: false, total: 0, index: 0))

        XCTAssertTrue(finder.isShown)
        XCTAssertEqual(finder.findQuery, "next")
        XCTAssertEqual(finder.findStatus, .match(index: 2, total: 7))
        finder.close()
        XCTAssertEqual(requests.operations.last, .cancel(nextPane))
    }

    @MainActor private final class Requests {
        let finder = PaneFinder()
        let styles = PaneSearch.Styles(match: "bg=yellow", current: "bg=orange")
        var operations: [PaneSearch.Operation] = []
        private var completions: [(Result<PaneSearch.Response, Error>) -> Void] = []

        init() {
            finder.windowID = { "@0" }
            finder.styles = { [styles] in styles }
            finder.perform = { [weak self] operation, completion in
                guard let self else { return false }
                self.operations.append(operation)
                self.completions.append(completion)
                return true
            }
        }

        func reply(at index: Int, _ response: PaneSearch.Response) throws {
            let completion = try XCTUnwrap(completions.indices.contains(index) ? completions[index] : nil)
            completion(.success(response))
        }
    }
}
