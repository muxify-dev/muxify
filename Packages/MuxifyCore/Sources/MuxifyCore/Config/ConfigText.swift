import Foundation

/// A Config's YAML text, read and edited by lines, so the user's comments, order and indentation stay (ADR 0074).
/// It follows block mappings only: a key inside a flow mapping (`{a: 1}`) or a list item is not found.
public struct ConfigText: Equatable {
    public private(set) var lines: [String]

    public init(_ text: String) {
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    public static func == (lhs: ConfigText, rhs: ConfigText) -> Bool { lhs.text == rhs.text }

    /// A key's line and the lines of its block value.
    struct Entry {
        let line: Int
        let indent: Int
        /// The value on the key's line, without a trailing comment.
        let inline: String
        /// The block value is on the lines after `line`, up to here.
        let end: Int
        var block: Range<Int> { (line + 1)..<end }
    }

    /// The value of the key at `path` as YAML text: the value on the key's line, or its block without the key's
    /// indentation. Nil when the key is not there.
    public func value(at path: [String]) -> String? {
        guard let entry = find(path) else { return nil }
        guard entry.inline.isEmpty else { return entry.inline }
        let block = lines[entry.block]
        let indent = block.filter(Self.isContent).map(Self.indent).min() ?? 0
        return block.map { String($0.dropFirst(min(indent, Self.indent($0)))) }.joined(separator: "\n")
    }

    /// The lines of the key at `path`, from 1, as `ConfigProblem.line` counts them.
    public func lineRange(of path: [String]) -> ClosedRange<Int>? {
        find(path).map { ($0.line + 1)...max($0.line + 1, $0.end) }
    }

    /// Sets the key at `path` to `value`, YAML text of one or more lines. The key's own line keeps its spelling and
    /// trailing comment. A missing key goes at the end of its closest section, with the sections it needs. False when
    /// that section has a value on its own line, such as a flow mapping, so the key cannot go under it.
    /// `block` puts even a one-line value on its own lines, as a list or a mapping needs; a flow value such as
    /// `[a, b]` stays on the key's line.
    @discardableResult
    public mutating func set(_ path: [String], to value: String, block: Bool = false) -> Bool {
        let block = block && !value.hasPrefix("[") && !value.hasPrefix("{")
        let valueLines = value.components(separatedBy: "\n")
        let step = indentStep
        if let entry = find(path) {
            let line = lines[entry.line]
            guard let key = Self.key(of: line) else { return false }
            let head = String(line[..<key.rest.startIndex])
            lines.replaceSubrange(entry.line..<entry.end,
                                  with: Self.render(head: head, comment: Self.comment(of: key.rest), value: valueLines,
                                                    indent: entry.indent + step, block: block))
            return true
        }
        var depth = path.count - 1
        while depth > 0, find(Array(path.prefix(depth))) == nil { depth -= 1 }
        var indent = 0
        var at = lines.count
        var new: [String] = []
        if depth > 0, let parent = find(Array(path.prefix(depth))) {
            guard parent.inline.isEmpty else { return false }
            indent = lines[parent.block].first(where: Self.isContent).map(Self.indent) ?? parent.indent + step
            at = parent.end
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { new.append("") }
            at = lines.count
        }
        for name in path[depth..<(path.count - 1)] {
            new.append(String(repeating: " ", count: indent) + "\(name):")
            indent += step
        }
        new += Self.render(head: String(repeating: " ", count: indent) + "\(path[path.count - 1]):", comment: "",
                           value: valueLines, indent: indent + step, block: block)
        if depth == 0 { new.append("") }
        lines.insert(contentsOf: new, at: at)
        return true
    }

    /// Removes the key at `path` and its value, then each section that it leaves with no keys.
    public mutating func remove(_ path: [String]) {
        guard let entry = find(path) else { return }
        lines.removeSubrange(entry.line..<entry.end)
        let parentPath = Array(path.dropLast())
        guard !parentPath.isEmpty, let parent = find(parentPath), parent.inline.isEmpty,
              !lines[parent.block].contains(where: Self.isContent) else { return }
        remove(parentPath)
    }

    /// The keys directly under `path`, or at the top for an empty path, in file order.
    func children(of path: [String]) -> [(name: String, entry: Entry)] {
        if path.isEmpty { return children(in: 0..<lines.count) }
        guard let entry = find(path), entry.inline.isEmpty else { return [] }
        return children(in: entry.block)
    }

    func find(_ path: [String]) -> Entry? {
        var range = 0..<lines.count
        var found: Entry?
        for name in path {
            guard let child = children(in: range).first(where: { $0.name == name })?.entry else { return nil }
            found = child
            range = child.block
        }
        return found
    }

    private func children(in range: Range<Int>) -> [(name: String, entry: Entry)] {
        guard let first = range.first(where: { Self.isContent(lines[$0]) }) else { return [] }
        let indent = Self.indent(lines[first])
        return range.compactMap { index in
            let line = lines[index]
            guard Self.isContent(line), Self.indent(line) == indent, let key = Self.key(of: line) else { return nil }
            return (key.name, entry(at: index, inline: Self.inlineValue(of: key.rest)))
        }
    }

    private func entry(at line: Int, inline: String) -> Entry {
        let indent = Self.indent(lines[line])
        var end = line + 1
        for index in (line + 1)..<lines.count where Self.isContent(lines[index]) {
            let own = Self.indent(lines[index])
            // A block list may sit at its key's indentation.
            let listItem = inline.isEmpty && own == indent && lines[index].dropFirst(own).hasPrefix("-")
            guard own > indent || listItem else { break }
            end = index + 1
        }
        return Entry(line: line, indent: indent, inline: inline, end: end)
    }

    /// The indentation of the file's first indented key, else 2.
    private var indentStep: Int {
        lines.lazy.filter(Self.isContent).map(Self.indent).first { $0 > 0 } ?? 2
    }

    private static func render(head: String, comment: String, value: [String], indent: Int, block: Bool) -> [String] {
        // A block list item cannot share its key's line.
        guard block || value.count > 1 || value[0].hasPrefix("- ") else { return ["\(head) \(value[0])\(comment)"] }
        let pad = String(repeating: " ", count: indent)
        return ["\(head)\(comment)"] + value.map { $0.isEmpty ? "" : pad + $0 }
    }

    static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func isContent(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !trimmed.hasPrefix("#")
    }

    /// `name: rest` for a line that holds a mapping key.
    static func key(of line: String) -> (name: String, rest: Substring)? {
        let body = line.drop { $0 == " " }
        guard let first = body.first, first != "-", first != "#" else { return nil }
        if first == "'" || first == "\"" {
            guard let close = body.dropFirst().firstIndex(of: first) else { return nil }
            let after = body[body.index(after: close)...]
            guard after.hasPrefix(":") else { return nil }
            let rest = after.dropFirst()
            guard rest.isEmpty || rest.first == " " else { return nil }
            return (String(body[body.index(after: body.startIndex)..<close]), rest)
        }
        var from = body.startIndex
        while let colon = body[from...].firstIndex(of: ":") {
            let next = body.index(after: colon)
            if next == body.endIndex || body[next] == " " {
                return (body[..<colon].trimmingCharacters(in: .whitespaces), body[next...])
            }
            from = next
        }
        return nil
    }

    /// Where a trailing comment starts: a `#` after a space, outside quotes.
    private static func commentStart(of rest: Substring) -> Substring.Index? {
        var quote: Character?
        var previous: Character = " "
        for index in rest.indices {
            let character = rest[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if (character == "'" || character == "\"") && " [{,".contains(previous) {
                quote = character
            } else if character == "#" && previous == " " {
                return index
            }
            previous = character
        }
        return nil
    }

    static func inlineValue(of rest: Substring) -> String {
        rest[..<(commentStart(of: rest) ?? rest.endIndex)].trimmingCharacters(in: .whitespaces)
    }

    private static func comment(of rest: Substring) -> String {
        commentStart(of: rest).map { "  " + rest[$0...] } ?? ""
    }
}
