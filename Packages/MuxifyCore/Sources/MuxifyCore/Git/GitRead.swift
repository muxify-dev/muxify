import Foundation

/// One of the Git View's reads (ADR 0085), with the inputs it had as a script. The Mac runs it through its
/// App Window's `EnvironmentLink`: `GitReader` in-process for the Local Environment, a `git` request to the Host Server
/// for a Host. Its JSON is `{"<case>": {<its values>}}`.
public enum GitRead: Codable, Equatable, Sendable {
    /// The repository of the folder, answered as a `GitSnapshot`. A folder in no repository fails with the Git View's
    /// "Not a git repository" message.
    case status(folder: String)
    /// A branch's history, answered as a `GitLog`.
    case log(root: String, branch: String)
    /// A change's or a folder's diff, `groups` in the order the diff pane shows them, each after a line `\n\x1E<group>`;
    /// `from` is where a renamed file came from. Answered as text, streamed.
    case change(root: String, path: String, from: String?, context: Int, groups: [GitChange.Group])
    /// The diff between two commits, answered as text, streamed.
    case range(root: String, from: String, to: String)
    /// A commit's fields, `\x1F`, then its patch, as `GitReads.parseCommitDetail` reads them, streamed.
    case commit(root: String, sha: String)
    /// A stash's patch, streamed.
    case stash(root: String, sha: String)
    /// A local branch's upstream remote URL and branch, for its pull request page, answered as a `GitRemote`.
    case upstream(root: String, branch: String)
    /// The URL of `origin`, or of the only remote, for a commit's page, answered as a `GitRemote`.
    case origin(root: String)
    /// Whether a file of the working tree is still there, before `e` opens it: answered as the text `present` or
    /// `missing`.
    case fileExists(path: String)

    /// What the read answers.
    public enum Answer: Sendable {
        case snapshot, log, text, remote
    }

    public var answer: Answer {
        switch self {
        case .status: .snapshot
        case .log: .log
        case .change, .range, .commit, .stash, .fileExists: .text
        case .upstream, .origin: .remote
        }
    }

    /// How long the read may take, as each script had it.
    public var timeout: TimeInterval {
        switch answer {
        case .remote: 10
        case .snapshot, .log, .text: 30
        }
    }
}

/// A remote of a repository, for the Git View's links: its URL with `insteadOf` rules applied, as git prints it, and
/// the upstream branch's name for a pull request.
public struct GitRemote: Codable, Equatable, Sendable {
    public var url: String
    public var branch: String?

    public init(url: String, branch: String? = nil) {
        self.url = url
        self.branch = branch
    }
}

/// What a `GitRead` answered.
public enum GitAnswer: Equatable, Sendable {
    case snapshot(GitSnapshot)
    case log(GitLog)
    case text(String)
    case remote(GitRemote)

    public var snapshot: GitSnapshot? { if case .snapshot(let value) = self { value } else { nil } }
    public var log: GitLog? { if case .log(let value) = self { value } else { nil } }
    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var remote: GitRemote? { if case .remote(let value) = self { value } else { nil } }
}

/// Runs the Git View's reads on this machine: the scripts of `GitReads`, parsed. The Local link runs it in-process;
/// the Host Server runs it for its `git` requests.
public struct GitReader: Sendable {
    private let scripts: ScriptRunning

    public init(scripts: ScriptRunning = LocalScripts()) {
        self.scripts = scripts
    }

    /// The answer, or the error the Git View shows: a `GitViewError`, or the script's `TmuxError`.
    public func run(_ read: GitRead) throws -> GitAnswer {
        switch read {
        case .status(let folder):
            return .snapshot(try GitReads.parseSnapshot(script(GitReads.snapshotScript, [folder], read)).get())
        case .log(let root, let branch):
            return .log(GitReads.parseLog(try script(GitReads.logScript, [root, branch], read)))
        case .change(let root, let path, let from, let context, let groups):
            return .text(try script(GitReads.changeScript, [root, path, from ?? "", String(context),
                                                            groups.map(\.rawValue).joined(separator: " ")], read))
        case .range(let root, let from, let to):
            return .text(try script(GitReads.gitScript, [root, "diff", "--no-color", "--no-ext-diff", "-M", from, to, "--"], read))
        case .commit(let root, let sha):
            return .text(try script(GitReads.commitScript, [root, sha], read))
        case .stash(let root, let sha):
            return .text(try script(GitReads.gitScript, [root, "stash", "show", "--patch", "--no-color", "--no-ext-diff", "-M", sha],
                                    read))
        case .upstream(let root, let branch):
            let lines = try script(GitReads.pullRequestLinkScript, [root, branch], read)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.count >= 2 else { throw GitViewError(message: GitHosting.Failure.noUpstream.message) }
            return .remote(GitRemote(url: lines[0], branch: lines[1]))
        case .origin(let root):
            return .remote(GitRemote(url: try script(GitReads.commitLinkScript, [root], read)))
        case .fileExists(let path):
            return .text(FileManager.default.fileExists(atPath: path) ? "present" : "missing")
        }
    }

