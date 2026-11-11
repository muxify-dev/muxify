import Foundation
import MuxifyCore

/// `muxify diagnostics summary`: a digest of one day file of the Diagnostics log, read straight from the folder, with
/// one trend line for each day file there. It needs no running app and changes nothing.
struct DiagnosticsSummaryInvocation: Equatable {
    /// The local day, `yyyy-MM-dd`.
    var date: String
    var folder: URL

    static func defaultFolder(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/Muxify")
    }

    static func fileName(for date: String) -> String { "muxify-\(date).log" }

    /// The day of `--date`, `yyyy-MM-dd`; nil for any other word, or a date that does not exist.
    static func day(_ word: String) -> String? {
        guard word.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = dayFormatter().date(from: word), dayFormatter().string(from: date) == word else { return nil }
        return word
    }

    static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    func run() throws {
        print(try text(), terminator: "")
    }

    /// The whole summary. A day with no file is an error that names the folder.
    func text() throws -> String {
        let name = Self.fileName(for: date)
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) else {
            throw CLIError("no Diagnostics log for \(date) in \(folder.path): there is no \(name)")
        }
        let day = DiagnosticsDay(String(decoding: data, as: UTF8.self))
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.range(of: #"^muxify-\d{4}-\d{2}-\d{2}\.log$"#, options: .regularExpression) != nil }
            .sorted()
        let trend = names.map { file -> (String, DiagnosticsDay) in
            let date = String(file.dropFirst("muxify-".count).dropLast(".log".count))
            if file == name { return (date, day) }
            let data = FileManager.default.contents(atPath: folder.appendingPathComponent(file).path) ?? Data()
            return (date, DiagnosticsDay(String(decoding: data, as: UTF8.self)))
        }
        return DiagnosticsSummary(date: date, day: day, trend: trend).text
    }
}

/// What one day file of the Diagnostics log holds, read through `DiagnosticsRecord`. A line it does not know, a
/// free-text line it has no use for, or a record with a field missing is skipped.
struct DiagnosticsDay {
    struct Minute {
        let date: Date
        let record: MinuteRecord
    }

    struct Freeze {
        let date: Date
        let length: TimeInterval
        /// The sample file taken during it, if any.
        var sample: String?
    }

    /// A sample's three `digest` records, folded into one.
    struct Digest {
        var samples: String?
        var busy: String?
        var libraries: [(name: String, value: String)] = []
        var symbols: [(name: String, value: String)] = []
        var frames: [(name: String, value: String)] = []
    }

    /// An event line that can explain missing minutes.
    struct Stop {
        let date: Date
        let label: String
    }

    private(set) var firstRecord: Date?
    private(set) var lastRecord: Date?
    private(set) var minutes: [Minute] = []
    private(set) var bursts: [BurstRecord] = []
    private(set) var freezes: [Freeze] = []
    private(set) var digests: [String: Digest] = [:]
    private(set) var stops: [Stop] = []
    /// The count of each kind of error, and the kinds in the order first seen.
    private(set) var errors: [String: Int] = [:]
    private(set) var errorKinds: [String] = []

    /// The event lines that can start a run of missing minutes, and their labels.
    static let stopLabels = ["system will sleep": "system sleep", "screens asleep": "screens asleep", "off": "Diagnostics off",
                             "quit": "quit"]
    /// The first words of the app's own event lines that are not errors.
    static let eventWords: Set<String> = ["launch", "on", "off", "quit", "app", "screen", "screens", "occlusion", "window", "entered",
                                          "exited", "active", "system", "user", "display", "animation", "freeze", "burst", "digest"]

