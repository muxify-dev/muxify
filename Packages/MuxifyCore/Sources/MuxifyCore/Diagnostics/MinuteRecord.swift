import Foundation

/// What the user did, as counts only: never a key code, a character, text, a title or a URL.
public struct InputCounts: Equatable, Sendable {
    public var keys = 0
    public var clicks = 0
    public var scrolls = 0
    public var sidebarSwitches = 0
    public var paletteOpens = 0

    public init(keys: Int = 0, clicks: Int = 0, scrolls: Int = 0, sidebarSwitches: Int = 0, paletteOpens: Int = 0) {
        self.keys = keys
        self.clicks = clicks
        self.scrolls = scrolls
        self.sidebarSwitches = sidebarSwitches
        self.paletteOpens = paletteOpens
    }

    public var isIdle: Bool { self == InputCounts() }

    public static func += (counts: inout InputCounts, more: InputCounts) {
        counts.keys += more.keys
        counts.clicks += more.clicks
        counts.scrolls += more.scrolls
        counts.sidebarSwitches += more.sidebarSwitches
        counts.paletteOpens += more.paletteOpens
    }

    private static let names = ["keys", "clicks", "scrolls", "sidebar_switches", "palette_opens"]
    private var counts: [Int] { [keys, clicks, scrolls, sidebarSwitches, paletteOpens] }

    /// `idle`, or `keys:N,clicks:N,scrolls:N,sidebar_switches:N,palette_opens:N`.
    public var value: String {
        isIdle ? "idle" : DiagnosticsRecord.pairs(zip(Self.names, counts.map(String.init)).map { ($0, $1) })
    }

    public init?(value: String) {
        if value == "idle" { self.init(); return }
        var counts: [String: Int] = [:]
        for pair in DiagnosticsRecord.pairs(in: value) ?? [] {
            guard Self.names.contains(pair.name), counts[pair.name] == nil, let count = Int(pair.value) else { return nil }
            counts[pair.name] = count
        }
        guard counts.count == Self.names.count else { return nil }
        let count = { (name: String) in counts[name] ?? 0 }
        self.init(keys: count("keys"), clicks: count("clicks"), scrolls: count("scrolls"),
                  sidebarSwitches: count("sidebar_switches"), paletteOpens: count("palette_opens"))
    }
}

/// The App Window: visible or occluded, active or inactive.
public struct AppWindowState: Equatable, Sendable {
    public var visible: Bool
    public var active: Bool

    public init(visible: Bool, active: Bool) {
        self.visible = visible
        self.active = active
    }

    /// `visible,active`, `occluded,inactive` and so on.
    public var value: String {
        DiagnosticsRecord.list([visible ? "visible" : "occluded", active ? "active" : "inactive"])
    }

    public init?(value: String) {
        let words = value.split(separator: ",").map(String.init)
        guard words.count == 2, ["visible", "occluded"].contains(words[0]), ["active", "inactive"].contains(words[1])
        else { return nil }
        self.init(visible: words[0] == "visible", active: words[1] == "active")
    }
}

/// What was moving on screen, read on the main thread at the end of a minute: the App Window, the Working marks
/// shown in the Active Environment and whether they move, the Sidebar mode and the counts it shows.
public struct MovingState: Equatable, Sendable {
    /// Nil when there is no App Window.
    public var window: AppWindowState?
    public var workingMarks = 0
    /// `ui.pulse` is on and Reduce Motion is off.
    public var marksMove = false
    /// Nil when there is no App Window.
    public var sidebar: SidebarMode?
    public var topicCards = 0
    public var sessionRows = 0

    public init(window: AppWindowState? = nil, workingMarks: Int = 0, marksMove: Bool = false, sidebar: SidebarMode? = nil,
                topicCards: Int = 0, sessionRows: Int = 0) {
        self.window = window
        self.workingMarks = workingMarks
        self.marksMove = marksMove
        self.sidebar = sidebar
        self.topicCards = topicCards
        self.sessionRows = sessionRows
    }

