import Foundation
import OSLog

/// Each minute logs the CPU the app used in that minute, its memory, threads and open files, and the errors the
/// system logged for it. A minute over half a core also samples the process, at most every ten minutes.
enum ResourceMonitor {
    private static let queue = DispatchQueue(label: "dev.muxify.resource-monitor", qos: .utility)
    private static let busyCPU = 50.0
    private static var timer: DispatchSourceTimer?
    private static var last = (uptime: ProcessInfo.processInfo.systemUptime, cpu: cpuTime())
    private static var lastCPUSample = -TimeInterval.infinity
    private static var systemLogRead = Date()

    static func start() {
        guard timer == nil else { return }
        // The first minute counts from now, and the system log from now: not from before diagnostics was off.
        queue.async {
            last = (ProcessInfo.processInfo.systemUptime, cpuTime())
            systemLogRead = Date()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler { tick() }
        timer.resume()
        self.timer = timer
    }

    static func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func tick() {
        let now = (uptime: ProcessInfo.processInfo.systemUptime, cpu: cpuTime())
        let percent = now.uptime > last.uptime ? (now.cpu - last.cpu) / (now.uptime - last.uptime) * 100 : 0
        last = now
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 1) - 1
        Diagnostics.write(String(format: "resources: cpu %.1f%%, memory %.0f MB, %d threads, %d open files",
                                 percent, Double(footprint()) / 1_048_576, threadCount(), files))
        copySystemLog()
        if percent > busyCPU, now.uptime - lastCPUSample > 600 {
            lastCPUSample = now.uptime
            ProcessSampler.sample(reason: "cpu", seconds: 5)
        }
    }

    /// The errors and faults the system logged for this process since the last read, each kind once.
    /// Muxify's own messages come through `Diagnostics.report`: the system log hides their text from the app.
    private static func copySystemLog() {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: systemLogRead)) else { return }
        let since = systemLogRead
        var kinds: [String] = []
        var seen: [String: (first: Date, count: Int)] = [:]
        for case let entry as OSLogEntryLog in entries where entry.date > since {
            systemLogRead = max(systemLogRead, entry.date)
            guard entry.level == .error || entry.level == .fault, entry.composedMessage != "<private>" else { continue }
            let source = entry.subsystem.isEmpty ? entry.sender : entry.subsystem
            let message = entry.composedMessage.replacingOccurrences(of: "\n", with: " ").prefix(500)
            let kind = "\(entry.level == .fault ? "fault" : "error") \(source): \(message)"
            if seen[kind] == nil { kinds.append(kind) }
            seen[kind, default: (entry.date, 0)].count += 1
        }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        for kind in kinds.prefix(100) {
            guard let (first, count) = seen[kind] else { continue }
            Diagnostics.write("system log \(clock.string(from: first)): \(kind)\(count > 1 ? " (\(count) times)" : "")")
        }
        if kinds.count > 100 { Diagnostics.write("system log: \(kinds.count - 100) more kinds of error left out") }
    }

    private static func cpuTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> TimeInterval { TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The memory Activity Monitor shows for the app.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}
