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

    func testANewLaunchAppendsToTheLogAndKnowsWhenItWasLastWritten() throws {
        let first = try DiagnosticsLog(folder: folder)
        XCTAssertNil(first.previousWrite)
        first.write("first launch")
        first.flush()

        let second = try DiagnosticsLog(folder: folder)
        second.write("second launch")
        second.flush()

        XCTAssertNotNil(second.previousWrite)
        XCTAssertEqual(try lines("muxify.log"), ["first launch", "second launch"])
    }

    func testAFullLogBecomesTheOlderFileAndReplacesThePreviousOne() throws {
        // Each line is 24 characters of time and 30 of text, so the second line passes the limit.
        let log = try DiagnosticsLog(folder: folder, sizeLimit: 100)
        for number in 1...5 { log.write("line \(number) " + String(repeating: "x", count: 23)) }
        log.flush()

        XCTAssertEqual(try lines("muxify.1.log").map { $0.prefix(6) }, ["line 3", "line 4"])
        XCTAssertEqual(try lines("muxify.log").map { $0.prefix(6) }, ["line 5"])
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