    public var fields: [(String, String)] {
        [("window", window?.value ?? "none"), ("working_marks", String(workingMarks)), ("marks_move", String(marksMove)),
         ("sidebar", sidebar.map(Self.word) ?? "none"), ("topic_cards", String(topicCards)), ("session_rows", String(sessionRows))]
    }

    /// The moving state in any record that has its fields, a `burst` as well as a `minute`.
    public init?(_ record: DiagnosticsRecord) {
        guard let window = record["window"], let marks = record["working_marks"].flatMap(Int.init),
              let moves = record["marks_move"].flatMap(Bool.init), let sidebar = record["sidebar"],
              let cards = record["topic_cards"].flatMap(Int.init), let rows = record["session_rows"].flatMap(Int.init)
        else { return nil }
        let windowState = window == "none" ? nil : AppWindowState(value: window)
        let mode = sidebar == "none" ? nil : [SidebarMode.topics, .sessions].first { Self.word($0) == sidebar }
        guard (window == "none") == (windowState == nil), (sidebar == "none") == (mode == nil) else { return nil }
        self.init(window: windowState, workingMarks: marks, marksMove: moves, sidebar: mode, topicCards: cards, sessionRows: rows)
    }

    private static func word(_ mode: SidebarMode) -> String { mode.rawValue.lowercased() }
}

/// The `minute` record: the app's CPU (average and peak per-second, in % of one core), the main thread's busy
/// share (% of the minute), its memory (phys footprint, MB), the same CPU and memory figures for each process group
/// that could be read, the app's threads and open files, the user's input, the counted SwiftUI bodies that ran and
/// what was moving.
public struct MinuteRecord: Equatable, Sendable {
    public var cpuAverage: Double
    public var cpuPeak: Double
    public var mainBusy: Double
    public var memoryMB: Double
    /// Only the groups that could be read: a group left out is not a zero.
    public var groups: [ProcessGroup: GroupFigures]
    public var threads: Int
    public var openFiles: Int
    public var input: InputCounts
    public var bodies: BodyCounts
    public var moving: MovingState

    public init(cpuAverage: Double, cpuPeak: Double, mainBusy: Double, memoryMB: Double, groups: [ProcessGroup: GroupFigures] = [:],
                threads: Int, openFiles: Int, input: InputCounts, bodies: BodyCounts = BodyCounts(), moving: MovingState) {
        self.cpuAverage = cpuAverage
        self.cpuPeak = cpuPeak
        self.mainBusy = mainBusy
        self.memoryMB = memoryMB
        self.groups = groups
        self.threads = threads
        self.openFiles = openFiles
        self.input = input
        self.bodies = bodies
        self.moving = moving
    }

    public var record: DiagnosticsRecord {
        var fields: [(String, String)] = [
            ("cpu.app.avg", DiagnosticsRecord.decimal(cpuAverage)), ("cpu.app.peak", DiagnosticsRecord.decimal(cpuPeak)),
            ("main.busy", DiagnosticsRecord.decimal(mainBusy)), ("mem.app", Self.megabytes(memoryMB)),
        ]
        for group in ProcessGroup.allCases {
            guard let figures = groups[group] else { continue }
            fields += [("cpu.\(group.rawValue).avg", DiagnosticsRecord.decimal(figures.cpuAverage)),
                       ("cpu.\(group.rawValue).peak", DiagnosticsRecord.decimal(figures.cpuPeak)),
                       ("mem.\(group.rawValue)", Self.megabytes(figures.memoryMB))]
        }
        fields += [("threads", String(threads)), ("open_files", String(openFiles)), ("input", input.value), ("bodies", bodies.value)]
        return DiagnosticsRecord(.minute, fields + moving.fields)
    }

