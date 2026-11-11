import XCTest

final class DiagnosticsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func lines(_ name: String) throws -> [String] {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map { String($0.split(separator: " ", maxSplits: 2)[2]) }
    }

    /// Today at `hour`:`minute`:`second`, local time, plus `days`.
    private func local(days: Int = 0, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let day = calendar.date(byAdding: .day, value: days, to: today)!
        return calendar.date(bySettingHour: hour, minute: minute, second: second, of: day)!
    }

    private func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "muxify-\(formatter.string(from: date)).log"
    }

    private func makeFile(_ name: String, modified: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: file.path, contents: Data("old\n".utf8))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    func testANewLaunchAppendsToTheDayFileAndKnowsWhenTheLogWasLastWritten() throws {
        let first = try DiagnosticsLog(folder: folder)
        XCTAssertNil(first.previousWrite)
        first.write("first launch")
        first.flush()

        let second = try DiagnosticsLog(folder: folder)
        second.write("second launch")
        second.flush()

        XCTAssertNotNil(second.previousWrite)
        XCTAssertEqual(try lines(dayName(Date())), ["first launch", "second launch"])
    }

    func testLinesGoToTheirLocalDaysFileAndTheFirstLineAfterMidnightOpensTheNextDay() throws {
        var now = local(days: -1, 23, 59, 58)
        let log = try DiagnosticsLog(folder: folder, now: { now })
        log.write("before midnight")
        log.flush()
        now = local(0, 0, 1)
        log.write("after midnight")
        log.write("later")
        log.flush()

        XCTAssertEqual(try lines(dayName(local(days: -1, 12, 0, 0))), ["before midnight"])
        XCTAssertEqual(try lines(dayName(local(0, 0, 1))), ["after midnight", "later"])
        XCTAssertEqual(log.url(for: now).lastPathComponent, dayName(now))
    }

    func testOpeningADayFileDeletesTheLogFilesOlderThanSevenDays() throws {
        let now = Date()
        let old = now.addingTimeInterval(-8 * 24 * 3600), recent = now.addingTimeInterval(-6 * 24 * 3600)
        try makeFile(dayName(old), modified: old)
        try makeFile(dayName(recent), modified: recent)
        try makeFile("muxify.log", modified: old)
        try makeFile("muxify.1.log", modified: old)
        try makeFile("freeze-2026-01-01-000000.txt", modified: old)

        let log = try DiagnosticsLog(folder: folder, now: { now })
        log.write("today")
        log.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, [dayName(recent), dayName(now), "freeze-2026-01-01-000000.txt"].sorted())
        XCTAssertEqual(try XCTUnwrap(log.previousWrite).timeIntervalSince1970, recent.timeIntervalSince1970, accuracy: 1)
    }

    func testAFullDayFileWritesOneLimitLineAndThenKeepsOnlyTheKeyLines() throws {
        // Each line is 24 characters of time and 30 of text, so the second line reaches the limit.
        let log = try DiagnosticsLog(folder: folder, sizeLimit: 100)
        for number in 1...2 { log.write("line \(number) " + String(repeating: "x", count: 23)) }
        for text in ["line 3", "minute cpu=1", "app active", "burst cpu=40", "freeze: main thread busy for 1.2s",
                     "digest file=burst.txt", "limit again", "report since the last run: x"] {
            log.write(text)
        }
        log.flush()
        let reopened = try DiagnosticsLog(folder: folder, sizeLimit: 100)
        reopened.write("after a relaunch")
        reopened.write("minute cpu=2")
        reopened.flush()

        let written = try lines(dayName(Date()))
        XCTAssertEqual(written.filter { $0.hasPrefix("limit ") }, ["limit size=100 keeps=minute,burst,freeze,digest"])
        XCTAssertEqual(written.map { String($0.prefix(6)) }, [
            "line 1", "line 2", "limit ", "minute", "burst ", "freeze", "digest", "minute",
        ])
    }

    func testReportsSinceTheLastRunAreTheAppsReportsWrittenAfterIt() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lastRun = Date().addingTimeInterval(-3600)
        for (name, age) in [("MuxifyApp-2026-10-28-110000.ips", 60.0), ("MuxifyApp_2026-10-27-090000.hang", 7200),
                            ("Ghostty-2026-10-28-110000.ips", 60)] {
            let file = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: file.path, contents: Data())
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
        }

        let reports = Diagnostics.reports(named: "MuxifyApp", since: lastRun, in: [folder, folder.appendingPathComponent("missing")])

        XCTAssertEqual(reports.map(\.lastPathComponent), ["MuxifyApp-2026-10-28-110000.ips"])
    }
}
