#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// The name that a caller gives to one Host CLI write, so that a second send of the write changes nothing. It is a
/// UUID in lower case.
public struct RequestID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Nil when `text` is not a UUID.
    public init?(_ text: String) {
        guard let uuid = UUID(uuidString: text) else { return nil }
        rawValue = uuid.uuidString.lowercased()
    }

    public var description: String { rawValue }
}

/// A Request that the command line is about to run: its id, its verb and its arguments in one canonical text. Two
/// sends are the same Request only when all three are equal.
public struct PendingRequest: Equatable, Sendable {
    public let id: RequestID
    /// The words of the verb, such as `topic new`.
    public let verb: String
    /// JSON with sorted keys: the words after the verb, the caller Pane and the working directory.
    public let arguments: String

    public init(id: RequestID, verb: String, words: [String], callerPane: String?, workingDirectory: String) {
        self.id = id
        self.verb = verb
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = Canonical(words: words, pane: callerPane, directory: workingDirectory)
        arguments = String(decoding: (try? encoder.encode(canonical)) ?? Data(), as: UTF8.self)
    }

    private struct Canonical: Encodable {
        let words: [String]
        let pane: String?
        let directory: String
    }
}

/// What the command line printed for a Request, and its exit status. A second send prints the same bytes.
public struct RequestReply: Equatable, Sendable {
    public var stdout: String
    /// The error line, without the `muxify: ` that the command line puts before it.
    public var stderr: String?
    public var exitCode: Int32

