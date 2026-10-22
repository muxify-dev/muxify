import Foundation

/// Finds the SessionPaths of `sessions.paths` on one machine, with one script that runs here or over a Remote
/// Environment's SSH master. Each repository it finds comes with its Worktrees, read from git's layout.
public enum SessionPathDiscovery {
    /// Takes the wanted folders, one per line, then each root's path and depth as a pair of arguments. Prints `H`
    /// and the home folder, `R` and the root's index when a root starts, then for each folder `D`, the folder, its
    /// kind (`directory`, `plain` or `bare`) and its real path, followed by its `git worktree list --porcelain`
    /// lines after `W`. Missing roots and hidden folders are skipped. With wanted folders, a folder that is not one
    /// of them or a parent of one is skipped before git runs in it.
    public static let script = """
    s='\(Tmux.separator)'
    nl='
    '
    wanted=$1
    shift
    printf 'H%s%s\\n' "$s" "$HOME"
    index=0
    while [ "$#" -ge 2 ]; do
        pattern=$1
        depth=$2
        shift 2
        case $pattern in
            "~") pattern=$HOME ;;
            "~/"*) pattern=$HOME/${pattern#"~/"} ;;
        esac
        printf 'R%s%s\\n' "$s" "$index"
        index=$((index + 1))
        old=$IFS
        IFS=$nl
        for root in $pattern; do
            IFS=$old
            [ "$root" = / ] || root=${root%/}
            [ -d "$root" ] || continue
            if [ "$depth" -eq 0 ]; then
                printf '%s\\n' "$root"
            else
                find "$root" -mindepth 1 -maxdepth "$depth" -name '.*' -prune -o -type d -print 2>/dev/null
            fi | while IFS= read -r dir; do
                if [ -n "$wanted" ]; then
                    case $nl$wanted$nl in
                        *"$nl$dir$nl"* | *"$nl$dir/"*) ;;
                        *) continue ;;
                    esac
                fi
                kind=directory
                if [ -e "$dir/.git" ] || { [ -f "$dir/HEAD" ] && [ -d "$dir/objects" ]; }; then
                    if [ "$(git -C "$dir" config --bool core.bare 2>/dev/null)" = true ]; then
                        kind=bare
                    elif top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \\
                        && [ "$(cd "$dir" && pwd -P)" = "$(cd "$top" && pwd -P)" ]; then
                        kind=plain
                    fi
                fi
                printf 'D%s%s%s%s%s%s\\n' "$s" "$dir" "$s" "$kind" "$s" "$(cd "$dir" && pwd -P)"
                [ "$kind" = directory ] && continue
                git -C "$dir" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
                    printf 'W%s%s\\n' "$s" "$line"
                done
            done
        done
        IFS=$old
    done
    """

    /// `within` nil wants every folder.
    public static func arguments(for roots: [SessionPathRoot], within folders: [String]? = nil) -> [String] {
        [folders?.joined(separator: "\n") ?? ""] + roots.flatMap { [$0.path, String($0.depth)] }
    }

