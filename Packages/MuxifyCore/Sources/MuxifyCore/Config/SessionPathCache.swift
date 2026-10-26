import Foundation

/// The last output of `SessionPathDiscovery.script` on one Environment, in a file, so that the SessionPaths show at
/// once after a start while the script runs again (ADR 0050). The output depends only on the script's arguments,
/// so a record is valid only for the same arguments. Aliases and display depths apply when the output is parsed.
public struct SessionPathCache: Sendable {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    /// Nil when the file is missing or unreadable, or when it holds the output for other arguments.
    public func output(for arguments: [String]) -> String? {
        guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.arguments == arguments else { return nil }
        return record.output
    }

    /// Writes nothing when the file holds this output already. Each App Window writes its own Environment's file,
    /// and the write replaces the file in one step, so a reader gets the old record or the new one.
    public func save(_ output: String, for arguments: [String]) {
        guard self.output(for: arguments) != output,
              let data = try? JSONEncoder().encode(Record(arguments: arguments, output: output)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private struct Record: Codable {
        let arguments: [String]
        let output: String
    }
}
