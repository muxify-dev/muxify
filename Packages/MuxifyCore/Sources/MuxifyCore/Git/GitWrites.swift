import Foundation

/// The scripts of the Git View's writes, which `GitWriter` runs on the repository's machine: in-process for the Local
/// Environment, in the Host Server for a Host. Only a `GitWrite` crosses the wire, never these (ADR 0085).
public enum GitWrites {
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

    /// Takes the folder, a branch, how to merge it (`ff`, `no-ff`, `squash` or `squash-leave`) and the branch it goes
    /// into, for the words. No editor opens, so git's message is kept. A merge that conflicts is told apart from
    /// other failures, which print what git said: the conflicts are left in the working tree, and a `ff` or `no-ff`
    /// merge stays in progress, as git does. A squash is no merge in git's eyes, so only the conflicts remain.
    /// `squash` commits what it took, with the message git prepared; `squash-leave` leaves it staged.
    static let mergeScript = """
    cd "$1" || exit 1
    branch=$2 kind=$3 into=$4
    export GIT_EDITOR=true GIT_MERGE_AUTOEDIT=no
    case $kind in
        ff) set -- --ff ;;
        no-ff) set -- --no-ff ;;
        squash|squash-leave) set -- --squash --ff ;;
        *) echo "Unknown merge: $kind" >&2; exit 1 ;;
    esac
    out=$(LC_ALL=C git -c color.ui=never merge --no-edit "$@" "$branch" 2>&1)
    status=$?
    if [ $status -ne 0 ]; then
        if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
            if [ "$kind" = ff ] || [ "$kind" = no-ff ]; then
                printf "Merging '%s' into '%s' conflicted: the conflicted files are in Changes. Stage them, then c concludes the merge, or m continues or aborts it.\\n" "$branch" "$into" >&2
            else
                printf "Squashing '%s' into '%s' conflicted: the conflicted files are in Changes. Stage them, then c commits.\\n" "$branch" "$into" >&2
            fi
        else
            printf '%s\\n' "$out" >&2
        fi
        exit 1
    fi
    if [ "$kind" = squash ] && ! git diff --cached --quiet; then
        git -c color.ui=never commit -q --no-edit 1>&2 || exit 1
    fi
    """

    /// Takes the folder, the branch to rebase onto and the branch you're on, for the words. `git rebase`, with no
    /// editor, so nothing waits for input. A rebase that conflicts is told apart from other failures, which print what
    /// git said: it stays in progress with the conflicts in Changes, where m continues, skips or aborts it.
    static let rebaseScript = """
    cd "$1" || exit 1
    onto=$2 head=$3
    export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true
    out=$(LC_ALL=C git -c core.editor=true -c color.ui=never rebase "$onto" 2>&1)
    status=$?
    if [ $status -ne 0 ]; then
        if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
            printf "Rebasing '%s' onto '%s' conflicted: the conflicted files are in Changes. Stage them, then m continues, skips or aborts the rebase.\\n" "$head" "$onto" >&2
        else
            printf '%s\\n' "$out" >&2
        fi
        exit 1
    fi
    """

    /// Takes the folder and the full hashes of the Copied commits, in any order. Cherry-picks them onto the branch you're
    /// on, oldest first: parents before their children, found by walking from the copies down to their common ancestor.
    /// A pick that conflicts is told apart from other failures, which print what git said: it stays in progress with the
    /// conflicts in Changes, where m continues, skips or aborts it.
    static let cherryPickScript = """
    cd "$1" || exit 1
    shift
    export GIT_EDITOR=true
    base=$(git merge-base --octopus "$@" 2>/dev/null)
    if [ -n "$base" ]; then
        ordered=$(git rev-list --topo-order --reverse "$@" "^$base^@")
    else
        ordered=$(git rev-list --no-walk --reverse "$@")
    fi
    picks=
    for commit in $ordered; do
        case " $* " in *" $commit "*) picks="$picks $commit" ;; esac
    done
    out=$(LC_ALL=C git -c core.editor=true -c color.ui=never cherry-pick $picks 2>&1)
    status=$?
    if [ $status -ne 0 ]; then
        if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
            printf 'The cherry-pick conflicted: the conflicted files are in Changes. Stage them, then m continues, skips or aborts it.\\n' >&2
        else
            printf '%s\\n' "$out" >&2
        fi
        exit 1
    fi
    """

    /// Takes the folder, `soft`, `mixed` or `hard`, and the commit to reset the branch you're on to. Git's own message
    /// shows when it fails. A hard reset leaves untracked files.
    static let resetScript = """
    cd "$1" || exit 1
    case $2 in
        soft|mixed|hard) ;;
        *) echo "Unknown reset: $2" >&2; exit 1 ;;
    esac
    LC_ALL=C git -c color.ui=never reset -q "--$2" "$3" 1>&2 || exit 1
    """

    /// Takes the folder and one of lazygit's reset options for the working
    /// tree: `nuke` puts tracked files back to HEAD and deletes untracked
    /// ones, `unstaged` puts tracked files back to what's staged,
    /// `untracked` deletes untracked files, `staged` stashes what's staged
    /// and drops that stash, as lazygit does, and `soft`, `mixed` and
    /// `hard` reset to HEAD. Ignored files stay.
    static let resetWorkingTreeScript = """
    cd "$1" || exit 1
    case $2 in
        nuke) git reset -q --hard HEAD && exec git clean -f -d -q ;;
        unstaged) exec git checkout -q -- . ;;
        untracked) exec git clean -f -d -q ;;
        staged)
            if ! git stash push -h 2>&1 | grep -q -e --staged; then
                echo "Discarding only what's staged needs git 2.35 or newer." >&2
                exit 1
            fi
            # With nothing staged git makes no stash, and the top one isn't this one's to drop.
            before=$(git rev-parse -q --verify refs/stash)
            git stash push -q --staged -m "Discarded staged changes" || exit 1
            after=$(git rev-parse -q --verify refs/stash)
            if [ -z "$after" ] || [ "$after" = "$before" ]; then echo "Nothing is staged." >&2; exit 1; fi
            exec git stash drop -q
            ;;
        soft|mixed|hard) exec git reset -q "--$2" HEAD ;;
        *) echo "Unknown reset: $2" >&2; exit 1 ;;
    esac
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
    public static let branchNotMergedMarker = "muxify:branch-not-merged"

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

    /// What the checkout script's stderr starts with when only Changes kept git from checking out.
    public static let checkoutBlockedMarker = "muxify:changes-in-the-way"

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
}
