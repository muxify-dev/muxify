import XCTest
@testable import MuxifyCLI
import MuxifyCore

final class DiagnosticsSummaryTests: XCTestCase {
    func testTheVerbTakesADateAndAFolderAndIsInTheHelp() throws {
        let environment = ["HOME": "/home/me"]
        let now = try time("2026-11-11", "17:30:00")
        XCTAssertEqual(try CLICommand(arguments: ["diagnostics", "summary"], environment: environment, now: now),
                       .diagnosticsSummary(DiagnosticsSummaryInvocation(date: "2026-11-11",
                                                                         folder: URL(fileURLWithPath: "/home/me/Library/Logs/Muxify"))))
        XCTAssertEqual(try CLICommand(arguments: ["diagnostics", "summary", "--date", "2026-02-28", "--folder", "/tmp/logs"],
                                      environment: environment, now: now),
                       .diagnosticsSummary(DiagnosticsSummaryInvocation(date: "2026-02-28", folder: URL(fileURLWithPath: "/tmp/logs"))))
        XCTAssertTrue(CLIVerbs.usage.contains("muxify diagnostics summary [--date YYYY-MM-DD] [--folder PATH]"), CLIVerbs.usage)
        XCTAssertTrue(CLIVerbs.usage.contains("diagnostics summary\n"), "the verb has its own paragraph")
    }

    func testABadDateIsAUsageError() {
        for arguments in [["--date", "2026-13-01"], ["--date", "2026-02-30"], ["--date", "yesterday"], ["--date", "2026-1-5"],
                          ["--date"], ["today"], ["--json"]] {
            XCTAssertThrowsError(try CLICommand(arguments: ["diagnostics", "summary"] + arguments, environment: [:]), "\(arguments)") { error in
                XCTAssertEqual((error as? CLIError)?.exitCode, 2, "\(arguments)")
                XCTAssertEqual((error as? CLIError)?.isUsage, true, "\(arguments)")
                XCTAssertEqual(error.localizedDescription, CLIVerbs.usage(for: ["diagnostics", "summary"]), "\(arguments)")
            }
        }
    }

    func testADayWithNoFileNamesTheFolderAndExitsOne() throws {
        let folder = try fixtureFolder()
        let invocation = DiagnosticsSummaryInvocation(date: "2026-11-09", folder: folder)
        XCTAssertThrowsError(try invocation.text()) { error in
            XCTAssertEqual((error as? CLIError)?.exitCode, 1)
            XCTAssertEqual((error as? CLIError)?.isUsage, false)
            XCTAssertEqual(error.localizedDescription,
                           "no Diagnostics log for 2026-11-09 in \(folder.path): there is no muxify-2026-11-09.log")
        }
    }

