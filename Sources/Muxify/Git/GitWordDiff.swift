import Foundation

/// The words that changed inside changed lines, marked as GitHub and delta
/// mark them. In a hunk, a run of removed lines directly followed by a run
/// of added lines is a block; its lines pair in order, as Split shows them,
/// and the tokens only one line of a pair has are marked. Lines left over
/// on either side have no pair and no marks.
enum GitWordDiff {
    /// A longer line gets no marks, so a minified file can't stall the view.
    static let lineLimit = 1_000
    /// Nor does a block with more lines than this on either side.
    static let blockLimit = 100
    /// A pair that shares less than this share of its code (whitespace
    /// aside) gets no marks: a rewritten line reads better as one band than
    /// as marks scattered over most of it. A half keeps a changed value or
    /// name marked (`quick brown fox` → `quick red fox` shares two thirds),
    /// and leaves a line that only keeps its keyword (`let a = 1` →
    /// `let total = count` shares two fifths) as a band.
    static let similarity = 0.5

    struct Token: Equatable {
        enum Kind: Equatable {
            /// A run of letters, digits and `_`.
            case word
            /// A run of whitespace.
            case space
            /// Any other character, on its own.
            case other

            init(_ character: Character) {
                if character.isLetter || character.isNumber || character == "_" {
                    self = .word
                } else if character.isWhitespace {
                    self = .space
                } else {
                    self = .other
                }
            }
        }

        let text: Substring
        let kind: Kind
        /// Where it is in the line as shown, tabs expanded as `GitDiffLine.shown`.
        let columns: Range<Int>
    }

    /// Sets `marks` on the paired lines of each block in a hunk's lines.
    static func mark(_ lines: inout [GitDiffLine]) {
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }
            let removed = index
            while index < lines.count, lines[index].kind == .removed { index += 1 }
            let added = index
            while index < lines.count, lines[index].kind == .added { index += 1 }
            guard added - removed <= blockLimit, index - added <= blockLimit else { continue }
            for offset in 0..<min(added - removed, index - added) {
                guard let marks = marks(old: lines[removed + offset].text, new: lines[added + offset].text) else { continue }
                lines[removed + offset].marks = marks.old
                lines[added + offset].marks = marks.new
            }
        }
    }

    /// The shown columns only one line of a pair has, or nil when the pair
    /// is too long or too different to mark.
    static func marks(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old.count <= lineLimit, new.count <= lineLimit else { return nil }
        let oldTokens = tokens(old)
        let newTokens = tokens(new)
        let (oldCommon, newCommon) = common(oldTokens, newTokens)
        func code(_ tokens: [Token], _ isCommon: [Bool]? = nil) -> Int {
            tokens.indices.reduce(0) { sum, index in
                tokens[index].kind == .space || isCommon?[index] == false ? sum : sum + tokens[index].text.count
            }
        }
        let total = code(oldTokens) + code(newTokens)
        guard total > 0, Double(2 * code(oldTokens, oldCommon)) >= similarity * Double(total) else { return nil }
        return (ranges(oldTokens, oldCommon), ranges(newTokens, newCommon))
    }

    static func tokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var column = 0
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            let startColumn = column
            let kind = Token.Kind(text[index])
            repeat {
                column += text[index] == "\t" ? 4 - column % 4 : 1
                index = text.index(after: index)
            } while kind != .other && index < text.endIndex && Token.Kind(text[index]) == kind
            tokens.append(Token(text: text[start..<index], kind: kind, columns: startColumn..<column))
        }
        return tokens
    }

    /// Which tokens of each side are in a longest common subsequence of the
    /// two. The ends they share are skipped first, so a small edit in a
    /// long line costs little.
    private static func common(_ a: [Token], _ b: [Token]) -> (a: [Bool], b: [Bool]) {
        var inA = [Bool](repeating: false, count: a.count)
        var inB = [Bool](repeating: false, count: b.count)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix].text == b[prefix].text {
            inA[prefix] = true
            inB[prefix] = true
            prefix += 1
        }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix].text == b[b.count - 1 - suffix].text {
            inA[a.count - 1 - suffix] = true
            inB[b.count - 1 - suffix] = true
            suffix += 1
        }
        let n = a.count - prefix - suffix
        let m = b.count - prefix - suffix
        guard n > 0, m > 0 else { return (inA, inB) }
        // lengths[i * (m + 1) + j]: the longest common subsequence of a's
        // middle from i and b's from j.
        var lengths = [Int32](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * (m + 1) + j] = a[prefix + i].text == b[prefix + j].text
                    ? lengths[(i + 1) * (m + 1) + j + 1] + 1
                    : max(lengths[(i + 1) * (m + 1) + j], lengths[i * (m + 1) + j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[prefix + i].text == b[prefix + j].text {
                inA[prefix + i] = true
                inB[prefix + j] = true
                i += 1
                j += 1
            } else if lengths[(i + 1) * (m + 1) + j] >= lengths[i * (m + 1) + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return (inA, inB)
    }

    /// The columns of the tokens not in common, next ones joined. A space
    /// between two marked tokens is marked too, so `brown fox` → `red cat`
    /// is one mark, not two.
    private static func ranges(_ tokens: [Token], _ isCommon: [Bool]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (index, token) in tokens.enumerated() {
            let isBridge = token.kind == .space && index > 0 && index < tokens.count - 1 && !isCommon[index - 1] && !isCommon[index + 1]
            guard !isCommon[index] || isBridge else { continue }
            if let last = ranges.last, last.upperBound == token.columns.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<token.columns.upperBound
            } else {
                ranges.append(token.columns)
            }
        }
        return ranges
    }
}
