import Foundation

/// A repository, as a script on its machine reported it from one of its checkouts.
public struct WorktreeRepository: Equatable, Sendable {
    /// The main working tree, or the bare folder.
    public let main: String
    /// Names the repository's folder in the root, and its Sessions: `<name>/<worktree name>`.
    public let name: String
    /// `${XDG_STATE_HOME:-$HOME/.local/state}` on that machine.
    public let stateHome: String
    public let home: String
    /// The checkout whose `.worktree.json` Muxify read, and the source of its copies and links.
    public let setupFolder: String?
    public let setup: WorktreeSetup

    /// The repository's name from git's common folder: `app` for `app/.git`, `app.git` and `app/.bare`.
    static func name(commonDirectory: String) -> String {
        let common = commonDirectory.hasSuffix("/") ? String(commonDirectory.dropLast()) : commonDirectory
        let parent = (common as NSString).deletingLastPathComponent
        let last = (common as NSString).lastPathComponent
        if last == ".git" || last == ".bare" { return (parent as NSString).lastPathComponent }
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// The folder that holds a new Worktree: the setup's `worktreePath`, else `<root>/<repository>`. `root` is the
    /// Config's `worktrees.root_path`, else `defaultRoot`; nil `defaultRoot` is Muxify's state folder on that machine.
    /// `repositoryFolder` names the repository's folder in the root, the repository's name by default.
    public func parent(root: String?, defaultRoot: String?, repositoryFolder: String? = nil) -> String {
        if let path = setup.worktreePath {
            let expanded = expand(path)
            let base = expanded.hasPrefix("/") ? expanded : ((setupFolder ?? main) as NSString).appendingPathComponent(expanded)
            return Folder.lexical(base)
        }
        let base = root.map(expand) ?? defaultRoot ?? stateHome + "/muxify/worktrees"
        return (Folder.lexical(base) as NSString).appendingPathComponent(repositoryFolder ?? name)
    }

    /// Where the new Worktree called `name` goes.
    public func folder(for name: String, root: String?, defaultRoot: String?) -> String {
        (parent(root: root, defaultRoot: defaultRoot) as NSString).appendingPathComponent(name)
    }

    /// What a Topic's new Worktree gets of this repository.
    public var topicSetup: TopicPlan.Setup { TopicPlan.Setup(repository: main, folder: setupFolder, setup: setup) }

    private func expand(_ path: String) -> String {
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }
}

/// The git and file work of a Muxify Worktree, as `/bin/sh` scripts that run on the Environment's machine.
public struct MuxifyWorktrees: Sendable {
    public let scripts: any ScriptRunning

    public init(scripts: any ScriptRunning) { self.scripts = scripts }

    /// The repository of the checkout at `folder`, with its Worktree setup: the checkout's `.worktree.json`, else the
    /// main working tree's.
    public func repository(at folder: String) throws -> WorktreeRepository {
        let output = try run(Self.inspectScript, [folder], timeout: 20)
        let fields = output.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else { throw MuxifyWorktreeError.script("git did not describe the repository of \(folder).") }
        var setupFolder: String?
        var setup = WorktreeSetup()
        if fields.count == 6, let newline = fields[5].firstIndex(of: "\n") {
            let found = String(fields[5][..<newline])
            setupFolder = found
            do { setup = try WorktreeSetup.parse(String(fields[5][fields[5].index(after: newline)...]), file: found + "/" + WorktreeSetup.fileName) }
            catch let invalid as WorktreeSetup.Invalid { throw MuxifyWorktreeError.setupInvalid(invalid.description) }
        }
        return WorktreeRepository(main: fields[1].isEmpty ? fields[0] : fields[1], name: WorktreeRepository.name(commonDirectory: fields[0]),
                                  stateHome: fields[3], home: fields[4], setupFolder: setupFolder, setup: setup)
    }

    /// What `add` makes: the commit it started at, and its folder as the machine resolves it.
    public struct Added: Equatable, Sendable {
        public let commit: String
        public let path: String
    }

