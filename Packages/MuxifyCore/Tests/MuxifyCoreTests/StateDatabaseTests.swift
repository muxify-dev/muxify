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
        XCTAssertEqual(try StateDatabase.userVersion(connection), StateDatabase.migrations.count)
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
        let move: StateDatabase.Import = { connection, paths, _ in
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

    // MARK: - The import of topics.json

    /// Opens the database as the app does, with the import's problem lines collected.
    private func open() throws -> (SQLiteConnection, [String]) {
        var problems: [String] = []
        let connection = try StateDatabase.open(paths, migrations: StateDatabase.migrations, imports: StateDatabase.imports,
                                                report: { problems.append($0) })
        return (connection, problems)
    }

    private var migratedFile: URL { paths.topicRecords.appendingPathExtension("migrated") }

    func testTheTopicsTableHoldsAColumnForEachFieldAndTheSlugIsNotUnique() throws {
        let (connection, _) = try open()
        let columns = try connection.query("SELECT name FROM pragma_table_info('topics') ORDER BY cid") { $0.text(0) ?? "" }
        XCTAssertEqual(columns, ["id"] + TopicTable.columns)
        XCTAssertEqual(try connection.query("SELECT name FROM pragma_table_info('open_places') ORDER BY cid") { $0.text(0) ?? "" },
                       ["id", "order"])
        try connection.execute("INSERT INTO topics (id, slug) VALUES ('a', 'same'), ('b', 'same')")
        XCTAssertEqual(try TopicStore(paths: paths).read().records.map(\.slug), ["same", "same"])
    }

    func testTheImportMovesTheValidRecordsAndOpenPlacesAndRenamesTheFile() throws {
        try paths.seedTopicRecordsFile(entries: [
            ##"{"id":"b","title":"B","order":1,"pinned":true,"tags":["Backend","#ops"],"note":"Bisect","snoozed_until":"never"}"##,
            #"{"id":"a","title":"A","order":-1.7976931348623157e+308,"session_order":"manual","unread":true,"guest":true,"settled_at":"2026-10-01T00:00:00Z","outcome":"Done","created_at":"2026-09-01T00:00:00Z","slug":"a","sessions":[{"id":"s","future":{"large":18446744073709551615}}]}"#,
        ], openPlaces: #"[{"id":"p2","order":2.5},{"id":"p1","order":0.5}]"#)
        let (_, problems) = try open()
        XCTAssertEqual(problems, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.topicRecords.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedFile.path), "the old file stays readable as topics.json.migrated")

        let contents = try TopicStore(paths: paths).read()
        XCTAssertEqual(contents.records.map(\.id), ["a", "b"])
        var a = TopicRecord(id: "a", title: "A", slug: "a")
        a.order = -.greatestFiniteMagnitude
        a.hasManualSessionOrder = true
        a.isUnread = true
        a.isGuest = true
        a.settledAt = "2026-10-01T00:00:00Z"
        a.outcome = "Done"
        a.createdAt = "2026-09-01T00:00:00Z"
        a.sessions = [.object(["id": .string("s"), "future": .object(["large": .unsignedInteger(UInt64.max)])])]
        var b = TopicRecord(id: "b", title: "B")
        b.order = 1
        b.isPinned = true
        b.tags = [Tag(name: "backend")!, Tag(name: "ops")!]
        b.note = "Bisect"
        XCTAssertEqual(contents.records, [a, b])
        XCTAssertEqual(contents.openPlaces, [OpenPlace(id: "p2", order: 2.5), OpenPlace(id: "p1", order: 0.5)])
        XCTAssertEqual(try paths.storedJSON("b", "tags"), .array([.string("backend"), .string("ops")]))
    }

    func testTheImportSkipsAnInvalidEntryAndARepeatedIDWithAProblemLineForEach() throws {
        try paths.seedTopicRecordsFile(entries: [
            #"{"id":"a","title":"A"}"#, #"{"id":"odd","title":7}"#, "42", #"{"id":"bad/id"}"#, #"{"id":"a","title":"Twin"}"#,
        ])
        let (_, problems) = try open()
        XCTAssertEqual(try TopicStore(paths: paths).read().records.map(\.title), ["A"], "the first entry with an id is the record")
        XCTAssertEqual(problems.count, 4, "\(problems)")
        let file = paths.topicRecords.path
        XCTAssertTrue(problems[0].hasPrefix("\(file): records[1] (id odd) is not a valid Topic record"), problems[0])
        XCTAssertTrue(problems[1].hasPrefix("\(file): records[2] is not a valid Topic record"), problems[1])
        XCTAssertTrue(problems[2].hasPrefix("\(file): records[3] (id bad/id) is not a valid Topic record"), problems[2])
        XCTAssertEqual(problems[3], "\(file): records[4] (id a) repeats the id of an earlier record, so Muxify did not import it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedFile.path), "the skipped entries stay readable there")
    }

    func testAFileThatIsNotARecordsFileStaysInPlaceAndNothingIsImported() throws {
        for text in [#"{"records":"gone"}"#, "[]", "{"] {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: paths.topicRecords)
            let (_, problems) = try open()
            XCTAssertEqual(problems.count, 1, "\(text): \(problems)")
            XCTAssertTrue(problems.first?.hasPrefix("\(paths.topicRecords.path) is not a Topic records file") == true, "\(problems)")
            XCTAssertEqual(try Data(contentsOf: paths.topicRecords), Data(text.utf8), "the file is left for the user")
            XCTAssertFalse(FileManager.default.fileExists(atPath: migratedFile.path))
            XCTAssertEqual(try TopicStore(paths: paths).read(), TopicContents(records: []))
        }
    }

    func testASecondOpenImportsNothing() throws {
        try paths.seedTopicRecordsFile(entries: [#"{"id":"a","title":"A"}"#], openPlaces: #"[{"id":"p","order":1}]"#)
        _ = try open()
        try TopicStore(paths: paths).write { transaction in
            try transaction.update("a") { $0.title = "Changed" }
            transaction.openPlaces = []
        }
        let (_, problems) = try open()
        XCTAssertEqual(problems, [])
        let contents = try TopicStore(paths: paths).read()
        XCTAssertEqual(contents.records.map(\.title), ["Changed"], "the second open did not read the old file again")
        XCTAssertEqual(contents.openPlaces, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedFile.path))
    }

    func testTheFirstReadOfAStoreImportsTheFile() throws {
        try paths.seedTopicRecordsFile(entries: [#"{"id":"a","title":"A"}"#])
        XCTAssertEqual(try TopicStore(paths: paths).read().records.map(\.id), ["a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.topicRecords.path))
    }

    // MARK: - The import of the Muxify Worktree record files

    /// Writes `text` as `worktrees/<name>.json`, as an older Muxify wrote each record.
    private func seedWorktreeFile(_ name: String, _ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: paths.worktrees, withIntermediateDirectories: true)
        let file = paths.worktrees.appendingPathComponent(name + ".json")
        try Data(text.utf8).write(to: file)
        return file
    }

    private func worktreeFile(id: String, path: String, environment: String? = nil, createdAt: String = "2026-09-01T10:00:00Z") -> String {
        let place = environment.map { #""environment":"\#($0)","# } ?? ""
        return #"{"id":"\#(id)",\#(place)"repository":"/src/app","name":"fix","path":"\#(path)","branch":"fix","base":"abc","created_at":"\#(createdAt)"}"#
    }

    func testTheWorktreesTableHasAUniquePath() throws {
        let (connection, _) = try open()
        XCTAssertEqual(try connection.query("SELECT name FROM pragma_table_info('worktrees') ORDER BY cid") { $0.text(0) ?? "" },
                       ["id", "environment", "repository", "name", "path", "branch", "base", "created_at"])
        try connection.execute("INSERT INTO worktrees VALUES ('a', NULL, '/r', 'a', '/t/a', 'a', 'c', '2026-09-01T10:00:00Z')")
        XCTAssertThrowsError(try connection.execute("INSERT INTO worktrees VALUES ('b', NULL, '/r', 'b', '/t/a', 'b', 'c', '2026-09-01T10:00:00Z')"))
    }

    func testTheImportMovesEachValidWorktreeRecordFileAndRenamesIt() throws {
        let local = try seedWorktreeFile("one", worktreeFile(id: "one", path: "/src/trees/one", createdAt: "2026-09-02T10:00:00Z"))
        let remote = try seedWorktreeFile("two", worktreeFile(id: "two", path: "/home/me/trees/two", environment: "box"))
        let (_, problems) = try open()
        XCTAssertEqual(problems, [])
        for file in [local, remote] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".migrated"), "the old file stays readable as <id>.json.migrated")
        }
        XCTAssertEqual(try MuxifyWorktreeStore(paths: paths).all(), [
            MuxifyWorktreeRecord(id: "two", environment: "box", repository: "/src/app", name: "fix", path: "/home/me/trees/two", branch: "fix",
                                 base: "abc", createdAt: Date(timeIntervalSince1970: 1_788_256_800)),
            MuxifyWorktreeRecord(id: "one", environment: nil, repository: "/src/app", name: "fix", path: "/src/trees/one", branch: "fix",
                                 base: "abc", createdAt: Date(timeIntervalSince1970: 1_788_343_200)),
        ])
    }

    func testTheImportSkipsAnUndecodableWorktreeFileWithAProblemLineAndLeavesIt() throws {
        let good = try seedWorktreeFile("good", worktreeFile(id: "good", path: "/src/trees/good"))
        let bad = try seedWorktreeFile("bad", #"{"id":"bad","path":7}"#)
        let twin = try seedWorktreeFile("twin", worktreeFile(id: "twin", path: "/src/trees/good"))
        let (_, problems) = try open()
        XCTAssertEqual(try MuxifyWorktreeStore(paths: paths).all().map(\.id), ["good"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path + ".migrated"))
        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertTrue(problems[0].hasPrefix("\(bad.path) is not a Muxify Worktree record"), problems[0])
        XCTAssertTrue(problems[1].hasPrefix("\(twin.path) repeats the id or the path"), problems[1])
        XCTAssertEqual(try Data(contentsOf: bad), Data(#"{"id":"bad","path":7}"#.utf8), "the file is left for the user")
        XCTAssertTrue(FileManager.default.fileExists(atPath: twin.path))
    }

    func testTheImportLeavesTheWorktreeCheckoutFoldersUntouched() throws {
        let checkout = paths.worktrees.appendingPathComponent("app/fix")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data("work".utf8).write(to: checkout.appendingPathComponent("notes.json"))
        let named = paths.worktrees.appendingPathComponent("odd.json", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        _ = try seedWorktreeFile("one", worktreeFile(id: "one", path: checkout.path))
        let (_, problems) = try open()
        XCTAssertEqual(problems, [])
        XCTAssertEqual(try Data(contentsOf: checkout.appendingPathComponent("notes.json")), Data("work".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: checkout.path), ["notes.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: named.path), "a folder named like a record file is a checkout")
        XCTAssertEqual(try MuxifyWorktreeStore(paths: paths).all().map(\.id), ["one"])
    }

    func testASecondOpenImportsNoWorktreeRecord() throws {
        _ = try seedWorktreeFile("one", worktreeFile(id: "one", path: "/src/trees/one"))
        _ = try open()
        try MuxifyWorktreeStore(paths: paths).remove("one")
        let (_, problems) = try open()
        XCTAssertEqual(problems, [])
        XCTAssertEqual(try MuxifyWorktreeStore(paths: paths).all(), [], "the second open did not read the old file again")
    }
}
