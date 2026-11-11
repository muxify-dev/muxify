import Foundation

/// A Ghostty config file and every file it includes with `config-file`, so
/// Muxify can watch each file the terminal's config comes from.
public struct ConfigFileSet {
    /// Every file read or looked for, including missing ones, so that
    /// creating one of them counts as a change.
    public private(set) var files: [String] = []

    /// Follows includes breadth first, as Ghostty's `loadRecursiveFiles`
    /// does. A file already read is a cycle and is not read again.
    public init(root: String, read: (String) -> String?) {
        var queue = [standardized(root)]
        var next = 0
        while next < queue.count {
            let path = queue[next]
            next += 1
            guard !files.contains(path) else { continue }
            files.append(path)
            guard let text = read(path) else { continue }
            let directory = (path as NSString).deletingLastPathComponent
            queue += Self.includes(in: text).map { Self.resolve($0, relativeTo: directory) }
        }
    }

    /// Ghostty's path rules: `~/` is the home directory, and a relative path
    /// is relative to the directory of the file that holds it.
    public static func resolve(_ value: String, relativeTo directory: String) -> String {
        if value.hasPrefix("~/") { return standardized((value as NSString).expandingTildeInPath) }
        if value.hasPrefix("/") { return standardized(value) }
        return standardized((directory as NSString).appendingPathComponent(value))
    }

    /// `resolve` for a path on a Remote Environment's machine: `~/` stays for
    /// the remote shell to expand with the remote home, never this Mac's.
    public static func resolveOnRemote(_ value: String, relativeTo directory: String) -> String {
        let path = value.hasPrefix("~/") || value.hasPrefix("/") ? value : (directory as NSString).appendingPathComponent(value)
        guard path == "~" || path.hasPrefix("~/") else { return standardized(path) }
        let rest = standardized("/" + String(path.dropFirst(2)))
        return rest == "/" ? "~" : "~" + rest
    }

    /// The paths of the `config-file = <path>` lines. A value may be in
    /// double quotes, and a leading `?` marks an optional file.
    private static func includes(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "config-file" else { return nil }
            var value = parts[1]
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if value.hasPrefix("?") { value.removeFirst() }
            return value.isEmpty ? nil : value
        }
    }
}

private func standardized(_ path: String) -> String {
    (path as NSString).standardizingPath
}
