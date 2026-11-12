import Foundation

/// What Muxify remembers of a Worktree it made, in or out of a Topic (ADR 0062). The record is the proof that
/// Muxify made it: `worktree list` lists records, and Remove Worktree removes only a Worktree that has one.
public struct MuxifyWorktreeRecord: Codable, Hashable, Sendable {
    public var id: String
    /// Nil on this Mac, else the name of the Remote Environment whose machine has the Worktree.
    public var environment: String?
    /// The repository's main working tree, or its bare folder.
    public var repository: String
    /// The name the user gave: the folder's name, and the Session's after the repository's.
    public var name: String
    public var path: String
    public var branch: String
    /// The full id of the commit the Worktree started at.
    public var base: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), environment: String?, repository: String, name: String, path: String,
                branch: String, base: String, createdAt: Date = Date()) {
        self.id = id
        self.environment = environment
        self.repository = repository
        self.name = name
        self.path = path
        self.branch = branch
        self.base = base
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, environment, repository, name, path, branch, base
        case createdAt = "created_at"
    }
}

/// The records in the state database: the `worktrees` table (`WorktreeTable`), one row for each record, on this Mac
/// for its own Worktrees and those of its Remote Environments. It keeps no records of its own, so two processes that
/// make two Worktrees each insert a row, and a second record at a path that has one fails.
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
        _ = try database.use(creating: false) { try $0.execute("DELETE FROM worktrees WHERE id = ?", id) }
    }
}
