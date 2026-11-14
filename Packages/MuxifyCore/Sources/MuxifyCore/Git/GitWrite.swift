import Foundation

/// One of the Git View's writes that changes the repository without the network (ADR 0085), with the inputs it had
/// as a script. The Mac runs it through its App Window's `EnvironmentLink`: `GitWriter` in-process for the Local
/// Environment, a `git_write` request to the Host Server for a Host. Its JSON is `{"<case>": {<its values>}}`, and it
/// answers what git printed, such as a new commit's short hash.
public enum GitWrite: Codable, Equatable, Sendable {
    /// Stages files and folders with everything in them. A conflicted file that still has conflict markers isn't
    /// staged, nor is anything with it.
    case stage(root: String, paths: [String])
    /// Unstages files and folders, also before the first commit.
    case unstage(root: String, paths: [String])
    /// Discards every change in files and folders, staged or not: tracked files go back to HEAD, new and untracked
    /// ones are deleted.
    case discard(root: String, paths: [String])
    /// Discards the unstaged changes in files and folders: tracked files go back to what's staged, untracked ones are
    /// deleted.
    case discardUnstaged(root: String, paths: [String])
    /// Applies a patch of some of a change's lines to the index, its reverse to the index, or its reverse to the
    /// working tree. `newFiles` are the new files it takes lines of, which git is told of first.
    case applyPatch(root: String, mode: PatchMode, patch: String, newFiles: [String])
    /// Commits what's staged with the message. Answers the new commit's short hash.
    case commit(root: String, message: String)
    /// Amends the last commit with what's staged and keeps its message. Answers the commit's short hash.
    case amend(root: String)
    /// Merges a branch into the one you're on, `into`, for the words.
    case merge(root: String, branch: String, kind: MergeKind, into: String)
    /// Rebases the branch you're on, `head`, for the words, onto a branch.
    case rebase(root: String, onto: String, head: String)
    /// Continues, skips or aborts the merge, rebase, `git am`, cherry-pick or revert in progress.
    case operation(root: String, command: OperationCommand, step: OperationStep)
    /// Cherry-picks the full hashes of commits, in any order, onto the branch you're on, oldest first.
    case cherryPick(root: String, commits: [String])
    /// Resets the branch you're on to a commit.
    case reset(root: String, kind: ResetKind, target: String)
    /// One of lazygit's reset options for the working tree.
    case resetWorkingTree(root: String, option: WorkingTreeReset)
    /// Stashes, with the message, which may be empty.
    case stash(root: String, kind: StashKind, message: String)
    /// Applies, pops or drops a stash, by its ref and its hash; refuses when the ref is no longer that stash.
    case stashEntry(root: String, action: StashAction, ref: String, sha: String)
    /// Renames a local branch.
    case renameBranch(root: String, branch: String, name: String)
    /// Deletes a local branch; without `force`, a branch that is not fully merged fails with
    /// `GitWrites.branchNotMergedMarker`.
    case deleteBranch(root: String, branch: String, force: Bool)
    /// Checks out a branch, a remote branch, a new branch off `base`, the previous branch or a commit. Without
    /// `autostash`, a checkout that Changes are in the way of fails with `GitWrites.checkoutBlockedMarker`, then git's
    /// message.
    case checkout(root: String, kind: CheckoutKind, target: String, autostash: Bool, base: String?)

    public enum PatchMode: String, Codable, Sendable { case stage, unstage, discard }

    public enum MergeKind: String, Codable, Sendable {
        case fastForward = "ff", mergeCommit = "no-ff", squashAndCommit = "squash", squashAndLeave = "squash-leave"
    }

    /// The git command of what's in progress, as `GitOperation.command` names it.
    public enum OperationCommand: String, Codable, Sendable {
        case merge, rebase, am, cherryPick = "cherry-pick", revert
    }

    public enum OperationStep: String, Codable, Sendable { case `continue`, skip, abort }

    public enum ResetKind: String, Codable, Sendable { case soft, mixed, hard }

    /// `nuke` puts tracked files back to HEAD and deletes untracked ones, `unstaged` puts tracked files back to what's
    /// staged, `untracked` deletes untracked files, `staged` discards what's staged, and `soft`, `mixed` and `hard`
    /// reset to HEAD. Ignored files stay.
    public enum WorkingTreeReset: String, Codable, CaseIterable, Sendable {
        case nuke, unstaged, untracked, staged, soft, mixed, hard
    }

    public enum StashKind: String, Codable, CaseIterable, Sendable {
        case all, untracked, staged, unstaged, keepIndex = "keepindex"
    }

