import XCTest
@testable import MuxifyCore

final class SettledAgeTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    /// Wednesday, 2026-11-04 at noon in Berlin.
    private var now: Date { at(2026, 11, 4, 12, 0) }

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func label(_ settled: Date, now: Date? = nil) -> String {
        SettledAge.label(settled: settled, now: now ?? self.now, calendar: calendar)
    }

    func testEachBandShowsItsWords() {
        XCTAssertEqual(label(at(2026, 11, 4, 0, 5)), "Today")
        XCTAssertEqual(label(at(2026, 11, 3, 23, 59)), "Yesterday")
        XCTAssertEqual(label(at(2026, 11, 2, 9, 0)), "Monday", "2 days ago shows the weekday")
        XCTAssertEqual(label(at(2026, 10, 29, 9, 0)), "Thursday", "6 days ago shows the weekday")
        XCTAssertEqual(label(at(2026, 10, 28, 9, 0)), "7 days ago")
        XCTAssertEqual(label(at(2026, 10, 6, 9, 0)), "29 days ago")
        XCTAssertEqual(label(at(2026, 10, 5, 9, 0)), "Oct 5", "30 days ago in the same year shows the date")
        XCTAssertEqual(label(at(2025, 12, 20, 9, 0)), "Dec 20, 2025", "another year shows the year")
        XCTAssertEqual(label(at(2025, 12, 31, 23, 0), now: at(2026, 1, 1, 0, 30)), "Yesterday", "a new year still counts days")
    }

    func testDaysCountMidnightsNotDayLengths() {
        let settled = at(2026, 11, 3, 23, 50)
        XCTAssertEqual(SettledAge.days(from: settled, to: at(2026, 11, 4, 0, 10), calendar: calendar), 1)
        XCTAssertEqual(label(settled, now: at(2026, 11, 4, 0, 10)), "Yesterday")
        XCTAssertEqual(label(at(2026, 11, 4, 0, 10), now: at(2026, 11, 4, 23, 50)), "Today")
    }

    func testDaysFollowTheCalendarsTimeZone() {
        // 2026-11-04 00:30 in Berlin is still 2026-11-03 in New York.
        var newYork = calendar
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let settled = at(2026, 11, 3, 20, 0)
        XCTAssertEqual(SettledAge.days(from: settled, to: at(2026, 11, 4, 0, 30), calendar: calendar), 1)
        XCTAssertEqual(SettledAge.days(from: settled, to: at(2026, 11, 4, 0, 30), calendar: newYork), 0)
    }

    func testAFutureSettleDateShowsToday() {
        XCTAssertEqual(SettledAge.days(from: at(2026, 11, 6, 9, 0), to: now, calendar: calendar), 0)
        XCTAssertEqual(label(at(2026, 11, 6, 9, 0)), "Today")
    }

    // MARK: The midnight the Settled group waits for

    /// The time from `now` to the moment the Settled group draws its cards again.
    private func wait(from now: Date, calendar: Calendar? = nil) -> TimeInterval? {
        SettledAge.nextMidnight(after: now, calendar: calendar ?? self.calendar).map { $0.timeIntervalSince(now) }
    }

    func testTheGroupWaitsUntilTheNextMidnightWhenTheLabelsChange() {
        XCTAssertEqual(wait(from: now), 12 * 3600, "from noon, half a day")
        let late = at(2026, 11, 4, 23, 59).addingTimeInterval(59)
        XCTAssertEqual(wait(from: late), 1, "from a second before midnight, a second")
        let next = SettledAge.nextMidnight(after: late, calendar: calendar)!
        XCTAssertEqual(label(now, now: next.addingTimeInterval(-1)), "Today", "the label holds until midnight")
        XCTAssertEqual(label(now, now: next), "Yesterday", "the label changes at the midnight the group waits for")
    }

    func testAtMidnightTheGroupWaitsForTheNextOne() {
        XCTAssertEqual(wait(from: at(2026, 11, 5, 0, 0)), 24 * 3600, "a midnight is no moment after itself")
    }

    func testTheWaitFollowsTheClocksOnTheDayTheyChange() {
        // Berlin turns its clocks back an hour on 2026-10-25, a day of 25 hours.
        XCTAssertEqual(wait(from: at(2026, 10, 25, 0, 0)), 25 * 3600)
        // Santiago skips from 00:00 to 01:00 on 2026-09-06: the day starts at 01:00, 12 hours after noon the day before.
        var santiago = calendar
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        let noon = santiago.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!
        let next = SettledAge.nextMidnight(after: noon, calendar: santiago)!
        XCTAssertEqual(next, santiago.startOfDay(for: noon.addingTimeInterval(18 * 3600)), "the first moment of the next day")
        XCTAssertEqual(santiago.component(.hour, from: next), 1)
        XCTAssertEqual(next.timeIntervalSince(noon), 12 * 3600)
    }

    private func settled(_ id: String, _ date: Date?) -> TopicRecord {
        var record = TopicRecord(id: id, title: id)
        record.settledAt = date.map { ISO8601DateFormatter().string(from: $0) }
        return record
    }

    private func forgotten(olderThan days: Int, _ records: [TopicRecord]) -> [String] {
        SettledAge.settled(olderThan: days, in: records, now: now, calendar: calendar).map(\.id)
    }

    func testOlderThanFourteenTakesTheCardThatSays15DaysAgoAndKeepsTheOneThatSays14DaysAgo() {
        let fifteen = at(2026, 10, 20, 23, 59), fourteen = at(2026, 10, 21, 0, 1)
        XCTAssertEqual(label(fifteen), "15 days ago")
        XCTAssertEqual(label(fourteen), "14 days ago")
        XCTAssertEqual(forgotten(olderThan: 14, [settled("fourteen", fourteen), settled("fifteen", fifteen)]), ["fifteen"])
    }

    func testOlderThanOneKeepsYesterdayAndToday() {
        let records = [settled("today", at(2026, 11, 4, 0, 5)), settled("yesterday", at(2026, 11, 3, 0, 5)),
                       settled("two", at(2026, 11, 2, 23, 0))]
        XCTAssertEqual(forgotten(olderThan: 1, records), ["two"])
    }

    func testOpenTopicsAndSettleDatesThatAreNoDateAreNeverChosen() {
        var unreadable = settled("unreadable", nil)
        unreadable.settledAt = "last spring"
        XCTAssertEqual(forgotten(olderThan: 1, [settled("open", nil), unreadable]), [])
    }

    func testTheChosenTopicsComeOldestFirst() {
        let records = [settled("may", at(2026, 5, 1, 9, 0)), settled("january", at(2026, 1, 1, 9, 0)), settled("march", at(2026, 3, 1, 9, 0))]
        XCTAssertEqual(forgotten(olderThan: 14, records), ["january", "march", "may"])
    }
}
