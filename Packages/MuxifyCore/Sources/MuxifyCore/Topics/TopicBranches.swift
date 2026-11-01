import Foundation

public struct TopicBranches: Equatable {
    private let values: [Folder: String]

    /// `read` gives a file's contents by its path, as the folders spell it.
    public init(records: [TopicRecord] = [], paths: [Folder] = [], read: (String) -> String? = { _ in nil }) {
        let folders = Set(paths).union(records.filter { $0.settledAt == nil }.flatMap(\.sessions).compactMap { session -> Folder? in
            guard let path = session["worktree_path"]?.string, !path.isEmpty else { return nil }
            return Folder.local(path)
        })
        var values: [Folder: String] = [:]
        var attempted: Set<String> = []
        var contents: [String: String] = [:]
        func cachedRead(_ path: String) -> String? {
            if attempted.insert(path).inserted { contents[path] = read(path) }
            return contents[path]
        }
        for folder in folders where !folder.path.isEmpty {
            var path = folder.path
            while !path.isEmpty {
                let headPath: String
                if let pointer = cachedRead(path + "/.git")?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    guard pointer.hasPrefix("gitdir: ") else { break }
                    let gitdir = String(pointer.dropFirst(8))
                    guard !gitdir.isEmpty, !gitdir.contains("\n"), !gitdir.contains("\r"), !gitdir.contains("\0") else { break }
                    let directory = (gitdir as NSString).isAbsolutePath ? gitdir : path + "/" + gitdir
                    headPath = (Folder.lexical(directory) as NSString).appendingPathComponent("HEAD")
                } else {
                    // The main checkout of a plain repository has a `.git` folder, not a `gitdir:` file.
                    headPath = path + "/.git/HEAD"
                }
                guard let head = cachedRead(headPath)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    let parent = (path as NSString).deletingLastPathComponent
                    if parent == path { break }
                    path = parent
                    continue
                }
                guard head.hasPrefix("ref: refs/heads/") else { break }
                let branch = String(head.dropFirst(16))
                guard !branch.isEmpty, branch.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                      branch.rangeOfCharacter(from: .controlCharacters) == nil else { break }
                values[folder] = branch
                break
            }
        }
        self.values = values
    }

    public subscript(worktree: Folder) -> String? { values[worktree] }
}
