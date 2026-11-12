#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// An advisory `flock` on an empty file that every process opens by name. The kernel keeps the lock on the open
/// file, never on disk, so a process that exits or crashes releases it, and the file is never written or removed.
/// Each `withLock` opens the file again: two holders in one process exclude each other as two processes do.
enum FileLock {
    enum Mode { case shared, exclusive }

    /// The order a thread takes the locks in. Two threads that each held one and waited for the other would
    /// wait for ever, so a thread never takes a lock of a lower rank than one it holds. The edit lock is the one lock
    /// left, so a thread never takes it twice.
    enum Rank: Int {
        case edit = 1
    }

    struct Busy: Error, CustomStringConvertible {
        let path: String
        var description: String { "Another Muxify process holds \((path as NSString).lastPathComponent) for too long." }
    }

    /// Runs `body` while it holds the lock. It retries with a backoff from 5 to 50 ms and throws `Busy` after
    /// `timeout`, so a stuck holder cannot hang the main thread. A thread never takes a lock it already holds:
    /// its second open would wait on its first for ever.
    static func withLock<T>(_ url: URL, _ mode: Mode, rank: Rank, timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        precondition(held.allSatisfy { $0 < rank.rawValue }, "\(url.lastPathComponent) is taken inside a lock of the same or a later rank")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let operation = (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB
        let deadline = Date().addingTimeInterval(timeout)
        var delay: useconds_t = 5_000
        while flock(descriptor, operation) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard Date() < deadline else { throw Busy(path: url.path) }
            usleep(delay)
            delay = min(delay * 2, 50_000)
        }
        held.append(rank.rawValue)
        defer { held.removeLast() }
        return try body()
    }

    /// The ranks of the locks the current thread holds, innermost last.
    private static var held: [Int] {
        get { Thread.current.threadDictionary[heldKey] as? [Int] ?? [] }
        set { Thread.current.threadDictionary[heldKey] = newValue }
    }

    private static let heldKey = "dev.muxify.FileLock.held"
}
