import XCTest
@testable import MuxifyCore

final class DiagnosticsRecordTests: XCTestCase {
    private let date = DiagnosticsRecord.formatter().date(from: "2026-11-11 17:07:34.120")!

    private func minute(input: InputCounts = InputCounts(keys: 12, clicks: 3, scrolls: 40, sidebarSwitches: 2, paletteOpens: 1))
        -> MinuteRecord {
        MinuteRecord(cpuAverage: 2.5, cpuPeak: 42.0, mainBusy: 7.5, memoryMB: 512, threads: 31, openFiles: 64, input: input,
                     moving: MovingState(window: AppWindowState(visible: true, active: false), workingMarks: 3, marksMove: true,
                                         sidebar: .sessions, topicCards: 9, sessionRows: 14))
    }

    func testAMinuteRecordWithEveryFieldRoundTripsThroughItsLine() throws {
        let record = minute().record
        let line = record.line(at: date)
        XCTAssertEqual(line, "2026-11-11 17:07:34.120 minute cpu.app.avg=2.5 cpu.app.peak=42.0 main.busy=7.5 mem.app=512 "
            + "threads=31 open_files=64 input=keys:12,clicks:3,scrolls:40,sidebar_switches:2,palette_opens:1 "
            + "window=visible,inactive working_marks=3 marks_move=true sidebar=sessions topic_cards=9 session_rows=14")

        let parsed = try XCTUnwrap(DiagnosticsRecord.parse(line))
        XCTAssertEqual(parsed.date, date)
        XCTAssertEqual(parsed.record, record)
        XCTAssertEqual(MinuteRecord(parsed.record), minute())
    }

    func testNoWindowAndNoSidebarRoundTrip() throws {
        var record = minute(input: InputCounts())
        record.moving = MovingState()
        let parsed = try XCTUnwrap(DiagnosticsRecord.parse(record.record.line(at: date)))
        XCTAssertEqual(parsed.record["window"], "none")
        XCTAssertEqual(parsed.record["sidebar"], "none")
        XCTAssertEqual(MinuteRecord(parsed.record), record)
    }

    func testEveryKindWritesAndParses() throws {
        for kind in DiagnosticsRecord.Kind.allCases {
            let record = DiagnosticsRecord(kind, [("list", DiagnosticsRecord.list(["a", "b"])),
                                                  ("pairs", DiagnosticsRecord.pairs([("SwiftUI", "95"), ("Muxify", "3")]))])
            let parsed = try XCTUnwrap(DiagnosticsRecord.parse(record.line(at: date)), kind.rawValue)
            XCTAssertEqual(parsed.record, record)
            XCTAssertEqual(parsed.record.list("list"), ["a", "b"])
            XCTAssertEqual(parsed.record.pairs("pairs")?.map { "\($0.name)=\($0.value)" }, ["SwiftUI=95", "Muxify=3"])
        }
    }

    func testAValueKeepsNoSpace() {
        let record = DiagnosticsRecord(.digest, [("file", "burst 17 07.txt")])
        XCTAssertEqual(record.text, "digest file=burst_17_07.txt")
    }

    func testALineItDoesNotKnowParsesToNil() {
        XCTAssertNil(DiagnosticsRecord.parse("2026-11-11 17:07:34.120 launch: pid 42, Muxify 1.0 (1), macOS 26"))
        XCTAssertNil(DiagnosticsRecord.parse("2026-11-11 17:07:34.120 freeze: main thread busy for 1.200s | app active"))
        XCTAssertNil(DiagnosticsRecord.parse("2026-11-11 17:07:34.120 resources: cpu 1.0%, memory 300 MB"))
        XCTAssertNil(DiagnosticsRecord.parse("2026-11-11 17:07:34.120 minute cpu.app.avg"))
        XCTAssertNil(DiagnosticsRecord.parse("not a line"))
        XCTAssertNil(DiagnosticsRecord.parse(""))
        XCTAssertNil(DiagnosticsRecord.parse("2026-11-11 minute cpu.app.avg=1.0"))
        XCTAssertNil(MinuteRecord(DiagnosticsRecord(.minute, [("cpu.app.avg", "1.0")])))
        XCTAssertNil(MinuteRecord(DiagnosticsRecord(.burst, minute().record.fields.map { ($0.key, $0.value) })))
    }

