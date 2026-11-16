import Foundation

/// The visit times in the state database: the `visits` table.
enum VisitTable {
    /// One row for each `VisitKey.stored` of a machine. `environment` is NULL for a visit to this machine's own
    /// Topics, Sessions and SessionPaths; set, it is the name of the Remote Environment whose App Window on this Mac
    /// recorded the visit. `visited_at` is seconds since 1970.
    static let migration = StateDatabase.Migration(
        """
        CREATE TABLE visits (
            environment TEXT,
            place TEXT NOT NULL,
            visited_at REAL NOT NULL
        )
        """,
        // A NULL is never equal to a NULL in a UNIQUE column, so the index is on the name with '' for this machine.
        "CREATE UNIQUE INDEX visits_place ON visits (IFNULL(environment, ''), place)"
    )

    /// A row whose `place` is no `VisitKey`, such as one a newer Muxify wrote, is left out.
    static func times(_ connection: SQLiteConnection, environment: String?) throws -> [VisitKey: Date] {
        let rows = try connection.query("SELECT place, visited_at FROM visits WHERE IFNULL(environment, '') = IFNULL(?, '')", environment) {
            ($0.text(0).flatMap(VisitKey.init(stored:)), Date(timeIntervalSince1970: $0.double(1)))
        }
        return Dictionary(rows.compactMap { key, date in key.map { ($0, date) } }, uniquingKeysWith: max)
    }

    /// Writes each time that is newer than the row's, then removes the machine's rows after its newest `capacity`.
    static func add(_ times: [VisitKey: Date], environment: String?, capacity: Int, _ connection: SQLiteConnection) throws {
        try connection.transaction {
            for (key, date) in times {
                try connection.execute(
                    """
                    INSERT INTO visits (environment, place, visited_at) VALUES (?, ?, ?)
                    ON CONFLICT (IFNULL(environment, ''), place) DO UPDATE SET visited_at = excluded.visited_at
                        WHERE excluded.visited_at > visits.visited_at
                    """,
                    environment, key.stored, date.timeIntervalSince1970)
            }
            try connection.execute(
                """
                DELETE FROM visits WHERE IFNULL(environment, '') = IFNULL(?, '') AND rowid NOT IN (
                    SELECT rowid FROM visits WHERE IFNULL(environment, '') = IFNULL(?, '') ORDER BY visited_at DESC LIMIT ?
                )
                """,
                environment, environment, capacity)
        }
    }
}

/// The visit times that the Mac app and the Host CLI share: the app ranks its lists by them, and the Host CLI
/// ranks `session-paths` by them and writes the visits of the phone. `environment` nil is this machine.
public struct VisitStore: Sendable {
    public let paths: MuxifyPaths
    private let database: StateConnection

    public init(paths: MuxifyPaths) {
        self.paths = paths
        database = StateConnection(paths: paths)
    }

    /// Without a state folder there is nothing to read, and the read creates nothing.
    public func times(environment: String? = nil) throws -> [VisitKey: Date] {
        try database.use(creating: false) { try VisitTable.times($0, environment: environment) } ?? [:]
    }

    /// Saves the visits. A key keeps its newer time, so a writer with an older time changes nothing.
    public func add(_ times: [VisitKey: Date], environment: String? = nil) throws {
        guard !times.isEmpty else { return }
        _ = try database.use(creating: true) { try VisitTable.add(times, environment: environment, capacity: VisitLog.capacity, $0) }
    }
}
