import Foundation

/// A folder on one machine. `path` is the spelling Muxify shows, writes to Topic records and gives to tmux, such as
/// the Config's `~/Dev/app` through a symlinked `~/Dev`. `real` is where it leads with symlinks resolved, as git,
/// `pwd -P` and tmux's `pane_current_path` give it. Two Folders are the same folder when their real paths are equal,
/// so no spelling of a path decides a match.
public struct Folder: Hashable, Sendable, CustomStringConvertible {
    public let path: String
    public let real: String

    /// A folder whose real path the machine that owns it gave, such as the discovery script's `pwd -P`.
    public init(path: String, real: String) {
        self.path = Self.lexical(path)
        self.real = Self.lexical(real)
    }

    /// A folder on this Mac, resolved with `realpath`. A folder that is gone resolves its nearest parent that is
    /// not, so a removed Worktree still compares with the folder it was in.
    public static func local(_ path: String) -> Folder {
        let shown = lexical(path)
        var existing = shown
        var missing: [String] = []
        while !existing.isEmpty, existing != "/" {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return Folder(path: shown, real: ([String(cString: resolved)] + missing.reversed()).joined(separator: "/"))
            }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return Folder(path: shown, real: shown)
    }

    public static func == (lhs: Folder, rhs: Folder) -> Bool { lhs.real == rhs.real }
    public func hash(into hasher: inout Hasher) { hasher.combine(real) }

    /// True for this folder and every folder below it.
    public func contains(_ other: Folder) -> Bool { relative(other.real, to: real) != nil }

    public var description: String { path }

    /// `.` and `..` and repeated `/` removed, by the text alone. Foundation's `standardizingPath` also drops
    /// `/private` from `/private/tmp`, which `realpath` and git keep, so it is not used for real paths.
    static func lexical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// The part of `path` below `folder`, empty for `folder` itself, or nil when `path` is not inside it. An empty path,
/// such as a record's missing `repository_path`, names no folder, so it holds nothing.
private func relative(_ path: String, to folder: String) -> String? {
    guard !folder.isEmpty else { return nil }
    if path == folder { return "" }
    let prefix = folder == "/" ? "/" : folder + "/"
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
}

/// Turns a path that one machine gave into a Folder. This Mac resolves with `realpath`. A Remote Environment cannot,
/// so it maps the path through the folders that discovery found there, whose real paths that machine gave.
public enum FolderResolver: Sendable {
    case local
    case known([Folder])

    /// A Remote Environment's resolver: its SessionPaths' folders and their Worktrees' folders, as discovery found them.
    public static func remote(_ sessionPaths: [SessionPath]) -> FolderResolver {
        .known(sessionPaths.flatMap { [$0.folder] + $0.layout.worktrees.map(\.folder) })
    }

    /// `path` in either spelling: the nearest known folder that holds it, by its shown path or by its real path,
    /// gives the other one, so a known `/` does not hide a nearer folder. A path in no known folder is taken as real.
    public func folder(_ path: String) -> Folder {
        switch self {
        case .local: return .local(path)
        case .known(let folders):
            let path = Folder.lexical(path)
            let matches = folders.flatMap { known in
                [relative(path, to: known.path).map { (length: known.path.count, folder: Folder(path: path, real: joined(known.real, $0))) },
                 relative(path, to: known.real).map { (length: known.real.count, folder: Folder(path: joined(known.path, $0), real: path)) }]
                    .compactMap { $0 }
            }
            return matches.max { $0.length < $1.length }?.folder ?? Folder(path: path, real: path)
        }
    }

    private func joined(_ folder: String, _ rest: String) -> String { rest.isEmpty || folder == "/" ? folder + rest : folder + "/" + rest }
}
