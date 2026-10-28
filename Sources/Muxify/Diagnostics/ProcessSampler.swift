import Foundation
import os

/// Runs `sample` on the app, the stacks of every thread over a few seconds, into a file in the diagnostics
/// folder. One sample runs at a time, and the folder keeps the newest `kept`.
enum ProcessSampler {
    private static let kept = 20
    private static let running = OSAllocatedUnfairLock(initialState: false)
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Blocks the calling thread for `seconds`, so call it off the main thread. Skips when a sample already runs.
    static func sample(reason: String, seconds: Int) {
        guard running.withLock({ running -> Bool in
            defer { running = true }
            return !running
        }) else { return }
        defer { running.withLock { $0 = false } }
        let name = "\(reason)-\(stamp.string(from: Date())).txt"
        let url = Diagnostics.folder.appendingPathComponent(name)
        Diagnostics.write("\(reason): sampling the process for \(seconds) s to \(name)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), String(seconds), "-mayDie", "-file", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Diagnostics.write("\(reason): cannot run sample: \(error)")
            return
        }
        prune()
    }

    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Diagnostics.folder, includingPropertiesForKeys: nil)) ?? []
        // The names start with the reason and end with the time, so sort by the time.
        let samples = files.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent.suffix(21) > $1.lastPathComponent.suffix(21) }
        for old in samples.dropFirst(kept) { try? FileManager.default.removeItem(at: old) }
    }
}