    /// Makes the Worktree at `path` from the checkout `from`. `.head` checks out the local branch `name` when it
    /// exists, as the user's script did, else makes it at HEAD. `.ref` makes the new branch `name` at the ref, and
    /// `.branch` checks out a branch that exists.
    public func add(name: String, from: String, at path: String, start: WorktreeStart) throws -> Added {
        let arguments: [String] = switch start {
        case .head: [from, path, "auto", name, "HEAD"]
        case .ref(let ref): [from, path, "new", name, ref]
        case .branch(let branch): [from, path, "branch", branch, ""]
        }
        let fields = try run(Self.addScript, arguments, timeout: 300).split(separator: "\n").map(String.init)
        guard fields.count == 2 else { throw MuxifyWorktreeError.script("git did not report the Worktree it made at \(path).") }
        return Added(commit: fields[0], path: fields[1])
    }

    /// Copies and links the setup's paths from `source` into `worktree`. Returns one line for each path, with the
    /// missing ones skipped, as the user's script printed them.
    public func sync(_ setup: WorktreeSetup, from source: String, to worktree: String) throws -> [String] {
        let items = setup.syncItems
        guard !items.isEmpty else { return [] }
        let arguments = [source, worktree] + items.flatMap { item -> [String] in
            switch item {
            case .copy(let path): ["copy", path]
            case .link(let path): ["symlink", path]
            }
        }
        return try run(Self.syncScript, arguments, timeout: 120).split(separator: "\n").map(String.init)
    }

    /// Writes the postCreate script into the Worktree's private git folder, where git does not see it as a change
    /// and removes it with the Worktree, and returns the command line that runs it. The user's shell types it.
    public func postCreateCommand(_ record: MuxifyWorktreeRecord, hooks: [String], setupFile: String) throws -> String {
        let script = Self.hookScript(record, hooks: hooks, setupFile: setupFile)
        let path = try run(Self.writeHookScript, [record.path, script], timeout: 20).trimmingCharacters(in: .newlines)
        return "bash " + Tmux.shellQuote(path)
    }

