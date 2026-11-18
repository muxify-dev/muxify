#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
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

/// The answers of `muxify session-paths` and of the Host Server's ranked `session_paths`: from the cache, then
/// refreshed after the answer.
extension SessionPathCache {
    /// The SessionPaths of the Config's `sessions.paths` from this cache, and whether the cache had them. Without them
    /// it finds the SessionPaths and saves them, so only the first answer on a machine waits for the discovery.
    public func sessionPaths(of config: Config) -> (sessionPaths: [SessionPath], fromCache: Bool) {
        let cached = config.sessionRoots.isEmpty ? nil : output(for: SessionPathDiscovery.arguments(for: config.sessionRoots))
        return (config.sessionPaths(inDiscovery: cached ?? discover(config)), cached != nil)
    }

    /// Finds every SessionPath of the Config and saves the output here. Nil when the Config has no `sessions.paths`
    /// or the discovery fails, which saves nothing.
    @discardableResult
    public func discover(_ config: Config) -> String? {
        guard !config.sessionRoots.isEmpty, let output = SessionPathDiscovery.output(for: config.sessionRoots) else { return nil }
        save(output, for: SessionPathDiscovery.arguments(for: config.sessionRoots))
        return output
    }

    /// Finds the SessionPaths again and saves them, after an answer from the cache. One refresh at a time for this
    /// file: a second one that starts meanwhile has nothing to add, so it ends at once.
    public func refresh(_ config: Config) {
        guard let lock = RefreshLock(file.appendingPathExtension("lock")) else { return }
        defer { lock.unlock() }
        discover(config)
    }
}

extension Config {
    /// The SessionPaths that a discovery's output names for this Config's roots and aliases; none for nil.
    public func sessionPaths(inDiscovery output: String?) -> [SessionPath] {
        output.map { SessionPathDiscovery.sessionPaths(in: $0, roots: sessionRoots, aliases: sessionAliases) } ?? []
    }
}

/// An exclusive lock on a file, held until `unlock` or the end of the process.
private struct RefreshLock {
    private let descriptor: Int32

    /// Nil when another process holds the lock, or the lock file cannot be made.
    init?(_ file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    func unlock() { close(descriptor) }
}
