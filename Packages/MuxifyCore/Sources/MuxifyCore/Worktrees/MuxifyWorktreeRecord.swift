import Foundation

/// What Muxify remembers of a Worktree it made, in or out of a Topic (ADR 0062). The record is the proof that
/// Muxify made it: `worktree list` lists records, and Remove Worktree removes only a Worktree that has one.
///
/// A record always describes a Worktree on the machine of its own database: a Host's Worktrees are in the Host's
/// `muxify.db`, which only the Host CLI there writes (ADR 0088). It names no Environment.
public struct MuxifyWorktreeRecord: Codable, Hashable, Sendable {
    public var id: String
    /// The repository's main working tree, or its bare folder.
    public var repository: String
    /// The name the user gave: the folder's name, and the Session's after the repository's.
    public var name: String
    public var path: String
    public var branch: String
    /// The full id of the commit the Worktree started at.
    public var base: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), repository: String, name: String, path: String,
                branch: String, base: String, createdAt: Date = Date()) {
        self.id = id
        self.repository = repository
        self.name = name
        self.path = path
        self.branch = branch
        self.base = base
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, repository, name, path, branch, base
        case createdAt = "created_at"
    }

    /// `created_at` is ISO 8601 text, as the old record files and the `worktrees` table have it, whatever the
    /// coder's date strategy.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        repository = try values.decode(String.self, forKey: .repository)
        name = try values.decode(String.self, forKey: .name)
        path = try values.decode(String.self, forKey: .path)
        branch = try values.decode(String.self, forKey: .branch)
        base = try values.decode(String.self, forKey: .base)
        let text = try values.decode(String.self, forKey: .createdAt)
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: values, debugDescription: "\(text) is not an ISO 8601 date")
        }
        createdAt = date
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(repository, forKey: .repository)
        try values.encode(name, forKey: .name)
        try values.encode(path, forKey: .path)
        try values.encode(branch, forKey: .branch)
        try values.encode(base, forKey: .base)
        try values.encode(ISO8601DateFormatter().string(from: createdAt), forKey: .createdAt)
    }
}

/// The records in the state database: the `worktrees` table (`WorktreeTable`), one row for each record of a
/// Worktree on this machine. It keeps no records of its own, so two processes that make two Worktrees each insert a
/// row, and a second record at a path that has one fails.
///
/// On the Mac, a row whose `environment` is set is an older Muxify's record of a Remote Environment's Worktree,
/// waiting to move to that Environment's Host (ADR 0088). Every read and write here but the `waiting` ones ignores
/// such a row.
public struct MuxifyWorktreeStore: Sendable {
    public let paths: MuxifyPaths
    private let database: StateConnection

    public init(paths: MuxifyPaths) {
        self.paths = paths
        database = StateConnection(paths: paths)
    }

    /// Every record, oldest first. Without a state folder there is nothing to read, and the read creates nothing.
    public func all() throws -> [MuxifyWorktreeRecord] {
        try database.use(creating: false) { try WorktreeTable.records($0) } ?? []
    }

    public func record(_ id: String) -> MuxifyWorktreeRecord? {
        (try? database.use(creating: false) { try WorktreeTable.records($0, id: id).first }) ?? nil
    }

    /// Inserts the record, or updates the one with its id. A record at a path that another record has fails with
    /// `MuxifyWorktreeError.pathTaken`, and writes nothing.
    public func write(_ record: MuxifyWorktreeRecord) throws {
        _ = try database.use(creating: true) { try WorktreeTable.write(record, $0) }
    }

    public func remove(_ id: String) throws {
        _ = try database.use(creating: false) { try $0.execute("DELETE FROM worktrees WHERE id = ? AND environment IS NULL", id) }
    }

    // MARK: - The rows that wait to move to a Host

    /// The rows waiting to move to `environment`'s Host, oldest first.
    public func waiting(for environment: String) throws -> [MuxifyWorktreeRecord] {
        try database.use(creating: false) { try WorktreeTable.records($0, waitingFor: environment) } ?? []
    }

    /// Deletes the rows of `ids` that wait for `environment`: the ones its Host took.
    public func removeWaiting(_ ids: [String], for environment: String) throws {
        guard !ids.isEmpty else { return }
        _ = try database.use(creating: false) { connection in
            try connection.transaction {
                for id in ids { try connection.execute("DELETE FROM worktrees WHERE id = ? AND environment = ?", id, environment) }
            }
        }
    }

    /// The Host's half of `adopt_worktrees`: each row becomes a record of this machine, as the import of the old
    /// record files makes one, unless a record has its id or its path already. Answers each row in order.
    public func adopt(_ rows: [MuxifyWorktreeRecord]) throws -> [AdoptedWorktree] {
        try database.use(creating: true) { try WorktreeTable.adopt(rows, $0) } ?? []
    }
}
