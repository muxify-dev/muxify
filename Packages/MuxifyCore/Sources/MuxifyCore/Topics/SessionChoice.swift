import Foundation

/// What the user picks in the New Topic and Add Session lists: a SessionPath, and the
/// Worktree of it when the SessionPath is a repository. A plain directory has no Worktree.
public struct SessionChoice: Identifiable, Equatable, Sendable {
    /// First configured launch name wins. Discovery never renames a path to resolve a collision.
    public static func launches(in paths: [SessionPath]) -> [SessionChoice] {
        var names: Set<String> = []
        return paths.flatMap(choices).filter { names.insert($0.name).inserted }
    }
    public let sessionPath: SessionPath
    public let worktree: Worktree?

    public init(sessionPath: SessionPath, worktree: Worktree?) {
        self.sessionPath = sessionPath
        self.worktree = worktree
    }

    public var id: String { directory.real }
    public var directory: Folder { worktree?.folder ?? sessionPath.folder }
    /// Names the Session this row opens.
    public var name: String { worktree.map { sessionPath.name(ofWorktreeAt: $0.folder) } ?? sessionPath.name }
    public var displayName: String { worktree.map { sessionPath.displayName(ofWorktreeAt: $0.folder) } ?? sessionPath.displayName }
    /// A checkout in its own folder, not the SessionPath folder itself.
    public var isWorktree: Bool { directory != sessionPath.folder }

    /// `newWorktree` asks for a new Worktree from this row's Worktree, which starts as `start` says; a plain
    /// directory has none to start from.
    public func workingCopy(newWorktree: Bool, start: WorktreeStart = .head) -> TopicWorkingCopyChoice {
        guard let worktree else { return .directory }
        return newWorktree ? .newWorktree(from: worktree.folder.path, start: start) : .worktree(path: worktree.folder.path)
    }

    public static func choices(of sessionPath: SessionPath) -> [SessionChoice] {
        let worktrees = sessionPath.layout.worktrees
        guard !worktrees.isEmpty else { return [SessionChoice(sessionPath: sessionPath, worktree: nil)] }
        return worktrees.map { SessionChoice(sessionPath: sessionPath, worktree: $0) }
    }

    /// The row whose directory holds `folder`, nearest first, so a Worktree inside a bare
    /// SessionPath folder wins over the folder.
    public static func containing(_ folder: Folder, in sessionPaths: [SessionPath]) -> SessionChoice? {
        sessionPaths.flatMap(choices).filter { $0.directory.contains(folder) }.max { $0.directory.real.count < $1.directory.real.count }
    }
}

/// One row of the New Topic and Add Session lists.
public struct SessionPathRow: Identifiable, Equatable, Sendable {
    public let choice: SessionChoice
    /// The other open Topics whose live Sessions use this row's folder, by label. The row can still be picked:
    /// each Topic gets its own Session there.
    public let alsoIn: [TopicSummary]

    public init(choice: SessionChoice, alsoIn: [TopicSummary]) {
        self.choice = choice
        self.alsoIn = alsoIn
    }

    public var id: String { choice.id }
    public var note: String? { alsoIn.isEmpty ? nil : "Also in " + alsoIn.map(\.label).joined(separator: ", ") }
}

public enum SessionPathRows {
    /// The rows of the New Topic list, or of the Add Session list of `topic`, in Config order.
    public static func build(sessionPaths: [SessionPath], windows: [TmuxWindow], records: [TopicRecord], titles: [String: String],
                             addingTo topic: TopicRecord? = nil) -> [SessionPathRow] {
        return SessionChoice.launches(in: sessionPaths).map { choice in
            let ids = Set(windows.filter { choice.directory.contains(.local($0.sessionPath)) }.compactMap(\.topicID))
            let alsoIn = records.filter { $0.settledAt == nil && $0.id != topic?.id && ids.contains($0.id) }
                .map { TopicSummary(id: $0.id, label: titles[$0.id] ?? TopicSummary(record: $0).label, tags: $0.tags.sorted()) }
            return SessionPathRow(choice: choice, alsoIn: alsoIn)
        }
    }
}
