import Foundation

/// Muxify's state database, `muxify.db` in the state folder. Every store opens its connection here, so each one
/// has WAL, the busy timeout and the current schema before it reads.
public enum StateDatabase {
    /// One step of the schema. Its index in `migrations`, plus one, is the `user_version` it brings the file to.
    public struct Migration {
        let apply: (SQLiteConnection) throws -> Void

        public init(_ apply: @escaping (SQLiteConnection) throws -> Void) { self.apply = apply }

        /// A step that runs these statements, one after another.
        public init(_ statements: String...) {
            apply = { connection in try statements.forEach { try connection.execute($0) } }
        }
    }

    /// A one-time move of state from elsewhere, such as an old JSON file, into the database. Each open runs it
    /// after the migrations, in their transaction, so it must find for itself whether there is anything to move. It
    /// gives each problem line, such as an entry it could not move, to its third argument.
    public typealias Import = (SQLiteConnection, MuxifyPaths, (String) -> Void) throws -> Void

    /// The schema, in order. Append a step; never change or remove one, since `user_version` counts them.
    ///
    /// A step only adds: a table, or a column that is nullable or has a default. An older build opens a file that a
    /// newer one migrated, finds a `user_version` higher than it knows, applies nothing and works with the tables
    /// and columns it knows, so no step may rename, drop or tighten what an older build reads or writes.
    static let migrations: [Migration] = [
        TopicTable.migration,
    ]

    /// The one-time imports, run after `migrations` on every open.
    static let imports: [Import] = [
        TopicTable.importRecordsFile,
    ]

    /// Where the problem lines of an import go. The app sends them to its Diagnostics log; anywhere else they go to
    /// standard error, as `muxify: <line>`. A line goes there once in a process, though each open repeats it while
    /// the file it names stays in place.
    public static var reportProblem: @Sendable (String) -> Void {
        get { reporter.withLock { $0 } }
        set { reporter.withLock { $0 = newValue } }
    }

    private static let reporter = ProblemReporter { line in
        FileHandle.standardError.write(Data("muxify: \(line)\n".utf8))
    }

    /// How long a write waits for another connection's transaction before it fails with a busy error, which the
    /// service reports as `storeBusy`.
    public static let busyTimeout: TimeInterval = 10

    /// Opens `paths.stateDatabase`, creating the state folder and the file when they are missing, and brings the
    /// schema up to date.
    public static func open(_ paths: MuxifyPaths) throws -> SQLiteConnection {
        try open(paths, migrations: migrations, imports: imports)
    }

    /// `report` takes the problem lines of the imports; by default they go to `reportProblem`, each once.
    static func open(_ paths: MuxifyPaths, migrations: [Migration], imports: [Import],
                     busyTimeout: TimeInterval = StateDatabase.busyTimeout,
                     report: (String) -> Void = { StateDatabase.reporter.reportOnce($0) }) throws -> SQLiteConnection {
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let connection = try SQLiteConnection(path: paths.stateDatabase.path)
        // The timeout comes first, so that the switch to WAL also waits for a connection that is opening it.
        try connection.setBusyTimeout(busyTimeout)
        _ = try connection.query("PRAGMA journal_mode = WAL") { $0.text(0) }
        try connection.transaction {
            let stored = try userVersion(connection)
            if stored < migrations.count {
                for migration in migrations[stored...] { try migration.apply(connection) }
                try connection.execute("PRAGMA user_version = \(migrations.count)")
            }
            for run in imports { try run(connection, paths, report) }
        }
        return connection
    }

    static func userVersion(_ connection: SQLiteConnection) throws -> Int {
        try connection.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
    }
}

/// The one place the problem reporter lives, so the app can set it from any thread, with the lines it reported.
private final class ProblemReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var report: @Sendable (String) -> Void
    private var reported: Set<String> = []

    /// Gives the line to the reporter unless it had it before.
    func reportOnce(_ line: String) {
        lock.lock()
        let report = reported.insert(line).inserted ? report : nil
        lock.unlock()
        report?(line)
    }

    init(_ report: @escaping @Sendable (String) -> Void) { self.report = report }

    func withLock<T>(_ body: (inout @Sendable (String) -> Void) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&report)
    }
}
