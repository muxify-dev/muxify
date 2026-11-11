import Foundation

/// One second of the app, as `BurstDetector` takes it.
public struct BurstSecond: Equatable, Sendable {
    /// The wall-clock time at the end of the second.
    public var end: Date
    /// Its length in seconds, about 1.
    public var length: TimeInterval
    /// The app's CPU over it, in % of one core.
    public var cpu: Double
    /// The main run loop's awake share of it, in %.
    public var mainBusy: Double
    /// The user's input during it.
    public var input: InputCounts

    public init(end: Date, length: TimeInterval = 1, cpu: Double, mainBusy: Double = 0, input: InputCounts = InputCounts()) {
        self.end = end
        self.length = length
        self.cpu = cpu
        self.mainBusy = mainBusy
        self.input = input
    }

    /// The second between two per-second readings of the app. Nil when `current` is no later than `previous`.
    public init?(from previous: MinuteAggregate.Reading, to current: MinuteAggregate.Reading, end: Date, input: InputCounts) {
        let length = current.uptime - previous.uptime
        guard length > 0 else { return nil }
        self.init(end: end, length: length, cpu: max(0, current.cpu - previous.cpu) / length * 100,
                  mainBusy: min(100, max(0, current.mainAwake - previous.mainAwake) / length * 100), input: input)
    }
}

/// The `burst` record: a Burst's start and length, the app's average and peak per-second CPU (% of one core), the
/// busiest second's main-thread share (%), the user's input over it, what was moving when it was found, the sample
/// files taken during it, and `open=true` when Diagnostics stopped or the app quit while it ran.
public struct BurstRecord: Equatable, Sendable {
    public var start: Date
    /// In seconds, from the start to the end of its last second at or over the threshold.
    public var length: TimeInterval
    public var cpuAverage: Double
    public var cpuPeak: Double
    public var mainBusyPeak: Double
    public var input: InputCounts
    public var moving: MovingState
    /// The sample file names, such as `burst-2026-11-11-170734.txt`; empty when the caps let none be taken.
    public var samples: [String]
    public var open: Bool

    public init(start: Date, length: TimeInterval, cpuAverage: Double, cpuPeak: Double, mainBusyPeak: Double,
                input: InputCounts = InputCounts(), moving: MovingState = MovingState(), samples: [String] = [], open: Bool = false) {
        self.start = start
        self.length = length
        self.cpuAverage = cpuAverage
        self.cpuPeak = cpuPeak
        self.mainBusyPeak = mainBusyPeak
        self.input = input
        self.moving = moving
        self.samples = samples
        self.open = open
    }

    /// The local time of `start`, to the millisecond, as one word: `2026-11-11T17:07:34.120`.
    public static let startFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"

    public var record: DiagnosticsRecord {
        var fields: [(String, String)] = [
            ("start", Self.startFormatter().string(from: start)), ("length", Self.decimal(length)),
            ("cpu.avg", Self.decimal(cpuAverage)), ("cpu.peak", Self.decimal(cpuPeak)),
            ("main.busy.peak", Self.decimal(mainBusyPeak)), ("input", input.value),
        ]
        fields += moving.fields
        fields.append(("samples", samples.isEmpty ? "none" : DiagnosticsRecord.list(samples)))
        if open { fields.append(("open", "true")) }
        return DiagnosticsRecord(.burst, fields)
    }

    /// Nil unless `record` is a `burst` record with every field. A record with no `open` is a Burst that ended.
    public init?(_ record: DiagnosticsRecord) {
        guard record.kind == .burst, let start = record["start"].flatMap(Self.startFormatter().date(from:)),
              let length = record["length"].flatMap(Double.init), let average = record["cpu.avg"].flatMap(Double.init),
              let peak = record["cpu.peak"].flatMap(Double.init), let busy = record["main.busy.peak"].flatMap(Double.init),
              let input = record["input"].flatMap(InputCounts.init(value:)), let moving = MovingState(record),
              let samples = record.list("samples"), record["open"].map({ $0 == "true" }) ?? true
        else { return nil }
        self.init(start: start, length: length, cpuAverage: average, cpuPeak: peak, mainBusyPeak: busy, input: input,
                  moving: moving, samples: samples == ["none"] ? [] : samples, open: record["open"] == "true")
    }

