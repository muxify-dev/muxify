import os

/// How many times each counted view's body ran, in every build. Diagnostics turns it on and off with itself, reads it
/// each second and logs what ran each minute and each Burst (`BodyCounts`); it never resets it. The TestDriver's
/// `counts` command reads it and may reset it, so a verify check can prove that a scroll of the Bench does not draw
/// every card again. To count a view, call `BodyCount.tick("<name>")` at the top of its body.
enum BodyCount {
    /// While false, a tick reads only this flag. Diagnostics sets it on the main thread, where bodies run.
    static var isOn = false
    /// Bodies tick on the main thread; Diagnostics reads off it.
    private static let lock = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    static func tick(_ name: String) {
        guard isOn else { return }
        lock.withLock { $0[name, default: 0] += 1 }
    }

    /// The counts since launch or the last reset.
    static var counts: [String: Int] { lock.withLock { $0 } }

    static func reset() { lock.withLock { $0 = [:] } }
}