    /// Nil unless `record` is a `minute` record with every field.
    public init?(_ record: DiagnosticsRecord) {
        guard record.kind == .minute,
              let average = record["cpu.app.avg"].flatMap(Double.init), let peak = record["cpu.app.peak"].flatMap(Double.init),
              let busy = record["main.busy"].flatMap(Double.init), let memory = record["mem.app"].flatMap(Double.init),
              let threads = record["threads"].flatMap(Int.init), let files = record["open_files"].flatMap(Int.init),
              let input = record["input"].flatMap(InputCounts.init(value:)), let bodies = record["bodies"].flatMap(BodyCounts.init(value:)),
              let moving = MovingState(record)
        else { return nil }
        var groups: [ProcessGroup: GroupFigures] = [:]
        for group in ProcessGroup.allCases {
            let values = ["cpu.\(group.rawValue).avg", "cpu.\(group.rawValue).peak", "mem.\(group.rawValue)"].map { record[$0] }
            guard values.contains(where: { $0 != nil }) else { continue }
            let numbers = values.compactMap { $0.flatMap(Double.init) }
            // Part of a group, or a figure that is not a number.
            guard numbers.count == 3 else { return nil }
            groups[group] = GroupFigures(cpuAverage: numbers[0], cpuPeak: numbers[1], memoryMB: numbers[2])
        }
        self.init(cpuAverage: average, cpuPeak: peak, mainBusy: busy, memoryMB: memory, groups: groups, threads: threads,
                  openFiles: files, input: input, bodies: bodies, moving: moving)
    }

    private static func megabytes(_ value: Double) -> String { String(format: "%.0f", value) }
}

/// One minute of per-second readings of the app: the CPU it used and the main run loop's awake time, both
/// running totals in seconds, against the system uptime, and each process group's CPU since the last reading.
public struct MinuteAggregate: Sendable {
    public struct Reading: Equatable, Sendable {
        public var uptime: TimeInterval
        public var cpu: TimeInterval
        public var mainAwake: TimeInterval
        /// The groups read this second; `ProcessGroupsMeter` makes them.
        public var groups: [ProcessGroup: GroupUsage]

        public init(uptime: TimeInterval, cpu: TimeInterval, mainAwake: TimeInterval, groups: [ProcessGroup: GroupUsage] = [:]) {
            self.uptime = uptime
            self.cpu = cpu
            self.mainAwake = mainAwake
            self.groups = groups
        }
    }

    public let start: Reading
    public private(set) var last: Reading
    /// The highest per-second CPU so far, in % of one core.
    public private(set) var cpuPeak = 0.0
    public private(set) var groups: [ProcessGroup: GroupMinute] = [:]

    public init(start: Reading) {
        self.start = start
        last = start
    }

    /// The length of the minute so far, in seconds.
    public var elapsed: TimeInterval { last.uptime - start.uptime }

    /// Takes the next reading. A reading no later than the last is left out.
    public mutating func add(_ reading: Reading) {
        let seconds = reading.uptime - last.uptime
        guard seconds > 0 else { return }
        cpuPeak = max(cpuPeak, (reading.cpu - last.cpu) / seconds * 100)
        for (group, usage) in reading.groups { groups[group, default: GroupMinute()].add(usage, over: seconds) }
        last = reading
    }

    /// The CPU over the whole minute, in % of one core.
    public var cpuAverage: Double {
        elapsed > 0 ? (last.cpu - start.cpu) / elapsed * 100 : 0
    }

    /// The main run loop's awake share of the minute, in %.
    public var mainBusy: Double {
        elapsed > 0 ? min(100, (last.mainAwake - start.mainAwake) / elapsed * 100) : 0
    }

    public func record(memoryMB: Double, threads: Int, openFiles: Int, input: InputCounts, bodies: BodyCounts = BodyCounts(),
                       moving: MovingState) -> MinuteRecord {
        MinuteRecord(cpuAverage: cpuAverage, cpuPeak: cpuPeak, mainBusy: mainBusy, memoryMB: memoryMB,
                     groups: groups.compactMapValues(\.figures), threads: threads, openFiles: openFiles, input: input,
                     bodies: bodies, moving: moving)
    }
}
