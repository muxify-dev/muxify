import Darwin
import Foundation

/// The pseudo-terminals in use on the Mac, and which processes hold them. macOS has a fixed number
/// (`kern.tty.ptmx_max`); when all are in use, no terminal can start, Muxify's included. Each open master, a file
/// descriptor on `/dev/ptmx`, is one PTY. Only the processes the user can see are counted, so `inUse` can be low.
struct PTYCensus: Equatable {
    struct Holder: Equatable {
        let name: String
        let pid: pid_t
        let count: Int
    }

    /// Use from this share of the limit up is high.
    static let highShare = 0.8

    let limit: Int
    let inUse: Int
    /// Most first.
    let holders: [Holder]

    var isHigh: Bool { limit > 0 && Double(inUse) >= Double(limit) * Self.highShare }

    /// For the log: "PTYs: 498 of 511 in use. Most held by: tmux 1083 (430), node 4411 (40)".
    var summary: String {
        let top = holders.prefix(10).map { "\($0.name) \($0.pid) (\($0.count))" }
        return "PTYs: \(inUse) of \(limit) in use." + (top.isEmpty ? "" : " Most held by: " + top.joined(separator: ", "))
    }

    /// For the user, after what failed.
    var explanation: String {
        let top = holders.prefix(3).map { "\($0.name) (\($0.count))" }
        return "The Mac has \(inUse) of its \(limit) pseudo-terminals in use"
            + (top.isEmpty ? "." : ", most by " + top.joined(separator: ", ") + ".")
    }

    /// Reads every process's open files, so it takes some milliseconds: call it off the main thread.
    static func take() -> PTYCensus {
        var holders: [Holder] = []
        for pid in allPIDs() {
            let count = ptyMasters(of: pid)
            if count > 0 { holders.append(Holder(name: name(of: pid), pid: pid, count: count)) }
        }
        holders.sort { ($0.count, $1.pid) > ($1.count, $0.pid) }
        return PTYCensus(limit: limit(), inUse: holders.reduce(0) { $0 + $1.count }, holders: holders)
    }

    private static func limit() -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.tty.ptmx_max", &value, &size, nil, 0) == 0 ? Int(value) : 0
    }

    private static func allPIDs() -> [pid_t] {
        // Room for the processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(Int(max(count, 0)))).filter { $0 > 0 }
    }

    private static func ptyMasters(of pid: pid_t) -> Int {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return 0 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return 0 }
        return fds.prefix(Int(filled) / stride).filter { $0.proc_fdtype == PROX_FDTYPE_VNODE && isPTYMaster(pid, $0.proc_fd) }.count
    }

    private static func isPTYMaster(_ pid: pid_t, _ fd: Int32) -> Bool {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return false }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path == "/dev/ptmx"
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "?" }
        return String(cString: buffer)
    }
}

/// Whether PTY use is high, so that a report comes once each time it rises into high use, not on every check.
struct PTYCrossing {
    private(set) var isHigh = false

    /// True when `census` is high and the one before was not.
    mutating func rose(_ census: PTYCensus) -> Bool {
        defer { isHigh = census.isHigh }
        return census.isHigh && !isHigh
    }
}

/// Every five minutes, whether diagnostics are on or not, takes a PTY census and reports it when use has risen into
/// high use: when the Mac runs out, terminals everywhere stop starting, and the log then names who held them.
enum PTYWatch {
    private static let queue = DispatchQueue(label: "dev.muxify.pty-watch", qos: .utility)
    private static var timer: DispatchSourceTimer?
    private static var crossing = PTYCrossing()

    static func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 300, leeway: .seconds(10))
        timer.setEventHandler {
            let census = PTYCensus.take()
            if crossing.rose(census) { Diagnostics.report("PTY use is high. \(census.summary)") }
        }
        timer.resume()
        self.timer = timer
    }
}
