import Foundation
import XCTest
@testable import MuxifyCore

final class EntrySelectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A conversation of `turns` turns: user, tool call, tool result, assistant. Entry n is n minutes after `start`.
    private func conversation(turns: Int) -> [Entry] {
        (0..<turns).flatMap { turn -> [(Entry.Role, String?, String)] in
            [(.user, nil, "ask \(turn)"), (.toolCall, turn.isMultiple(of: 2) ? "Bash" : "Edit", #"{"n":\#(turn)}"#),
             (.toolResult, turn.isMultiple(of: 2) ? "Bash" : "Edit", "output \(turn)"), (.assistant, nil, "answer \(turn)")]
        }.enumerated().map { index, item in
            Entry(index: index, at: start.addingTimeInterval(Double(index) * 60), role: item.0, tool: item.1, text: item.2)
        }
    }

    private func indexes(_ result: EntrySelection.Result) -> [Int] { result.entries.map(\.entry.index) }

    func testTheDefaultGivesTheLastTwentyUserAndAssistantEntriesWithTheirOwnIndexes() {
        let result = EntrySelection(window: .tail(20)).apply(to: conversation(turns: 50))
        XCTAssertEqual(indexes(result), (40..<50).flatMap { [$0 * 4, $0 * 4 + 3] })
        XCTAssertEqual(result.total, 200)
        XCTAssertEqual(result.filtered, 100)
        XCTAssertEqual(result.hiddenByRole, 100)
        XCTAssertEqual(result.cut, 0)
    }

    func testTheLastToolCallWithoutAResultShowsWhenToolsAreHidden() {
        var entries = conversation(turns: 2)
        entries.append(Entry(index: 8, at: nil, role: .toolCall, tool: "Bash", text: "waiting"))
        XCTAssertEqual(indexes(EntrySelection().apply(to: entries)), [0, 3, 4, 7, 8])
        entries.append(Entry(index: 9, at: nil, role: .toolResult, tool: "Bash", text: "done"))
        XCTAssertEqual(indexes(EntrySelection().apply(to: entries)), [0, 3, 4, 7], "a call with its result stays hidden")
    }

    func testToolFilterKeepsOnlyThoseToolsWithoutCase() {
        let result = EntrySelection(roles: [.toolCall, .toolResult], tools: ["bash"]).apply(to: conversation(turns: 3))
        XCTAssertEqual(indexes(result), [1, 2, 9, 10])
    }

    func testGrepIgnoresCaseUnlessThePatternHasACapitalAndSearchesToolNames() throws {
        var entries = conversation(turns: 3)
        entries[3] = Entry(index: 3, at: nil, role: .assistant, text: "The Token expired")
        let all = Set(Entry.Role.allCases)
        XCTAssertEqual(indexes(EntrySelection(roles: all, grep: try .init(pattern: "token")).apply(to: entries)), [3])
        XCTAssertEqual(indexes(EntrySelection(roles: all, grep: try .init(pattern: "token$|Tok")).apply(to: entries)), [3])
        XCTAssertEqual(indexes(EntrySelection(roles: all, grep: try .init(pattern: "TOKEN")).apply(to: entries)), [])
        XCTAssertEqual(indexes(EntrySelection(roles: all, grep: try .init(pattern: "^edit$")).apply(to: entries)), [5, 6])
        XCTAssertThrowsError(try EntrySelection.Grep(pattern: "("))
    }

    func testGrepContextCountsTheEntriesThatTheRoleFilterKept() throws {
        let result = EntrySelection(grep: try .init(pattern: "answer 1$", context: 1)).apply(to: conversation(turns: 3))
        XCTAssertEqual(indexes(result), [4, 7, 8], "the hidden tool Entries do not count as context")
    }

    func testSinceAndAfterFilterBeforeTheWindow() {
        let entries = conversation(turns: 5)
        XCTAssertEqual(indexes(EntrySelection(since: start.addingTimeInterval(12 * 60), window: .head(2)).apply(to: entries)), [12, 15])
        let after = EntrySelection(after: 12, window: .tail(20)).apply(to: entries)
        XCTAssertEqual(indexes(after), [15, 16, 19])
        XCTAssertEqual(after.filtered, 3)
    }

    func testRangeUsesTheOriginalIndexFromEitherEndAndMayBeOpen() {
        let entries = conversation(turns: 5)
        let all = Set(Entry.Role.allCases)
        XCTAssertEqual(indexes(EntrySelection(roles: all, window: .range(4, 6)).apply(to: entries)), [4, 5, 6])
        XCTAssertEqual(indexes(EntrySelection(window: .range(4, 6)).apply(to: entries)), [4], "hidden Entries keep their index")
        XCTAssertEqual(indexes(EntrySelection(roles: all, window: .range(-3, -1)).apply(to: entries)), [17, 18, 19])
        XCTAssertEqual(indexes(EntrySelection(roles: all, window: .range(17, nil)).apply(to: entries)), [17, 18, 19])
        XCTAssertEqual(indexes(EntrySelection(roles: all, window: .range(nil, 1)).apply(to: entries)), [0, 1])
    }

    func testTheCutKeepsTheFullLengthAndMarksTheCutEntry() {
        let entries = [Entry(index: 0, at: nil, role: .user, text: "short"), Entry(index: 1, at: nil, role: .assistant, text: "abcdefgh")]
        let cut = EntrySelection(maxChars: 6).apply(to: entries)
        XCTAssertEqual(cut.entries.map(\.text), ["short", "abcdef"])
        XCTAssertEqual(cut.entries.map(\.chars), [5, 8])
        XCTAssertEqual(cut.entries.map(\.truncated), [false, true])
        XCTAssertEqual(cut.cut, 1)
        XCTAssertEqual(EntrySelection(maxChars: nil).apply(to: entries).entries.map(\.text), ["short", "abcdefgh"])
    }

    func testSinceReadsISOTimesAndTypedTimesTowardThePast() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try Date.ISO8601FormatStyle().parse("2026-10-18T12:00:00Z") // a Sunday
        func since(_ text: String) -> String? {
            EntrySelection.since(text, now: now, calendar: calendar).map { $0.ISO8601Format() }
        }
        XCTAssertEqual(since("2h"), "2026-10-18T10:00:00Z")
        XCTAssertEqual(since("30m"), "2026-10-18T11:30:00Z")
        XCTAssertEqual(since("17:30"), "2026-10-17T17:30:00Z")
        XCTAssertEqual(since("9am"), "2026-10-18T09:00:00Z")
        XCTAssertEqual(since("mon"), "2026-10-12T09:00:00Z")
        XCTAssertEqual(since("today"), "2026-10-18T09:00:00Z")
        XCTAssertEqual(since("2026-10-01T08:00:00Z"), "2026-10-01T08:00:00Z")
        XCTAssertNil(since("tomorrow"))
        XCTAssertNil(since("never"))
        XCTAssertNil(since("soon"))
    }

    func testTypedTimeReadsEachFormAndRefusesTheRest() {
        let forms: [String: TypedTime] = [
            "+5m": .relative(5, .minute), "2h": .relative(2, .hour), "+2d": .relative(2, .day),
            "today": .day(0, hour: 9, minute: 0), "today 10:30": .day(0, hour: 10, minute: 30), "today 1:00": .day(0, hour: 1, minute: 0),
            "tomorrow 12:15": .day(1, hour: 12, minute: 15), "tomorrow 1 pm": .day(1, hour: 13, minute: 0),
            "mon": .weekday(2, hour: 9, minute: 0), "sun": .weekday(1, hour: 9, minute: 0), "fri 9": .weekday(6, hour: 9, minute: 0),
            "1300": .next(hour: 13, minute: 0), "9": .next(hour: 9, minute: 0), "930": .next(hour: 9, minute: 30),
            "13:00": .next(hour: 13, minute: 0), "1:30 pm": .next(hour: 13, minute: 30), "130pm": .next(hour: 13, minute: 30),
            "12am": .next(hour: 0, minute: 0), "12pm": .next(hour: 12, minute: 0), "0700": .next(hour: 7, minute: 0),
        ]
        for (form, expected) in forms { XCTAssertEqual(TypedTime(form), expected, form) }
        for form in ["+0m", "+-1h", "+999999999999999999d", "+1w", "friday", "tomorrow 24:00", "today 09:60", "never",
                     "2400", "1360", "13pm", "0am", "12345", "1:3", "123:00", "today pm", "today 09:00 extra", ""] {
            XCTAssertNil(TypedTime(form), form)
        }
    }
}
