import Foundation
import MuxifyCore

/// Paths as lazygit's file tree: folders before files, each sorted, and a
/// folder holding nothing but one folder shown as one row, like
/// `Sources/Muxify`.
enum GitTree {
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
    static func nodes(_ paths: [String], collapsed: Set<String> = []) -> [Node] {
        final class Folder {
            var folders: [String: Folder] = [:]
            var files: [(name: String, index: Int)] = []
        }
        let root = Folder()
        for (index, path) in paths.enumerated() {
            let parts = path.split(separator: "/").map(String.init)
            var folder = root
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
        add(root, path: "", depth: 0)
        return nodes
    }

    /// Whether `path` is in `folder`, at any depth.
    static func path(_ path: String, isIn folder: String) -> Bool {
        path.hasPrefix(folder + "/")
    }
}