    /// Every section of a day with minutes, Bursts, a freeze, digests, gaps and errors, in its fixed order and form,
    /// over a day file that also holds lines the summary does not know.
    func testTheSummaryOfADay() throws {
        let folder = try fixtureFolder()
        guard case .diagnosticsSummary(let invocation) = try CLICommand(
            arguments: ["diagnostics", "summary", "--date", "2026-11-10", "--folder", folder.path], environment: [:]) else {
            return XCTFail("expected diagnostics summary")
        }
        let moving = "window=visible,active working_marks=2 marks_move=true sidebar=sessions topic_cards=4 session_rows=9"
        XCTAssertEqual(try invocation.text(), """
        Day 2026-11-10
          records 09:01:00 – 10:50:00
          minutes recorded 9
          gaps 4
            09:05:00 – 10:00:00  54 min missing  system sleep
            10:00:00 – 10:31:00  30 min missing  quit
            10:31:00 – 10:40:00  8 min missing  unknown
            10:40:00 – 10:50:00  9 min missing  screens asleep

        CPU (minute average, % of one core)
          idle (7 min)
            app       p50 4.0  p90 7.0  max 7.0
            commands  p50 3.0  p90 3.0  max 3.0
            tmux      p50 0.5  p90 2.5  max 2.5
          with input (2 min)
            app       p50 20.0  p90 40.0  max 40.0
            webkit    p50 8.0  p90 12.0  max 12.0
            tmux      p50 4.0  p90 6.0  max 6.0

        Main thread (main.busy, % of the minute)
          idle        p50 2.0  p90 3.5
          with input  p50 10.0  p90 30.0

        Memory (MB)
          app       start 300  end 295  peak 350 at 10:00:00
          commands  peak 40 at 09:02:00
          webkit    peak 210 at 09:05:00
          tmux      peak 26 at 09:05:00

        Bursts 3
          worst 3 by cpu.avg × length
          1. 09:03:10  30.0 s  cpu.avg 40.0  cpu.peak 48.0  main.busy.peak 90.0
             input keys:0,clicks:0,scrolls:40,sidebar_switches:12,palette_opens:0
             moving \(moving)
             bodies SidebarCard:900,TopicsSection:12
             digest burst-2026-11-10-090313.txt  samples 5000  busy 97.8%
               libraries AttributeGraph 58.8%, SwiftUI 20.1%, Muxify 3.0%
               symbols AG::Graph::update@AttributeGraph 20.0%, s2@SwiftUI 10.0%, s3@SwiftUI 9.0%, s4@SwiftUI 8.0%, s5@SwiftUI 7.0%
               frames SidebarCard.body 30.0%, f2 20.0%, f3 10.0%, f4 5.0%, f5 4.0%
          2. 09:04:10  10.0 s  cpu.avg 50.0  cpu.peak 60.0  main.busy.peak 70.0
             input idle
             moving \(moving)
             bodies none
             no sample
          3. 09:04:40  5.0 s  cpu.avg 90.0  cpu.peak 95.0  main.busy.peak 99.0  open
             input idle
             moving \(moving)
             bodies none
             sample burst-2026-11-10-090440.txt, not digested

        Freezes 1
          1. 09:02:31  2.2 s
             digest freeze-2026-11-10-090230.txt  samples 2500  busy 100.0%
               libraries SwiftUI 70.0%
               symbols none
               frames TopicsList.body 50.0%

        Errors 4 kinds
          5     system log: error com.apple.foo: bad thing
          2     tmux command failed
          1     report since the last run
          1     config

        Trend (one line a day file)
          2026-11-10  idle p50 4.0  with input p50 20.0  bursts 3  freezes 1  peak mem 350 MB
          2026-11-11  idle p50 5.0  with input p50 10.0  bursts 1  freezes 0  peak mem 410 MB

        """)
    }

    func testAnEmptyDayFileStillPrintsEverySection() throws {
        let folder = try fixtureFolder()
        FileManager.default.createFile(atPath: folder.appendingPathComponent("muxify-2026-11-08.log").path,
                                       contents: Data("not a line\n2026-11-08 09:00:00.000 future kind=1\n".utf8))
        let text = try DiagnosticsSummaryInvocation(date: "2026-11-08", folder: folder).text()
        XCTAssertTrue(text.hasPrefix("Day 2026-11-08\n  records none\n  minutes recorded 0\n  gaps 0\n"), text)
        XCTAssertTrue(text.contains("  idle (0 min)\n  with input (0 min)\n"), text)
        XCTAssertTrue(text.contains("Memory (MB)\n  no minutes\n"), text)
        XCTAssertTrue(text.contains("Errors 0 kinds\n"), text)
        XCTAssertTrue(text.contains("  2026-11-08  idle p50 -  with input p50 -  bursts 0  freezes 0  peak mem -\n"), text)
    }

    // MARK: Fixture

