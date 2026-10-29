import XCTest

final class AddressEditTests: XCTestCase {
    private let host = HistoryPrefix(display: "github.com", url: "https://github.com", keys: ["a", "b"], ownKey: nil)
    private let page = HistoryEntry(key: "https://gist.github.com/x", url: "https://gist.github.com/x", title: "Gist",
                                    recent: [.init(at: Date(), weight: 1)], topics: [])

    private func suggest(_ query: String) -> [Suggestion] {
        [.prefix(host, title: ""), .page(page), .search(query)]
    }

    func testATypedLetterCompletesTheHostAndSelectsTheAddedText() {
        var edit = AddressEdit(url: "")
        edit.textChanged(to: "g", suggest: suggest)
        XCTAssertEqual(edit.text, "github.com")
        XCTAssertEqual(edit.completion, NSRange(location: 1, length: 9))
        XCTAssertEqual(edit.target, .suggestion(.prefix(host, title: "")), "↩ opens the completed host")
        edit.textChanged(to: "gi", suggest: suggest)
        XCTAssertEqual(edit.text, "github.com", "typing over the selection completes again")
        XCTAssertEqual(edit.typed, "gi")
    }

    func testBackspaceAndAPasteDoNotComplete() {
        var edit = AddressEdit(url: "")
        edit.textChanged(to: "gi", suggest: suggest)
        XCTAssertEqual(edit.text, "gi", "two letters at once are a paste")
        edit.textChanged(to: "git", suggest: suggest)
        XCTAssertEqual(edit.text, "github.com")
        edit.textChanged(to: "github.com", suggest: suggest)
        XCTAssertEqual(edit.completion, NSRange(location: 3, length: 7), "the field echoing the completion is no change")
        edit.textChanged(to: "git", suggest: suggest)
        XCTAssertEqual(edit.text, "git", "⌫ removes the completion and does not complete again")
        XCTAssertNil(edit.completion)
        XCTAssertEqual(edit.target, .text("git"))
    }

    func testArrowsSelectASuggestionAndTheFieldShowsItsURL() {
        var edit = AddressEdit(url: "")
        edit.textChanged(to: "gi", suggest: suggest)
        XCTAssertTrue(edit.move(1))
        XCTAssertTrue(edit.move(1))
        XCTAssertEqual(edit.selection, 1)
        XCTAssertEqual(edit.text, "https://gist.github.com/x")
        XCTAssertEqual(edit.target, .suggestion(.page(page)))
        XCTAssertTrue(edit.move(1))
        XCTAssertEqual(edit.text, "gi", "the search row shows the query")
        XCTAssertTrue(edit.move(1))
        XCTAssertNil(edit.selection, "past the end the field shows the typed text")
        XCTAssertEqual(edit.text, "gi")
        XCTAssertTrue(edit.move(-1))
        XCTAssertEqual(edit.selection, 2, "↑ from no selection goes to the last row")
    }

    func testEscapeClosesTheListFirst() {
        var edit = AddressEdit(url: "")
        edit.textChanged(to: "gi", suggest: suggest)
        XCTAssertTrue(edit.showsList)
        XCTAssertTrue(edit.escape())
        XCTAssertFalse(edit.showsList)
        XCTAssertFalse(edit.escape(), "the second ⎋ is for the field")
        XCTAssertFalse(edit.move(1), "↓ goes to the field while the list is closed")
        edit.textChanged(to: "gis", suggest: suggest)
        XCTAssertTrue(edit.showsList, "typing shows the list again")
    }

    func testTheListHidesWhileTheTextIsTheURLOfTheTab() {
        var edit = AddressEdit(url: "https://github.com")
        XCTAssertFalse(edit.showsList)
        edit.textChanged(to: "https://github.co", suggest: suggest)
        XCTAssertTrue(edit.showsList)
        edit.textChanged(to: "https://github.com", suggest: suggest)
        XCTAssertFalse(edit.showsList)
    }
}
