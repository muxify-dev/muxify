import Foundation

/// What the header's HEAD read found in a folder: the branch or commit it shows, and whether the folder is in a
/// repository at all. A read that failed or timed out, a folder that is gone, or a machine without git, knows
/// nothing, so it never says "not a repository".
public enum GitHeadRead: Codable, Equatable, Sendable {
    /// In a repository, on this branch or short commit; nil when git names neither.
    case repository(head: String?)
    /// In no repository: the Git View would only say "Not a git repository".
    case notRepository
    case unknown

    /// Takes the folder. Prints a section, `head` with HEAD, or `none` when the folder is in no
    /// repository, by the same test as the Git View's snapshot; nothing when it cannot tell.
    public static let script = """
    cd "$1" 2>/dev/null || exit 0
    command -v git >/dev/null 2>&1 || exit 0
    git rev-parse --show-toplevel >/dev/null 2>&1 || { printf '\\036none\\n'; exit 0; }
    printf '\\036head\\n'
    git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || true
    """

    public init(_ result: Result<String, Error>) {
        guard case .success(let output) = result else { self = .unknown; return }
        let sections = GitReads.sections(output)
        if sections["none"] != nil {
            self = .notRepository
        } else if let head = sections["head"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            self = .repository(head: head.isEmpty ? nil : head)
        } else {
            self = .unknown
        }
    }

    public var head: String? {
        if case .repository(let head) = self { head } else { nil }
    }

    /// True or false once the read could tell; nil when it could not.
    public var isRepository: Bool? {
        switch self {
        case .repository: true
        case .notRepository: false
        case .unknown: nil
        }
    }
}

/// The Git View's reads, as /bin/sh scripts that run on the repository's machine (ADR 0087): in-process for the Local
/// Environment, in the Host Server for a Host. No script crosses the wire; `GitReader` runs them and parses their output.
public enum GitReads {
    /// How many commits the History, or a branch's commits, list.
    public static let commitLimit = 300

    /// Takes the folder. Prints sections, each a line `\x1E<name>` and then
    /// its output; only `error` when the folder isn't in a repository.
    public static let snapshotScript = """
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
    # The bare repository, which %(worktreepath) names for the branch its HEAD names, though it has no files.
    section bare; g worktree list --porcelain | awk 'NR == 1 { path = substr($0, 10) } NR == 2 { if ($0 == "bare") print path; exit }'
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
    public static let gitScript = """
    cd "$1" || exit 1
    shift
    export GIT_OPTIONAL_LOCKS=0
    exec git -c core.quotepath=off -c color.ui=never -c diff.mnemonicPrefix=false -c diff.noprefix=false "$@"
    """

    /// Takes the folder, a file or folder of the worktree, the path a file
    /// was renamed from, lines of context, and the groups to show, e.g.
    /// `unstaged staged`. Prints each group's patch after a line
    /// `\n\x1E<group>`.
    public static let changeScript = """
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
    public static let commitScript = """
    cd "$1" || exit 1
    export GIT_OPTIONAL_LOCKS=0
    exec git -c core.quotepath=off -c color.ui=never -c diff.mnemonicPrefix=false -c diff.noprefix=false \\
        show --no-color --no-ext-diff -M -m --first-parent --format='%H%x00%P%x00%an%x00%ae%x00%at%x00%B%x1F' "$2" --
    """

