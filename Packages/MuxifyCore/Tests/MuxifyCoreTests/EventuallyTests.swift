import Foundation
import MuxifyTestSupport
import XCTest

/// The shared waits: they return once their signal comes, report their message when it never does, and stretch by the
/// time scale. Each timeout here names its scale, so CI's scale of 3 does not change what the test proves.
final class EventuallyTests: XCTestCase {
    func testItReturnsWithoutWaitingWhenTheConditionAlreadyHolds() {
        var looks = 0
        let failures = Failures()
        let held = eventually("never", scale: 1, fail: failures.add) { looks += 1; return true }
        XCTAssertTrue(held)
        XCTAssertEqual(looks, 1)
        XCTAssertEqual(failures.messages, [])
    }

    func testItReturnsAsSoonAsTheConditionHolds() {
        let start = Date()
        let ready = start.addingTimeInterval(0.1)
        let failures = Failures()
        XCTAssertTrue(eventually("never ready", scale: 1, fail: failures.add) { Date() >= ready })
        // Far below the 10 s timeout: the wait ended at the signal, not at its deadline.
        XCTAssertLessThan(Date().timeIntervalSince(start), scaled(5))
        XCTAssertEqual(failures.messages, [])
    }

    func testOnTheMainThreadItRunsMainQueueWork() {
        XCTAssertTrue(Thread.isMainThread)
        var ran = false
        DispatchQueue.main.async { ran = true }
        let failures = Failures()
        XCTAssertTrue(eventually("the main queue did not run", fail: failures.add) { ran })
        XCTAssertEqual(failures.messages, [])
    }

    func testTheMainQueueWaitReturnsOnceTheWorkQueuedBeforeItRan() {
        var ran: [Int] = []
        DispatchQueue.main.async { ran.append(1) }
        DispatchQueue.main.async { ran.append(2) }
        waitForTheMainQueue()
        XCTAssertEqual(ran, [1, 2])
    }

    func testATimeoutReportsTheMessageWhereTheTestWaited() {
        let failures = Failures()
        let start = Date()
        let line: UInt = #line + 1
        let held = eventually("the door never opened", timeout: 0.1, scale: 1, fail: failures.add) { false }
        XCTAssertFalse(held)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.1)
        XCTAssertEqual(failures.messages, ["the door never opened"])
        XCTAssertEqual(failures.lines, [line])
        XCTAssertEqual(failures.files, ["\(#filePath)"])
    }

    func testTheScaleStretchesTheDeadline() {
        let failures = Failures()
        var start = Date()
        XCTAssertFalse(eventually("never", timeout: 0.1, scale: 5, fail: failures.add) { false })
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(failures.messages, ["never"])

        // 0.3 s is past the 0.1 s the test names, but within the 0.5 s that the scale makes of it.
        start = Date()
        let ready = start.addingTimeInterval(0.3)
        XCTAssertTrue(eventually("not ready in time", timeout: 0.1, scale: 5, fail: failures.add) { Date() >= ready })
        XCTAssertEqual(failures.messages, ["never"])
    }

    func testTheAsyncFormWaitsForTheConditionAndReportsATimeout() async {
        // The condition holds on its third look, so the wait must look again rather than return.
        var looks = 0
        let failures = Failures()
        let held = await eventually("the third look never came", scale: 1, fail: failures.add) { looks += 1; return looks == 3 }
        XCTAssertTrue(held)
        XCTAssertEqual(looks, 3)
        XCTAssertEqual(failures.messages, [])

        let start = Date()
        let late = await eventually("the condition never held", timeout: 0.1, scale: 3, fail: failures.add) { false }
        XCTAssertFalse(late)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        XCTAssertEqual(failures.messages, ["the condition never held"])
    }

    func testTheScaleIsOneUnlessTheEnvironmentSetsOneOrMore() {
        XCTAssertEqual(TestTime.scale(from: [:]), 1)
        for value in ["", " ", "fast", "0", "0.5", "-3", "nan", "inf"] {
            XCTAssertEqual(TestTime.scale(from: ["MUXIFY_TEST_TIME_SCALE": value]), 1, value)
        }
        XCTAssertEqual(TestTime.scale(from: ["MUXIFY_TEST_TIME_SCALE": "1"]), 1)
        XCTAssertEqual(TestTime.scale(from: ["MUXIFY_TEST_TIME_SCALE": "3"]), 3)
        XCTAssertEqual(TestTime.scale(from: ["MUXIFY_TEST_TIME_SCALE": "2.5"]), 2.5)
        XCTAssertEqual(scaled(2), 2 * TestTime.scale)
    }

    func testTheSettleWaitReturnsOnceItemsStopComing() async {
        // A burst: one new item at each look, up to ten, then none.
        var count = 0
        let failures = Failures()
        let start = Date()
        let seen = await settled("the burst did not settle", quiet: 0.3, scale: 1, fail: failures.add) {
            count = min(count + 1, 10)
            return Array(1...count)
        }
        XCTAssertEqual(seen, Array(1...10))
        // It waited out the quiet period after the last item, and no longer than its deadline.
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(start), scaled(5))
        XCTAssertEqual(failures.messages, [])
    }

    func testTheSettleWaitReportsItemsThatNeverStop() async {
        let failures = Failures()
        var count = 0
        let start = Date()
        let seen = await settled("the items never stopped", quiet: 0.2, timeout: 0.3, scale: 2, fail: failures.add) {
            count += 1
            return Array(0..<count)
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.6)
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(failures.messages, ["the items never stopped"])
    }
}

/// What a wait reported instead of failing the test.
private final class Failures {
    private(set) var messages: [String] = []
    private(set) var files: [String] = []
    private(set) var lines: [UInt] = []

    func add(_ message: String, file: StaticString, line: UInt) {
        messages.append(message)
        files.append("\(file)")
        lines.append(line)
    }
}
