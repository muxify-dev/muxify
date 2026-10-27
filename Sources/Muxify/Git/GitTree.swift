import Foundation
import MuxifyCore

/// Paths as lazygit's file tree: folders before files, each sorted, and a
/// folder holding nothing but one folder shown as one row, like
/// `Sources/Muxify`.
enum GitTree {
    /// The path of the `/` row that holds the whole tree, as lazygit's
    /// Files panel shows it; git takes it for the whole working tree.
    static let root = "."

    struct Node: Equatable {
        /// The folder's path, or the file's.
        let path: String
        /// What the row shows: `Sources/Muxify`, or the file's name.
        let name: String
        let depth: Int
        /// The file's index in the paths; nil for a folder.
        let file: Int?
    }

    /// The rows of the tree, leaving out what is in the `collapsed` folders.
    /// `withRoot` puts the `/` row above them when more than one row is on
    /// top, as lazygit does: one file or one folder at the top needs none.
    static func nodes(_ paths: [String], collapsed: Set<String> = [], withRoot: Bool = false) -> [Node] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [(name: String, index: Int)] = []
        }
        let top = Folder()
        for (index, path) in paths.enumerated() {
            let parts = path.split(separator: "/").map(String.init)
            var folder = top
            for part in parts.dropLast() {
                if let next = folder.folders[part] {
                    folder = next
                } else {
                    let next = Folder()
                    folder.folders[part] = next
                    folder = next
                }
            }
            folder.files.append((parts.last ?? path, index))
        }
        var nodes: [Node] = []
        func add(_ folder: Folder, path: String, depth: Int) {
            for name in folder.folders.keys.sorted() {
                var child = folder.folders[name]!
                var label = name
                var childPath = path.isEmpty ? name : "\(path)/\(name)"
                while child.files.isEmpty, child.folders.count == 1, let only = child.folders.first {
                    label += "/\(only.key)"
                    childPath += "/\(only.key)"
                    child = only.value
                }
                nodes.append(Node(path: childPath, name: label, depth: depth, file: nil))
                if !collapsed.contains(childPath) { add(child, path: childPath, depth: depth + 1) }
            }
            for file in folder.files.sorted(by: { $0.name < $1.name }) {
                nodes.append(Node(path: paths[file.index], name: file.name, depth: depth, file: file.index))
            }
        }
        if withRoot, top.folders.count + top.files.count > 1 {
            nodes.append(Node(path: root, name: "/", depth: 0, file: nil))
            if !collapsed.contains(root) { add(top, path: "", depth: 1) }
        } else {
            add(top, path: "", depth: 0)
        }
        return nodes
    }

    /// Whether `path` is in `folder`, at any depth; every path is in the root.
    static func path(_ path: String, isIn folder: String) -> Bool {
        folder == root || path.hasPrefix(folder + "/")
    }
}
