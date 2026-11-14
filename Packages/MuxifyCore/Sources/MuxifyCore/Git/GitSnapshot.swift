import Foundation

// What the Git View reads of a repository. The reads run on whichever machine has the repository: in-process for
// the Local Environment, in the Host Server for a Host (ADR 0085), so these values cross the wire as JSON.

/// What the Git View lists of a repository (CONTEXT.md): its status, changed
/// files, local branches, commits and stashes.
public struct GitSnapshot: Codable, Equatable, Sendable {
    /// The worktree's top folder.
    public var root: String
    public var repositoryName: String
    /// The folder of a linked worktree, when it isn't the repository's own.
    public var worktreeName: String?
    /// The repository's own folder: where its main checkout is, or its git directory when it is bare. Topic records
    /// name a Worktree's repository by it.
    public var repositoryFolder = ""
    /// The repository's common git directory, the same from every Worktree of it: what Copied commits are kept by.
    public var commonDirectory = ""
    /// The current branch, or the short commit of a detached HEAD.
    public var head: String
    public var isDetached = false
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    /// The changed files, as `git status` lists them.
    public var changes: [GitChange] = []
    /// What the toolbar's ↑/↓ count against: the upstream, else main.
    public var comparison: GitComparison?
    public var branches: [GitBranch] = []
    /// The names of the remote branches, such as `origin/foo`, for `c` in Branches to suggest.
    public var remoteBranches: [String] = []
    /// The branch that `git checkout -` goes back to, if it is still a branch.
    public var previousBranch: String?
    public var commits: [GitCommit] = []
    /// The History graph, a row per commit.
    public var graph: [GitGraphRow] = []
    public var stashes: [GitStash] = []
    /// `main` or `master`: what the current branch is compared with.
    public var mainBranch: String?
    /// A merge, rebase or the like that git is in the middle of.
    public var operation: GitOperation?
    /// git's message for the merge in progress, without its `#` lines.
    public var mergeMessage: String?

    public init(root: String, repositoryName: String, worktreeName: String? = nil, head: String, isDetached: Bool = false) {
        self.root = root
        self.repositoryName = repositoryName
        self.worktreeName = worktreeName
        self.head = head
        self.isDetached = isDetached
    }

    private enum CodingKeys: String, CodingKey {
        case root
        case repositoryName = "repository_name"
        case worktreeName = "worktree_name"
        case repositoryFolder = "repository_folder"
        case commonDirectory = "common_directory"
        case head
        case isDetached = "detached"
        case upstream, ahead, behind, changes, comparison, branches
        case remoteBranches = "remote_branches"
        case previousBranch = "previous_branch"
        case commits, graph, stashes
        case mainBranch = "main_branch"
        case operation
        case mergeMessage = "merge_message"
    }

    /// The current branch's history.
    public var log: GitLog { GitLog(commits: commits, graph: graph) }

    /// A commit now concludes a merge.
    public var isMerging: Bool {
        if case .merge? = operation { return true }
        return false
    }

    /// The toolbar's "Merging feature" or "Rebasing feature 3/7".
    public var operationTitle: String? {
        func name(_ sha: String) -> String { branches.first { $0.sha == sha }?.name ?? String(sha.prefix(7)) }
        func progress(_ step: Int?, _ steps: Int?) -> String {
            guard let step, let steps else { return "" }
            return " \(step)/\(steps)"
        }
        switch operation {
        case .merge(let shas)?: return "Merging " + shas.map(name).joined(separator: ", ")
        case .rebase(let branch, let step, let steps)?: return "Rebasing" + (branch.map { " \($0)" } ?? "") + progress(step, steps)
        case .applying(let step, let steps)?: return "Applying patches" + progress(step, steps)
        case .cherryPick(let sha)?: return "Cherry-picking \(sha.prefix(7))"
        case .revert(let sha)?: return "Reverting \(sha.prefix(7))"
        case .bisect?: return "Bisecting"
        case nil: return nil
        }
    }
}

/// What git is in the middle of: a merge, a rebase, `git am`, a cherry-pick or
/// a revert, which m continues, skips or aborts, or a bisect.
public enum GitOperation: Equatable, Sendable {
    /// The commits being merged in.
    case merge([String])
    /// The branch being rebased, and the step it's at of how many.
    case rebase(branch: String?, step: Int?, steps: Int?)
    case applying(step: Int?, steps: Int?)
    case cherryPick(String)
    case revert(String)
    case bisect

    /// Why A doesn't amend now, if it doesn't.
    public var amendBlock: String? {
        switch self {
        case .merge: "A merge is in progress: conclude it with c first, then amend."
        case .rebase, .applying, .cherryPick, .revert:
            (commitBlock ?? "").replacingOccurrences(of: ": continue", with: ", so the last commit isn't amended: continue")
        case .bisect: nil
        }
    }

    /// Why c doesn't commit now, if it doesn't.
    public var commitBlock: String? {
        switch self {
        case .rebase, .applying, .cherryPick, .revert: "\(title) is in progress: continue it with m."
        case .merge, .bisect: nil
        }
    }