    /// Takes the folder and a branch. Prints its history in the sections
    /// the snapshot prints the current branch's in.
    public static let logScript = """
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



    /// Takes the folder and a local branch, and prints the URL of its upstream's remote, with `insteadOf` rules applied,
    /// then the upstream branch's name. A branch with no upstream, or one on the remote `.`, prints the reason to stderr.
    public static let pullRequestLinkScript = """
    cd "$1" || exit 1
    remote=$(git config "branch.$2.remote") && ref=$(git config "branch.$2.merge") && [ "$remote" != . ] || {
        echo "\(GitHosting.Failure.noUpstream.message)" >&2
        exit 1
    }
    url=$(git ls-remote --get-url "$remote") || exit 1
    printf '%s\\n%s\\n' "$url" "${ref#refs/heads/}"
    """

    /// Takes the folder and prints the URL of `origin`, or of the only remote when there is no `origin`, with `insteadOf`
    /// rules applied. With neither, it prints the reason to stderr.
    public static let commitLinkScript = """
    cd "$1" || exit 1
    remotes=$(git remote) || exit 1
    if printf '%s\\n' "$remotes" | grep -qx origin; then
        remote=origin
    elif set -f && set -- $remotes && [ $# -eq 1 ]; then
        remote=$1
    else
        echo "\(GitHosting.Failure.noOrigin.message)" >&2
        exit 1
    fi
    exec git ls-remote --get-url "$remote"
    """

    // MARK: Parsing

    /// The snapshot, or what the Git View says instead of one.
    public static func parseSnapshot(_ output: String) -> Result<GitSnapshot, GitViewError> {
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
        snapshot.commonDirectory = common
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
        let branches = parseBranches(sections["branches"] ?? "", bareRepository: trimmed(sections["bare"] ?? "")).map { branch in
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
    public static func parseLog(_ output: String) -> GitLog {
        log(sections(output))
    }

    /// Each section's output by name.
    public static func sections(_ output: String) -> [String: String] {
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
    public static func parseRemoteBranches(_ output: String) -> [String] {
        let prefix = "refs/remotes/"
        return output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix(prefix), !line.hasSuffix("/HEAD") else { return nil }
            return String(line.dropFirst(prefix.count))
        }
    }

    /// `git status --porcelain=v1 --branch -z`.
    public static func parseStatus(_ output: String) -> (changes: [GitChange], upstream: String?, ahead: Int, behind: Int) {
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
    public static func counted(_ changes: [GitChange], staged: [String: (Int?, Int?)], unstaged: [String: (Int?, Int?)],
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
    public static func parseParts(_ output: String) -> [(group: GitChange.Group, patch: String)] {
        output.components(separatedBy: "\n\u{1E}").dropFirst().compactMap { chunk in
            let parts = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let group = GitChange.Group(rawValue: String(parts[0])) else { return nil }
            return (group, parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// `git diff --numstat -z`: lines added and removed by path; nil for
    /// a binary file's `-`.
    public static func parseNumstat(_ output: String) -> [String: (Int?, Int?)] {
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
    public static func parseLineCounts(_ output: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.drop { $0 == " " }.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let count = Int(parts[0]), parts[1] != "total" else { continue }
            counts[String(parts[1])] = count
        }
        return counts
    }

    /// `master 2 14`: ahead and behind HEAD, by branch.
    public static func parseDivergence(_ output: String) -> [String: (Int, Int)] {
        var counts: [String: (Int, Int)] = [:]
        for line in output.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count == 3, let ahead = Int(words[1]), let behind = Int(words[2]) else { continue }
            counts[String(words[0])] = (ahead, behind)
        }
        return counts
    }

    public static func parseComparison(_ output: String) -> GitComparison? {
        let words = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard words.count == 3, let ahead = Int(words[1]), let behind = Int(words[2]) else { return nil }
        return GitComparison(base: String(words[0]), ahead: ahead, behind: behind)
    }

    /// A branch at `bareRepository` is checked out nowhere: as git does, the Git View checks it out in any Worktree.
    public static func parseBranches(_ output: String, bareRepository: String = "") -> [GitBranch] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\0")
            guard fields.count >= 7, !fields[1].isEmpty else { return nil }
            return GitBranch(
                name: fields[1], sha: fields[6], isHead: fields[0] == "*",
                upstream: fields[2].isEmpty ? nil : fields[2], track: fields[3],
                date: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)),
                worktreePath: fields[5].isEmpty || fields[5] == bareRepository ? nil : fields[5]
            )
        }
    }

    /// `unpushed` and `unmerged` are nil when there is no upstream or no
    /// main branch to compare with.
    public static func parseCommits(_ output: String, unpushed: Set<String>?, unmerged: Set<String>?) -> [GitCommit] {
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
    public static func decorations(_ text: String) -> (tags: [String], branches: [String], remotes: [String]) {
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

    public static func parseStashes(_ output: String) -> [GitStash] {
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
    public static func parseOperation(_ output: String) -> GitOperation? {
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
    public static func parseMergeMessage(_ text: String) -> String {
        trimmed(text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }.joined(separator: "\n"))
    }

    /// `git show` with `commitScript`'s format: the commit, then its patch.
    public static func parseCommitDetail(_ output: String) -> (detail: GitCommitDetail?, patch: String) {
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