    init(_ text: String) {
        let formatter = DiagnosticsRecord.formatter()
        var samplings: [(date: Date, name: String)] = []
        for line in text.split(separator: "\n") {
            guard let (date, text) = DiagnosticsRecord.timestamped(String(line), formatter: formatter) else { continue }
            if let record = DiagnosticsRecord(text: text) {
                firstRecord = firstRecord ?? date
                lastRecord = date
                switch record.kind {
                case .minute: if let minute = MinuteRecord(record) { minutes.append(Minute(date: date, record: minute)) }
                case .burst: if let burst = BurstRecord(record) { bursts.append(burst) }
                case .digest: if let sample = record["sample"] { digests[sample, default: Digest()].add(record) }
                case .freeze, .limit: break
                }
                continue
            }
            readEvent(text, at: date, samplings: &samplings)
        }
        minutes.sort { $0.date < $1.date }
        // A freeze's sample starts while the freeze runs; its line comes when the freeze ends.
        var used = Set<String>()
        for index in freezes.indices {
            let freeze = freezes[index]
            let start = freeze.date.addingTimeInterval(-freeze.length - 1)
            let sample = samplings.last { $0.date >= start && $0.date <= freeze.date && !used.contains($0.name) }
            if let sample { used.insert(sample.name) }
            freezes[index].sample = sample?.name
        }
    }

    private mutating func readEvent(_ text: String, at date: Date, samplings: inout [(date: Date, name: String)]) {
        if let label = Self.stopLabels[text] { stops.append(Stop(date: date, label: label)) }
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return }
        let word = first.hasSuffix(":") ? String(first.dropLast()) : first
        // A record cut short or with a bad field, or a record of a kind this reader does not know, is no event.
        if DiagnosticsRecord.Kind(rawValue: first) != nil { return }
        if words.count > 1, words.dropFirst().allSatisfy({ $0.contains("=") && !$0.hasPrefix("=") }) { return }
        if text.hasPrefix("freeze: main thread busy for "),
           let seconds = words.dropFirst(5).first.flatMap({ Double(String($0.prefix { $0.isNumber || $0 == "." })) }) {
            freezes.append(Freeze(date: date, length: seconds))
            return
        }
        if text.contains(": sampling the process for "), let name = words.last {
            if word == "freeze" { samplings.append((date, name)) }
            return
        }
        if let range = text.range(of: ": cannot run sample") { return error(String(text[..<range.upperBound])) }
        if word == "digest" { return error(words.dropLast().joined(separator: " ")) }
        if text.hasPrefix("system log: "), let count = words.dropFirst(2).first.flatMap(Int.init) {
            return error("system log: more kinds of error left out", count: count)
        }
        if text.hasPrefix("system log "), let colon = text.range(of: ": ") {
            var kind = String(text[colon.upperBound...])
            var count = 1
            if let times = kind.range(of: #" \((\d+) times\)$"#, options: .regularExpression) {
                count = Int(kind[times].dropFirst(2).prefix { $0.isNumber }) ?? 1
                kind.removeSubrange(times)
            }
            return error("system log: " + kind, count: count)
        }
        if text.hasPrefix("report since the last run: ") { return error("report since the last run") }
        guard !Self.eventWords.contains(word) else { return }
        // Muxify's own message: its kind is the part before its first colon.
        error(String(text.prefix { $0 != ":" }.prefix(120)))
    }

    private mutating func error(_ kind: String, count: Int = 1) {
        if errors[kind] == nil { errorKinds.append(kind) }
        errors[kind, default: 0] += count
    }

    /// The idle minutes, or the minutes with input.
    func minutes(idle: Bool) -> [MinuteRecord] {
        minutes.map(\.record).filter { $0.input.isIdle == idle }
    }

    /// The highest app memory of the day, in MB.
    var peakMemory: Double? { minutes.map(\.record.memoryMB).max() }
}

extension DiagnosticsDay.Digest {
    mutating func add(_ record: DiagnosticsRecord) {
        if let value = record["samples"] { samples = value }
        if let value = record["busy"] { busy = value }
        if let value = record.pairs("libraries") { libraries = value }
        if let value = record.pairs("symbols") { symbols = value }
        if let value = record.pairs("frames") { frames = value }
    }
}

/// The text `muxify diagnostics summary` prints, in sections that keep their order and their form.
struct DiagnosticsSummary {
    static let worstBursts = 10
    static let topSymbols = 5
    static let topFrames = 5

