import Foundation

/// One checkout of a SessionPath's repository, as `git worktree list` reports it.
public struct Worktree: Hashable, Sendable {
    public let folder: Folder
    /// Nil when HEAD is detached.
    public let branch: String?

    public init(folder: Folder, branch: String?) {
        self.folder = folder
        self.branch = branch
    }

    /// A Worktree in a folder on this Mac.
    public init(path: String, branch: String?) {
        self.init(folder: .local(path), branch: branch)
    }
}

/// What git says a SessionPath directory is. Read with `detect`, never from folder names.
public enum RepositoryLayout: Equatable, Sendable {
    case directory
    case plainRepository([Worktree])
    case bareRepository([Worktree])

    public var worktrees: [Worktree] {
        switch self {
        case .directory: return []
        case .plainRepository(let worktrees), .bareRepository(let worktrees): return worktrees
        }
    }

    /// What `SessionPathDiscovery` finds at `path` alone. A folder inside somebody else's checkout is a plain
    /// directory, so a SessionPath that is a subfolder of a repository does not list that repository's Worktrees.
    public static func detect(at path: String) -> RepositoryLayout {
        SessionPathDiscovery.discover([SessionPathRoot(path: path)], aliases: [:]).first?.layout ?? .directory
    }

    /// The layout the discovery script reports for a folder of `kind`.
    init(kind: String, worktrees: [Worktree]) {
        switch kind {
        case "bare": self = .bareRepository(worktrees)
        case "plain": self = .plainRepository(worktrees)
        default: self = .directory
        }
    }

    /// The checkouts in `git worktree list --porcelain`, without the bare entry and
    /// without prunable entries whose folder is gone. git gives real paths, so `resolver` gives each its spelling.
    public static func parse(worktreeList: String, resolver: FolderResolver) -> [Worktree] {
        worktreeList.components(separatedBy: "\n\n").compactMap { block -> Worktree? in
            let lines = block.components(separatedBy: "\n")
            guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst(9), !path.isEmpty,
                  !lines.contains("bare"), !lines.contains(where: { $0.hasPrefix("prunable") }) else { return nil }
            let branch = lines.first { $0.hasPrefix("branch refs/heads/") }.map { String($0.dropFirst(18)) }
            return Worktree(folder: resolver.folder(String(path)), branch: branch)
        }
    }
}