    /// The operation as a sentence starts with it, such as "A rebase" or "git am".
    private var title: String {
        switch self {
        case .merge: "A merge"
        case .rebase: "A rebase"
        case .applying: "git am"
        case .cherryPick: "A cherry-pick"
        case .revert: "A revert"
        case .bisect: "A bisect"
        }
    }

    /// What m calls it, such as "rebase" or "git am"; nil for a bisect, which m leaves alone.
    public var noun: String? {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .applying: "git am"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .bisect: nil
        }
    }

    /// The git command that goes on with it, such as `rebase` for `git rebase --continue`.
    public var command: String? {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .applying: "am"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .bisect: nil
        }
    }

    /// Git has no `--skip` for a merge.
    public var canSkip: Bool {
        switch self {
        case .merge, .bisect: false
        case .rebase, .applying, .cherryPick, .revert: true
        }
    }

    /// An SF Symbol for it.
    public var symbol: String {
        switch self {
        case .merge: "arrow.triangle.merge"
        case .rebase, .applying: "arrow.triangle.2.circlepath"
        case .cherryPick: "arrow.uturn.forward"
        case .revert: "arrow.uturn.backward"
        case .bisect: "magnifyingglass"
        }
    }
}

extension GitOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, shas, branch, step, steps, sha
    }

    private enum Kind: String, Codable {
        case merge, rebase, applying
        case cherryPick = "cherry_pick"
        case revert, bisect
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .merge: self = .merge(try values.decodeIfPresent([String].self, forKey: .shas) ?? [])
        case .rebase:
            self = .rebase(branch: try values.decodeIfPresent(String.self, forKey: .branch),
                           step: try values.decodeIfPresent(Int.self, forKey: .step),
                           steps: try values.decodeIfPresent(Int.self, forKey: .steps))
        case .applying:
            self = .applying(step: try values.decodeIfPresent(Int.self, forKey: .step),
                             steps: try values.decodeIfPresent(Int.self, forKey: .steps))
        case .cherryPick: self = .cherryPick(try values.decode(String.self, forKey: .sha))
        case .revert: self = .revert(try values.decode(String.self, forKey: .sha))
        case .bisect: self = .bisect
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .merge(let shas):
            try values.encode(Kind.merge, forKey: .kind)
            try values.encode(shas, forKey: .shas)
        case .rebase(let branch, let step, let steps):
            try values.encode(Kind.rebase, forKey: .kind)
            try values.encodeIfPresent(branch, forKey: .branch)
            try values.encodeIfPresent(step, forKey: .step)
            try values.encodeIfPresent(steps, forKey: .steps)
        case .applying(let step, let steps):
            try values.encode(Kind.applying, forKey: .kind)
            try values.encodeIfPresent(step, forKey: .step)
            try values.encodeIfPresent(steps, forKey: .steps)
        case .cherryPick(let sha):
            try values.encode(Kind.cherryPick, forKey: .kind)
            try values.encode(sha, forKey: .sha)
        case .revert(let sha):
            try values.encode(Kind.revert, forKey: .kind)
            try values.encode(sha, forKey: .sha)
        case .bisect:
            try values.encode(Kind.bisect, forKey: .kind)
        }
    }
}

/// A branch's history, newest first, with its graph.
public struct GitLog: Codable, Equatable, Sendable {
    public var commits: [GitCommit] = []
    public var graph: [GitGraphRow] = []
    /// Why it couldn't be read.
    public var error: String?

    public init(commits: [GitCommit] = [], graph: [GitGraphRow] = [], error: String? = nil) {
        self.commits = commits
        self.graph = graph
        self.error = error
    }
}

/// A changed file, from `git status`: the index's letter (staged) and the
/// worktree's (unstaged), as lazygit shows them, and its line counts.
public struct GitChange: Equatable, Identifiable, Sendable {
    /// The diffs of a change, in the order the diff pane shows them:
    /// unstaged first, as in lazygit.
    public enum Group: String, CaseIterable, Codable, Sendable {
        case unstaged, staged, untracked

        public var title: String { rawValue.capitalized }
    }

    /// `M`, `A`, `D`, `R`, `C`, `T`, `U` for a conflict, `?` when
    /// untracked, or a space for no change.
    public let index: Character
    public let worktree: Character
    public let path: String
    /// Where a renamed or copied file came from.
    public var originalPath: String?
    /// Lines added and removed, staged and unstaged together; an untracked
    /// file's line count. Nil for a binary file.
    public var additions: Int?
    public var deletions: Int?

    public init(index: Character, worktree: Character, path: String, originalPath: String? = nil,
                additions: Int? = nil, deletions: Int? = nil) {
        self.index = index
        self.worktree = worktree
        self.path = path
        self.originalPath = originalPath
        self.additions = additions
        self.deletions = deletions
    }

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    /// `MM`, `A `, `??`, as `git status --short` writes it.
    public var status: String { "\(index)\(worktree)" }
    public var isUntracked: Bool { index == "?" }
    /// `UU`, `AA`, `DD`, or a `U` on one side.
    public var isConflict: Bool { index == "U" || worktree == "U" || (index == worktree && (index == "A" || index == "D")) }

