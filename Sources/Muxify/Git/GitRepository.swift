import Foundation
import MuxifyCore

/// What the Git View lists of a repository (CONTEXT.md): its status, changed
/// files, local branches, commits and stashes.
struct GitSnapshot: Equatable {
    /// The worktree's top folder.
    var root: String
    var repositoryName: String
    /// The folder of a linked worktree, when it isn't the repository's own.
    var worktreeName: String?
    /// The repository's own folder: where its main checkout is, or its git directory when it is bare. Topic records
    /// name a Worktree's repository by it.
    var repositoryFolder = ""
    /// The current branch, or the short commit of a detached HEAD.
    var head: String
    var isDetached = false
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// The changed files, as `git status` lists them.
    var changes: [GitChange] = []
    /// What the toolbar's ↑/↓ count against: the upstream, else main.
    var comparison: GitComparison?
    var branches: [GitBranch] = []
    /// The names of the remote branches, such as `origin/foo`, for `c` in Branches to suggest.
    var remoteBranches: [String] = []
    /// The branch that `git checkout -` goes back to, if it is still a branch.
    var previousBranch: String?
    var commits: [GitCommit] = []
    /// The History graph, a row per commit.
    var graph: [GitGraphRow] = []
    var stashes: [GitStash] = []
    /// `main` or `master`: what the current branch is compared with.
    var mainBranch: String?
    /// A merge, rebase or the like that git is in the middle of.
    var operation: GitOperation?
    /// git's message for the merge in progress, without its `#` lines.
    var mergeMessage: String?

    /// The current branch's history.
    var log: GitLog { GitLog(commits: commits, graph: graph) }

    /// A commit now concludes a merge.
    var isMerging: Bool {
        if case .merge? = operation { return true }
        return false
    }