    /// Two day files and some other files of a Diagnostics folder.
    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try dayOne().joined(separator: "\n").write(to: folder.appendingPathComponent("muxify-2026-11-10.log"), atomically: true, encoding: .utf8)
        try dayTwo().joined(separator: "\n").write(to: folder.appendingPathComponent("muxify-2026-11-11.log"), atomically: true, encoding: .utf8)
        for other in ["muxify.log", "freeze-2026-11-10-090230.txt", "muxify-2026-11-10.log.bak"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(other).path, contents: Data("2026-11-10 09:00:00.000 off\n".utf8))
        }
        return folder
    }

    private let formatter = DiagnosticsRecord.formatter()

    private func time(_ day: String, _ clock: String) throws -> Date {
        try XCTUnwrap(formatter.date(from: "\(day) \(clock).000"), "\(day) \(clock)")
    }

    private func line(_ day: String, _ clock: String, _ text: String) throws -> String {
        "\(formatter.string(from: try time(day, clock))) \(text)"
    }

    private let moving = MovingState(window: AppWindowState(visible: true, active: true), workingMarks: 2, marksMove: true,
                                     sidebar: .sessions, topicCards: 4, sessionRows: 9)

    private func minute(_ day: String, _ clock: String, cpu: Double, busy: Double, memory: Double, input: InputCounts = InputCounts(),
                        groups: [ProcessGroup: GroupFigures] = [:]) throws -> String {
        let record = MinuteRecord(cpuAverage: cpu, cpuPeak: cpu * 2, mainBusy: busy, memoryMB: memory, groups: groups, threads: 30,
                                  openFiles: 80, input: input, moving: moving)
        return try line(day, clock, record.record.text)
    }

    private func burst(_ day: String, _ start: String, length: TimeInterval, cpu: Double, peak: Double, busy: Double,
                       input: InputCounts = InputCounts(), bodies: BodyCounts = BodyCounts(), samples: [String] = [],
                       open: Bool = false) throws -> String {
        let begin = try time(day, start)
        let record = BurstRecord(start: begin, length: length, cpuAverage: cpu, cpuPeak: peak, mainBusyPeak: busy, input: input,
                                 bodies: bodies, moving: moving, samples: samples, open: open)
        return "\(formatter.string(from: begin.addingTimeInterval(length + 3))) \(record.record.text)"
    }

    private func figures(_ cpu: Double, _ memory: Double) -> GroupFigures {
        GroupFigures(cpuAverage: cpu, cpuPeak: cpu, memoryMB: memory)
    }

    private func dayOne() throws -> [String] {
        let day = "2026-11-10"
        let burstSample = "burst-2026-11-10-090313.txt"
        let freezeSample = "freeze-2026-11-10-090230.txt"
        let symbols = ["AG::Graph::update@AttributeGraph:20.0", "s2@SwiftUI:10.0", "s3@SwiftUI:9.0", "s4@SwiftUI:8.0", "s5@SwiftUI:7.0",
                       "s6@SwiftUI:6.0"]
        return [
            "not a line at all",
            try line(day, "09:00:00", "launch: pid 42, Muxify 1.0 (1), macOS 26, 1 screens"),
            try line(day, "09:00:01", "report since the last run: /Users/me/Library/Logs/DiagnosticReports/MuxifyApp-2026-11-09.ips"),
            try minute(day, "09:01:00", cpu: 1, busy: 0.5, memory: 300, groups: [.tmux: figures(0.5, 20)]),
            try line(day, "09:01:30", "future kind=1 other=2"),
            try line(day, "09:01:31", "minute cpu.app.avg=oops"),
            try line(day, "09:01:32", "minute garbage"),
            try line(day, "09:01:33", "burst start=nope"),
            try line(day, "09:01:34", "app active"),
            try line(day, "09:01:35", "occlusion changed: app active, window 0x1 NSWindow visible unoccluded"),
            try line(day, "09:01:36", "animation #3 NSScrollAnimationHelper 0x2 duration 0.200s | app active, window -"),
            try line(day, "09:01:37", "display link stuck: #1 link 0x3 still animating"),
            try line(day, "09:01:38", "config: unknown key ui.wobble"),
            try minute(day, "09:02:00", cpu: 2, busy: 1, memory: 310, groups: [.tmux: figures(1.5, 22), .commands: figures(3, 40)]),
            try line(day, "09:02:00", "system log 09:01:58: error com.apple.foo: bad thing (3 times)"),
            try line(day, "09:02:30", "freeze: sampling the process for 3 s to \(freezeSample)"),
            try line(day, "09:02:31", "freeze: main thread busy for 2.200s | app active, window -"),
            try line(day, "09:02:33", DiagnosticsRecord(.digest, [("sample", freezeSample), ("samples", "2500"), ("busy", "100.0"),
                                                                  ("libraries", "SwiftUI:70.0")]).text),
            try line(day, "09:02:33", DiagnosticsRecord(.digest, [("sample", freezeSample), ("symbols", "none")]).text),
            try line(day, "09:02:33", DiagnosticsRecord(.digest, [("sample", freezeSample), ("frames", "TopicsList.body:50.0")]).text),
            try minute(day, "09:03:00", cpu: 3, busy: 1.5, memory: 305, groups: [.tmux: figures(2.5, 21)]),
            try line(day, "09:03:00", "system log 09:02:59: error com.apple.foo: bad thing (2 times)"),
            try line(day, "09:03:13", "burst: sampling the process for 5 s to \(burstSample)"),
            try line(day, "09:03:18", DiagnosticsRecord(.digest, [("sample", burstSample), ("samples", "5000"), ("busy", "97.8"),
                                                                  ("libraries", "AttributeGraph:58.8,SwiftUI:20.1,Muxify:3.0")]).text),
            try line(day, "09:03:18", DiagnosticsRecord(.digest, [("sample", burstSample), ("symbols", symbols.joined(separator: ","))]).text),
            try line(day, "09:03:18", DiagnosticsRecord(.digest, [("sample", burstSample),
                                                                  ("frames", "SidebarCard.body:30.0,f2:20.0,f3:10.0,f4:5.0,f5:4.0,f6:3.0")]).text),
            try burst(day, "09:03:10", length: 30, cpu: 40, peak: 48, busy: 90, input: InputCounts(scrolls: 40, sidebarSwitches: 12),
                      bodies: BodyCounts(["SidebarCard": 900, "TopicsSection": 12]), samples: [burstSample]),
            try minute(day, "09:04:00", cpu: 20, busy: 10, memory: 320, input: InputCounts(keys: 5),
                       groups: [.tmux: figures(4, 25), .webkit: figures(12, 200)]),
            try burst(day, "09:04:10", length: 10, cpu: 50, peak: 60, busy: 70),
            try line(day, "09:04:30", "tmux command failed: no server"),
            try burst(day, "09:04:40", length: 5, cpu: 90, peak: 95, busy: 99, samples: ["burst-2026-11-10-090440.txt"], open: true),
            try line(day, "09:04:50", "tmux command failed: no session"),
            try minute(day, "09:05:00", cpu: 40, busy: 30, memory: 330, input: InputCounts(clicks: 3),
                       groups: [.tmux: figures(6, 26), .webkit: figures(8, 210)]),
            try line(day, "09:05:20", "system will sleep"),
            try line(day, "09:59:50", "system woke"),
            try minute(day, "10:00:00", cpu: 4, busy: 2, memory: 350, groups: [.tmux: figures(0.5, 24)]),
            try line(day, "10:00:30", "quit"),
            try line(day, "10:30:00", "launch: pid 43, Muxify 1.0 (1), macOS 26, 1 screens"),
            try minute(day, "10:31:00", cpu: 5, busy: 2.5, memory: 280),
            try minute(day, "10:40:00", cpu: 6, busy: 3, memory: 290),
            try line(day, "10:40:30", "screens asleep"),
            try minute(day, "10:50:00", cpu: 7, busy: 3.5, memory: 295),
            "2026-11-10 10:5",
        ]
    }

    private func dayTwo() throws -> [String] {
        let day = "2026-11-11"
        return [
            try line(day, "08:00:00", "launch: pid 44, Muxify 1.0 (1), macOS 26, 1 screens"),
            try minute(day, "08:01:00", cpu: 5, busy: 1, memory: 400),
            try minute(day, "08:02:00", cpu: 10, busy: 4, memory: 410, input: InputCounts(keys: 1)),
            try burst(day, "08:02:10", length: 4, cpu: 35, peak: 40, busy: 50),
        ]
    }
}
