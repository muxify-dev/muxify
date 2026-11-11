import Foundation
import MuxifyCore

/// The Diagnostics log: append-only text files that any thread can write to, one a local day,
/// `muxify-YYYY-MM-DD.log` by the date of each line. When a day's file opens, every Diagnostics log file last written
/// over `kept` ago is deleted, the older `muxify.log` and `muxify.1.log` too. Once a day's file passes `sizeLimit`,
/// it writes one `limit` line and from then on takes only the lines whose kind is in `keptPastLimit`.
final class DiagnosticsLog: @unchecked Sendable {
    /// The kinds of line a day's file still takes past its size limit.
    static let keptPastLimit: [DiagnosticsRecord.Kind] = [.minute, .burst, .freeze, .digest]

    let folder: URL
    /// When the newest Diagnostics log file was last written before this opening, or nil when there is none.
    let previousWrite: Date?
    private let sizeLimit: UInt64
    private let kept: TimeInterval
    private let now: () -> Date
    private let queue = DispatchQueue(label: "dev.muxify.diagnostics-log", qos: .utility)
    private var day: String?
    private var file: FileHandle?
    private var limited = false
    private let clock = DiagnosticsRecord.formatter()
    private let days = DiagnosticsLog.formatter("yyyy-MM-dd")

    init(folder: URL, sizeLimit: UInt64 = 50 << 20, kept: TimeInterval = 7 * 24 * 3600,
         now: @escaping () -> Date = Date.init) throws {
        self.folder = folder
        self.sizeLimit = sizeLimit
        self.kept = kept
        self.now = now
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        previousWrite = Self.logFiles(in: folder).compactMap(Self.modified).max()
        let date = now()
        try queue.sync { try open(days.string(from: date), at: date) }
    }

    /// The day's file that a line written at `date` goes to.
    func url(for date: Date) -> URL {
        folder.appendingPathComponent("muxify-\(days.string(from: date)).log")
    }

    func write(_ text: String) {
        let date = now()
        queue.async { [self] in
            let day = days.string(from: date)
            if day != self.day { try? open(day, at: date) }
            guard let file else { return }
            if limited, !Self.keptPastLimit.map(\.rawValue).contains(Self.kind(of: text)) { return }
            append(text, at: date, to: file)
            guard !limited, let size = try? file.offset(), size >= sizeLimit else { return }
            limited = true
            let limit = DiagnosticsRecord(.limit, [("size", String(sizeLimit)),
                                                   ("keeps", DiagnosticsRecord.list(Self.keptPastLimit.map(\.rawValue)))])
            append(limit.text, at: date, to: file)
        }
    }

    /// Returns once every line written so far is in the file.
    func flush() {
        queue.sync {}
    }

    /// The first word of a line, without its colon: `freeze` for "freeze: main thread busy for 1.2s".
    static func kind(of text: String) -> String {
        let word = text.prefix { $0 != " " }
        return String(word.hasSuffix(":") ? word.dropLast() : word)
    }

    private func append(_ text: String, at date: Date, to file: FileHandle) {
        try? file.write(contentsOf: Data("\(clock.string(from: date)) \(text)\n".utf8))
    }

    private func open(_ day: String, at date: Date) throws {
        try? file?.close()
        file = nil
        self.day = day
        let url = url(for: date)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: url)
        limited = try file.seekToEnd() >= sizeLimit
        self.file = file
        prune(before: date.addingTimeInterval(-kept), keeping: url)
    }

    private func prune(before cutoff: Date, keeping current: URL) {
        for old in Self.logFiles(in: folder) where old.lastPathComponent != current.lastPathComponent {
            if let modified = Self.modified(old), modified < cutoff { try? FileManager.default.removeItem(at: old) }
        }
    }

    /// The day files, and the `muxify.log` and `muxify.1.log` that came before them.
    private static func logFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { file in
            let name = file.lastPathComponent
            return name == "muxify.log" || name == "muxify.1.log"
                || name.wholeMatch(of: /muxify-\d{4}-\d{2}-\d{2}\.log/) != nil
        }
    }

    private static func modified(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