    /// The toolbar's "Merging feature" or "Rebasing feature 3/7".
    var operationTitle: String? {
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
enum GitOperation: Equatable {
    /// The commits being merged in.
    case merge([String])
    /// The branch being rebased, and the step it's at of how many.
    case rebase(branch: String?, step: Int?, steps: Int?)
    case applying(step: Int?, steps: Int?)
    case cherryPick(String)
    case revert(String)
    case bisect

    /// Why A doesn't amend now, if it doesn't.
    var amendBlock: String? {
        switch self {
        case .merge: "A merge is in progress: conclude it with c first, then amend."
        case .rebase, .applying, .cherryPick, .revert:
            (commitBlock ?? "").replacingOccurrences(of: ": continue", with: ", so the last commit isn't amended: continue")
        case .bisect: nil
        }
    }

    /// Why c doesn't commit now, if it doesn't.
    var commitBlock: String? {
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
    var noun: String? {
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
    var command: String? {
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
    var canSkip: Bool {
        switch self {
        case .merge, .bisect: false
        case .rebase, .applying, .cherryPick, .revert: true
        }
    }

    /// An SF Symbol for it.
    var symbol: String {
        switch self {
        case .merge: "arrow.triangle.merge"
        case .rebase, .applying: "arrow.triangle.2.circlepath"
        case .cherryPick: "arrow.uturn.forward"
        case .revert: "arrow.uturn.backward"
        case .bisect: "magnifyingglass"
        }
    }
}

/// A branch's history, newest first, with its graph.
struct GitLog: Equatable {
    var commits: [GitCommit] = []
    var graph: [GitGraphRow] = []
    /// Why it couldn't be read.
    var error: String?
}

/// A changed file, from `git status`: the index's letter (staged) and the
/// worktree's (unstaged), as lazygit shows them, and its line counts.
struct GitChange: Equatable, Identifiable {
    /// The diffs of a change, in the order the diff pane shows them:
    /// unstaged first, as in lazygit.
    enum Group: String, CaseIterable {
        case unstaged, staged, untracked

        var title: String { rawValue.capitalized }
    }

    /// `M`, `A`, `D`, `R`, `C`, `T`, `U` for a conflict, `?` when
    /// untracked, or a space for no change.
    let index: Character
    let worktree: Character
    let path: String
    /// Where a renamed or copied file came from.
    var originalPath: String?
    /// Lines added and removed, staged and unstaged together; an untracked
    /// file's line count. Nil for a binary file.
    var additions: Int?
    var deletions: Int?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// `MM`, `A `, `??`, as `git status --short` writes it.
    var status: String { "\(index)\(worktree)" }
    var isUntracked: Bool { index == "?" }
    /// `UU`, `AA`, `DD`, or a `U` on one side.
    var isConflict: Bool { index == "U" || worktree == "U" || (index == worktree && (index == "A" || index == "D")) }

    var groups: [Group] {
        if isUntracked { return [.untracked] }
        if isConflict { return [.unstaged] }
        return (worktree != " " ? [.unstaged] : []) + (index != " " ? [.staged] : [])
    }

    /// Nothing left to stage: lazygit shows it green, the rest red.
    var isStaged: Bool { groups == [.staged] }
}

/// The current branch against its upstream, or against main without one.
struct GitComparison: Equatable {
    let base: String
    let ahead: Int
    let behind: Int
}

struct GitBranch: Equatable, Identifiable {
    let name: String
    /// The commit it's at.
    let sha: String
    let isHead: Bool
    let upstream: String?
    /// `ahead 1, behind 2`, `gone`, or empty when in sync.
    let track: String
    let date: Date?
    /// Where the branch is checked out, if anywhere.
    let worktreePath: String?
    /// Commits the branch has that the current one doesn't, and the other
    /// way round.
    var ahead = 0
    var behind = 0

    var id: String { name }
    var isInSync: Bool { upstream != nil && track.isEmpty }
}

struct GitCommit: Equatable, Identifiable {
    /// Like lazygit: red until pushed, yellow until in the main branch, then green.
    enum Status: Equatable { case unpushed, pushed, merged }

    let sha: String
    let author: String
    let date: Date
    let tags: [String]
    /// The branches at it: local, like `master`, and remote, like
    /// `origin/master`.
    var refs: [String] = []
    var remotes: [String] = []
    var parents: [String] = []
    let subject: String
    var status = Status.merged

    var id: String { sha }
    var shortSHA: String { String(sha.prefix(8)) }
    var isMerge: Bool { parents.count > 1 }

    /// `Yauhen Karatkou` → `YK`.
    var initials: String {
        let words = author.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(author.prefix(2))
        return String(letters).uppercased()
    }
}

/// What the diff pane's header card says about a commit.
struct GitCommitDetail: Equatable {
    let sha: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let title: String
    let body: String
}

struct GitStash: Equatable, Identifiable {
    /// `stash@{0}`.
    let ref: String
    let sha: String
    let date: Date
    let message: String

    var id: String { sha }
}

/// The git commands of the Git View, as /bin/sh scripts that run on the
/// Environment's machine, like Session Paths (ADR 0009).
enum GitRepository {
    /// How many commits the History, or a branch's commits, list.
    static let commitLimit = 300

    /// Takes the folder. Prints sections, each a line `\x1E<name>` and then
    /// its output; only `error` when the folder isn't in a repository.
    static let snapshotScript = """
    section() { printf '\\036%s\\n' "$1"; }
    cd "$1" 2>/dev/null || { section error; printf 'No such folder: %s\\n' "$1"; exit 0; }
    top=$(git rev-parse --show-toplevel 2>/dev/null) || { section error; printf 'Not a git repository: %s\\n' "$1"; exit 0; }
    cd "$top" || exit 1
    # Physical, like the common directory below, so a symlink isn't a worktree.
    top=$(pwd -P)
    export GIT_OPTIONAL_LOCKS=0
    g() { git -c core.quotepath=off -c color.ui=never "$@"; }
    section root; printf '%s\\n' "$top"
    section common; (cd "$(g rev-parse --git-common-dir)" && pwd -P)
    section head; g symbolic-ref -q --short HEAD || { printf 'detached '; g rev-parse -q --short HEAD; }
    section status; g status --porcelain=v1 --branch -z --untracked-files=all
    section unstaged; g diff --numstat -z --no-color --no-ext-diff 2>/dev/null
    section staged; g diff --cached --numstat -z -M --no-color --no-ext-diff 2>/dev/null
    section untracked; g ls-files -z --others --exclude-standard | xargs -0 wc -l 2>/dev/null
    section branches
    g for-each-ref --sort=-committerdate \\
        --format='%(HEAD)%00%(refname:short)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(worktreepath)%00%(objectname)' refs/heads
    section remotebranches; g for-each-ref --format='%(refname)' refs/remotes
    section previous; g rev-parse --abbrev-ref '@{-1}' 2>/dev/null
    \(mainRefs)
    rev=HEAD upstream='HEAD@{upstream}'
    \(logSections)
    section main; printf '%s\\n' "$main"
    section comparison
    if g rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
        printf '%s ' "$(g rev-parse --abbrev-ref '@{upstream}')"; g rev-list --left-right --count 'HEAD...@{upstream}' --
    elif [ -n "$main" ] && [ "$main" != "$(g symbolic-ref -q --short HEAD)" ]; then
        printf '%s ' "$main"; g rev-list --left-right --count "HEAD...$main" -- 2>/dev/null
    fi
    # Each branch against HEAD; git before 2.41 has no ahead-behind atom.
    section divergence
    g for-each-ref --format='%(refname:short) %(ahead-behind:HEAD)' refs/heads 2>/dev/null ||
        for branch in $(g for-each-ref --format='%(refname:short)' refs/heads); do
            printf '%s ' "$branch"; g rev-list --left-right --count "$branch...HEAD" -- 2>/dev/null || printf '\\n'
        done
    section stashes; g stash list --no-color --format='%gd%x00%H%x00%ct%x00%gs' 2>/dev/null
    # What git is in the middle of, from the files it keeps for it.
    section operation
    dir=$(g rev-parse --absolute-git-dir)
    fields() { for name in "$@"; do printf '%s\\n' "$(cat "$name" 2>/dev/null)"; done; }
    if [ -d "$dir/rebase-merge" ]; then
        printf 'rebase\\n'; fields "$dir/rebase-merge/head-name" "$dir/rebase-merge/msgnum" "$dir/rebase-merge/end"
    elif [ -d "$dir/rebase-apply" ]; then
        if [ -f "$dir/rebase-apply/applying" ]; then printf 'am\\n'; else printf 'rebase\\n'; fi
        fields "$dir/rebase-apply/head-name" "$dir/rebase-apply/next" "$dir/rebase-apply/last"
    elif [ -f "$dir/CHERRY_PICK_HEAD" ]; then
        printf 'cherry-pick\\n'; cat "$dir/CHERRY_PICK_HEAD"
    elif [ -f "$dir/REVERT_HEAD" ]; then
        printf 'revert\\n'; cat "$dir/REVERT_HEAD"
    elif [ -f "$dir/MERGE_HEAD" ]; then
        printf 'merge\\n'; cat "$dir/MERGE_HEAD"
        section merge_message; cat "$dir/MERGE_MSG" 2>/dev/null
    elif [ -f "$dir/BISECT_LOG" ]; then
        printf 'bisect\\n'
    fi
    exit 0
    """

    /// Takes the folder, then git's arguments.
    static let gitScript = """
    cd "$1" || exit 1
    shift
    export GIT_OPTIONAL_LOCKS=0
    exec git -c core.quotepath=off -c color.ui=never -c diff.mnemonicPrefix=false -c diff.noprefix=false "$@"
    """

    /// Takes the folder, a file or folder of the worktree, the path a file
    /// was renamed from, lines of context, and the groups to show, e.g.
    /// `unstaged staged`. Prints each group's patch after a line
    /// `\n\x1E<group>`.
    static let changeScript = """
    cd "$1" || exit 1
    path=$2 from=$3 context=${4:-3} groups=$5
    export GIT_OPTIONAL_LOCKS=0
    set -- -c core.quotepath=off -c color.ui=never -c diff.mnemonicPrefix=false -c diff.noprefix=false \\
        diff --no-color --no-ext-diff -U"$context"
    for group in $groups; do
        printf '\\n\\036%s\\n' "$group"
        case $group in
            unstaged) git "$@" -- "$path" ;;
            staged) if [ -n "$from" ]; then git "$@" --cached -M -- "$from" "$path"; else git "$@" --cached -M -- "$path"; fi ;;
            untracked) git ls-files -z --others --exclude-standard -- "$path" | xargs -0 -r -n 1 git "$@" --no-index -- /dev/null ;;
        esac
    done
    exit 0
    """

    /// Takes the folder and a commit. Prints its fields, `\x1F`, then its
    /// patch; a merge's against its first parent.
    static let commitScript = """
    cd "$1" || exit 1
    export GIT_OPTIONAL_LOCKS=0
    exec git -c core.quotepath=off -c color.ui=never -c diff.mnemonicPrefix=false -c diff.noprefix=false \\
        show --no-color --no-ext-diff -M -m --first-parent --format='%H%x00%P%x00%an%x00%ae%x00%at%x00%B%x1F' "$2" --
    """

    /// Takes the folder and a branch. Prints its history in the sections
    /// the snapshot prints the current branch's in.
    static let logScript = """
    section() { printf '\\036%s\\n' "$1"; }
    cd "$1" || exit 1
    # `refs/heads/x@{upstream}` isn't a branch's upstream; `x@{upstream}` is.
    rev=refs/heads/$2 upstream=$2@{upstream}
    export GIT_OPTIONAL_LOCKS=0
    g() { git -c core.quotepath=off -c color.ui=never "$@"; }
    \(mainRefs)
    \(logSections)
    exit 0
    """

    /// Sets `main` to `main` or `master`, and `refs` to the refs a commit
    /// is merged once it's in.
    private static let mainRefs = """
    main=
    refs=
    for name in main master; do
        if [ -z "$main" ] && g show-ref -q --verify "refs/heads/$name"; then main=$name; fi
    done
    for ref in refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
        if g show-ref -q --verify "$ref"; then refs="$refs $ref"; fi
    done
    """

    /// `$rev`'s commits, and which of them aren't in `$upstream` or merged
    /// yet.
    private static let logSections = """
    section commits
    g log -n \(commitLimit) --topo-order --decorate=full --no-color --format='%H%x00%an%x00%at%x00%D%x00%P%x00%s' "$rev" -- 2>/dev/null
    section unpushed
    if g rev-parse -q --verify "$upstream" >/dev/null 2>&1; then
        g rev-list -n \(commitLimit) "$rev" --not "$upstream" --
    else
        printf 'none\\n'
    fi
    section unmerged
    if [ -n "$refs" ]; then g rev-list -n \(commitLimit) "$rev" --not $refs -- 2>/dev/null; else printf 'none\\n'; fi
    """

    /// Takes the folder, then files and folders to stage, with everything
    /// in them: new, changed and deleted files. A conflicted file that
    /// still has conflict markers isn't staged, nor is anything with it.
    static let stageScript = """
    cd "$1" || exit 1
    shift
    export GIT_LITERAL_PATHSPECS=1
    marked=$(git -c core.quotepath=off diff --name-only -z --diff-filter=U -- "$@" |
        xargs -0 -r grep -l -E '^(<<<<<<<|>>>>>>>)( |$)|^=======$' -- 2>/dev/null)
    if [ -n "$marked" ]; then
        printf 'Still has conflict markers, so nothing was staged:\\n%s\\n' "$marked" >&2
        printf 'Resolve them, or stage it anyway with git add in the terminal.\\n' >&2
        exit 1
    fi
    exec git -c core.quotepath=off add -A -- "$@"
    """

    /// Takes the folder, then files and folders to unstage. Before the
    /// first commit there's no HEAD to reset them to.
    static let unstageScript = """
    cd "$1" || exit 1
    shift
    export GIT_LITERAL_PATHSPECS=1
    if git rev-parse -q --verify HEAD >/dev/null; then
        exec git -c core.quotepath=off reset -q -- "$@"
    fi
    exec git -c core.quotepath=off rm -q -r --cached --ignore-unmatch -- "$@"
    """

    /// Takes the folder, then files and folders to discard every change in,
    /// staged or not: tracked files go back to HEAD, and new and untracked
    /// ones are deleted. Paths are literal, so `app/[id]` isn't a pattern
    /// that takes `app/i` with it.
    static let discardScript = """
    cd "$1" || exit 1
    shift
    export GIT_LITERAL_PATHSPECS=1
    if git rev-parse -q --verify HEAD >/dev/null; then
        git reset -q -- "$@" || exit 1
    else
        git rm -q -r --cached --ignore-unmatch -- "$@" || exit 1
    fi
    for path in "$@"; do
        if [ -n "$(git ls-files -- "$path")" ]; then git checkout -q -- "$path" || exit 1; fi
    done
    exec git clean -f -d -q -- "$@"
    """

    /// Takes the folder, then files and folders to discard the unstaged
    /// changes in: tracked files go back to what's staged, and untracked
    /// ones are deleted.
    static let discardUnstagedScript = """
    cd "$1" || exit 1
    shift
    export GIT_LITERAL_PATHSPECS=1
    for path in "$@"; do
        if [ -n "$(git ls-files -- "$path")" ]; then git checkout -q -- "$path" || exit 1; fi
    done
    exec git clean -f -d -q -- "$@"
    """

    /// Takes the folder, `stage`, `unstage` or `discard`, a patch of some
    /// of a change's lines, and the new files it takes lines of. Applies
    /// it to the index, its reverse to the index, or its reverse to the
    /// worktree. git is first told the new files are coming, and if the
    /// patch doesn't apply, they're untracked again.
    static let applyPatchScript = """
    cd "$1" || exit 1
    mode=$2 patch=$3
    shift 3
    case $mode in
        stage) flags=--cached ;;
        unstage) flags='--cached -R' ;;
        *) flags=-R ;;
    esac
    export GIT_LITERAL_PATHSPECS=1
    if [ $# -gt 0 ]; then git add -N -- "$@" || exit 1; fi
    printf '%s' "$patch" | git apply --recount --whitespace=nowarn $flags - && exit 0
    if [ $# -gt 0 ]; then git rm -q -f --cached -- "$@"; fi
    exit 1
    """

    /// Takes the folder; amends the last commit with what's staged and keeps
    /// its message. Prints the commit's short hash; hooks' output goes to
    /// stderr, where a failure shows it.
    static let amendScript = """
    cd "$1" || exit 1
    git -c color.ui=never commit -q --amend --no-edit 1>&2 || exit 1
    git rev-parse --short HEAD
    """

    /// Takes the folder, the git command of what's in progress (`merge`, `rebase`, `am`, `cherry-pick` or `revert`)
    /// and one of `continue`, `skip` and `abort`. No editor opens, so git's message is kept. Git's own words, on
    /// stderr, say why it refused; when conflicts are left, a line says where to resolve them.
    static let operationScript = """
    cd "$1" || exit 1
    export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true
    git -c core.editor=true -c color.ui=never "$2" "--$3" 1>&2 && exit 0
    code=$?
    if [ "$3" != abort ] && [ -n "$(git diff --name-only --diff-filter=U)" ]; then
        printf 'Conflicts remain: resolve them in Changes and stage each file, then m continues again.\\n' >&2
    fi
    exit $code
    """

    /// Takes the folder and the message; commits what's staged. Prints the
    /// new commit's short hash; hooks' output goes to stderr, where a
    /// failure shows it.
    static let makeCommitScript = """
    cd "$1" || exit 1
    printf '%s\\n' "$2" | git -c color.ui=never commit -q -F - 1>&2 || exit 1
    git rev-parse --short HEAD
    """

    /// Takes the folder, one of `all`, `untracked`, `staged`, `unstaged` and
    /// `keepindex`, and the message, which may be empty. Stashes as `git
    /// stash push` does, which leaves untracked files except for `untracked`.
    /// `unstaged` is how lazygit does it: what's staged is committed for a
    /// moment, the rest is stashed, and the commit is undone, softly.
    static let stashScript = """
    cd "$1" || exit 1
    kind=$2 message=$3
    push() {
        flags=$1
        set -- push -q
        if [ -n "$flags" ]; then set -- "$@" "$flags"; fi
        if [ -n "$message" ]; then set -- "$@" -m "$message"; fi
        git stash "$@"
    }
    case $kind in
        all) push ;;
        untracked) push --include-untracked ;;
        keepindex) push --keep-index ;;
        staged)
            if ! git stash push -h 2>&1 | grep -q -e --staged; then
                echo "Stashing only what's staged needs git 2.35 or newer." >&2
                exit 1
            fi
            push --staged
            ;;
        unstaged)
            git rev-parse -q --verify HEAD >/dev/null || { echo "There is no commit yet to stash the unstaged changes against." >&2; exit 1; }
            if git diff --cached --quiet; then
                push
                exit $?
            fi
            git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --no-verify -m '[muxify] stashing unstaged changes' || exit 1
            push
            status=$?
            git reset -q --soft HEAD^ || exit 1
            exit $status
            ;;
        *) echo "Unknown stash option: $kind" >&2; exit 1 ;;
    esac
    """

    /// Takes the folder, `apply`, `pop` or `drop`, a stash's ref and its hash. Refuses when the ref is no longer the
    /// stash that was selected. A conflict leaves the conflicted files in the working tree, and the stash in the list
    /// even for a pop, as git does; it is told apart from other failures, which print what git said.
    static let stashEntryScript = """
    cd "$1" || exit 1
    action=$2 ref=$3 sha=$4
    if [ "$(git rev-parse -q --verify "$ref" 2>/dev/null)" != "$sha" ]; then
        echo "$ref is no longer the stash that was selected. Look at the stashes again." >&2
        exit 1
    fi
    if [ "$action" = drop ]; then exec git stash drop -q "$ref"; fi
    out=$(LC_ALL=C git stash "$action" "$ref" 2>&1)
    status=$?
    if [ $status -ne 0 ]; then
        if printf '%s\\n' "$out" | grep -q '^CONFLICT'; then
            echo "Applying $ref conflicted: the conflicted files are in Changes. The stash is kept." >&2
        else
            printf '%s\\n' "$out" >&2
        fi
        exit 1
    fi
    """

    /// Takes the folder, a branch and its new name.
    static let renameBranchScript = """
    cd "$1" || exit 1
    git branch -m -- "$2" "$3"
    """

    /// What the delete script's stderr is when `git branch -d` refused because the branch isn't fully merged.
    static let branchNotMergedMarker = "muxify:branch-not-merged"

    /// Takes the folder, a branch and `1` to force. Without force it tells a branch that git won't delete for not
    /// being fully merged from any other failure, which prints what git said, such as that another Worktree has it
    /// checked out. A Worktree is never removed.
    static let deleteBranchScript = """
    cd "$1" || exit 1
    if [ "$3" = 1 ]; then exec git branch -D -- "$2"; fi
    out=$(LC_ALL=C git branch -d -- "$2" 2>&1)
    status=$?
    if [ $status -ne 0 ]; then
        if printf '%s\\n' "$out" | grep -q 'is not fully merged'; then
            echo "\(branchNotMergedMarker)" >&2
        else
            printf '%s\\n' "$out" >&2
        fi
        exit 1
    fi
    """

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

    /// What the checkout script's stderr starts with when only Changes kept git from checking out.
    static let checkoutBlockedMarker = "muxify:changes-in-the-way"

    /// Takes the folder, `branch`, `remote`, `new`, `previous` or `commit`, the branch, the new branch's name or the
    /// commit, `1` to stash the changes first and pop them after, and for `new` the branch it is off of. `remote`
    /// makes a local branch that tracks the remote one, and `previous` is `git checkout -`. Without it, a checkout that Changes would be overwritten by fails with `checkoutBlockedMarker`, then
    /// git's message. A pop that conflicts keeps the stash, as git does, and says so.
    static let checkoutScript = """
    cd "$1" || exit 1
    kind=$2 target=$3 autostash=$4 base=$5
    if [ "$kind" = previous ] && ! git rev-parse -q --verify '@{-1}' >/dev/null 2>&1; then
        echo 'There is no previous branch to check out.' >&2
        exit 1
    fi
    checkout() {
        case "$kind" in
            branch) LC_ALL=C git checkout "$target" -- ;;
            remote) LC_ALL=C git checkout --track "$target" -- ;;
            new) LC_ALL=C git checkout -b "$target" "$base" -- ;;
            previous) LC_ALL=C git checkout - ;;
            *) LC_ALL=C git checkout --detach "$target" ;;
        esac
    }
    if [ "$autostash" != 1 ]; then
        out=$(checkout 2>&1) && exit 0
        if printf '%s\n' "$out" | grep -q 'would be overwritten by checkout'; then echo 'muxify:changes-in-the-way' >&2; fi
        printf '%s\n' "$out" >&2
        exit 1
    fi
    before=$(git rev-parse -q --verify refs/stash 2>/dev/null)
    git stash push -q --include-untracked -m "Autostash before checking out $target" || exit 1
    after=$(git rev-parse -q --verify refs/stash 2>/dev/null)
    if ! out=$(checkout 2>&1); then
        if [ "$after" != "$before" ]; then git stash pop -q >/dev/null 2>&1; fi
        printf '%s\n' "$out" >&2
        exit 1
    fi
    if [ "$after" != "$before" ] && ! git stash pop -q >/dev/null 2>&1; then
        echo "Checked out, but popping the stash conflicted: the conflicted files are in Changes. The stash is kept." >&2
        exit 1
    fi
    """

    // MARK: Parsing

    /// The snapshot, or what the Git View says instead of one.
    static func parseSnapshot(_ output: String) -> Result<GitSnapshot, GitViewError> {
        let sections = sections(output)
        if let error = sections["error"] {
            return .failure(GitViewError(message: error.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        guard let root = sections["root"].map(trimmed), !root.isEmpty else {
            return .failure(GitViewError(message: "Could not read the repository."))
        }
        let common = trimmed(sections["common"] ?? "")
        let headLine = trimmed(sections["head"] ?? "")
        let isDetached = headLine.hasPrefix("detached ")
        var snapshot = GitSnapshot(
            root: root,
            repositoryName: repositoryName(root: root, commonDirectory: common),
            worktreeName: worktreeName(root: root, commonDirectory: common),
            head: isDetached ? String(headLine.dropFirst("detached ".count)) : headLine,
            isDetached: isDetached
        )
        if !common.isEmpty {
            snapshot.repositoryFolder = (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent : common
        }
        let status = parseStatus(sections["status"] ?? "")
        snapshot.changes = counted(status.changes, staged: parseNumstat(sections["staged"] ?? ""),
                                   unstaged: parseNumstat(sections["unstaged"] ?? ""),
                                   untracked: parseLineCounts(sections["untracked"] ?? ""))
        snapshot.upstream = status.upstream
        snapshot.ahead = status.ahead
        snapshot.behind = status.behind
        // The current branch first, as lazygit lists it.
        let divergence = parseDivergence(sections["divergence"] ?? "")
        let branches = parseBranches(sections["branches"] ?? "").map { branch in
            var branch = branch
            (branch.ahead, branch.behind) = divergence[branch.name] ?? (0, 0)
            return branch
        }
        snapshot.branches = branches.filter(\.isHead) + branches.filter { !$0.isHead }
        snapshot.remoteBranches = parseRemoteBranches(sections["remotebranches"] ?? "")
        let previous = trimmed(sections["previous"] ?? "")
        snapshot.previousBranch = branches.contains { $0.name == previous } ? previous : nil
        snapshot.comparison = parseComparison(sections["comparison"] ?? "")
        let main = trimmed(sections["main"] ?? "")
        snapshot.mainBranch = main.isEmpty ? nil : main
        let log = log(sections)
        snapshot.commits = log.commits
        snapshot.graph = log.graph
        snapshot.stashes = parseStashes(sections["stashes"] ?? "")
        snapshot.operation = parseOperation(sections["operation"] ?? "")
        snapshot.mergeMessage = sections["merge_message"].map(parseMergeMessage)
        return .success(snapshot)
    }

    /// `logScript`'s output.
    static func parseLog(_ output: String) -> GitLog {
        log(sections(output))
    }

    /// Each section's output by name.
    private static func sections(_ output: String) -> [String: String] {
        var sections: [String: String] = [:]
        for chunk in output.components(separatedBy: "\u{1E}").dropFirst() {
            let parts = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            sections[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        return sections
    }

    private static func log(_ sections: [String: String]) -> GitLog {
        let commits = parseCommits(sections["commits"] ?? "", unpushed: shaSet(sections["unpushed"]),
                                   unmerged: shaSet(sections["unmerged"]))
        return GitLog(commits: commits, graph: GitGraphRow.layout(commits))
    }

    /// `git for-each-ref refs/remotes`, as `origin/foo`; a remote's `HEAD` is no branch.
    static func parseRemoteBranches(_ output: String) -> [String] {
        let prefix = "refs/remotes/"
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(prefix), !line.hasSuffix("/HEAD") else { return nil }
            return String(line.dropFirst(prefix.count))
        }
    }

    /// `git status --porcelain=v1 --branch -z`.
    static func parseStatus(_ output: String) -> (changes: [GitChange], upstream: String?, ahead: Int, behind: Int) {
        var fields = output.components(separatedBy: "\0")[...]
        var upstream: String?
        var ahead = 0
        var behind = 0
        if let first = fields.first, first.hasPrefix("## ") {
            fields = fields.dropFirst()
            let line = first.dropFirst(3)
            let names = line.split(separator: " ", maxSplits: 1).first ?? ""
            if let range = names.range(of: "...") { upstream = String(names[range.upperBound...]) }
            if let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]"), open < close {
                for part in line[line.index(after: open)..<close].split(separator: ",") {
                    let words = part.split(separator: " ")
                    guard words.count == 2, let count = Int(words[1]) else { continue }
                    if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
                }
            }
        }
        var changes: [GitChange] = []
        while let field = fields.popFirst() {
            let characters = Array(field)
            guard characters.count > 3 else { continue }
            var change = GitChange(index: characters[0], worktree: characters[1], path: String(characters[3...]))
            if "RC".contains(change.index) || "RC".contains(change.worktree) { change.originalPath = fields.popFirst() }
            changes.append(change)
        }
        return (changes, upstream, ahead, behind)
    }

    /// The changes with their line counts: staged and unstaged added up,
    /// nil when a side is binary.
    static func counted(_ changes: [GitChange], staged: [String: (Int?, Int?)], unstaged: [String: (Int?, Int?)],
                        untracked: [String: Int]) -> [GitChange] {
        changes.map { change in
            var change = change
            if change.isUntracked {
                change.additions = untracked[change.path]
                change.deletions = 0
                return change
            }
            let counts = change.groups.compactMap { ($0 == .staged ? staged : unstaged)[change.path] }
            guard !counts.contains(where: { $0.0 == nil || $0.1 == nil }) else { return change }
            change.additions = counts.reduce(0) { $0 + ($1.0 ?? 0) }
            change.deletions = counts.reduce(0) { $0 + ($1.1 ?? 0) }
            return change
        }
    }

    /// `changeScript`'s output: each group's patch.
    static func parseParts(_ output: String) -> [(group: GitChange.Group, patch: String)] {
        output.components(separatedBy: "\n\u{1E}").dropFirst().compactMap { chunk in
            let parts = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let group = GitChange.Group(rawValue: String(parts[0])) else { return nil }
            return (group, parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// `git diff --numstat -z`: lines added and removed by path; nil for
    /// a binary file's `-`.
    static func parseNumstat(_ output: String) -> [String: (Int?, Int?)] {
        var fields = output.components(separatedBy: "\0")[...]
        var counts: [String: (Int?, Int?)] = [:]
        while let field = fields.popFirst() {
            let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            // A rename: the old path and the new one follow.
            if path.isEmpty {
                _ = fields.popFirst()
                path = fields.popFirst() ?? ""
            }
            counts[path] = (Int(parts[0]), Int(parts[1]))
        }
        return counts
    }

    /// `wc -l` of the untracked files.
    static func parseLineCounts(_ output: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.drop { $0 == " " }.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[0]), parts[1] != "total" else { continue }
            counts[String(parts[1])] = count
        }
        return counts
    }

    /// `master 2 14`: ahead and behind HEAD, by branch.
    static func parseDivergence(_ output: String) -> [String: (Int, Int)] {
        var counts: [String: (Int, Int)] = [:]
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count == 3, let ahead = Int(words[1]), let behind = Int(words[2]) else { continue }
            counts[String(words[0])] = (ahead, behind)
        }
        return counts
    }

    static func parseComparison(_ output: String) -> GitComparison? {
        let words = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard words.count == 3, let ahead = Int(words[1]), let behind = Int(words[2]) else { return nil }
        return GitComparison(base: String(words[0]), ahead: ahead, behind: behind)
    }

    static func parseBranches(_ output: String) -> [GitBranch] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count >= 7, !fields[1].isEmpty else { return nil }
            return GitBranch(
                name: fields[1], sha: fields[6], isHead: fields[0] == "*",
                upstream: fields[2].isEmpty ? nil : fields[2], track: fields[3],
                date: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)),
                worktreePath: fields[5].isEmpty ? nil : fields[5]
            )
        }
    }

    /// `unpushed` and `unmerged` are nil when there is no upstream or no
    /// main branch to compare with.
    static func parseCommits(_ output: String, unpushed: Set<String>?, unmerged: Set<String>?) -> [GitCommit] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count >= 6, fields[0].count >= 7 else { return nil }
            let sha = fields[0]
            let refs = decorations(fields[3])
            var commit = GitCommit(
                sha: sha, author: fields[1],
                date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                tags: refs.tags, refs: refs.branches, remotes: refs.remotes,
                parents: fields[4].split(separator: " ").map(String.init),
                subject: fields[5...].joined(separator: " ")
            )
            // Without an upstream, everything not yet in the main branch is unpushed.
            if unpushed?.contains(sha) ?? (unmerged?.contains(sha) ?? true) {
                commit.status = .unpushed
            } else if unmerged?.contains(sha) ?? true {
                commit.status = .pushed
            }
            return commit
        }
    }

    /// `%D` with `--decorate=full`: `HEAD -> refs/heads/master,
    /// tag: refs/tags/v1, refs/remotes/origin/master`. A detached `HEAD`
    /// and `origin/HEAD` are left out.
    static func decorations(_ text: String) -> (tags: [String], branches: [String], remotes: [String]) {
        var refs: (tags: [String], branches: [String], remotes: [String]) = ([], [], [])
        for decoration in text.components(separatedBy: ", ") where !decoration.isEmpty {
            let name = decoration.hasPrefix("HEAD -> ") ? String(decoration.dropFirst("HEAD -> ".count)) : decoration
            if name.hasPrefix("tag: ") {
                let tag = name.dropFirst("tag: ".count)
                refs.tags.append(String(tag.hasPrefix("refs/tags/") ? tag.dropFirst("refs/tags/".count) : tag))
            } else if name.hasPrefix("refs/remotes/") {
                if !name.hasSuffix("/HEAD") { refs.remotes.append(String(name.dropFirst("refs/remotes/".count))) }
            } else if name.hasPrefix("refs/heads/") {
                refs.branches.append(String(name.dropFirst("refs/heads/".count)))
            } else if name != "HEAD", !name.hasSuffix("/HEAD") {
                refs.branches.append(name)
            }
        }
        return refs
    }

    static func parseStashes(_ output: String) -> [GitStash] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count >= 4 else { return nil }
            return GitStash(ref: fields[0], sha: fields[1],
                            date: Date(timeIntervalSince1970: TimeInterval(fields[2]) ?? 0),
                            message: fields[3...].joined(separator: " "))
        }
    }

