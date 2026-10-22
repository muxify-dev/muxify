import Foundation

enum TopicWorktrees {
    /// Missing provenance is never permission to remove a Worktree.
    public static let createdKey = "worktree_created"

    /// The remembered-Session field that holds the full id of the commit a created Worktree started at.
    public static let baseKey = "base"

    public static func isCreated(_ session: JSONValue) -> Bool { session[createdKey] == .bool(true) }

    /// Whether `worktree` sits inside Muxify's worktrees folder `root`. Settle never removes a Worktree outside it, so the
    /// user's own Worktrees, and those Muxify made before the folder existed, stay wherever they are.
    public static func isInside(_ worktree: Folder, root: Folder) -> Bool {
        worktree != root && root.contains(worktree)
    }

    /// The Worktrees Settle may remove: those inside `root` that the Topic created, with their branch merged.
    public static func merged(in topic: TopicRecord, root: String) -> Set<Folder> {
        let root = Folder.local(root)
        return Set(topic.sessions.compactMap { session in
            guard isCreated(session), let sessionPath = session["repository_path"]?.string, let path = session["worktree_path"]?.string,
                  let branch = session["branch"]?.string else { return nil }
            let worktree = Folder.local(path)
            guard isInside(worktree, root: root), isMerged(.init(repositoryPath: sessionPath, path: path, branch: branch)) else { return nil }
            return worktree
        })
    }