    // MARK: Process groups

    func testEachGroupThatWasReadIsWrittenAfterTheAppsMemory() throws {
        var record = minute()
        record.groups = [.commands: GroupFigures(cpuAverage: 3.5, cpuPeak: 61.0, memoryMB: 24),
                         .webkit: GroupFigures(cpuAverage: 12.0, cpuPeak: 40.5, memoryMB: 380),
                         .tmux: GroupFigures(cpuAverage: 0.5, cpuPeak: 2.0, memoryMB: 9)]
        let line = record.record.line(at: date)
        XCTAssertTrue(line.contains(" mem.app=512 cpu.commands.avg=3.5 cpu.commands.peak=61.0 mem.commands=24 "
            + "cpu.webkit.avg=12.0 cpu.webkit.peak=40.5 mem.webkit=380 cpu.tmux.avg=0.5 cpu.tmux.peak=2.0 mem.tmux=9 threads=31 "), line)
        let parsed = try XCTUnwrap(DiagnosticsRecord.parse(line))
        XCTAssertEqual(MinuteRecord(parsed.record), record)
    }

    func testAGroupThatCouldNotBeReadIsLeftOutNotZero() throws {
        var record = minute()
        record.groups = [.commands: GroupFigures(cpuAverage: 1.0, cpuPeak: 4.0, memoryMB: 0)]
        let parsed = try XCTUnwrap(DiagnosticsRecord.parse(record.record.line(at: date))).record
        XCTAssertEqual(parsed["mem.commands"], "0")
        for key in ["cpu.webkit.avg", "cpu.webkit.peak", "mem.webkit", "cpu.tmux.avg", "cpu.tmux.peak", "mem.tmux"] {
            XCTAssertNil(parsed[key], key)
        }
        XCTAssertEqual(MinuteRecord(parsed)?.groups, record.groups)

        // A group with a figure missing, or not a number, is not a minute record.
        var fields = parsed.fields.map { ($0.key, $0.value) }
        fields.append(("cpu.tmux.avg", "1.0"))
        XCTAssertNil(MinuteRecord(DiagnosticsRecord(.minute, fields)))
        fields += [("cpu.tmux.peak", "x"), ("mem.tmux", "3")]
        XCTAssertNil(MinuteRecord(DiagnosticsRecord(.minute, fields)))
    }