    /// Runs the preDelete hooks in the Worktree, one at a time. Returns their output; a hook that fails stops the
    /// rest, and its output comes with the failure.
    public func runPreDelete(_ record: MuxifyWorktreeRecord, hooks: [String]) throws -> String {
        guard !hooks.isEmpty else { return "" }
        let output = try run(Self.preDeleteScript, Self.hookVariables(record).map(\.1) + hooks, timeout: 600)
        guard let marker = output.range(of: Self.hookFailedMarker, options: .backwards) else { return output }
        let reason = output[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        throw MuxifyWorktreeError.hookFailed(output: String(output[..<marker.lowerBound]), reason: reason)
    }

    public enum State: String, Codable, Sendable {
        case clean, dirty, missing
    }

    /// Clean, dirty or missing, for each folder in order. Untracked files count as changes, as for Settle.
    public func states(_ paths: [String]) throws -> [State] {
        guard !paths.isEmpty else { return [] }
        let lines = try run(Self.statesScript, paths, timeout: 60).split(separator: "\n").map(String.init)
        guard lines.count == paths.count else { throw MuxifyWorktreeError.script("git did not report the state of every Worktree.") }
        return lines.map { State(rawValue: $0) ?? .dirty }
    }

    /// `git worktree remove`, from the repository. `force` removes a dirty Worktree too. A folder that is already
    /// gone only leaves git's entry, which a prune removes.
    public func remove(_ record: MuxifyWorktreeRecord, force: Bool) throws {
        _ = try run(Self.removeScript, [record.repository, record.path, force ? "force" : ""], timeout: 120)
    }

    private func run(_ script: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        do { return try scripts.runScript(script, arguments: arguments, timeout: timeout) }
        catch TmuxError.failed(_, let stderr) {
            throw MuxifyWorktreeError.script(stderr.isEmpty ? "A Worktree command failed." : stderr)
        }
    }

    // MARK: - Scripts

    /// Prints git's common folder, the main working tree (empty when bare), the checkout's top (empty when bare),
    /// the state home and HOME, one a line; then, when a checkout has a setup, its folder and the file.
    static let inspectScript = #"""
    cd "$1" 2>/dev/null || { echo "No folder is at $1." >&2; exit 3; }
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "$1 is not in a git repository." >&2; exit 4; }
    top=$(git rev-parse --show-toplevel 2>/dev/null)
    main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
    [ "$(git -C "$common" rev-parse --is-bare-repository 2>/dev/null)" = true ] && main=""
    printf '%s\n' "$common" "$main" "$top" "${XDG_STATE_HOME:-$HOME/.local/state}" "$HOME"
    for dir in "$top" "$main"; do
      if [ -n "$dir" ] && [ -f "$dir/.worktree.json" ]; then printf '%s\n' "$dir"; cat "$dir/.worktree.json"; exit 0; fi
    done
    """#

    /// Arguments: the checkout, the new folder, auto|new|branch, the branch, the ref. Prints the commit and the folder.
    static let addScript = #"""
    cd "$1" 2>/dev/null || { echo "No folder is at $1." >&2; exit 3; }
    dest=$2 mode=$3 branch=$4 ref=$5
    [ -e "$dest" ] && { echo "The folder $dest exists. Muxify made no Worktree." >&2; exit 6; }
    git check-ref-format --branch "$branch" >/dev/null 2>&1 || { echo "$branch cannot name a git branch." >&2; exit 7; }
    has_branch() { git show-ref --verify --quiet "refs/heads/$branch"; }
    if [ "$mode" = auto ]; then if has_branch; then mode=branch; else mode=new; fi; fi
    mkdir -p "$(dirname "$dest")" || exit 10
    if [ "$mode" = branch ]; then
      has_branch || { echo "No local branch $branch is in the repository of $1." >&2; exit 8; }
      held=$(git worktree list --porcelain | awk -v b="branch refs/heads/$branch" '/^worktree /{w=substr($0,10)} $0==b{print w}')
      [ -n "$held" ] && { echo "The branch $branch is checked out in the Worktree $held. git checks out a branch in one Worktree only." >&2; exit 9; }
      commit=$(git rev-parse --verify "refs/heads/$branch^{commit}") || exit 8
      git worktree add --quiet "$dest" "$branch" >&2 || exit 10
    else
      has_branch && { echo "The branch $branch exists. Leave out --base to check it out." >&2; exit 11; }
      commit=$(git rev-parse --verify --quiet --end-of-options "$ref^{commit}") || { echo "No commit matches $ref in $1." >&2; exit 5; }
      git worktree add --quiet -b "$branch" "$dest" "$commit" >&2 || exit 10
    fi
    printf '%s\n' "$commit" "$(cd "$dest" && pwd -P)"
    """#

    /// Arguments: the source checkout, the Worktree, then pairs of copy|symlink and a relative path.
    static let syncScript = #"""
    src=$1 dest=$2; shift 2
    while [ $# -gt 1 ]; do
      kind=$1 item=$2; shift 2
      if [ ! -e "$src/$item" ] && [ ! -L "$src/$item" ]; then printf 'skip %s (missing): %s\n' "$kind" "$item"; continue; fi
      parent=$(dirname "$dest/$item")
      mkdir -p "$parent" || exit 1
      if [ "$kind" = copy ]; then
        cp -R "$src/$item" "$parent/" && printf 'copy %s\n' "$item" || exit 1
      elif [ -e "$dest/$item" ] || [ -L "$dest/$item" ]; then
        printf 'skip symlink (exists): %s\n' "$item"
      else
        ln -s "$src/$item" "$dest/$item" && printf 'symlink %s\n' "$item" || exit 1
      fi
    done
    """#

    /// Arguments: the Worktree, the script. Prints the script's path.
    static let writeHookScript = #"""
    gitdir=$(git -C "$1" rev-parse --absolute-git-dir) || exit 1
    printf '%s\n' "$2" > "$gitdir/muxify-post-create.sh" || exit 1
    printf '%s\n' "$gitdir/muxify-post-create.sh"
    """#

    static let hookFailedMarker = "\u{1}muxify-hook-failed\u{1}"

    /// Arguments: the four hook variables in `hookVariables` order, then the hooks. It always exits 0: a failed
    /// hook prints the marker and its reason last, so the output before it reaches the user too.
    static let preDeleteScript = #"""
    cd "$1" 2>/dev/null || { echo "No folder is at $1." >&2; exit 3; }
    export MUXIFY_WORKTREE_PATH="$1" MUXIFY_WORKTREE_NAME="$2" MUXIFY_WORKTREE_BRANCH="$3" MUXIFY_REPOSITORY_PATH="$4"
    shift 4
    for hook; do
      printf '$ %s\n' "$hook"
      bash -lc "$hook" </dev/null 2>&1 || { status=$?; printf '\001muxify-hook-failed\001%s exited with %s.\n' "$hook" "$status"; exit 0; }
    done
    """#

    static let statesScript = #"""
    for p; do
      if [ ! -d "$p" ]; then echo missing
      elif [ -z "$(git -C "$p" status --porcelain --untracked-files=normal 2>/dev/null)" ]; then echo clean
      else echo dirty; fi
    done
    """#

    /// Arguments: the repository, the Worktree, force or empty.
    static let removeScript = #"""
    cd "$1" 2>/dev/null || { echo "The repository $1 is gone." >&2; exit 3; }
    if [ -d "$2" ]; then
      if [ "$3" = force ]; then git worktree remove --force "$2" >&2 || exit 10
      else git worktree remove "$2" >&2 || exit 10; fi
    fi
    git worktree prune
    """#

    static func hookVariables(_ record: MuxifyWorktreeRecord) -> [(String, String)] {
        [("MUXIFY_WORKTREE_PATH", record.path), ("MUXIFY_WORKTREE_NAME", record.name),
         ("MUXIFY_WORKTREE_BRANCH", record.branch), ("MUXIFY_REPOSITORY_PATH", record.repository)]
    }

    /// The bash script that the new Session's first Window runs: each hook in a login bash, as the user's script
    /// ran them, stopping at the first that fails. The Window's shell stays open after it.
    static func hookScript(_ record: MuxifyWorktreeRecord, hooks: [String], setupFile: String) -> String {
        var lines = ["# Muxify runs the postCreate hooks of \(setupFile) here, one at a time, and stops at the first that fails.",
                     "cd " + Tmux.shellQuote(record.path) + " || exit 1"]
        lines += hookVariables(record).map { "export \($0.0)=" + Tmux.shellQuote($0.1) }
        lines.append(#"muxify_hook() { printf '\n\033[1m$ %s\033[0m\n' "$1"; bash -lc "$1" || { status=$?; printf '\n\033[31mpostCreate stopped: the hook exited with %s.\033[0m\n' "$status"; exit "$status"; }; }"#)
        lines += hooks.map { "muxify_hook " + Tmux.shellQuote($0) }
        lines.append(#"printf '\n\033[32mpostCreate done.\033[0m\n'"#)
        return lines.joined(separator: "\n")
    }
}

public enum MuxifyWorktreeError: Error, Equatable, CustomStringConvertible {
    /// A script's own message, from stderr.
    case script(String)
    case setupInvalid(String)
    case hookFailed(output: String, reason: String)
    case exists(name: String, path: String, session: String)
    case unavailable(String)
    case ambiguous(String, paths: [String])
    case inUse(path: String, sessions: [String])
    case hasChanges(String)
    case nameInvalid(String)

    public var description: String {
        switch self {
        case .script(let message): return message
        case .setupInvalid(let message): return message
        case .hookFailed(let output, let reason):
            let shown = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (shown.isEmpty ? "" : shown + "\n") + "preDelete stopped: \(reason) The Worktree was kept; --force removes it anyway."
        case .exists(let name, let path, let session):
            return "\(name) is already a Muxify Worktree at \(path). Open its Session: muxify session open \(session)"
        case .unavailable(let value): return "No Muxify Worktree matches \(value). muxify worktree list --all lists them."
        case .ambiguous(let value, let paths):
            return "More than one Muxify Worktree is called \(value): \(paths.joined(separator: ", ")). Name one by its path."
        case .inUse(let path, let sessions):
            return "The Sessions \(sessions.joined(separator: ", ")) use the Worktree \(path). --kill stops them and removes it."
        case .hasChanges(let path):
            return "The Worktree \(path) has uncommitted changes or untracked files. --force removes it anyway."
        case .nameInvalid(let name): return "\(name) cannot name a Worktree: it is empty, starts with a dash or a dot, or has a space or a control character."
        }
    }
}
