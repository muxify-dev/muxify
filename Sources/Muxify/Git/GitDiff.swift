import Foundation
import MuxifyCore

/// A patch as the Git View's diff pane shows it: files, hunks, and lines
/// with their numbers in the old and new file.
struct GitPatch: Equatable {
    var files: [GitPatchFile] = []
    /// Lines left out past `GitPatch.lineLimit`.
    var omittedLines = 0

    static let lineLimit = 20_000

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// A change's patches one after another, each file marked with its
    /// group.
    static func joined(_ parts: [(group: GitChange.Group, patch: GitPatch)]) -> GitPatch {
        var joined = GitPatch()
        for part in parts {
            for var file in part.patch.files {
                file.id = joined.files.count
                file.group = part.group
                joined.files.append(file)
            }
            joined.omittedLines += part.patch.omittedLines
        }
        return joined
    }

    /// Parses `git diff` or `git show` output. Lines before the first
    /// `diff` header are ignored.
    static func parse(_ output: String) -> GitPatch {
        var patch = GitPatch()
        var file: GitPatchFile?
        var inHeader = false
        var markerWidth = 1
        var old = 0
        var new = 0
        var lineCount = 0
        func finish() {
            if var file {
                for hunk in file.hunks.indices { GitWordDiff.mark(&file.hunks[hunk].lines) }
                patch.files.append(file)
            }
            file = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                finish()
                let path = GitPatchFile.path(inHeader: String(line))
                file = GitPatchFile(id: patch.files.count, oldPath: path.old, newPath: path.new)
                inHeader = true
                continue
            }
            guard file != nil else { continue }
            if line.hasPrefix("@@") {
                let at = line.prefix { $0 == "@" }.count
                markerWidth = max(1, at - 1)
                let words = line.split(separator: " ")
                // `@@ -16,6 +16,7 @@`, or one `-` range per parent in a combined diff.
                let ranges = words.dropFirst().prefix(markerWidth + 1)
                old = Self.start(ranges.first) ?? 0
                new = Self.start(ranges.last) ?? 0
                let close = line.dropFirst(at).range(of: String(repeating: "@", count: at))
                let header = close.map { String(line[..<$0.upperBound]) } ?? String(line)
                let context = close.map { line[$0.upperBound...].trimmingCharacters(in: .whitespaces) } ?? ""
                file?.hunks.append(GitHunk(oldStart: old, newStart: new, header: header, context: context))
                inHeader = false
                continue
            }
            if inHeader {
                file?.readHeader(String(line))
                continue
            }
            guard file?.hunks.isEmpty == false else { continue }
            if line.hasPrefix("\\") {
                file?.append(GitDiffLine(kind: .note, old: nil, new: nil, text: String(line.dropFirst(2))))
                continue
            }
            let marker = line.prefix(markerWidth)
            guard marker.count == markerWidth, marker.allSatisfy({ $0 == "+" || $0 == "-" || $0 == " " }) else { continue }
            lineCount += 1
            guard lineCount <= lineLimit else {
                patch.omittedLines += 1
                continue
            }
            let text = String(line.dropFirst(markerWidth))
            if marker.contains("+") {
                file?.append(GitDiffLine(kind: .added, old: nil, new: new, text: text))
                new += 1
            } else if marker.contains("-") {
                file?.append(GitDiffLine(kind: .removed, old: old, new: nil, text: text))
                old += 1
            } else {
                file?.append(GitDiffLine(kind: .context, old: old, new: new, text: text))
                old += 1
                new += 1
            }
        }
        finish()
        return patch
    }

    /// `-16,6` → 16.
    private static func start(_ range: Substring?) -> Int? {
        guard let range else { return nil }
        return Int(range.dropFirst().split(separator: ",").first ?? "")
    }
}

struct GitPatchFile: Equatable, Identifiable {
    enum Change: Equatable {
        case modified, added, deleted, renamed, copied
    }

    var id: Int
    var oldPath: String
    var newPath: String
    var change = Change.modified
    /// Staged, unstaged or untracked, in a change's patch.
    var group: GitChange.Group?
    var isBinary = false
    var hunks: [GitHunk] = []
    var additions = 0
    var deletions = 0

    var path: String { change == .deleted ? oldPath : newPath }

