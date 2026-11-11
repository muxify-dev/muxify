import Foundation
import os

/// Runs `sample` on the app, the stacks of every thread over a few seconds, into a file in the diagnostics
/// folder. One sample runs at a time, and the folder keeps the newest `kept`. Its CPU is left out of the `minute`
/// record's commands group.
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
        if let problem = run("/usr/bin/sample", [String(getpid()), String(seconds), "-mayDie", "-file", url.path]) {
            Diagnostics.write("\(reason): cannot run sample: \(problem)")
            return
        }
        prune()
    }

    /// Runs `path` to its exit with no input or output, and leaves its CPU out of the commands group: it starts
    /// the process itself, not through `Process`, so that it waits for it itself (`ProcessGroupSources.reapLeftOut`).
    /// Returns what went wrong, or nil.
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        // Like the control clients: no other descriptor of the app, every signal at its default and none blocked.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        guard result == 0 else { return String(cString: strerror(result)) }
        // Waits for the exit without reaping, so the CPU is taken out in the same step as the reap.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        ProcessGroupSources.reapLeftOut(pid)
        return nil
    }

    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Diagnostics.folder, includingPropertiesForKeys: nil)) ?? []
        // The names start with the reason and end with the time, so sort by the time.
        let samples = files.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent.suffix(21) > $1.lastPathComponent.suffix(21) }
        for old in samples.dropFirst(kept) { try? FileManager.default.removeItem(at: old) }
    }
}
