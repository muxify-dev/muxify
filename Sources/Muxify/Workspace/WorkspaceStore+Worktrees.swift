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

    /// Why Create Worktree, Remove Worktree and the list of Muxify Worktrees are refused, or nil when the link serves
    /// Muxify Worktrees. A Host's records are the Host CLI's alone, so a Remote App Window without its Host Server
    /// refuses them, with the reason it gives for Topics (ADR 0088).
    var worktreesRefusal: String? {
        guard !link.features.contains(.worktrees) else { return nil }
        let reason = topicsUnavailableReason?.reason ?? "its Host Server has not answered yet"
        return "Muxify Worktrees are unavailable on \(environmentName): \(reason)."
    }

    /// The Worktree `name` from the checkout of `choice`, and a No Topic Session in it that the App Window shows.
    func createWorktree(from choice: SessionChoice, name: String, start: WorktreeStart) {
        guard let worktree = choice.worktree else { return }
        perform(EnvironmentRequest(.createWorktree(name: name, from: worktree.folder.path, start: start, open: true)))
    }

    /// Every Muxify Worktree of the Environment, read where its records are.
    func listWorktrees() async -> Result<[MuxifyWorktreeSummary], TopicFailure> {
        if let refusal = worktreesRefusalFailure { return .failure(refusal) }
        let response = await link.run(EnvironmentRequest(.listWorktrees(all: true, from: nil)), client: nil, local: environmentService())
        switch response {
        case .worktrees(let worktrees)?: return .success(worktrees)
        case .failed(let failure)?: return .failure(failure)
        case nil: return .failure(Self.notConnected)
        default: return .failure(TopicFailure(kind: .tmuxFailed, phase: .nothingChanged, message: "Muxify could not list the Worktrees."))
        }
    }

    /// New Worktree's start choices from the checkout at `folder`, read with git on the Environment's machine.
    func newWorktreeStarts(from folder: String) async -> Result<[WorktreeStartChoice], TopicFailure> {
        if let refusal = worktreesRefusalFailure { return .failure(refusal) }
        return await link.worktreeStarts(from: folder, local: environmentService()) ?? .failure(Self.notConnected)
    }

    /// `worktreesRefusal` as the failure of a request that changed nothing.
    var worktreesRefusalFailure: TopicFailure? {
        worktreesRefusal.map { TopicFailure(kind: .unsupported, phase: .nothingChanged, message: $0) }
    }

    /// `kill` stops the Sessions that use it, as ⌘↩ asks; `force` removes it with changes or after a failed hook.
    func removeWorktree(_ worktree: MuxifyWorktreeSummary, kill: Bool, force: Bool) {
        perform(EnvironmentRequest(.removeWorktree(worktree.id, kill: kill, force: force)))
    }
}
