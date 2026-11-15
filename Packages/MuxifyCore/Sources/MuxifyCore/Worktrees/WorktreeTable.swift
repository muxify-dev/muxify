import Foundation

/// The Muxify Worktree records in the state database: the `worktrees` table, how a record maps to a row, and the
/// one-time import of the `worktrees/<id>.json` files an older Muxify wrote.
enum WorktreeTable {
    /// One row for each record, keyed by its id. `environment` is NULL for a Worktree on this machine; set, the row is
    /// an older Muxify's record of that Remote Environment's Worktree, waiting to move to its Host (ADR 0090), and no
    /// new row sets it. The schema only grows, so the column stays. No two records share a path. `created_at` is
    /// ISO 8601 text, as the record files had it.
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

    /// Every record of this machine, oldest first, or the one with `id`; with `waitingFor`, the rows waiting to move
    /// to that Environment's Host instead. A row whose `created_at` is not an ISO 8601 date, such as one changed by
    /// hand, is left out.
    static func records(_ connection: SQLiteConnection, id: String? = nil, waitingFor environment: String? = nil) throws -> [MuxifyWorktreeRecord] {
        let formatter = ISO8601DateFormatter()
        let read = { (row: SQLiteStatement) -> MuxifyWorktreeRecord? in
            guard let createdAt = row.text(7).flatMap(formatter.date(from:)) else { return nil }
            return MuxifyWorktreeRecord(id: row.text(0) ?? "", repository: row.text(2) ?? "", name: row.text(3) ?? "",
                                        path: row.text(4) ?? "", branch: row.text(5) ?? "", base: row.text(6) ?? "", createdAt: createdAt)
        }
        let rows = if let environment {
            try connection.query("SELECT \(columns) FROM worktrees WHERE environment = ?", environment, row: read)
        } else if let id {
            try connection.query("SELECT \(columns) FROM worktrees WHERE id = ? AND environment IS NULL", id, row: read)
        } else {
            try connection.query("SELECT \(columns) FROM worktrees WHERE environment IS NULL", row: read)
        }
        return rows.compactMap { $0 }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Inserts the record, or updates the row with its id, in one transaction. A path that another record has throws
    /// `MuxifyWorktreeError.pathTaken`; the UNIQUE path backs that check. Only the import of an older Muxify's record
    /// file passes `environment`, for a row that waits to move to that Environment's Host.
    static func write(_ record: MuxifyWorktreeRecord, environment: String? = nil, _ connection: SQLiteConnection) throws {
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
                record.id, environment, record.repository, record.name, record.path, record.branch, record.base,
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
            let environment: String?
            do {
                let data = try Data(contentsOf: file)
                record = try decoder.decode(MuxifyWorktreeRecord.self, from: data)
                environment = try decoder.decode(RecordFileEnvironment.self, from: data).environment
            } catch {
                report("\(file.path) is not a Muxify Worktree record, so Muxify did not import it and left it in place: \(error)")
                continue
            }
            let clash = try connection.query("SELECT id FROM worktrees WHERE id = ? OR path = ?", record.id, record.path) { $0.text(0) }
            guard clash.isEmpty else {
                report("\(file.path) repeats the id or the path of a Muxify Worktree record Muxify has, so Muxify did not import it and left it in place")
                continue
            }
            try write(record, environment: environment, connection)
            try StateDatabase.renameToMigrated(file)
        }
    }

    /// An old record file's `environment`: set for a Remote Environment's Worktree, whose row then waits to move.
    private struct RecordFileEnvironment: Decodable {
        let environment: String?
    }

    // MARK: - Adopting the rows of the Mac

    /// Writes each row as a record of this machine, in one transaction, as `importRecordFiles` writes a file's: a row
    /// whose id or path a record has already is skipped with the reason.
    static func adopt(_ rows: [MuxifyWorktreeRecord], _ connection: SQLiteConnection) throws -> [AdoptedWorktree] {
        try connection.transaction {
            try rows.map { row in
                if try !connection.query("SELECT id FROM worktrees WHERE id = ?", row.id, row: { $0.text(0) }).isEmpty {
                    return AdoptedWorktree(id: row.id, skipped: "a Muxify Worktree record with the id \(row.id) is on the Host already")
                }
                if try !connection.query("SELECT id FROM worktrees WHERE path = ?", row.path, row: { $0.text(0) }).isEmpty {
                    return AdoptedWorktree(id: row.id, skipped: "a Muxify Worktree record at \(row.path) is on the Host already")
                }
                try write(row, connection)
                return AdoptedWorktree(id: row.id)
            }
        }
    }
}
