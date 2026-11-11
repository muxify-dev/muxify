import XCTest
@testable import MuxifyCore

final class BurstTests: XCTestCase {
    private let midday = DiagnosticsRecord.formatter().date(from: "2026-11-11 12:00:00.000")!

    /// Feeds one reading a second, starting a second after `from`, and takes each sample the detector asks for.
    /// Returns the ended Bursts and the seconds (from `from`) at which samples were taken.
    private func run(_ detector: inout BurstDetector, _ cpu: [Double], from start: Date? = nil,
                     busy: Double = 10, input: InputCounts = InputCounts()) -> (bursts: [BurstRecord], samples: [Int], starts: Int) {
        let start = start ?? midday
        var bursts: [BurstRecord] = [], samples: [Int] = [], starts = 0
        for (index, value) in cpu.enumerated() {
            let second = index + 1
            let step = detector.add(BurstSecond(end: start.addingTimeInterval(TimeInterval(second)), cpu: value, mainBusy: busy, input: input))
            if step.started { starts += 1 }
            if step.wantsSample {
                detector.sampled("burst-\(second).txt")
                samples.append(second)
            }
            if let ended = step.ended { bursts.append(ended) }
        }
        return (bursts, samples, starts)
    }

    private func seconds(_ count: Int, at cpu: Double) -> [Double] { Array(repeating: cpu, count: count) }

    // Case 2: a swipe burst at about 42% for 12 seconds.
    func testTwelveSecondsAtAbout42PercentGiveOneBurstOfTheRightLength() throws {
        var detector = BurstDetector()
        let cpu = seconds(5, at: 2) + [41, 43, 42, 44, 40, 42, 43, 41, 42, 44, 42, 41] + seconds(5, at: 2)
        let result = run(&detector, cpu, input: InputCounts(scrolls: 4, sidebarSwitches: 1))
        let burst = try XCTUnwrap(result.bursts.first)
        XCTAssertEqual(result.bursts.count, 1)
        XCTAssertEqual(burst.length, 12)
        XCTAssertEqual(burst.start, midday.addingTimeInterval(5))
        XCTAssertEqual(burst.cpuAverage, 42.08, accuracy: 0.01)
        XCTAssertEqual(burst.cpuPeak, 44)
        XCTAssertEqual(burst.mainBusyPeak, 10)
        XCTAssertEqual(burst.input, InputCounts(scrolls: 48, sidebarSwitches: 12))
        XCTAssertEqual(burst.samples, ["burst-8.txt"], "one sample when the Burst is found")
        XCTAssertFalse(burst.open)
        XCTAssertFalse(detector.isOpen)
    }

    func testTwoSecondsAt90PercentGiveNone() {
        var detector = BurstDetector()
        let result = run(&detector, seconds(3, at: 1) + seconds(2, at: 90) + seconds(10, at: 1))
        XCTAssertEqual(result.starts, 0)
        XCTAssertEqual(result.bursts, [])
        XCTAssertEqual(result.samples, [])
    }

    func testThreeSecondsAt30PercentStartOne() {
        var detector = BurstDetector()
        let result = run(&detector, seconds(2, at: 29.9) + seconds(3, at: 30))
        XCTAssertEqual(result.starts, 1)
        XCTAssertTrue(detector.isOpen)
        XCTAssertEqual(result.samples, [5])
        let open = detector.close()
        XCTAssertEqual(open?.length, 3)
        XCTAssertEqual(open?.open, true)
        XCTAssertFalse(detector.isOpen)
    }

    func testADipShorterThanThreeSecondsIsPartOfTheBurst() throws {
        var detector = BurstDetector()
        let result = run(&detector, seconds(4, at: 50) + seconds(2, at: 5) + seconds(4, at: 50) + seconds(3, at: 5))
        XCTAssertEqual(result.bursts.count, 1)
        XCTAssertEqual(try XCTUnwrap(result.bursts.first).length, 10)
        XCTAssertEqual(try XCTUnwrap(result.bursts.first).cpuAverage, 41)
    }

    // Case 1: the app idles at 40–55% for an hour.
    func testAnHourAt40To55PercentGivesOneBurstSampledAtTheStartAndEveryTenMinutes() throws {
        var detector = BurstDetector()
        let hour = (0..<3600).map { 40 + Double($0 % 16) }
        let result = run(&detector, hour + seconds(3, at: 3))
        XCTAssertEqual(result.starts, 1)
        XCTAssertEqual(result.bursts.count, 1)
        let burst = try XCTUnwrap(result.bursts.first)
        XCTAssertEqual(burst.length, 3600)
        XCTAssertEqual(result.samples, [3, 603, 1203, 1803, 2403, 3003])
        XCTAssertEqual(burst.samples, result.samples.map { "burst-\($0).txt" })
    }

    func testASampleIsAskedForAgainEachSecondUntilOneIsTaken() {
        var detector = BurstDetector()
        var asked: [Int] = []
        for second in 1...6 {
            let step = detector.add(BurstSecond(end: midday.addingTimeInterval(TimeInterval(second)), cpu: 60))
            if step.wantsSample { asked.append(second) }
            // Another sample runs at seconds 3 and 4.
            if step.wantsSample, second == 5 { detector.sampled("burst-5.txt") }
        }
        XCTAssertEqual(asked, [3, 4, 5])
    }

