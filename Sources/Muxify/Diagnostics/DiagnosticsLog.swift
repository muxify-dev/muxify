import Foundation

/// An append-only text file that any thread can write to. Once it passes `sizeLimit` it becomes `<name>.1.log`,
/// replacing the older one, so the log takes at most twice the limit.
final class DiagnosticsLog: @unchecked Sendable {
    let url: URL
    /// When the file was last written before this opening, or nil when it is new.
    let previousWrite: Date?
    private let sizeLimit: UInt64
    private let queue = DispatchQueue(label: "dev.muxify.diagnostics-log", qos: .utility)
    private var file: FileHandle?
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(folder: URL, name: String = "muxify", sizeLimit: UInt64 = 20 << 20) throws {
        url = folder.appendingPathComponent("\(name).log")
        self.sizeLimit = sizeLimit
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        previousWrite = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
        self.file = file
    }

    func write(_ text: String) {
        let date = Date()
        queue.async { [self] in
            guard let file else { return }
            try? file.write(contentsOf: Data("\(clock.string(from: date)) \(text)\n".utf8))
            if let size = try? file.offset(), size > sizeLimit { rotate() }
        }
    }

    /// Returns once every line written so far is in the file.
    func flush() {
        queue.sync {}
    }

    private func rotate() {
        try? file?.close()
        let older = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: older)
        try? FileManager.default.moveItem(at: url, to: older)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
    }
}
