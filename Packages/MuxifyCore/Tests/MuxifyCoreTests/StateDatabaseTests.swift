import XCTest
@testable import MuxifyCore

final class StateDatabaseTests: XCTestCase {
    private var root: URL!
    private var paths: MuxifyPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muxify-state-" + UUID().uuidString)
        paths = MuxifyPaths(environment: ["XDG_STATE_HOME": root.path], home: "/nonexistent")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testOpeningAnEmptyStateFolderCreatesTheDatabaseInWALModeWithATenSecondBusyTimeout() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
        let connection = try StateDatabase.open(paths)
        XCTAssertEqual(paths.stateDatabase, root.appendingPathComponent("muxify/muxify.db"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stateDatabase.path))
        XCTAssertEqual(try connection.query("PRAGMA journal_mode") { $0.text(0) }, ["wal"])
        XCTAssertEqual(try connection.query("PRAGMA busy_timeout") { $0.int(0) }, [10_000])
        XCTAssertEqual(try StateDatabase.userVersion(connection), 0)
    }

    func testOpeningAppliesOnlyTheMigrationsPastTheStoredVersion() throws {
        var applied: [String] = []
        let first = StateDatabase.Migration { connection in
            applied.append("first")
            try connection.execute("CREATE TABLE first (id TEXT PRIMARY KEY)")
        }
        _ = try StateDatabase.open(paths, migrations: [first], imports: [])
        XCTAssertEqual(applied, ["first"])

        let second = StateDatabase.Migration { connection in
            applied.append("second")
            try connection.execute("ALTER TABLE first ADD COLUMN note TEXT")
        }
        let connection = try StateDatabase.open(paths, migrations: [first, second], imports: [])
        XCTAssertEqual(applied, ["first", "second"])
        XCTAssertEqual(try StateDatabase.userVersion(connection), 2)
        try connection.execute("INSERT INTO first (id, note) VALUES (?, ?)", "t", "kept")

        _ = try StateDatabase.open(paths, migrations: [first, second], imports: [])
        XCTAssertEqual(applied, ["first", "second"])
    }

    func testTheImportsRunAfterTheMigrationsOnEveryOpen() throws {
        let table = StateDatabase.Migration("CREATE TABLE moved (name TEXT)")
        var imports = 0
        let move: StateDatabase.Import = { connection, paths in
            imports += 1
            XCTAssertEqual(paths, self.paths)
            try connection.execute("INSERT INTO moved (name) VALUES (?)", "run \(imports)")
        }
        _ = try StateDatabase.open(paths, migrations: [table], imports: [move])
        let connection = try StateDatabase.open(paths, migrations: [table], imports: [move])
        XCTAssertEqual(try connection.query("SELECT name FROM moved ORDER BY rowid") { $0.text(0) }, ["run 1", "run 2"])
    }

    func testANewerDatabaseOpensAndCanBeReadAndWritten() throws {
        let table = StateDatabase.Migration("CREATE TABLE topics (id TEXT PRIMARY KEY, title TEXT)")
        let newer = StateDatabase.Migration("ALTER TABLE topics ADD COLUMN future TEXT")
        let written = try StateDatabase.open(paths, migrations: [table, newer], imports: [])
        try written.execute("INSERT INTO topics (id, title, future) VALUES ('a', 'A', 'kept')")

        let older = try StateDatabase.open(paths, migrations: [table], imports: [])
        XCTAssertEqual(try StateDatabase.userVersion(older), 2)
        try older.execute("INSERT INTO topics (id, title) VALUES (?, ?)", "b", "B")
        try older.execute("UPDATE topics SET title = ? WHERE id = ?", "Renamed", "a")
        XCTAssertEqual(try older.query("SELECT id, title FROM topics ORDER BY id") { "\($0.text(0)!) \($0.text(1)!)" },
                       ["a Renamed", "b B"])
        XCTAssertEqual(try written.query("SELECT future FROM topics WHERE id = 'a'") { $0.text(0) }, ["kept"])
    }

    func testATransactionCommitsOnReturnAndRollsBackOnAThrow() throws {
        let connection = try StateDatabase.open(paths, migrations: [StateDatabase.Migration("CREATE TABLE notes (text TEXT)")],
                                                imports: [])
        struct Refused: Error {}
        XCTAssertThrowsError(try connection.transaction {
            try connection.execute("INSERT INTO notes (text) VALUES (?)", "dropped")
            throw Refused()
        }) { XCTAssertTrue($0 is Refused) }
        try connection.transaction {
            try connection.execute("INSERT INTO notes (text) VALUES (?)", "kept")
            XCTAssertThrowsError(try connection.transaction {
                try connection.execute("INSERT INTO notes (text) VALUES (?)", "inner")
                throw Refused()
            })
        }
        let other = try StateDatabase.open(paths)
        XCTAssertEqual(try other.query("SELECT text FROM notes") { $0.text(0) }, ["kept"])
    }

    func testAWriteThatWaitsOutTheBusyTimeoutFailsAsStoreBusy() throws {
        let holder = try StateDatabase.open(paths)
        let waiter = try StateDatabase.open(paths, migrations: [], imports: [], busyTimeout: 0.2)
        var busy: Error?
        try holder.transaction {
            XCTAssertThrowsError(try waiter.transaction {}) { busy = $0 }
        }
        let error = try XCTUnwrap(busy as? SQLiteError)
        XCTAssertTrue(error.isBusy)
        let failure = EnvironmentService(paths: paths).failure(error, phase: .nothingChanged)
        XCTAssertEqual(failure.kind, .storeBusy)
        XCTAssertEqual(failure.message, "Another Muxify process holds muxify.db for too long.")
        XCTAssertNoThrow(try waiter.transaction {})
    }

    func testAFailingStatementGivesSQLitesMessage() throws {
        let connection = try StateDatabase.open(paths)
        XCTAssertThrowsError(try connection.execute("SELECT * FROM missing")) { error in
            let failure = EnvironmentService(paths: paths).failure(error, phase: .nothingChanged)
            XCTAssertEqual(failure.kind, .storeFailed)
            XCTAssertEqual(failure.message,
                           "Muxify could not read or write its state in \(paths.stateDatabase.path). SQLite: no such table: missing.")
        }
    }
}