    func testNoMoreThanOneBurstSampleAMinute() {
        var detector = BurstDetector()
        // Two Bursts 20 seconds apart: the second is not sampled.
        let short = seconds(5, at: 60) + seconds(15, at: 1)
        let result = run(&detector, short + short + seconds(60, at: 1) + short)
        XCTAssertEqual(result.bursts.count, 3)
        XCTAssertEqual(result.bursts.map(\.samples.count), [1, 0, 1])
        XCTAssertEqual(result.samples, [3, 103])
    }

    func testAShortBurstHeldBackByTheMinuteCapIsSampledOnceTheMinutePasses() {
        var detector = BurstDetector()
        let result = run(&detector, seconds(5, at: 60) + seconds(5, at: 1) + seconds(80, at: 60) + seconds(3, at: 1))
        XCTAssertEqual(result.bursts.map(\.samples.count), [1, 1])
        XCTAssertEqual(result.samples, [3, 63])
    }

    func testNoMoreThanFortyBurstSamplesADay() {
        var detector = BurstDetector()
        // A Burst every two minutes: 45 of them in an hour and a half.
        let everyTwoMinutes = Array((0..<45).map { _ in seconds(5, at: 60) + seconds(115, at: 1) }.joined())
        let result = run(&detector, everyTwoMinutes)
        XCTAssertEqual(result.bursts.count, 45)
        XCTAssertEqual(result.samples.count, BurstDetector.samplesPerDay)
        XCTAssertEqual(result.bursts.filter { $0.samples.isEmpty }.count, 5, "a capped Burst still gets its record")

        // The next local day starts the count again.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: midday)!
        XCTAssertEqual(run(&detector, seconds(5, at: 60) + seconds(3, at: 1), from: tomorrow).samples, [3])
    }

    func testASecondBetweenTwoReadingsGivesItsCPUAndMainThreadShare() throws {
        let previous = MinuteAggregate.Reading(uptime: 100, cpu: 10, mainAwake: 5)
        let current = MinuteAggregate.Reading(uptime: 100.5, cpu: 10.25, mainAwake: 5.1)
        let second = try XCTUnwrap(BurstSecond(from: previous, to: current, end: midday, input: InputCounts(keys: 1)))
        XCTAssertEqual(second.length, 0.5)
        XCTAssertEqual(second.cpu, 50, accuracy: 0.001)
        XCTAssertEqual(second.mainBusy, 20, accuracy: 0.001)
        XCTAssertNil(BurstSecond(from: current, to: current, end: midday, input: InputCounts()))
    }

    // MARK: The record

    private let date = DiagnosticsRecord.formatter().date(from: "2026-11-11 17:07:34.120")!

    private func burst(open: Bool = false, samples: [String] = ["burst-2026-11-11-170722.txt", "burst-2026-11-11-171722.txt"])
        -> BurstRecord {
        BurstRecord(start: DiagnosticsRecord.formatter().date(from: "2026-11-11 17:07:19.250")!, length: 15,
                    cpuAverage: 42.3, cpuPeak: 55.0, mainBusyPeak: 91.5,
                    input: InputCounts(keys: 0, clicks: 2, scrolls: 40, sidebarSwitches: 6, paletteOpens: 0),
                    bodies: BodyCounts(["TopicsSection": 6, "SidebarCard": 300]),
                    moving: MovingState(window: AppWindowState(visible: true, active: true), workingMarks: 2, marksMove: true,
                                        sidebar: .topics, topicCards: 12, sessionRows: 0),
                    samples: samples, open: open)
    }

    func testABurstRecordWithEveryFieldRoundTripsThroughItsLine() throws {
        let line = burst().record.line(at: date)
        XCTAssertEqual(line, "2026-11-11 17:07:34.120 burst start=2026-11-11T17:07:19.250 length=15.0 cpu.avg=42.3 cpu.peak=55.0 "
            + "main.busy.peak=91.5 input=keys:0,clicks:2,scrolls:40,sidebar_switches:6,palette_opens:0 "
            + "bodies=SidebarCard:300,TopicsSection:6 window=visible,active working_marks=2 marks_move=true sidebar=topics topic_cards=12 session_rows=0 "
            + "samples=burst-2026-11-11-170722.txt,burst-2026-11-11-171722.txt")
        let parsed = try XCTUnwrap(DiagnosticsRecord.parse(line))
        XCTAssertEqual(parsed.record.kind, .burst)
        XCTAssertEqual(BurstRecord(parsed.record), burst())
    }

    func testAnOpenBurstWithNoSampleRoundTrips() throws {
        let record = burst(open: true, samples: [])
        let line = record.record.line(at: date)
        XCTAssertTrue(line.hasSuffix(" samples=none open=true"), line)
        let parsed = try XCTUnwrap(DiagnosticsRecord.parse(line))
        XCTAssertEqual(BurstRecord(parsed.record), record)
    }

    func testABurstRecordMissingAFieldIsNil() {
        let fields = burst().record.fields
        for left in fields {
            let record = DiagnosticsRecord(.burst, fields.filter { $0 != left }.map { ($0.key, $0.value) })
            XCTAssertNil(BurstRecord(record), left.key)
        }
        XCTAssertNil(BurstRecord(DiagnosticsRecord(.minute, fields.map { ($0.key, $0.value) })))
    }
}
