import MuxifyCore

// New Worktree and Remove Worktree: Muxify Worktrees with no Topic, on the Environment the App Window shows (ADR 0062).
extension WorkspaceStore {
    func presentNewWorktree(keepingHistory: Bool = false) {
        guard !changingTopic else { return }
        palette.begin(.newWorktree, keepingHistory: keepingHistory)
        refreshSessionPaths()
    }

    func presentRemoveWorktree(keepingHistory: Bool = false) {
        guard !changingTopic else { return }
        palette.begin(.removeWorktree(RemoveWorktreeDraft()), keepingHistory: keepingHistory)
    }

    /// The Worktree `name` from the checkout of `choice`, and a No Topic Session in it that the App Window shows.
    func createWorktree(from choice: SessionChoice, name: String, start: WorktreeStart) {
        guard let worktree = choice.worktree else { return }
        perform(EnvironmentRequest(.createWorktree(name: name, from: worktree.folder.path, start: start, open: true)))
    }

    /// `kill` stops the Sessions that use it, as ⌘↩ asks; `force` removes it with changes or after a failed hook.
    func removeWorktree(_ worktree: MuxifyWorktreeSummary, kill: Bool, force: Bool) {
        perform(EnvironmentRequest(.removeWorktree(worktree.id, kill: kill, force: force)))
    }
}
