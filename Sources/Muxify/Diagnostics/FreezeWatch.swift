import AppKit
import os

/// Watches the main run loop. A pass that works for over a second is a freeze: once it passes the second, the
/// process is sampled to a file, and when it ends its length goes to the log.
enum FreezeWatch {
    private struct Pass {
        var number = 0
        var started: TimeInterval?
        /// Each start and stop counts one, so the watching thread of an earlier start ends.
        var run = 0
    }

    private static let threshold: TimeInterval = 1
    private static let current = OSAllocatedUnfairLock(initialState: Pass())
    private static var observer: CFRunLoopObserver?

    static func start() {
        guard observer == nil else { return }
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            let now = ProcessInfo.processInfo.systemUptime
            if activity == .afterWaiting {
                current.withLock { $0.number += 1; $0.started = now }
                return
            }
            let started = current.withLock { pass -> TimeInterval? in
                defer { pass.started = nil }
                return pass.started
            }
            guard let started, now - started > threshold else { return }
            Diagnostics.write("freeze: main thread busy for \(Diagnostics.seconds(now - started))\(DisplayLinkProbe.summary) | "
                + Diagnostics.describe(NSApp.keyWindow ?? NSApp.mainWindow))
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        let run = current.withLock { $0.run += 1; return $0.run }
        Thread.detachNewThread { watch(run) }
    }

    static func stop() {
        guard let observer else { return }
        CFRunLoopObserverInvalidate(observer)
        self.observer = nil
        current.withLock { $0.run += 1; $0.started = nil }
    }

    /// Samples each pass at most once, while it still runs.
    private static func watch(_ run: Int) {
        var sampled = 0
        while true {
            Thread.sleep(forTimeInterval: 0.25)
            let pass = current.withLock { $0 }
            guard pass.run == run else { return }
            guard let started = pass.started, pass.number != sampled,
                  ProcessInfo.processInfo.systemUptime - started > threshold else { continue }
            sampled = pass.number
            ProcessSampler.sample(reason: "freeze", seconds: 3)
        }
    }
}
