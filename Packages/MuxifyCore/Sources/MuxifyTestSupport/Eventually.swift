import Foundation
import XCTest

// The one way a test waits for a signal. A test waits for what it asserts, never a fixed time: a busy CI runner
// can overrun any sleep. Every deadline and quiet period here is multiplied by the time scale, so CI can give every
// wait more time without editing a test.

/// How long the waits give a signal, as a multiple of the times the tests name.
public enum TestTime {
    /// The scale of this test process: `MUXIFY_TEST_TIME_SCALE`, which CI sets to 3.
    public static let scale = scale(from: ProcessInfo.processInfo.environment)

    /// The scale that `environment` sets. Unset, empty, not a number or below 1 means 1, so a local run fails fast.
    public static func scale(from environment: [String: String]) -> Double {
        let value = environment["MUXIFY_TEST_TIME_SCALE"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let scale = Double(value), scale.isFinite, scale >= 1 else { return 1 }
        return scale
    }

    /// How often the waits look at their condition.
    static let poll: TimeInterval = 0.02
}

/// `seconds` stretched by the time scale, for a bound on elapsed time where speed is the behaviour under test.
public func scaled(_ seconds: TimeInterval) -> TimeInterval {
    seconds * TestTime.scale
}

/// How a wait reports that its signal never came: the message, and where the test waited.
public typealias WaitFailure = (_ message: String, _ file: StaticString, _ line: UInt) -> Void

/// Reports a wait's timeout as a test failure.
public func failTheTest(_ message: String, file: StaticString, line: UInt) {
    XCTFail(message, file: file, line: line)
}

/// Waits until `condition` holds, looking every 20 ms, for up to `timeout` seconds times the time scale. On timeout
/// it reports `message` through `fail`, which a test of the wait itself replaces. On the main thread it runs the main
/// run loop between looks, so main-queue work can happen. Returns whether the condition held. An async test gets the
/// async form, which sleeps its task rather than block a thread.
@available(*, noasync, message: "an async test waits with the async form")
@discardableResult
public func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 10, scale: Double = TestTime.scale,
                       file: StaticString = #filePath, line: UInt = #line, fail: WaitFailure = failTheTest,
                       until condition: () throws -> Bool) rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout * scale)
    while try !condition() {
        guard Date() < deadline else {
            fail(message(), file, line)
            return false
        }
        pause(TestTime.poll)
    }
    return true
}

/// Waits until `condition` holds, as the sync form does, sleeping the task between looks. Without this overload an
/// async test that passes a sync condition would get the sync form, which blocks its thread.
@discardableResult
public func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 10, scale: Double = TestTime.scale,
                       isolation: isolated (any Actor)? = #isolation,
                       file: StaticString = #filePath, line: UInt = #line, fail: WaitFailure = failTheTest,
                       until condition: () throws -> Bool) async rethrows -> Bool {
    try await eventually(message(), timeout: timeout, scale: scale, file: file, line: line, fail: fail) {
        () async throws -> Bool in try condition()
    }
}

/// Waits until `condition` holds, as the sync form does, sleeping the task between looks.
@discardableResult
public func eventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 10, scale: Double = TestTime.scale,
                       isolation: isolated (any Actor)? = #isolation,
                       file: StaticString = #filePath, line: UInt = #line, fail: WaitFailure = failTheTest,
                       until condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout * scale)
    while try await !condition() {
        guard Date() < deadline else {
            fail(message(), file, line)
            return false
        }
        try? await Task.sleep(nanoseconds: UInt64(TestTime.poll * 1_000_000_000))
    }
    return true
}

/// Waits until no new item has come for `quiet` seconds, for up to `timeout` seconds, both times the time scale, and
/// returns the items it saw last. `items` gives every item so far; a longer collection means a new item. On timeout,
/// when items still come, it reports `message` through `fail` and returns what it saw.
@discardableResult
public func settled<Items: Collection>(_ message: @autoclosure () -> String, quiet: TimeInterval = 1.2,
                                       timeout: TimeInterval = 10, scale: Double = TestTime.scale,
                                       isolation: isolated (any Actor)? = #isolation,
                                       file: StaticString = #filePath, line: UInt = #line, fail: WaitFailure = failTheTest,
                                       items: () async throws -> Items) async rethrows -> Items {
    let deadline = Date().addingTimeInterval(timeout * scale)
    var seen = try await items()
    var lastChange = Date()
    while Date().timeIntervalSince(lastChange) < quiet * scale {
        guard Date() < deadline else {
            fail(message(), file, line)
            return seen
        }
        try? await Task.sleep(nanoseconds: UInt64(TestTime.poll * 1_000_000_000))
        let now = try await items()
        if now.count != seen.count { lastChange = Date() }
        seen = now
    }
    return seen
}

/// Lets `seconds` pass: on the main thread by running its run loop, elsewhere by sleeping.
private func pause(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    guard Thread.isMainThread else { return Thread.sleep(until: until) }
    while Date() < until {
        // false when the run loop has nothing to run, which would return at once and spin.
        guard RunLoop.current.run(mode: .default, before: until) else { return Thread.sleep(until: until) }
    }
}