    /// The header's HEAD read of a folder.
    public func head(_ folder: String) -> GitHeadRead {
        GitHeadRead(Result { try scripts.runScript(GitHeadRead.script, arguments: [folder], timeout: 5) })
    }

    /// What the `repository` subscription compares: HEAD, the git directories and a fingerprint of the status.
    public func probe(_ folder: String) -> RepositoryProbe {
        RepositoryProbe(Result { try scripts.runScript(RepositoryProbe.script, arguments: [folder], timeout: 5) })
    }

    private func script(_ script: String, _ arguments: [String], _ read: GitRead) throws -> String {
        try scripts.runScript(script, arguments: arguments, timeout: read.timeout)
    }

    /// What the Git View says for a read that failed.
    public static func message(for error: Error) -> String {
        switch error {
        case let error as GitViewError: return error.message
        case TmuxError.failed(_, let stderr): return stderr.isEmpty ? "git failed." : stderr
        case TmuxError.timedOut: return "git took too long to answer."
        default: return String(describing: error)
        }
    }
}

/// What the `repository` subscription subscribes to: the folder of a Git View or of the header's HEAD read.
public struct RepositorySubscription: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) { self.path = path }
}

/// An event of the `repository` subscription: HEAD as the header shows it, and whether HEAD, the index or the working
/// tree changed since the event before, so the Git View and the header read again.
public struct RepositoryEvent: Codable, Equatable, Sendable {
    /// The branch, or the short commit of a detached HEAD; nil in no repository.
    public var head: String?
    /// Whether the folder is in a repository.
    public var repository: Bool
    /// False on the first event, which is the whole state; true on each change after it.
    public var changed: Bool

    public init(head: String?, repository: Bool, changed: Bool) {
        self.head = head
        self.repository = repository
        self.changed = changed
    }

    public init(_ read: GitHeadRead, changed: Bool) {
        self.init(head: read.head, repository: read.isRepository == true, changed: changed)
    }

    /// The event as the header's HEAD read.
    public var headRead: GitHeadRead { repository ? .repository(head: head) : .notRepository }
}

/// One probe of a folder: HEAD, the folders whose changes the `repository` subscription watches, and a fingerprint
/// of HEAD's commit and branch, the index's modification time and a checksum of the status (ADR 0072's probe).
public struct RepositoryProbe: Equatable, Sendable {
    public var head: GitHeadRead
    /// The top folder of the working tree.
    public var root: String?
    /// The Worktree's own git directory: HEAD and the index.
    public var gitDirectory: String?
    /// The common git directory: the refs.
    public var commonDirectory: String?
    public var fingerprint: String?

    /// Takes the folder. Prints the sections of `GitHeadRead.script`, then `directories` (the git directory, the common
    /// git directory and the top folder, a line each) and `probe`. `GIT_OPTIONAL_LOCKS=0`, so its `git status` never
    /// rewrites the index, which would change the index's time on every probe and wake the watch.
    static let script = """
    cd "$1" 2>/dev/null || exit 0
    command -v git >/dev/null 2>&1 || exit 0
    export GIT_OPTIONAL_LOCKS=0
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { printf '\\036none\\n'; exit 0; }
    printf '\\036head\\n'
    git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true
    printf '\\036directories\\n'
    git rev-parse --absolute-git-dir 2>/dev/null || echo
    (cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || echo
    printf '%s\\n' "$top"
    printf '\\036probe\\n'
    git rev-parse -q --verify HEAD 2>/dev/null
    git symbolic-ref -q HEAD 2>/dev/null
    index=$(git rev-parse --git-path index 2>/dev/null)
    stat -c %y "$index" 2>/dev/null || stat -f %Fm "$index" 2>/dev/null
    git -c core.quotepath=off status --porcelain=v1 --branch -z --untracked-files=all 2>/dev/null | cksum
    """

    public init(head: GitHeadRead, root: String? = nil, gitDirectory: String? = nil, commonDirectory: String? = nil,
                fingerprint: String? = nil) {
        self.head = head
        self.root = root
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
        self.fingerprint = fingerprint
    }

    init(_ result: Result<String, Error>) {
        self.init(head: GitHeadRead(result))
        guard case .success(let output) = result, head.isRepository == true else { return }
        let sections = GitReads.sections(output)
        let directories = (sections["directories"] ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func line(_ index: Int) -> String? { directories.indices.contains(index) && !directories[index].isEmpty ? directories[index] : nil }
        gitDirectory = line(0)
        commonDirectory = line(1)
        root = line(2)
        fingerprint = sections["probe"]
    }
}
