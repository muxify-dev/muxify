import Foundation

/// One of the Git View's commands that talk to a remote: fetch, push, pull and deleting a remote branch (ADR 0089,
/// Credentials). It runs on the repository's machine, through `GitNetworkRunner`: in-process for the Local Environment,
/// as a `git_network` request to the Host Server for a Host. git's and ssh's questions, such as a passphrase, come back
/// through askpass and are asked in the Git View. Its JSON is `{"<case>": {<its values>}}`, and it answers what git
/// printed.
public enum GitNetwork: Codable, Equatable, Sendable {
    /// Fetches all remotes, as lazygit's `f` does by default.
    case fetch(root: String)
    /// Pushes the branch you're on. `upstream` pushes it to `branch` on `remote` and sets that as its upstream; `force`
    /// is `--force-with-lease`, which stops when the remote branch isn't where the last fetch saw it.
    case push(root: String, mode: Mode, remote: String, branch: String)
    /// Pulls the branch you're on, following the user's git config, such as `pull.rebase`. `upstream` pulls `branch`
    /// from `remote`, which then becomes its upstream. A pull that conflicts leaves the merge or rebase in progress and
    /// says so.
    case pull(root: String, mode: Mode, remote: String, branch: String)
    /// Deletes the branch that a local branch tracks on its remote, with `git push <remote> --delete <branch>`.
    case deleteRemoteBranch(root: String, branch: String)

    public enum Mode: String, Codable, Sendable { case plain, upstream, force }

    /// The name of the Action, as a message about it says it: "<Environment> disconnected before Push finished."
    public var action: String {
        switch self {
        case .fetch: "Fetch"
        case .push: "Push"
        case .pull: "Pull"
        case .deleteRemoteBranch: "Delete Remote Branch"
        }
    }

    /// How long it may take, a question included: the user may take a while to find a passphrase.
    public var timeout: TimeInterval { 600 }

    /// The script that does it, and its arguments.
    var script: (text: String, arguments: [String]) {
        switch self {
        case .fetch(let root): (Self.fetchScript, [root])
        case .push(let root, let mode, let remote, let branch): (Self.pushScript, [root, mode.rawValue, remote, branch])
        case .pull(let root, let mode, let remote, let branch): (Self.pullScript, [root, mode.rawValue, remote, branch])
        case .deleteRemoteBranch(let root, let branch): (Self.deleteRemoteBranchScript, [root, branch])
        }
    }

    /// Takes the folder and a local branch, and deletes the branch it tracks on its remote.
    static let deleteRemoteBranchScript = """
    cd "$1" || exit 1
    remote=$(git config "branch.$2.remote") || { echo "'$2' has no remote branch." >&2; exit 1; }
    ref=$(git config "branch.$2.merge") || { echo "'$2' has no remote branch." >&2; exit 1; }
    if [ "$remote" = . ]; then echo "'$2' tracks a local branch, not a remote one." >&2; exit 1; fi
    exec git push "$remote" --delete "${ref#refs/heads/}"
    """

    /// Takes the folder and fetches all remotes.
    static let fetchScript = """
    cd "$1" || exit 1
    exec git fetch --all
    """

    /// Takes the folder, `plain`, `upstream` or `force`, and for `upstream` a remote and a branch.
    static let pushScript = """
    cd "$1" || exit 1
    case "$2" in
        upstream) exec git push --set-upstream "$3" "HEAD:refs/heads/$4" ;;
        force) exec git push --force-with-lease ;;
        *) exec git push ;;
    esac
    """

    /// Takes the folder, `plain` or `upstream`, and for `upstream` a remote and a branch. `--no-edit` keeps a merge from
    /// waiting for an editor. A pull that conflicts says so; any other failure prints what git said.
    static let pullScript = """
    cd "$1" || exit 1
    mode=$2 remote=$3 branch=$4
    if [ "$mode" = upstream ]; then set -- pull --no-edit "$remote" "$branch"; else set -- pull --no-edit; fi
    out=$(git "$@" 2>&1)
    status=$?
    if [ $status -ne 0 ]; then
        if [ -e "$(git rev-parse --git-path MERGE_HEAD)" ]; then
            echo "Pulling conflicted: the merge is in progress, with the conflicted files in Changes." >&2
        elif [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
            echo "Pulling conflicted: the rebase is in progress, with the conflicted files in Changes." >&2
        else
            printf '%s\\n' "$out" >&2
        fi
        exit 1
    fi
    if [ "$mode" = upstream ]; then git branch --set-upstream-to="$remote/$branch" >/dev/null 2>&1; fi
    exit 0
    """
}

/// A `git_network` request: the command, and the operation that its askpass questions name, so the Mac asks each in the
/// Git View that started it.
public struct GitNetworkRequest: Codable, Equatable, Sendable {
    public var network: GitNetwork
    public var operation: String

    public init(network: GitNetwork, operation: String) {
        self.network = network
        self.operation = operation
    }
}
