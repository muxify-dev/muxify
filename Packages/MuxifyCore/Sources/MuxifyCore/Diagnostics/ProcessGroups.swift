import Foundation

/// The processes around the app that the `minute` record gives their own CPU and memory, beside the app's:
/// - `commands`: the processes the app starts, `sample` left out;
/// - `webkit`: the Browser's WebContent processes, one per web view, so a lower bound;
/// - `tmux`: the Local tmux server, which serves all of its clients, Muxify's and any other.
public enum ProcessGroup: String, CaseIterable, Sendable {
    case commands, webkit, tmux
}

/// One process's CPU so far (user and system, seconds) and memory (phys footprint, bytes).
public struct ProcessUsage: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var cpu: TimeInterval
    public var footprint: UInt64

    public init(pid: Int32, name: String, cpu: TimeInterval, footprint: UInt64) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.footprint = footprint
    }
}

/// The CPU, in seconds, of the app's children that have exited and been waited for: all of them, and the ones
/// left out of `commands` (`sample`). Both only grow.
public struct ReapedChildren: Equatable, Sendable {
    public var all: TimeInterval
    public var leftOut: TimeInterval

    public init(all: TimeInterval, leftOut: TimeInterval) {
        self.all = all
        self.leftOut = leftOut
    }
}

/// What the process groups are read from. The app's reads the kernel; a test's is a fake.
public protocol ProcessTable {
    /// The app's live children.
    func children() -> [Int32]
    /// Nil when the process has exited or cannot be read, such as another user's.
    func usage(of pid: Int32) -> ProcessUsage?
    func reaped() -> ReapedChildren
}

/// A group's CPU since the last reading, in seconds, and its memory now, in bytes.
public struct GroupUsage: Equatable, Sendable {
    public var cpu: TimeInterval
    public var footprint: UInt64

    public init(cpu: TimeInterval, footprint: UInt64) {
        self.cpu = cpu
        self.footprint = footprint
    }
}

/// Turns one process table reading a second into each group's CPU over that second. A group it cannot read,
/// or reads for the first time, has no usage that second: never a zero it did not measure.
public struct ProcessGroupsMeter: Sendable {
    /// Diagnostics' own sampler: taking a sample is not load.
    public static let leftOutNames: Set<String> = ["sample"]

    private var commands = CommandsMeter()
    private var webkit = PIDGroupMeter()
    private var tmux = PIDGroupMeter()

    public init() {}

    /// `webkit` are the web views' process identifiers; `tmux` the Local server's, nil with no Local server.
    public mutating func read(_ table: ProcessTable, webkit webkitPIDs: [Int32], tmux tmuxPID: Int32?) -> [ProcessGroup: GroupUsage] {
        var groups: [ProcessGroup: GroupUsage] = [:]
        groups[.commands] = commands.read(table)
        groups[.webkit] = webkit.read(Self.usages(webkitPIDs, in: table))
        groups[.tmux] = tmux.read(Self.usages(tmuxPID.map { [$0] } ?? [], in: table))
        return groups
    }

    /// Nil when none of `pids` can be read.
    private static func usages(_ pids: [Int32], in table: ProcessTable) -> [ProcessUsage]? {
        let usages = Set(pids).compactMap(table.usage(of:))
        return usages.isEmpty ? nil : usages
    }
}

/// The commands: exited children through the reaped total, live ones through their own reads, `sample` in neither.
/// A child that exits was read while it lived, and its whole CPU then comes again in the reaped total: what was
/// read of it is owed and taken off that total, once the total has grown by it.
struct CommandsMeter: Sendable {
    private var reaped: TimeInterval?
    /// The CPU each live child had at its last read.
    private var live: [Int32: TimeInterval] = [:]
    private var owed: TimeInterval = 0

    mutating func read(_ table: ProcessTable) -> GroupUsage? {
        // Children first: one that is waited for between the two reads is then read alive and owed next time.
        let children = table.children().compactMap(table.usage(of:))
            .filter { !ProcessGroupsMeter.leftOutNames.contains($0.name) }
        let total = table.reaped()
        let counted = total.all - total.leftOut
        defer {
            reaped = counted
            live = Dictionary(children.map { ($0.pid, $0.cpu) }, uniquingKeysWith: max)
        }
        guard let last = reaped else {
            return nil
        }
        // A child not seen before started since the last read, so all of its CPU is new.
        let liveCPU = children.reduce(0) { $0 + max(0, $1.cpu - (live[$1.pid] ?? 0)) }
        let alive = Set(children.map(\.pid))
        owed += live.filter { !alive.contains($0.key) }.values.reduce(0, +)
        let grown = max(0, counted - last)
        let paid = min(owed, grown)
        owed -= paid
        return GroupUsage(cpu: liveCPU + grown - paid, footprint: children.reduce(0) { $0 + $1.footprint })
    }
}

/// A group of processes that are not the app's children, named by pid. A process not seen at the last read is
/// counted from this one on: what it used before is not known to be new.
struct PIDGroupMeter: Sendable {
    private var last: [Int32: TimeInterval] = [:]

    mutating func read(_ usages: [ProcessUsage]?) -> GroupUsage? {
        guard let usages else {
            last = [:]
            return nil
        }
        defer { last = Dictionary(usages.map { ($0.pid, $0.cpu) }, uniquingKeysWith: max) }
        let known = usages.filter { last[$0.pid] != nil }
        guard !known.isEmpty else { return nil }
        return GroupUsage(cpu: known.reduce(0) { $0 + max(0, $1.cpu - (last[$1.pid] ?? 0)) },
                          footprint: usages.reduce(0) { $0 + $1.footprint })
    }
}

/// A group's figures for a minute: its average and peak per-second CPU, in % of one core, and its memory at the
/// end of the minute, in MB.
public struct GroupFigures: Equatable, Sendable {
    public var cpuAverage: Double
    public var cpuPeak: Double
    public var memoryMB: Double

    public init(cpuAverage: Double, cpuPeak: Double, memoryMB: Double) {
        self.cpuAverage = cpuAverage
        self.cpuPeak = cpuPeak
        self.memoryMB = memoryMB
    }
}

/// A group's seconds of a minute. The average is over the seconds it was read, not the whole minute.
public struct GroupMinute: Sendable {
    public private(set) var cpu: TimeInterval = 0
    public private(set) var seconds: TimeInterval = 0
    public private(set) var cpuPeak = 0.0
    public private(set) var footprint: UInt64 = 0

    public init() {}

    public mutating func add(_ usage: GroupUsage, over seconds: TimeInterval) {
        guard seconds > 0 else { return }
        cpu += usage.cpu
        self.seconds += seconds
        cpuPeak = max(cpuPeak, usage.cpu / seconds * 100)
        footprint = usage.footprint
    }

    /// Nil when the group was not read in the minute.
    public var figures: GroupFigures? {
        seconds > 0 ? GroupFigures(cpuAverage: cpu / seconds * 100, cpuPeak: cpuPeak, memoryMB: Double(footprint) / 1_048_576) : nil
    }
}
