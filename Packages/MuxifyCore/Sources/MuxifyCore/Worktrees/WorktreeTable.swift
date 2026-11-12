import Foundation

/// The Muxify Worktree records in the state database: the `worktrees` table, how a record maps to a row, and the
/// one-time import of the `worktrees/<id>.json` files an older Muxify wrote.
enum WorktreeTable {
    /// One row for each record, keyed by its id. `environment` is NULL for a Worktree on this machine. No two records
    /// share a path. `created_at` is ISO 8601 text, as the record files had it.
    static let migration = StateDatabase.Migration(
        """
        CREATE TABLE worktrees (
            id TEXT PRIMARY KEY NOT NULL,
            environment TEXT,
            repository TEXT NOT NULL,
            name TEXT NOT NULL,
            path TEXT NOT NULL UNIQUE,
            branch TEXT NOT NULL,
            base TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
        """
    )

    private static let columns = "id, environment, repository, name, path, branch, base, created_at"

    /// Every record, oldest first, or the one with `id`. A row whose `created_at` is not an ISO 8601 date, such as one
    /// changed by hand, is left out.
    static func records(_ connection: SQLiteConnection, id: String? = nil) throws -> [MuxifyWorktreeRecord] {
        let formatter = ISO8601DateFormatter()
        let read = { (row: SQLiteStatement) -> MuxifyWorktreeRecord? in
            guard let createdAt = row.text(7).flatMap(formatter.date(from:)) else { return nil }
            return MuxifyWorktreeRecord(id: row.text(0) ?? "", environment: row.text(1), repository: row.text(2) ?? "", name: row.text(3) ?? "",
                                        path: row.text(4) ?? "", branch: row.text(5) ?? "", base: row.text(6) ?? "", createdAt: createdAt)
        }
        let rows = if let id {
            try connection.query("SELECT \(columns) FROM worktrees WHERE id = ?", id, row: read)
        } else {
            try connection.query("SELECT \(columns) FROM worktrees", row: read)
        }
        return rows.compactMap { $0 }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Inserts the record, or updates the row with its id, in one transaction. A path that another record has throws
    /// `MuxifyWorktreeError.pathTaken`; the UNIQUE path backs that check.
    static func write(_ record: MuxifyWorktreeRecord, _ connection: SQLiteConnection) throws {
        try connection.transaction {
            let taken = try connection.query("SELECT id FROM worktrees WHERE path = ? AND id != ?", record.path, record.id) { $0.text(0) }
            guard taken.isEmpty else { throw MuxifyWorktreeError.pathTaken(record.path) }
            try connection.execute(
                """
                INSERT INTO worktrees (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET environment = excluded.environment, repository = excluded.repository,
                    name = excluded.name, path = excluded.path, branch = excluded.branch, base = excluded.base,
                    created_at = excluded.created_at
                """,
                record.id, record.environment, record.repository, record.name, record.path, record.branch, record.base,
                ISO8601DateFormatter().string(from: record.createdAt))
        }
    }

    // MARK: - The import

    /// Moves each `<id>.json` record file in the state folder's `worktrees` into the table and renames it to
    /// `<id>.json.migrated`. A file that is not a record, or whose id or path a row already has, stays where it is with
    /// a problem line that names it. The Worktrees' own folders there are never touched.
    static func importRecordFiles(_ connection: SQLiteConnection, _ paths: MuxifyPaths, report: (String) -> Void) throws {
        let folder = paths.worktrees
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in names.sorted() where (name as NSString).pathExtension == "json" {
            let file = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            let record: MuxifyWorktreeRecord
            do { record = try decoder.decode(MuxifyWorktreeRecord.self, from: Data(contentsOf: file)) } catch {
                report("\(file.path) is not a Muxify Worktree record, so Muxify did not import it and left it in place: \(error)")
                continue
            }
            let clash = try connection.query("SELECT id FROM worktrees WHERE id = ? OR path = ?", record.id, record.path) { $0.text(0) }
            guard clash.isEmpty else {
                report("\(file.path) repeats the id or the path of a Muxify Worktree record Muxify has, so Muxify did not import it and left it in place")
                continue
            }
            try write(record, connection)
            try StateDatabase.renameToMigrated(file)
        }
    }
}
