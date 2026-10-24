import Foundation

/// The Agent guard (ADR 0041): which Agents an operation that changes a Worktree's files would change files
/// under. Those are the Agents that are working or blocked, and run in a Pane whose folder is the Worktree or inside
/// it. An Agent that is done, failed or has no Status doesn't count, and neither does one in another Worktree of the
/// same repository, nor one in a folder outside the repository.
public enum AgentGuard {
    /// Whether an Agent with this Status has a turn running or waiting.
    public static func isActive(_ status: AgentStatus?) -> Bool {
        status == .working || status == .blocked
    }

    /// The Agents of `agents` that are active in `worktree`, in their order. A Pane's folder and the Worktree's are
    /// compared by real path, so a symlinked spelling of either is the same folder (ADR 0022). `resolver` turns a
    /// Pane's folder into a Folder on the machine that owns it.
    public static func agents(in worktree: Folder, among agents: [Agent], resolver: FolderResolver = .local) -> [Agent] {
        agents.filter { agent in
            isActive(agent.status) && !agent.path.isEmpty && worktree.contains(resolver.folder(agent.path))
        }
    }
}