    let date: String
    let day: DiagnosticsDay
    /// Each day file in the folder, the oldest first.
    let trend: [(date: String, day: DiagnosticsDay)]

    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var text: String {
        (daySection + cpuSection + mainThreadSection + memorySection + burstSection + freezeSection + errorSection + trendSection)
            .joined(separator: "\n") + "\n"
    }

    // MARK: Sections

    private var daySection: [String] {
        var lines = ["Day \(date)"]
        if let first = day.firstRecord, let last = day.lastRecord {
            lines.append("  records \(clock.string(from: first)) – \(clock.string(from: last))")
        } else {
            lines.append("  records none")
        }
        lines.append("  minutes recorded \(day.minutes.count)")
        let gaps = self.gaps
        lines.append("  gaps \(gaps.count)")
        lines += gaps.map { "    \(clock.string(from: $0.from)) – \(clock.string(from: $0.to))  \($0.missing) min missing  \($0.label)" }
        return lines + [""]
    }

    private var cpuSection: [String] {
        var lines = ["CPU (minute average, % of one core)"]
        for (idle, title) in [(true, "idle"), (false, "with input")] {
            let minutes = day.minutes(idle: idle)
            lines.append("  \(title) (\(minutes.count) min)")
            for (name, values) in Self.groups(minutes) {
                lines.append("    " + Self.padded(name, 10) + Self.spread(values, max: true))
            }
        }
        return lines + [""]
    }

    private var mainThreadSection: [String] {
        ["Main thread (main.busy, % of the minute)"]
            + [(true, "idle"), (false, "with input")].map { idle, title in
                "  " + Self.padded(title, 12) + Self.spread(day.minutes(idle: idle).map(\.mainBusy), max: false)
            } + [""]
    }

    private var memorySection: [String] {
        var lines = ["Memory (MB)"]
        let minutes = day.minutes
        guard let first = minutes.first, let last = minutes.last else { return lines + ["  no minutes", ""] }
        let peak = minutes.max { $0.record.memoryMB < $1.record.memoryMB }!
        lines.append("  " + Self.padded("app", 10) + "start \(Self.megabytes(first.record.memoryMB))  end \(Self.megabytes(last.record.memoryMB))  "
            + "peak \(Self.megabytes(peak.record.memoryMB)) at \(clock.string(from: peak.date))")
        for group in ProcessGroup.allCases {
            let readings = minutes.compactMap { minute in minute.record.groups[group].map { (minute.date, $0.memoryMB) } }
            guard let top = readings.max(by: { $0.1 < $1.1 }) else { continue }
            lines.append("  " + Self.padded(group.rawValue, 10) + "peak \(Self.megabytes(top.1)) at \(clock.string(from: top.0))")
        }
        return lines + [""]
    }