    /// The full id of the commit that `ref` names in the Worktree `base`; with no ref, its HEAD, local unpushed
    /// commits included. The plan records this id, so a branch that moves later does not change where the
    /// Worktree started.
    public static func commit(_ ref: String?, in base: Worktree) throws -> String {
        do {
            return try Shell.run("/usr/bin/git", ["rev-parse", "--verify", "--quiet", "--end-of-options", (ref ?? "HEAD") + "^{commit}"],
                                 directory: base.folder.path).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is ShellError {
            throw TopicRequestError.baseUnavailable(ref: ref ?? "HEAD", worktree: base.folder.path)
        }
    }

    /// Creates the Worktree on a new branch at `commit`.
    public static func add(_ worktree: TopicPlan.WorktreeSpec, at commit: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: worktree.path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        _ = try Shell.run("/usr/bin/git", worktree.arguments + [commit], directory: worktree.repositoryPath)
    }

    public static func isMerged(_ worktree: TopicPlan.WorktreeSpec) -> Bool {
        guard let branch = try? Shell.run("/usr/bin/git", ["symbolic-ref", "--short", "HEAD"], directory: worktree.path),
              branch.trimmingCharacters(in: .whitespacesAndNewlines) == worktree.branch else { return false }
        return (try? Shell.run("/usr/bin/git", ["merge-base", "--is-ancestor", "refs/heads/" + worktree.branch, "HEAD"],
                               directory: worktree.repositoryPath)) != nil
    }

    /// Makes the Worktree again when its folder is gone. A branch that still exists is checked out as it is. A
    /// branch that is gone starts again at `base`, so the recorded `base` stays true; with no `base`, at the HEAD
    /// of the SessionPath.
    public static func restore(_ worktree: TopicPlan.WorktreeSpec, base: String?) throws {
        guard !FileManager.default.fileExists(atPath: worktree.path) else { return }
        let listed = try Shell.run("/usr/bin/git", ["worktree", "list", "--porcelain"], directory: worktree.repositoryPath)
        let folder = Folder.local(worktree.path)
        // git lists real paths, and a stale entry is removed by the path that git knows it by.
        if let stale = listed.components(separatedBy: "\n").filter({ $0.hasPrefix("worktree ") }).map({ String($0.dropFirst(9)) })
            .first(where: { Folder(path: $0, real: $0) == folder }) {
            _ = try Shell.run("/usr/bin/git", ["worktree", "remove", stale], directory: worktree.repositoryPath)
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: worktree.path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let arguments = branchExists(worktree) ? ["worktree", "add", worktree.path, worktree.branch]
                                               : worktree.arguments + (base.map { [$0] } ?? [])
        _ = try Shell.run("/usr/bin/git", arguments, directory: worktree.repositoryPath)
    }

    private static func branchExists(_ worktree: TopicPlan.WorktreeSpec) -> Bool {
        (try? Shell.run("/usr/bin/git", ["show-ref", "--verify", "--quiet", "refs/heads/" + worktree.branch],
                        directory: worktree.repositoryPath)) != nil
    }

    /// Refuses the Worktree commands that git would refuse halfway through a run. The service calls this before it
    /// writes the record or runs tmux, so a refusal changes nothing.
    static func check(_ commands: [TopicPlan.Command]) throws {
        for command in commands {
            switch command {
            case .restoreWorktree(let worktree, let base?):
                guard !FileManager.default.fileExists(atPath: worktree.path), !branchExists(worktree) else { continue }
                guard (try? Shell.run("/usr/bin/git", ["rev-parse", "--verify", "--quiet", "--end-of-options", base + "^{commit}"],
                                      directory: worktree.repositoryPath)) != nil else {
                    throw TopicRequestError.worktreeBaseMissing(base: base, worktree: worktree.path)
                }
            case .removeMergedWorktree(let worktree), .removeCleanWorktree(let worktree):
                // An explicit mode, so that a status.showUntrackedFiles=no setting does not hide the untracked files
                // that make git worktree remove refuse.
                let status = try Shell.run("/usr/bin/git", ["status", "--porcelain", "--untracked-files=normal"], directory: worktree.path)
                guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw TopicRequestError.worktreeHasChanges(worktree.path)
                }
            default:
                continue
            }
        }
    }

    /// `windows` are the live Windows of the tmux server whose Sessions may use the Worktree.
    public static func removeMerged(_ worktree: TopicPlan.WorktreeSpec, root: String,
                              windows: [TmuxWindow], panes: [TmuxPane] = []) throws {
        let folder = Folder.local(worktree.path)
        guard isInside(folder, root: .local(root)) else { throw Failure.notMuxifys }
        guard isMerged(worktree) else { throw Failure.notMerged }
        guard !windows.contains(where: { $0.folders.contains(where: folder.contains) }),
              !panes.contains(where: { folder.contains(.local($0.path)) }) else { throw Failure.inUse }
        try check([.removeMergedWorktree(worktree)])
        _ = try Shell.run("/usr/bin/git", ["worktree", "remove", worktree.path], directory: worktree.repositoryPath)
    }

    public static func removeClean(_ worktree: TopicPlan.WorktreeSpec, root: String, windows: [TmuxWindow], panes: [TmuxPane] = []) throws {
        let folder = Folder.local(worktree.path)
        guard isInside(folder, root: .local(root)) else { throw Failure.notMuxifys }
        guard !windows.contains(where: { $0.folders.contains(where: folder.contains) }),
              !panes.contains(where: { folder.contains(.local($0.path)) }) else { throw Failure.inUse }
        try check([.removeCleanWorktree(worktree)])
        _ = try Shell.run("/usr/bin/git", ["worktree", "remove", worktree.path], directory: worktree.repositoryPath)
    }

    private enum Failure: Error, CustomStringConvertible {
        case notMuxifys, notMerged, inUse
        public var description: String {
            switch self {
            case .notMuxifys: return "The worktree is not in Muxify's worktrees folder. The worktree was kept."
            case .notMerged: return "The worktree branch is not merged into the main working copy. The worktree was kept."
            case .inUse: return "A live Session uses the worktree. The worktree was kept."
            }
        }
    }
}

extension TmuxWindow {
    /// The folders the Window's Pane and its Session work in. Topics are local, so both resolve on this Mac.
    var folders: [Folder] { [.local(path), .local(sessionPath)] }
}