    /// The line of the new file where its first change is, or 1.
    var firstChangedLine: Int {
        for hunk in hunks {
            if let index = hunk.lines.firstIndex(where: { $0.kind == .added || $0.kind == .removed }) { return hunk.newLine(at: index) }
        }
        return 1
    }

    fileprivate mutating func append(_ line: GitDiffLine) {
        hunks[hunks.count - 1].lines.append(line)
        if line.kind == .added { additions += 1 }
        if line.kind == .removed { deletions += 1 }
    }

    fileprivate mutating func readHeader(_ line: String) {
        if line.hasPrefix("new file mode") {
            change = .added
        } else if line.hasPrefix("deleted file mode") {
            change = .deleted
        } else if line.hasPrefix("rename from ") {
            change = .renamed
            oldPath = String(line.dropFirst("rename from ".count))
        } else if line.hasPrefix("rename to ") {
            newPath = String(line.dropFirst("rename to ".count))
        } else if line.hasPrefix("copy from ") {
            change = .copied
            oldPath = String(line.dropFirst("copy from ".count))
        } else if line.hasPrefix("copy to ") {
            newPath = String(line.dropFirst("copy to ".count))
        } else if line.hasPrefix("Binary files ") {
            isBinary = true
        } else if line.hasPrefix("--- ") {
            let path = line.dropFirst(4)
            if path == "/dev/null" { change = .added } else { oldPath = String(path.hasPrefix("a/") ? path.dropFirst(2) : path) }
        } else if line.hasPrefix("+++ ") {
            let path = line.dropFirst(4)
            if path == "/dev/null" { change = .deleted } else { newPath = String(path.hasPrefix("b/") ? path.dropFirst(2) : path) }
        }
    }

    /// `diff --git a/old b/new`, or `diff --cc path`. The `---`/`+++`
    /// lines that follow, if any, correct paths with spaces.
    static func path(inHeader line: String) -> (old: String, new: String) {
        if line.hasPrefix("diff --git "), let b = line.range(of: " b/", options: .backwards) {
            let old = line[line.index(line.startIndex, offsetBy: "diff --git ".count)..<b.lowerBound]
            return (String(old.hasPrefix("a/") ? old.dropFirst(2) : old), String(line[b.upperBound...]))
        }
        let path = String(line.split(separator: " ", maxSplits: 2).last ?? "")
        return (path, path)
    }
}

struct GitHunk: Equatable {
    let oldStart: Int
    let newStart: Int
    /// `@@ -16,6 +16,7 @@`
    let header: String
    /// The enclosing function or type git found, e.g. `enum ConfigAction {`.
    let context: String
    var lines: [GitDiffLine] = []
    /// `context` with syntax colors, from `GitHighlighter`.
    var styledContext: AttributedString?

    /// The line of the new file that the line at `index` is, or sits
    /// beside: a removed line takes the next line that has a new number,
    /// else the last one before it, else the hunk's start.
    func newLine(at index: Int) -> Int {
        guard lines.indices.contains(index) else { return max(newStart, 1) }
        let beside = lines[index...].lazy.compactMap(\.new).first ?? lines[..<index].lazy.reversed().compactMap(\.new).first
        return beside ?? max(newStart, 1)
    }

    /// Side by side: each run of removed lines next to the added lines
    /// that follow it, the shorter side padded with blanks.
    var pairs: [(old: GitDiffLine?, new: GitDiffLine?)] {
        pairIndices.map { ($0.old.map { lines[$0] }, $0.new.map { lines[$0] }) }
    }