    private var burstSection: [String] {
        var lines = ["Bursts \(day.bursts.count)"]
        let worst = day.bursts.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (lhs.element.cpuAverage * lhs.element.length, rhs.element.cpuAverage * rhs.element.length)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .prefix(Self.worstBursts).map(\.element)
        if !worst.isEmpty { lines.append("  worst \(worst.count) by cpu.avg × length") }
        for (index, burst) in worst.enumerated() {
            lines.append("  \(index + 1). \(clock.string(from: burst.start))  " + String(format: "%.1f s", burst.length)
                + "  cpu.avg \(Self.decimal(burst.cpuAverage))  cpu.peak \(Self.decimal(burst.cpuPeak))"
                + "  main.busy.peak \(Self.decimal(burst.mainBusyPeak))" + (burst.open ? "  open" : ""))
            lines.append("     input \(burst.input.value)")
            lines.append("     moving " + burst.moving.fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
            lines.append("     bodies \(burst.bodies.value)")
            if burst.samples.isEmpty { lines.append("     no sample") }
            for sample in burst.samples { lines += digestLines(sample) }
        }
        return lines + [""]
    }

    private var freezeSection: [String] {
        var lines = ["Freezes \(day.freezes.count)"]
        for (index, freeze) in day.freezes.enumerated() {
            lines.append("  \(index + 1). \(clock.string(from: freeze.date))  " + String(format: "%.1f s", freeze.length))
            if let sample = freeze.sample { lines += digestLines(sample) } else { lines.append("     no sample") }
        }
        return lines + [""]
    }

    private var errorSection: [String] {
        let kinds = day.errorKinds.enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (day.errors[lhs.element] ?? 0, day.errors[rhs.element] ?? 0)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
        return ["Errors \(kinds.count) kinds"] + kinds.map { "  " + Self.padded("\(day.errors[$0] ?? 0)", 6) + $0 } + [""]
    }

    private var trendSection: [String] {
        ["Trend (one line a day file)"] + trend.map { date, day in
            let idle = Self.median(day.minutes(idle: true).map(\.cpuAverage))
            let input = Self.median(day.minutes(idle: false).map(\.cpuAverage))
            return "  \(date)  idle p50 \(idle.map(Self.decimal) ?? "-")  with input p50 \(input.map(Self.decimal) ?? "-")"
                + "  bursts \(day.bursts.count)  freezes \(day.freezes.count)"
                + "  peak mem \(day.peakMemory.map { Self.megabytes($0) + " MB" } ?? "-")"
        }
    }

    // MARK: Parts

    struct Gap {
        let from: Date
        let to: Date
        let missing: Int
        let label: String
    }

    /// The runs of missing minutes between two `minute` records, each labelled with the event line nearest its start.
    var gaps: [Gap] {
        zip(day.minutes, day.minutes.dropFirst()).compactMap { before, after in
            let missing = Int((after.date.timeIntervalSince(before.date) / 60).rounded()) - 1
            guard missing > 0 else { return nil }
            let stop = day.stops.filter { $0.date >= before.date && $0.date <= after.date }
                .min { $0.date.timeIntervalSince(before.date) < $1.date.timeIntervalSince(before.date) }
            return Gap(from: before.date, to: after.date, missing: missing, label: stop?.label ?? "unknown")
        }
    }

    private func digestLines(_ sample: String) -> [String] {
        guard let digest = day.digests[sample] else { return ["     sample \(sample), not digested"] }
        func shares(_ items: some Sequence<(name: String, value: String)>) -> String {
            let text = items.map { "\($0.name) \($0.value)%" }.joined(separator: ", ")
            return text.isEmpty ? "none" : text
        }
        return [
            "     digest \(sample)  samples \(digest.samples ?? "-")  busy \(digest.busy.map { $0 + "%" } ?? "-")",
            "       libraries \(shares(digest.libraries))",
            "       symbols \(shares(digest.symbols.prefix(Self.topSymbols)))",
            "       frames \(shares(digest.frames.prefix(Self.topFrames)))",
        ]
    }

    /// The average CPU of each group present in `minutes`: the app first.
    private static func groups(_ minutes: [MinuteRecord]) -> [(String, [Double])] {
        guard !minutes.isEmpty else { return [] }
        return [("app", minutes.map(\.cpuAverage))] + ProcessGroup.allCases.compactMap { group in
            let values = minutes.compactMap { $0.groups[group]?.cpuAverage }
            return values.isEmpty ? nil : (group.rawValue, values)
        }
    }

    private static func spread(_ values: [Double], max: Bool) -> String {
        guard !values.isEmpty else { return "no minutes" }
        var text = "p50 \(decimal(percentile(values, 50)))  p90 \(decimal(percentile(values, 90)))"
        if max { text += "  max \(decimal(values.max()!))" }
        return text
    }

    /// The nearest-rank percentile.
    static func percentile(_ values: [Double], _ percent: Double) -> Double {
        let sorted = values.sorted()
        let rank = Int((percent / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count, Swift.max(1, rank)) - 1]
    }

    private static func median(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : percentile(values, 50)
    }

    private static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func decimal(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func megabytes(_ value: Double) -> String { String(format: "%.0f", value) }
}