    public var groups: [Group] {
        if isUntracked { return [.untracked] }
        if isConflict { return [.unstaged] }
        return (worktree != " " ? [.unstaged] : []) + (index != " " ? [.staged] : [])
    }

    /// Nothing left to stage: lazygit shows it green, the rest red.
    public var isStaged: Bool { groups == [.staged] }
}

extension GitChange: Codable {
    private enum CodingKeys: String, CodingKey {
        /// The two letters as `git status --short` writes them.
        case status, path
        case originalPath = "original_path"
        case additions, deletions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let status = Array(try values.decode(String.self, forKey: .status))
        guard status.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .status, in: values, debugDescription: "not two letters")
        }
        self.init(index: status[0], worktree: status[1], path: try values.decode(String.self, forKey: .path),
                  originalPath: try values.decodeIfPresent(String.self, forKey: .originalPath),
                  additions: try values.decodeIfPresent(Int.self, forKey: .additions),
                  deletions: try values.decodeIfPresent(Int.self, forKey: .deletions))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(status, forKey: .status)
        try values.encode(path, forKey: .path)
        try values.encodeIfPresent(originalPath, forKey: .originalPath)
        try values.encodeIfPresent(additions, forKey: .additions)
        try values.encodeIfPresent(deletions, forKey: .deletions)
    }
}

/// The current branch against its upstream, or against main without one.
public struct GitComparison: Codable, Equatable, Sendable {
    public let base: String
    public let ahead: Int
    public let behind: Int

    public init(base: String, ahead: Int, behind: Int) {
        self.base = base
        self.ahead = ahead
        self.behind = behind
    }
}

public struct GitBranch: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    /// The commit it's at.
    public let sha: String
    public let isHead: Bool
    public let upstream: String?
    /// `ahead 1, behind 2`, `gone`, or empty when in sync.
    public let track: String
    public let date: Date?
    /// Where the branch is checked out, if anywhere. A bare repository's HEAD is no checkout: it has no files.
    public let worktreePath: String?
    /// Commits the branch has that the current one doesn't, and the other
    /// way round.
    public var ahead = 0
    public var behind = 0

    public init(name: String, sha: String, isHead: Bool, upstream: String?, track: String, date: Date?, worktreePath: String?,
                ahead: Int = 0, behind: Int = 0) {
        self.name = name
        self.sha = sha
        self.isHead = isHead
        self.upstream = upstream
        self.track = track
        self.date = date
        self.worktreePath = worktreePath
        self.ahead = ahead
        self.behind = behind
    }

    private enum CodingKeys: String, CodingKey {
        case name, sha
        case isHead = "head"
        case upstream, track, date
        case worktreePath = "worktree_path"
        case ahead, behind
    }

    public var id: String { name }
    public var isInSync: Bool { upstream != nil && track.isEmpty }
}

public struct GitCommit: Codable, Equatable, Identifiable, Sendable {
    /// Like lazygit: red until pushed, yellow until in the main branch, then green.
    public enum Status: String, Codable, Equatable, Sendable { case unpushed, pushed, merged }

    public let sha: String
    public let author: String
    public let date: Date
    public let tags: [String]
    /// The branches at it: local, like `master`, and remote, like
    /// `origin/master`.
    public var refs: [String] = []
    public var remotes: [String] = []
    public var parents: [String] = []
    public let subject: String
    public var status = Status.merged

    public init(sha: String, author: String, date: Date, tags: [String], refs: [String] = [], remotes: [String] = [],
                parents: [String] = [], subject: String, status: Status = .merged) {
        self.sha = sha
        self.author = author
        self.date = date
        self.tags = tags
        self.refs = refs
        self.remotes = remotes
        self.parents = parents
        self.subject = subject
        self.status = status
    }

    public var id: String { sha }
    public var shortSHA: String { String(sha.prefix(8)) }
    public var isMerge: Bool { parents.count > 1 }

    /// `Yauhen Karatkou` → `YK`.
    public var initials: String {
        let words = author.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(author.prefix(2))
        return String(letters).uppercased()
    }
}

/// What the diff pane's header card says about a commit.
public struct GitCommitDetail: Equatable, Sendable {
    public let sha: String
    public let parents: [String]
    public let author: String
    public let email: String
    public let date: Date
    public let title: String
    public let body: String

    public init(sha: String, parents: [String], author: String, email: String, date: Date, title: String, body: String) {
        self.sha = sha
        self.parents = parents
        self.author = author
        self.email = email
        self.date = date
        self.title = title
        self.body = body
    }
}

public struct GitStash: Codable, Equatable, Identifiable, Sendable {
    /// `stash@{0}`.
    public let ref: String
    public let sha: String
    public let date: Date
    public let message: String

    public init(ref: String, sha: String, date: Date, message: String) {
        self.ref = ref
        self.sha = sha
        self.date = date
        self.message = message
    }

    public var id: String { sha }
}

/// Why the Git View has nothing to list, or why a read failed, in the words the Git View shows.
public struct GitViewError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(message: String) { self.message = message }

    public var errorDescription: String? { message }
}