    /// `pairs`, as indexes of `lines`.
    var pairIndices: [(old: Int?, new: Int?)] {
        var pairs: [(old: Int?, new: Int?)] = []
        var removed: [Int] = []
        var added: [Int] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                pairs.append((removed.indices.contains(index) ? removed[index] : nil,
                              added.indices.contains(index) ? added[index] : nil))
            }
            removed = []
            added = []
        }
        for (index, line) in lines.enumerated() {
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(index)
            case .added:
                added.append(index)
            case .context, .note:
                flush()
                pairs.append((index, index))
            }
        }
        flush()
        return pairs
    }

    /// The hunk's lines in a patch of only the picked ones (indexes of
    /// `lines`), and how many it has on each side; nil without a changed
    /// line picked. The rest stay as they are: forward, a line not picked
    /// isn't added and isn't removed; reversed, for taking the picked
    /// lines back out, one isn't taken out and isn't put back.
    func body(picking picked: Set<Int>, reversed: Bool) -> (text: String, old: Int, new: Int)? {
        var text = ""
        var old = 0
        var new = 0
        var hasChange = false
        // A "No newline at end of file" goes with the line before it.
        var isKept = false
        for (index, line) in lines.enumerated() {
            let marker: Character?
            switch line.kind {
            case .context: marker = " "
            case .added: marker = picked.contains(index) ? "+" : reversed ? " " : nil
            case .removed: marker = picked.contains(index) ? "-" : reversed ? nil : " "
            case .note:
                if isKept { text += "\\ \(line.text)\n" }
                continue
            }
            isKept = marker != nil
            guard let marker else { continue }
            text += "\(marker)\(line.text)\n"
            if marker != "+" { old += 1 }
            if marker != "-" { new += 1 }
            if marker != " " { hasChange = true }
        }
        return hasChange ? (text, old, new) : nil
    }
}

extension GitPatchFile {
    /// How many of the picked lines, by hunk, are added or removed.
    func changedLines(picking picked: [Int: Set<Int>]) -> Int {
        picked.reduce(0) { count, pick in
            guard hunks.indices.contains(pick.key) else { return count }
            let lines = hunks[pick.key].lines
            return count + pick.value.filter { lines.indices.contains($0) && (lines[$0].kind == .added || lines[$0].kind == .removed) }.count
        }
    }

    /// A patch of only the picked lines, by hunk, as lazygit stages lines:
    /// forward, to apply to what the diff is from; reversed, to take them
    /// back out of what it's to. It changes the file in place, even a new
    /// or deleted one. Nil without a changed line picked.
    func patch(picking picked: [Int: Set<Int>], reversed: Bool) -> String? {
        var hunksText = ""
        // How far the moving side's lines are from the fixed side's, after
        // the hunks so far.
        var shift = 0
        for (index, hunk) in hunks.enumerated() {
            guard let picks = picked[index], let body = hunk.body(picking: picks, reversed: reversed) else { continue }
            // git finds a hunk by the side it applies to, which keeps all
            // of its lines; the other moves with the hunks before it. An
            // empty side starts at the line before.
            let (start, count, otherCount) = reversed ? (hunk.newStart, body.new, body.old) : (hunk.oldStart, body.old, body.new)
            let first = count == 0 ? start + 1 : start
            let other = first + shift - (otherCount == 0 ? 1 : 0)
            shift += otherCount - count
            let (old, new) = reversed ? (other, start) : (start, other)
            hunksText += "@@ -\(old),\(body.old) +\(new),\(body.new) @@\n" + body.text
        }
        guard !hunksText.isEmpty else { return nil }
        return "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n" + hunksText
    }
}

struct GitDiffLine: Equatable {
    enum Kind: Equatable {
        case context, added, removed
        /// `\ No newline at end of file`
        case note
    }

    let kind: Kind
    let old: Int?
    let new: Int?
    let text: String
    /// `text` as shown: tabs as spaces to the next multiple of 4, so each
    /// character is a column.
    let shown: String
    /// `shown` with syntax colors and changed words marked, from
    /// `GitHighlighter`.
    var styled: AttributedString?
    /// The columns of `shown` that changed from the line it pairs with, from
    /// `GitWordDiff`.
    var marks: [Range<Int>] = []

    init(kind: Kind, old: Int?, new: Int?, text: String) {
        self.kind = kind
        self.old = old
        self.new = new
        self.text = text
        guard text.contains("\t") else {
            shown = text
            return
        }
        var shown = ""
        for character in text {
            if character == "\t" {
                shown += String(repeating: " ", count: 4 - shown.count % 4)
            } else {
                shown.append(character)
            }
        }
        self.shown = shown
    }

    /// The text of `shown`'s characters in `range`, with the tabs they
    /// came from.
    func text(in range: Range<Int>) -> String {
        guard text.contains("\t") else { return String(shown.dropFirst(range.lowerBound).prefix(range.count)) }
        var column = 0
        var result = ""
        for character in text {
            let width = character == "\t" ? 4 - column % 4 : 1
            if column + width > range.lowerBound, column < range.upperBound { result.append(character) }
            column += width
        }
        return result
    }
}
