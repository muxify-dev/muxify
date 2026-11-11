import Foundation
import Yams

/// The Config's YAML tree with the Config Overrides it names under `override`
/// merged on top (ADR 0075). Each node remembers the file it was written in,
/// so a problem shows that file's path and line, and a relative path in it
/// starts at that file's directory.
struct ConfigOverrides {
    /// The Config's tree with every Config Override merged on top.
    let root: Node
    /// The Override paths the Config names, resolved, missing ones included.
    let paths: [String]
    /// Problems with the `override` values, found before the sections are read.
    let problems: [ConfigProblem]
    /// The Config, then each Config Override that was read, in list order.
    private let files: [String]
    /// One per Config Override that was read, set on each of its nodes.
    /// Yams holds a node's anchor weakly, so these keep them alive; a node
    /// without one of them comes from the Config.
    private let anchors: [Anchor]

    /// Reads each Config Override through `read` and merges it on top. A
    /// missing Override is skipped; a syntax error in one fails the whole load.
    static func merge(_ config: Node, path: String, read: (String) -> String?) -> Result<ConfigOverrides, ConfigSyntaxError> {
        var problems: [ConfigProblem] = []
        let named = overridePaths(in: config, path: path, problems: &problems)
        var root = config
        var files = [path]
        var anchors: [Anchor] = []
        for file in named {
            guard let text = read(file) else { continue }
            let node: Node?
            do {
                node = try Yams.compose(yaml: text)
            } catch {
                return .failure(ConfigSyntaxError(path: file, error))
            }
            let anchor = Anchor(rawValue: "muxify-config-override-\(anchors.count + 1)")
            files.append(file)
            anchors.append(anchor)
            guard var node else { continue }
            if let mapping = node.mapping, let key = mapping.keys.first(where: { $0.string == "override" }) {
                problems.append(ConfigProblem(path: file, line: key.mark?.line ?? 1,
                                              message: "override: only the Config can name Config Overrides"))
                node = .mapping(Node.Mapping(mapping.filter { $0.key != key }.map { ($0.key, $0.value) },
                                             mapping.tag, mapping.style, mapping.mark, mapping.anchor))
            }
            root = merged(root, over: tagged(node, anchor))
        }
        return .success(ConfigOverrides(root: root, paths: named, problems: problems, files: files, anchors: anchors))
    }

    /// The file `node` was written in.
    func file(of node: Node) -> String {
        guard let anchor = node.anchor, let index = anchors.firstIndex(where: { $0 === anchor }) else { return files[0] }
        return files[index + 1]
    }

    /// Where a problem in `path` sorts: the Config first, then the Overrides in list order.
    func order(of path: String) -> Int {
        files.firstIndex(of: path) ?? 0
    }

    /// `override`: one path or a list of them. A bad entry is a problem and is skipped.
    private static func overridePaths(in config: Node, path: String, problems: inout [ConfigProblem]) -> [String] {
        guard let value = config.mapping?["override"], value.null == nil else { return [] }
        let directory = (path as NSString).deletingLastPathComponent
        let entries = value.sequence.map(Array.init) ?? [value]
        return entries.compactMap { entry in
            guard entry.tag == Yams.Tag(.str), let text = entry.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.rangeOfCharacter(from: .controlCharacters) == nil else {
                problems.append(ConfigProblem(path: path, line: entry.mark?.line ?? 1,
                                              message: "override: expected a path or a list of paths"))
                return nil
            }
            return ConfigFileSet.resolve(text, relativeTo: directory)
        }
    }

    /// A mapping merges key by key; anything else on top replaces what is below
    /// it whole. A key below keeps its place, and a key only `top` has comes
    /// after, in `top`'s order.
    private static func merged(_ below: Node, over top: Node) -> Node {
        guard let base = below.mapping, let overlay = top.mapping else { return top }
        var pairs = base.map { ($0.key, $0.value) }
        for (key, value) in overlay {
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[index].1 = merged(pairs[index].1, over: value)
            } else {
                pairs.append((key, value))
            }
        }
        return .mapping(Node.Mapping(pairs, base.tag, base.style, base.mark, base.anchor))
    }

    /// `node` and every node in it, with `anchor` set.
    private static func tagged(_ node: Node, _ anchor: Anchor) -> Node {
        switch node {
        case .scalar(var scalar):
            scalar.anchor = anchor
            return .scalar(scalar)
        case .mapping(let mapping):
            return .mapping(Node.Mapping(mapping.map { (tagged($0.key, anchor), tagged($0.value, anchor)) },
                                         mapping.tag, mapping.style, mapping.mark, anchor))
        case .sequence(let sequence):
            return .sequence(Node.Sequence(sequence.map { tagged($0, anchor) }, sequence.tag, sequence.style, sequence.mark, anchor))
        case .alias:
            return node
        }
    }
}