    /// A new formatter of `startFormat` in local time.
    public static func startFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = startFormat
        return formatter
    }

    private static func decimal(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// Finds each Burst in the app's per-second CPU. A Burst starts when the app is at or over `cpuThreshold` for
/// `startSeconds` seconds in a row, and ends after `endSeconds` seconds in a row below it. It asks for a sample when
/// a Burst starts and every `resampleInterval` while it lasts, but never sooner than `sampleSpacing` after the last
/// Burst sample, nor more than `samplesPerDay` a local day. A sample the caps hold back is asked for again each
/// second while the Burst lasts. The caller takes the sample and reports it with `sampled`.
public struct BurstDetector: Sendable {
    public static let cpuThreshold = 30.0
    public static let startSeconds = 3
    public static let endSeconds = 3
    public static let resampleInterval: TimeInterval = 600
    public static let sampleSpacing: TimeInterval = 60
    public static let samplesPerDay = 40

    /// What one second did.
    public struct Step: Equatable, Sendable {
        /// A Burst started with this second.
        public var started = false
        /// A sample is due now. The caller reports a sample it took with `sampled`.
        public var wantsSample = false
        /// The Burst that ended with this second.
        public var ended: BurstRecord?
    }

    private struct Open: Sendable {
        var start: Date
        var length: TimeInterval = 0
        var cpuSeconds = 0.0
        var cpuPeak = 0.0
        var mainBusyPeak = 0.0
        var input = InputCounts()
        var moving = MovingState()
        var samples: [String] = []
        var lastSample: Date?

        mutating func add(_ second: BurstSecond) {
            length += second.length
            cpuSeconds += second.cpu * second.length
            cpuPeak = max(cpuPeak, second.cpu)
            mainBusyPeak = max(mainBusyPeak, second.mainBusy)
            input += second.input
        }

        func record(open: Bool) -> BurstRecord {
            BurstRecord(start: start, length: length, cpuAverage: length > 0 ? cpuSeconds / length : 0, cpuPeak: cpuPeak,
                        mainBusyPeak: mainBusyPeak, input: input, moving: moving, samples: samples, open: open)
        }
    }

    private let calendar: Calendar
    /// The seconds in a row at or over the threshold, before a Burst starts.
    private var hot: [BurstSecond] = []
    /// The seconds in a row below the threshold, while a Burst runs.
    private var cold: [BurstSecond] = []
    private var burst: Open?
    private var now: Date?
    private var lastSample: Date?
    private var sampleDay: Date?
    private var samplesThatDay = 0

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public var isOpen: Bool { burst != nil }

    public mutating func add(_ second: BurstSecond) -> Step {
        now = second.end
        var step = Step()
        let isHot = second.cpu >= Self.cpuThreshold
        if var open = burst {
            if isHot {
                // A dip shorter than `endSeconds` is part of the Burst.
                for dip in cold { open.add(dip) }
                cold = []
                open.add(second)
                burst = open
            } else {
                cold.append(second)
                if cold.count >= Self.endSeconds {
                    step.ended = open.record(open: false)
                    burst = nil
                    cold = []
                }
            }
        } else if isHot {
            hot.append(second)
            if hot.count >= Self.startSeconds {
                var open = Open(start: hot[0].end.addingTimeInterval(-hot[0].length))
                for earlier in hot { open.add(earlier) }
                hot = []
                burst = open
                step.started = true
            }
        } else {
            hot = []
        }
        step.wantsSample = wantsSample
        return step
    }

    /// The sample named `name` was taken for the Burst that runs now.
    public mutating func sampled(_ name: String) {
        guard burst != nil, let now else { return }
        burst?.samples.append(name)
        burst?.lastSample = now
        samplesThatDay = samples(on: now) + 1
        sampleDay = now
        lastSample = now
    }

    /// What was moving when the Burst that runs now started.
    public mutating func setMoving(_ moving: MovingState) {
        burst?.moving = moving
    }

    /// The Burst that runs now, as an `open` record, for when Diagnostics stops or the app quits; nil when none runs.
    /// The detector then starts again from no seconds.
    public mutating func close() -> BurstRecord? {
        defer {
            hot = []
            cold = []
            burst = nil
        }
        return burst?.record(open: true)
    }

    private var wantsSample: Bool {
        guard let burst, cold.isEmpty, let now else { return false }
        if let last = burst.lastSample, now.timeIntervalSince(last) < Self.resampleInterval { return false }
        if let lastSample, now.timeIntervalSince(lastSample) < Self.sampleSpacing { return false }
        return samples(on: now) < Self.samplesPerDay
    }

    private func samples(on date: Date) -> Int {
        guard let sampleDay, calendar.isDate(sampleDay, inSameDayAs: date) else { return 0 }
        return samplesThatDay
    }
}
