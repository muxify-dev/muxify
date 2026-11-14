import Foundation
import MuxifyCore

/// The Git View's network commands, as /bin/sh scripts that run in a pseudo-terminal on the Environment's machine, so
/// git's questions for credentials are asked in the Git View. Its reads are `GitRead` and its other writes `GitWrite`,
/// both in MuxifyCore.
enum GitRepository {
    /// Takes the folder and a local branch, and deletes the branch it tracks on its remote with
    /// `git push <remote> --delete <branch>`. It runs in a pseudo-terminal, so credential questions are asked in the Git View.
    static let deleteRemoteBranchScript = """
    cd "$1" || exit 1
    remote=$(git config "branch.$2.remote") || { echo "'$2' has no remote branch." >&2; exit 1; }
    ref=$(git config "branch.$2.merge") || { echo "'$2' has no remote branch." >&2; exit 1; }
    if [ "$remote" = . ]; then echo "'$2' tracks a local branch, not a remote one." >&2; exit 1; fi
    exec git push "$remote" --delete "${ref#refs/heads/}"
    """

    /// Takes the folder and fetches all remotes, as lazygit's `f` does by default. It runs in a pseudo-terminal
    /// (`TerminalCommand`), so git's and ssh's questions for credentials are asked in the Git View.
    static let fetchScript = """
    cd "$1" || exit 1
    exec git fetch --all
    """

    /// Takes the folder, `plain`, `upstream` or `force`, and for `upstream` a remote and a branch. `upstream` pushes
    /// the current branch to that branch and sets it as the upstream; `force` is `--force-with-lease`, which stops when
    /// the remote branch isn't where the last fetch saw it. It runs in a pseudo-terminal, as the fetch does.
    static let pushScript = """
    cd "$1" || exit 1
    case "$2" in
        upstream) exec git push --set-upstream "$3" "HEAD:refs/heads/$4" ;;
        force) exec git push --force-with-lease ;;
        *) exec git push ;;
    esac
    """

    /// Takes the folder, `plain` or `upstream`, and for `upstream` a remote and a branch to pull, which then become
    /// the upstream. A plain pull follows the user's git config, such as `pull.rebase`; `--no-edit` keeps a merge from
    /// waiting for an editor. A pull that conflicts leaves the merge or rebase in progress, with the conflicts in
    /// Changes, and says so; any other failure prints what git said.
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


    /// lazygit's ages: `45s`, `3m`, `2h`, `5d`, `1w`, `4M`, `2y`.
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let units: [(String, Int)] = [("y", 31_536_000), ("M", 2_592_000), ("w", 604_800), ("d", 86_400), ("h", 3_600), ("m", 60)]
        for (unit, length) in units where seconds >= length { return "\(seconds / length)\(unit)" }
        return "\(seconds)s"
    }
}
