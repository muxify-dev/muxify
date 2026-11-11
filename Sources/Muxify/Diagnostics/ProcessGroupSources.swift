import Darwin
import Foundation
import MuxifyCore
import os

/// Where the `minute` record's process groups come from (`ProcessGroupsMeter`): the Local tmux server's pid, which
/// the Local Workspace Stores set from each snapshot, the Browser's web process identifiers, read on the main thread
/// once a minute, and the CPU of the `sample` runs Diagnostics waited for, to leave out of the commands.
enum ProcessGroupSources {
    private struct State {
        var tmuxServer: pid_t?
        var webProcesses: [pid_t] = []
        var leftOutReaped: TimeInterval = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// The Local tmux server, or nil when it does not run.
    static func setLocalTmuxServer(_ pid: pid_t?) {
        state.withLock { $0.tmuxServer = pid }
    }

    static func setWebProcesses(_ pids: [pid_t]) {
        state.withLock { $0.webProcesses = pids }
    }

    static var current: (webkit: [pid_t], tmux: pid_t?) {
        state.withLock { ($0.webProcesses, $0.tmuxServer) }
    }

    /// Waits for `pid`, a child that has exited (`waitid` with `WNOWAIT`), and leaves its CPU out of the commands.
    /// The wait and the sum are one step under the lock that `reaped()` reads in, so the two totals always agree.
    static func reapLeftOut(_ pid: pid_t) {
        state.withLock { state in
            var status: Int32 = 0
            var usage = rusage()
            guard wait4(pid, &status, 0, &usage) == pid else { return }
            state.leftOutReaped += cpuSeconds(usage)
        }
    }

    /// The CPU of the app's waited-for children, and of the ones left out.
    static func reaped() -> ReapedChildren {
        state.withLock { state in
            var usage = rusage()
            getrusage(RUSAGE_CHILDREN, &usage)
            return ReapedChildren(all: cpuSeconds(usage), leftOut: state.leftOutReaped)
        }
    }

    static func cpuSeconds(_ usage: rusage) -> TimeInterval {
        func seconds(_ time: timeval) -> TimeInterval { TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

/// The kernel's process table: the app's children through libproc, any process the user owns through
/// `proc_pid_rusage`. Another user's process, such as root's, cannot be read.
struct KernelProcessTable: ProcessTable {
    /// `proc_pid_rusage` gives its times in Mach time units, not nanoseconds, on Apple silicon.
    private static let nanosecondsPerUnit: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    func children() -> [Int32] {
        let me = getpid()
        // Room for the children that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(max(0, proc_listchildpids(me, nil, 0))) + 16)
        let count = pids.withUnsafeMutableBytes { proc_listchildpids(me, $0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(count, 0)))).filter { $0 > 0 }
    }

    func usage(of pid: Int32) -> ProcessUsage? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return nil }
        let cpu = Double(info.ri_user_time + info.ri_system_time) * Self.nanosecondsPerUnit / 1_000_000_000
        return ProcessUsage(pid: pid, name: PTYCensus.name(of: pid), cpu: cpu, footprint: info.ri_phys_footprint)
    }

    func reaped() -> ReapedChildren {
        ProcessGroupSources.reaped()
    }
}