    func testTheMinuteAveragesAGroupOverTheSecondsItWasRead() {
        var reading = MinuteAggregate.Reading(uptime: 1000, cpu: 50, mainAwake: 10)
        var minute = MinuteAggregate(start: reading)
        for second in 0..<60 {
            reading.uptime += 1
            // The tmux server is read for the last 20 seconds only; the Browser is never open.
            reading.groups = [.commands: GroupUsage(cpu: second == 30 ? 0.8 : 0.02, footprint: 10 * 1_048_576)]
            if second >= 40 { reading.groups[.tmux] = GroupUsage(cpu: 0.01, footprint: 6 * 1_048_576) }
            minute.add(reading)
        }
        let record = minute.record(memoryMB: 300, threads: 20, openFiles: 40, input: InputCounts(), moving: MovingState())
        let commands = try? XCTUnwrap(record.groups[.commands])
        XCTAssertEqual(commands?.cpuPeak ?? 0, 80, accuracy: 0.001)
        XCTAssertEqual(commands?.cpuAverage ?? 0, (59 * 2 + 80) / 60, accuracy: 0.001)
        XCTAssertEqual(commands?.memoryMB, 10)
        XCTAssertEqual(record.groups[.tmux]?.cpuAverage ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(record.groups[.tmux]?.memoryMB, 6)
        XCTAssertNil(record.groups[.webkit])
        XCTAssertNil(record.record["cpu.webkit.avg"])
    }

    // MARK: The minute

    private func aggregate(cpuPerSecond: [Double]) -> MinuteAggregate {
        var reading = MinuteAggregate.Reading(uptime: 1000, cpu: 50, mainAwake: 10)
        var minute = MinuteAggregate(start: reading)
        for percent in cpuPerSecond {
            reading.uptime += 1
            reading.cpu += percent / 100
            reading.mainAwake += 0.05
            minute.add(reading)
        }
        return minute
    }

    func testThePeakKeepsAOneSecondSpikeThatTheAverageHides() {
        let minute = aggregate(cpuPerSecond: Array(repeating: 1, count: 30) + [90] + Array(repeating: 1, count: 29))
        XCTAssertEqual(minute.elapsed, 60)
        XCTAssertEqual(minute.cpuPeak, 90, accuracy: 0.001)
        XCTAssertEqual(minute.cpuAverage, (59 + 90) / 60, accuracy: 0.001)
        XCTAssertLessThan(minute.cpuAverage, 5)
        XCTAssertEqual(minute.mainBusy, 5, accuracy: 0.001)

        let record = minute.record(memoryMB: 300, threads: 20, openFiles: 40, input: InputCounts(), moving: MovingState()).record
        XCTAssertEqual(record["cpu.app.peak"], "90.0")
        XCTAssertEqual(record["cpu.app.avg"], "2.5")
        XCTAssertEqual(record["main.busy"], "5.0")
    }

    func testAReadingNoLaterThanTheLastIsLeftOut() {
        var minute = aggregate(cpuPerSecond: [10])
        minute.add(MinuteAggregate.Reading(uptime: minute.last.uptime, cpu: minute.last.cpu + 5, mainAwake: 0))
        XCTAssertEqual(minute.cpuPeak, 10, accuracy: 0.001)
        XCTAssertEqual(minute.elapsed, 1)
    }

    func testZeroInputIsIdle() {
        let record = aggregate(cpuPerSecond: [1, 1]).record(memoryMB: 300, threads: 20, openFiles: 40, input: InputCounts(),
                                                              moving: MovingState()).record
        XCTAssertEqual(record["input"], "idle")
        XCTAssertEqual(InputCounts(value: "idle"), InputCounts())
        XCTAssertFalse(InputCounts(sidebarSwitches: 1).isIdle)
        XCTAssertEqual(InputCounts(sidebarSwitches: 1).value, "keys:0,clicks:0,scrolls:0,sidebar_switches:1,palette_opens:0")
    }

    /// The input field names five kinds and gives each a count: it has nowhere to put a key, text, a title or a URL.
    func testTheInputFieldIsCountsOnly() throws {
        let value = InputCounts(keys: 7, clicks: 2, scrolls: 9, sidebarSwitches: 1, paletteOpens: 4).value
        let pairs = try XCTUnwrap(DiagnosticsRecord.pairs(in: value))
        XCTAssertEqual(pairs.map(\.name), ["keys", "clicks", "scrolls", "sidebar_switches", "palette_opens"])
        XCTAssertTrue(pairs.allSatisfy { Int($0.value) != nil }, value)
        XCTAssertNil(InputCounts(value: "keys:a,clicks:0,scrolls:0,sidebar_switches:0,palette_opens:0"))
        XCTAssertNil(InputCounts(value: "text:hello,clicks:0,scrolls:0,sidebar_switches:0,palette_opens:0"))

        // Every other field of the record is a number, a fixed word or a list of fixed words.
        let record = minute().record
        let fixed: Set<String> = ["visible", "occluded", "active", "inactive", "none", "true", "false", "topics", "sessions"]
        for field in record.fields where field.key != "input" {
            let words = field.value.split(separator: ",").map(String.init)
            XCTAssertTrue(words.allSatisfy { Double($0) != nil || fixed.contains($0) }, "\(field.key)=\(field.value)")
        }
    }
}