    /// The snapshot's `operation` section: what it is, then its fields a
    /// line each.
    static func parseOperation(_ output: String) -> GitOperation? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { trimmed(String($0)) }
        func field(_ index: Int) -> String? { lines.indices.contains(index) && !lines[index].isEmpty ? lines[index] : nil }
        // `refs/heads/feature`, or `detached HEAD`.
        let branch = field(1).flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        switch lines.first {
        case "rebase": return .rebase(branch: branch, step: field(2).flatMap { Int($0) }, steps: field(3).flatMap { Int($0) })
        case "am": return .applying(step: field(2).flatMap { Int($0) }, steps: field(3).flatMap { Int($0) })
        case "cherry-pick": return field(1).map(GitOperation.cherryPick)
        case "revert": return field(1).map(GitOperation.revert)
        case "merge": return .merge(lines.dropFirst().filter { !$0.isEmpty })
        case "bisect": return .bisect
        default: return nil
        }
    }

    /// `MERGE_MSG` without the lines git comments out, such as the
    /// conflicts it lists.
    static func parseMergeMessage(_ text: String) -> String {
        trimmed(text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }.joined(separator: "\n"))
    }

    /// `git show` with `commitScript`'s format: the commit, then its patch.
    static func parseCommitDetail(_ output: String) -> (detail: GitCommitDetail?, patch: String) {
        guard let separator = output.firstIndex(of: "\u{1F}") else { return (nil, output) }
        let fields = output[..<separator].components(separatedBy: "\0")
        guard fields.count >= 6 else { return (nil, String(output[output.index(after: separator)...])) }
        let message = fields[5...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let detail = GitCommitDetail(
            sha: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
            parents: fields[1].split(separator: " ").map(String.init),
            author: fields[2], email: fields[3],
            date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
            title: String(lines.first ?? ""),
            body: lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        )
        return (detail, String(output[output.index(after: separator)...]))
    }

    /// lazygit's ages: `45s`, `3m`, `2h`, `5d`, `1w`, `4M`, `2y`.
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let units: [(String, Int)] = [("y", 31_536_000), ("M", 2_592_000), ("w", 604_800), ("d", 86_400), ("h", 3_600), ("m", 60)]
        for (unit, length) in units where seconds >= length { return "\(seconds / length)\(unit)" }
        return "\(seconds)s"
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shaSet(_ section: String?) -> Set<String>? {
        guard let section, trimmed(section) != "none" else { return nil }
        return Set(section.split(separator: "\n").map(String.init))
    }

    /// The main worktree's folder: `.git`'s parent, or a bare repository's
    /// own folder.
    private static func repositoryName(root: String, commonDirectory: String) -> String {
        guard !commonDirectory.isEmpty else { return (root as NSString).lastPathComponent }
        let common = commonDirectory as NSString
        let folder = common.lastPathComponent == ".git" ? common.deletingLastPathComponent : commonDirectory
        let name = (folder as NSString).lastPathComponent
        return name.hasSuffix(".git") && name.count > 4 ? String(name.dropLast(4)) : name
    }

    private static func worktreeName(root: String, commonDirectory: String) -> String? {
        guard !commonDirectory.isEmpty, (commonDirectory as NSString).lastPathComponent == ".git" else { return nil }
        let main = (commonDirectory as NSString).deletingLastPathComponent
        let name = (root as NSString).lastPathComponent
        return Folder(path: root, real: root) == Folder(path: main, real: main) ? nil : name
    }
}

/// Why the Git View has nothing to list.
struct GitViewError: Error, Equatable {
    let message: String
}
