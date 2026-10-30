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

/// The records, one file each in `$XDG_STATE_HOME/muxify/worktrees/<id>.json`, as Topics are. Two processes that make
/// two Worktrees write two files, so no write merges another, and a write is atomic, so no reader sees half of one.
public struct MuxifyWorktreeStore: Sendable {
    public let folder: URL

    public init(paths: MuxifyPaths) { folder = paths.worktrees }
    public init(folder: URL) { self.folder = folder }

    /// Every record. A file that is not a record, such as one a newer Muxify wrote, is skipped. The folder also
    /// holds the Worktrees of the default root, which are folders.
    public func all() throws -> [MuxifyWorktreeRecord] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { file in (try? Data(contentsOf: file)).flatMap { try? decoder.decode(MuxifyWorktreeRecord.self, from: $0) } }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func record(_ id: String) -> MuxifyWorktreeRecord? {
        try? all().first { $0.id == id }
    }

    public func write(_ record: MuxifyWorktreeRecord) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: file(record.id), options: .atomic)
    }

    public func remove(_ id: String) throws {
        let file = file(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func file(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }
}
