import XCTest
@testable import MuxifyCore

final class BodyCountsTests: XCTestCase {
    func testTheBodiesBetweenTwoReadingsAreTheirDifferenceWithNoZero() {
        let bodies = BodyCounts(from: ["SidebarCard": 40, "TopicsList": 3, "TopicCard": 9],
                                to: ["SidebarCard": 70, "TopicsList": 3, "TopicCard": 12, "AgentMarkSpine": 5])
        XCTAssertEqual(bodies, BodyCounts(["SidebarCard": 30, "TopicCard": 3, "AgentMarkSpine": 5]))
        XCTAssertEqual(bodies.value, "AgentMarkSpine:5,SidebarCard:30,TopicCard:3")
    }

    /// The TestDriver's `counts reset=True` empties the counter while Diagnostics reads it each second.
    func testADeltaAcrossATestDriverResetIsNeverNegative() {
        var readings: [[String: Int]] = [["SidebarCard": 300, "TopicCard": 120]]
        readings.append([:])                                    // reset
        readings.append(["SidebarCard": 4])                     // 4 bodies after the reset
        readings.append(["SidebarCard": 10, "TopicCard": 2])
        readings.append(["TopicCard": 1])                       // reset again, then one body
        var minute = BodyCounts()
        for (earlier, later) in zip(readings, readings.dropFirst()) {
            let second = BodyCounts(from: earlier, to: later)
            XCTAssertTrue(second.counts.values.allSatisfy { $0 > 0 }, "\(earlier) -> \(later): \(second.value)")
            minute += second
        }
        XCTAssertEqual(minute, BodyCounts(["SidebarCard": 10, "TopicCard": 3]))
        XCTAssertEqual(BodyCounts(from: ["SidebarCard": 300], to: [:]).value, "none")
    }

    func testTheValueRoundTripsAndNoneIsEmpty() {
        let bodies = BodyCounts(["TopicsSection": 2, "SidebarCard": 300, "SessionsSection": 0])
        XCTAssertEqual(bodies.value, "SidebarCard:300,TopicsSection:2")
        XCTAssertEqual(BodyCounts(value: bodies.value), bodies)
        XCTAssertEqual(BodyCounts().value, "none")
        XCTAssertEqual(BodyCounts(value: "none"), BodyCounts())
        for bad in ["", "SidebarCard", "SidebarCard:x", "SidebarCard:0", "SidebarCard:1,SidebarCard:2", ":3"] {
            XCTAssertNil(BodyCounts(value: bad), bad)
        }
    }

    func testAMinuteRecordCarriesItsBodies() throws {
        let minute = MinuteRecord(cpuAverage: 40, cpuPeak: 55, mainBusy: 80, memoryMB: 400, threads: 30, openFiles: 60,
                                  input: InputCounts(sidebarSwitches: 10), bodies: BodyCounts(["SidebarCard": 300]),
                                  moving: MovingState())
        let record = try XCTUnwrap(DiagnosticsRecord.parse(minute.record.line(at: Date(timeIntervalSince1970: 0)))).record
        XCTAssertEqual(record["bodies"], "SidebarCard:300")
        XCTAssertEqual(MinuteRecord(record), minute)
        let fields = minute.record.fields.filter { $0.key != "bodies" }.map { ($0.key, $0.value) }
        XCTAssertNil(MinuteRecord(DiagnosticsRecord(.minute, fields)), "a minute record with no bodies")
    }

    func testABurstAddsTheBodiesOfItsSecondsAndItsDips() throws {
        var detector = BurstDetector()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let cpu: [Double] = [2, 45, 45, 45, 10, 45, 2, 2, 2]
        var ended: BurstRecord?
        for (index, value) in cpu.enumerated() {
            let second = BurstSecond(end: start.addingTimeInterval(TimeInterval(index + 1)), cpu: value,
                                     bodies: BodyCounts(["SidebarCard": index + 1]))
            if let burst = detector.add(second).ended { ended = burst }
        }
        // Seconds 2 to 6, the dip at 5 included; the cold seconds after are not part of it.
        XCTAssertEqual(try XCTUnwrap(ended).bodies, BodyCounts(["SidebarCard": 2 + 3 + 4 + 5 + 6]))
    }
}