    /// The SessionPaths in the script's output, in root order and then by path. The first root to find a folder
    /// names it. A folder inside a repository the script found is not a SessionPath of its own: it is that
    /// repository's subfolder or Worktree. `aliases` maps a path as the Config wrote it, `~` included,
    /// to its alias.
    public static func sessionPaths(in output: String, roots: [SessionPathRoot], aliases: [String: String]) -> [SessionPath] {
        var home = ""
        var found: [Found] = []
        var root = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.components(separatedBy: Tmux.separator)
            switch fields.first {
            case "H" where fields.count == 2: home = fields[1]
            case "R" where fields.count == 2: root = Int(fields[1]) ?? root
            case "D" where fields.count == 4:
                found.append(Found(root: root, path: Folder.lexical(fields[1]), kind: fields[2], real: Folder.lexical(fields[3])))
            case "W" where fields.count == 2 && !found.isEmpty:
                found[found.count - 1].worktrees.append(fields[1])
            default: continue
            }
        }
        var sessionPaths: [SessionPath] = []
        var repositoryFolders: [Folder] = []
        let ordered = found.enumerated().sorted { ($0.element.root, $0.element.path) < ($1.element.root, $1.element.path) }.map(\.element)
        // git gives real paths. A checkout that the script also found under a root takes that root's spelling.
        let resolver = FolderResolver.known(ordered.filter { roots.indices.contains($0.root) }.map(\.folder))
        let folderAliases = Dictionary(aliases.map { (resolver.folder(expand($0.key, home: home)), $0.value) }, uniquingKeysWith: { first, _ in first })
        let mainRepositories = ordered.filter(\.isMainRepository).map(\.folder)
        for entry in ordered where roots.indices.contains(entry.root) {
            guard !sessionPaths.contains(where: { $0.folder == entry.folder }),
                  !repositoryFolders.contains(where: { $0.contains(entry.folder) }) else { continue }
            // A linked Worktree whose repository was also found is a row of that SessionPath, whichever sorts first.
            if entry.kind != "directory", !entry.isMainRepository, let main = entry.mainCheckout,
               mainRepositories.contains(where: { $0.contains(main) }) { continue }
            let layout = RepositoryLayout(kind: entry.kind, worktrees: RepositoryLayout.parse(worktreeList: entry.worktrees.joined(separator: "\n"), resolver: resolver))
            if entry.kind != "directory" { repositoryFolders += [entry.folder] + layout.worktrees.map(\.folder) }
            let name = entry.path.split(separator: "/").suffix(roots[entry.root].displayDepth)
                .map { SessionPath.sessionName(String($0)) }.joined(separator: "/")
            guard !name.isEmpty else { continue }
            sessionPaths.append(SessionPath(folder: entry.folder, name: name, alias: folderAliases[entry.folder], layout: layout))
        }
        return sessionPaths
    }

    /// Runs the script on this Mac. With `within`, only the SessionPaths that hold one of those folders, as the full
    /// run names them, are found.
    public static func discover(_ roots: [SessionPathRoot], aliases: [String: String], within folders: [String]? = nil) -> [SessionPath] {
        guard !roots.isEmpty, folders?.isEmpty != true,
              let output = try? Shell.run("/bin/sh", ["-c", script, "muxify"] + arguments(for: roots, within: folders)) else { return [] }
        return sessionPaths(in: output, roots: roots, aliases: aliases)
    }

    public static func warnings(in paths: [SessionPath]) -> [String] {
        var first: [String: Folder] = [:]
        return paths.flatMap(SessionChoice.choices).compactMap { choice in
            if let folder = first[choice.name], folder != choice.directory {
                return "Session name '\(choice.name)' from \(choice.directory.path) is already used by \(folder.path). The first path wins; set display_depth to distinguish them."
            }
            first[choice.name] = choice.directory
            return nil
        }
    }


    private static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return Folder.lexical((home as NSString).appendingPathComponent(String(path.dropFirst(2)))) }
        return Folder.lexical(path)
    }
}

/// One folder the script reported, with its `git worktree list --porcelain` lines.
private struct Found {
    let root: Int
    let path: String
    let kind: String
    /// With symlinks resolved, as git reports paths.
    let real: String
    var worktrees: [String] = []

    var folder: Folder { Folder(path: path, real: real) }

    /// git lists the main checkout, or the bare repository, first, by its real path.
    var mainCheckout: Folder? {
        worktrees.first { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }.map { Folder(path: $0, real: $0) }
    }

    /// A repository's own folder, not one of its linked Worktrees. A bare layout's main entry is the
    /// `.bare` folder inside it.
    var isMainRepository: Bool {
        kind != "directory" && mainCheckout.map(folder.contains) == true
    }
}
