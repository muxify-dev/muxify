import Foundation
import MuxifyCore
import OSLog

/// Reads the app's CPU and its process groups' (`ProcessGroupsMeter`) each second, and each minute writes a `minute`
/// record: the average and peak per-second CPU, the main thread's busy share, memory, each group's figures, threads
/// and open files, the user's input, the counted SwiftUI bodies that ran (`BodyCount`) and what was moving. Then it copies the errors the system logged for the app.
/// Each second also goes to the Burst detector (`BurstDetector`): a Burst is sampled into `burst-<time>.txt`, and
/// when it ends, or Diagnostics stops or the app quits while it runs, it writes a `burst` record.
enum ResourceMonitor {
    private static let queue = DispatchQueue(label: "dev.muxify.resource-monitor", qos: .utility)
    private static let minuteLength: TimeInterval = 60
    private static let burstSampleSeconds = 5
    private static var timer: DispatchSourceTimer?
    private static var groups = ProcessGroupsMeter()
    private static var minute = MinuteAggregate(start: reading())
    /// The minute's input so far: the input is taken each second, for the Burst detector too.
    private static var minuteInput = InputCounts()
    /// The body counter at the last second, and the bodies that ran over the minute so far.
    private static var counted: [String: Int] = [:]
    private static var minuteBodies = BodyCounts()
    private static var bursts = BurstDetector()
    private static var systemLogRead = Date()

    static func start() {
        guard timer == nil else { return }
        // The first minute counts from now, and the system log from now: not from before diagnostics was off.
        queue.async {
            groups = ProcessGroupsMeter()
            minute = MinuteAggregate(start: reading())
            minuteInput = InputCounts()
            counted = BodyCount.counts
            minuteBodies = BodyCounts()
            bursts = BurstDetector()
            systemLogRead = Date()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { tick() }
        timer.resume()
        self.timer = timer
    }

    /// Writes the Burst that runs now, if any, as `open=true`.
    static func stop() {
        timer?.cancel()
        timer = nil
        closeBurst()
    }

    /// Writes the Burst that runs now, if any, as `open=true`: Diagnostics stops or the app quits. On the main thread.
    static func closeBurst() {
        guard let open = queue.sync(execute: { bursts.close() }) else { return }
        Diagnostics.write(open.record)
    }

    /// One `getrusage` and one read of the process groups a second; the rest once a minute.
    private static func tick() {
        let previous = minute.last
        let now = reading()
        minute.add(now)
        let secondInput = DiagnosticsInput.take()
        minuteInput += secondInput
        // Never reset here: the TestDriver's reset is a fall, which `BodyCounts` takes as a restart from zero.
        let counts = BodyCount.counts
        let secondBodies = BodyCounts(from: counted, to: counts)
        counted = counts
        minuteBodies += secondBodies
        if let second = BurstSecond(from: previous, to: now, end: Date(), input: secondInput, bodies: secondBodies) {
            watchBursts(second)
        }
        guard minute.elapsed >= minuteLength - 0.5 else { return }
        let ended = minute
        minute = MinuteAggregate(start: now)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 1) - 1
        let memory = Double(footprint()) / 1_048_576, threads = threadCount(), input = minuteInput, bodies = minuteBodies
        minuteInput = InputCounts()
        minuteBodies = BodyCounts()
        // What was moving is the main thread's state, read there once a minute.
        DispatchQueue.main.async {
            let moving = MainActor.assumeIsolated { Diagnostics.movingState() }
            // The web views' processes, for the next minute's reads.
            ProcessGroupSources.setWebProcesses(MainActor.assumeIsolated { BrowserTab.webProcesses() })
            let record = ended.record(memoryMB: memory, threads: threads, openFiles: files, input: input, bodies: bodies,
                                      moving: moving)
            Diagnostics.write(record.record)
        }
        copySystemLog()
    }

    /// Feeds the Burst detector. A Burst takes what was moving from the main thread when it starts, and its samples
    /// run off this queue, so the seconds keep coming while one records. A sample that another sample, such as a
    /// freeze's, holds back is asked for again the next second.
    private static func watchBursts(_ second: BurstSecond) {
        let step = bursts.add(second)
        if step.started {
            DispatchQueue.main.async {
                let moving = MainActor.assumeIsolated { Diagnostics.movingState() }
                queue.async { bursts.setMoving(moving) }
            }
        }
        if step.wantsSample, let name = ProcessSampler.start(reason: "burst", seconds: burstSampleSeconds) {
            bursts.sampled(name)
        }
        if let ended = step.ended { Diagnostics.write(ended.record) }
    }

    private static func reading() -> MinuteAggregate.Reading {
        let uptime = ProcessInfo.processInfo.systemUptime
        let sources = ProcessGroupSources.current
        return MinuteAggregate.Reading(uptime: uptime, cpu: cpuTime(), mainAwake: FreezeWatch.mainAwake(at: uptime),
                                       groups: groups.read(KernelProcessTable(), webkit: sources.webkit, tmux: sources.tmux))
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
        return ProcessGroupSources.cpuSeconds(usage)
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