    public enum StashAction: String, Codable, Sendable {
        /// The stash stays.
        case apply
        /// Applies it and drops it, unless it conflicts.
        case pop
        case drop
    }

    public enum CheckoutKind: String, Codable, Sendable { case branch, remote, new, previous, commit }

    /// The name of the Action, as a message about it says it: "<Environment> disconnected before Commit finished."
    public var action: String {
        switch self {
        case .stage: "Stage"
        case .unstage: "Unstage"
        case .discard, .discardUnstaged: "Discard"
        case .applyPatch(_, let mode, _, _):
            switch mode {
            case .stage: "Stage"
            case .unstage: "Unstage"
            case .discard: "Discard"
            }
        case .commit: "Commit"
        case .amend: "Amend"
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .operation(_, _, let step):
            switch step {
            case .continue: "Continue"
            case .skip: "Skip"
            case .abort: "Abort"
            }
        case .cherryPick: "Cherry-pick"
        case .reset, .resetWorkingTree: "Reset"
        case .stash: "Stash"
        case .stashEntry(_, let action, _, _):
            switch action {
            case .apply: "Apply Stash"
            case .pop: "Pop Stash"
            case .drop: "Drop Stash"
            }
        case .renameBranch: "Rename Branch"
        case .deleteBranch: "Delete Branch"
        case .checkout: "Checkout"
        }
    }

    /// How long the write may take, as each script had it: hooks and signing can take a while, or wait for you.
    public var timeout: TimeInterval {
        switch self {
        case .commit, .amend, .merge, .rebase, .operation, .cherryPick: 600
        default: 30
        }
    }

    /// The script that does it, and its arguments.
    var script: (text: String, arguments: [String]) {
        switch self {
        case .stage(let root, let paths): (GitWrites.stageScript, [root] + paths)
        case .unstage(let root, let paths): (GitWrites.unstageScript, [root] + paths)
        case .discard(let root, let paths): (GitWrites.discardScript, [root] + paths)
        case .discardUnstaged(let root, let paths): (GitWrites.discardUnstagedScript, [root] + paths)
        case .applyPatch(let root, let mode, let patch, let newFiles):
            (GitWrites.applyPatchScript, [root, mode.rawValue, patch] + newFiles)
        case .commit(let root, let message): (GitWrites.makeCommitScript, [root, message])
        case .amend(let root): (GitWrites.amendScript, [root])
        case .merge(let root, let branch, let kind, let into): (GitWrites.mergeScript, [root, branch, kind.rawValue, into])
        case .rebase(let root, let onto, let head): (GitWrites.rebaseScript, [root, onto, head])
        case .operation(let root, let command, let step): (GitWrites.operationScript, [root, command.rawValue, step.rawValue])
        case .cherryPick(let root, let commits): (GitWrites.cherryPickScript, [root] + commits)
        case .reset(let root, let kind, let target): (GitWrites.resetScript, [root, kind.rawValue, target])
        case .resetWorkingTree(let root, let option): (GitWrites.resetWorkingTreeScript, [root, option.rawValue])
        case .stash(let root, let kind, let message): (GitWrites.stashScript, [root, kind.rawValue, message])
        case .stashEntry(let root, let action, let ref, let sha): (GitWrites.stashEntryScript, [root, action.rawValue, ref, sha])
        case .renameBranch(let root, let branch, let name): (GitWrites.renameBranchScript, [root, branch, name])
        case .deleteBranch(let root, let branch, let force): (GitWrites.deleteBranchScript, [root, branch, force ? "1" : "0"])
        case .checkout(let root, let kind, let target, let autostash, let base):
            (GitWrites.checkoutScript, [root, kind.rawValue, target, autostash ? "1" : "0"] + (base.map { [$0] } ?? []))
        }
    }
}

/// What a `GitWrite` answered: what git printed.
public struct GitWritten: Codable, Equatable, Sendable {
    public var output: String

    public init(output: String) { self.output = output }
}

/// Runs the Git View's writes on this machine: the scripts of `GitWrites`. The Local link runs it in-process; the
/// Host Server runs it for its `git_write` requests.
public struct GitWriter: Sendable {
    private let scripts: ScriptRunning

    public init(scripts: ScriptRunning = LocalScripts()) {
        self.scripts = scripts
    }

    /// What git printed, or the script's `TmuxError`, whose stderr says why, as `GitReader.message(for:)` shows it.
    @discardableResult
    public func run(_ write: GitWrite) throws -> String {
        let script = write.script
        return try scripts.runScript(script.text, arguments: script.arguments, timeout: write.timeout)
    }
}