    public init(stdout: String, stderr: String? = nil, exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// What the ledger knows about a Request id.
public enum RequestLookup: Equatable, Sendable {
    /// No row: the Request runs as a first send.
    case new
    /// A `done` row with the same verb and arguments.
    case replay(RequestReply)
    /// A `started` row with the same verb and arguments: the records changed, and the run did not finish.
    case resume
    /// The id has a row for another verb or other arguments. `verb` is the verb of that row.
    case mismatch(verb: String)
}

/// The `applied_requests` table of the state database: one row for each Request of the last 24 hours.
enum RequestTable {
    /// `state` is `started` or `done`. `stdout`, `stderr` and `exit_code` are NULL until the row is `done`.
    /// `created_at` is seconds since 1970.
    static let migration = StateDatabase.Migration(
        """
        CREATE TABLE applied_requests (
            id TEXT PRIMARY KEY NOT NULL,
            verb TEXT NOT NULL,
            arguments TEXT NOT NULL,
            state TEXT NOT NULL,
            stdout TEXT,
            stderr TEXT,
            exit_code INTEGER,
            created_at REAL NOT NULL
        )
        """
    )

    /// How long a row stays.
    static let lifetime: TimeInterval = 86400

    private enum State {
        case started
        case done(RequestReply)
    }

    static func lookup(_ request: PendingRequest, _ connection: SQLiteConnection) throws -> RequestLookup {
        let rows = try connection.query("SELECT verb, arguments, state, stdout, stderr, exit_code FROM applied_requests WHERE id = ?",
                                        request.id.rawValue) { row -> (verb: String, arguments: String, state: State) in
            let state: State = row.text(2) == "done"
                ? .done(RequestReply(stdout: row.text(3) ?? "", stderr: row.text(4), exitCode: Int32(row.int(5))))
                : .started
            return (row.text(0) ?? "", row.text(1) ?? "", state)
        }
        guard let row = rows.first else { return .new }
        guard row.verb == request.verb, row.arguments == request.arguments else { return .mismatch(verb: row.verb) }
        switch row.state {
        case .started: return .resume
        case .done(let reply): return .replay(reply)
        }
    }

    /// Call it in the transaction that writes the records, so the row is there exactly when the records changed.
    /// A row that the id has stays as it is.
    static func start(_ request: PendingRequest, now: Date, _ connection: SQLiteConnection) throws {
        try prune(now: now, connection)
        try connection.execute("INSERT OR IGNORE INTO applied_requests (id, verb, arguments, state, created_at) VALUES (?, ?, ?, 'started', ?)",
                               request.id.rawValue, request.verb, request.arguments, now.timeIntervalSince1970)
    }

    static func finish(_ request: PendingRequest, reply: RequestReply, now: Date, _ connection: SQLiteConnection) throws {
        try prune(now: now, connection)
        try connection.execute(
            """
            INSERT INTO applied_requests (id, verb, arguments, state, stdout, stderr, exit_code, created_at)
            VALUES (?, ?, ?, 'done', ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET state = 'done', stdout = excluded.stdout, stderr = excluded.stderr,
                                           exit_code = excluded.exit_code
            """,
            request.id.rawValue, request.verb, request.arguments, reply.stdout, reply.stderr, Int(reply.exitCode), now.timeIntervalSince1970)
    }

    private static func prune(now: Date, _ connection: SQLiteConnection) throws {
        try connection.execute("DELETE FROM applied_requests WHERE created_at < ?", now.timeIntervalSince1970 - lifetime)
    }
}

/// The record of the Requests that this Host applied, so that a second send of a Request gets the first answer.
/// `TopicStore` writes the `started` row with the records; the command line reads the row and writes the `done` row.
public struct RequestLedger: Sendable {
    public let paths: MuxifyPaths
    private let database: StateConnection

    public init(paths: MuxifyPaths) {
        self.paths = paths
        database = StateConnection(paths: paths)
    }

    public func lookup(_ request: PendingRequest) throws -> RequestLookup {
        try database.use(creating: false) { try RequestTable.lookup(request, $0) } ?? .new
    }

    /// Writes the Reply as the answer of the Request, and removes each row that is older than 24 hours.
    public func finish(_ request: PendingRequest, reply: RequestReply, now: Date = Date()) throws {
        try database.use(creating: true) { connection in
            try connection.transaction { try RequestTable.finish(request, reply: reply, now: now, connection) }
        }
    }

    /// Waits until no other process runs a Request with this id, then holds the id until `unlock`. Two sends of one
    /// Request can run at the same time; the second one waits here and then finds the row of the first.
    public func lock(_ id: RequestID, now: Date = Date()) throws -> RequestLock {
        let folder = paths.state.appendingPathComponent("requests", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        RequestLock.prune(folder, now: now)
        return try RequestLock(path: folder.appendingPathComponent(id.rawValue + ".lock").path)
    }
}

/// An exclusive `flock` on the lock file of one Request id. The lock ends at `unlock`, or when the process ends.
public final class RequestLock: @unchecked Sendable {
    private let descriptor: Int32

    init(path: String) throws {
        while true {
            let descriptor = open(path, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    let code = errno
                    close(descriptor)
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
            }
            // A prune can remove the file between the open and the lock. Then this lock is on a file that no other
            // process can open, so take the lock again on the file that the path names now.
            var held = stat(), named = stat()
            if fstat(descriptor, &held) == 0, stat(path, &named) == 0, held.st_ino == named.st_ino, held.st_dev == named.st_dev {
                self.descriptor = descriptor
                return
            }
            close(descriptor)
        }
    }

    public func unlock() {
        flock(descriptor, LOCK_UN)
    }

    deinit { close(descriptor) }

    /// Removes each lock file that is older than the ledger's rows and that no process holds.
    static func prune(_ folder: URL, now: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "lock" {
            guard let changed = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(changed) > RequestTable.lifetime else { continue }
            let descriptor = open(file.path, O_RDWR)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { unlink(file.path) }
            close(descriptor)
        }
    }
}

extension TopicFailure {
    /// The kinds of a refusal: the Host looked at the request and its own state, and said no. The answer is as final
    /// as a success, so the ledger keeps it. A kind that is not here can change when the same Request runs again,
    /// such as tmux that does not run or a database that is busy, so the ledger does not keep it. `source_unavailable`
    /// and `topic_empty` are not here, because a tmux server that does not run gives them too.
    static let refusalKinds: Set<Kind> = [
        .topicUnavailable, .topicMembershipChanged, .topicAmbiguous, .sourceHasNoTopic, .noTarget, .unsupported,
        .sessionPathUnavailable, .duplicateSession, .tagUndefined, .branchUnavailable, .branchCheckedOut, .chooseSession,
        .topicsUnavailable, .sessionNameInvalid, .panesChanged, .cardAtEnd, .sessionAtEnd, .cardHidden, .windowNotInSession,
        .cardNotInPlay, .cardNotBenched, .cardPinned, .cardGuest, .placeNotOpen, .cardCannotFill, .worktreeExists, .worktreeUnavailable,
        .worktreeAmbiguous, .worktreeInUse, .worktreeHasChanges, .worktreeSetupInvalid, .worktreeNameInvalid,
    ]

    /// True when the request changed nothing and the Host refused it, so a second send must get the same answer.
    public var isRefusal: Bool { phase == .nothingChanged && Self.refusalKinds.contains(kind) }
}
