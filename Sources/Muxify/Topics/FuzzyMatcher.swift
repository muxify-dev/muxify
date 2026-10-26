import Foundation

struct FuzzyQuery: Equatable {
    let words: [String]
    /// Per word, the lowest score that counts as a match: 55% of what the word scores against itself. A word spread
    /// thinly over a long path, such as "claude" over "~/.local/state/…", scored at most 46%; initials and parts of a
    /// word at least 64%. A one-character word has no minimum, so the letter inside a word still matches.
    let minimumScores: [Int]

    init(_ text: String) {
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        minimumScores = words.map { $0.count < 2 ? 0 : (FuzzyMatcher.match($0, in: $0, scheme: .history)?.score ?? 0) * 11 / 20 }
    }

    var isEmpty: Bool { words.isEmpty }
}

struct FuzzyMatch: Equatable {
    let score: Int
    /// Character offsets into the text, ascending.
    let positions: [Int]
}

/// fzf's `--scheme`: the bonus for a word that starts after a space, and after a delimiter such as `/`.
struct FuzzyScheme {
    let boundaryWhite: Int
    let boundaryDelimiter: Int

    /// A space beats `/`, which beats `-`.
    static let `default` = FuzzyScheme(boundaryWhite: FuzzyMatcher.bonusBoundaryWhite, boundaryDelimiter: FuzzyMatcher.bonusBoundaryDelimiter)
    /// Every separator earns the same, so "Fix game", "fix/game" and "fix-game" score alike. The palettes use it: Topic
    /// titles separate words with spaces and Session names with `/` and `-`, and neither should win for that.
    static let history = FuzzyScheme(boundaryWhite: FuzzyMatcher.bonusBoundary, boundaryDelimiter: FuzzyMatcher.bonusBoundary)
}

/// A port of fzf's FuzzyMatchV2 (src/algo/algo.go at v0.74.4, no normalization), with its default and history
/// schemes, without its single- and two-character fast paths, which only speed up the same result.
/// Smart case: a word with an uppercase letter matches case-sensitively, as in fzf.
enum FuzzyMatcher {
    static let scoreMatch = 16
    static let scoreGapStart = -3
    static let scoreGapExtension = -1
    static let bonusBoundary = scoreMatch / 2
    static let bonusNonWord = scoreMatch / 2
    static let bonusCamel123 = bonusBoundary + scoreGapExtension
    static let bonusConsecutive = -(scoreGapStart + scoreGapExtension)
    static let bonusFirstCharMultiplier = 2
    static let bonusBoundaryWhite = bonusBoundary + 2
    static let bonusBoundaryDelimiter = bonusBoundary + 1

    enum CharClass: Int {
        case white, nonWord, delimiter, lower, upper, letter, number
    }

    private static let delimiters: Set<Character> = ["/", ",", ":", ";", "|"]

    /// Nil when `word` is not a subsequence of `text`.
    static func match(_ word: String, in text: String, scheme: FuzzyScheme = .default) -> FuzzyMatch? {
        let pattern = Array(word)
        let M = pattern.count
        guard M > 0 else { return FuzzyMatch(score: 0, positions: []) }
        let caseSensitive = pattern.contains(where: \.isUppercase)
        let whole = Array(text)
        guard M <= whole.count else { return nil }
        func folded(_ character: Character) -> Character {
            guard !caseSensitive, character.isUppercase else { return character }
            let lowered = character.lowercased()
            return lowered.count == 1 ? Character(lowered) : character
        }

        // The prefilter narrows the text to the span that can hold a match and refuses a non-subsequence.
        var firstIdx = 0, idx = 0, lastIdx = 0
        for (pidx, char) in pattern.enumerated() {
            guard let found = whole[idx...].firstIndex(where: { folded($0) == char }) else { return nil }
            if pidx == 0, found > 0 { firstIdx = found - 1 }
            lastIdx = found
            idx = found + 1
        }
        var maxIdx = lastIdx + 1
        if lastIdx + 1 < whole.count, let end = whole[(lastIdx + 1)...].lastIndex(where: { folded($0) == pattern[M - 1] }) {
            maxIdx = end + 1
        }
        let minIdx = firstIdx
        let raw = Array(whole[minIdx..<maxIdx])
        let T = raw.map(folded)
        let N = T.count

        var H0 = [Int](repeating: 0, count: N)
        var C0 = [Int](repeating: 0, count: N)
        var B = [Int](repeating: 0, count: N)
        var F = [Int](repeating: 0, count: M)
        var maxScore = 0, maxScorePos = 0
        var pidx = 0
        lastIdx = 0
        let pchar0 = pattern[0]
        var pchar = pattern[0], prevH0 = 0, prevClass = CharClass.white, inGap = false
        for off in 0..<N {
            let char = T[off]
            let cls = charClass(raw[off])
            let bonus = Self.bonus(prevClass, cls, scheme: scheme)
            B[off] = bonus
            prevClass = cls
            if char == pchar {
                if pidx < M {
                    F[pidx] = off
                    pidx += 1
                    pchar = pattern[min(pidx, M - 1)]
                }
                lastIdx = off
            }
            if char == pchar0 {
                let score = scoreMatch + bonus * bonusFirstCharMultiplier
                H0[off] = score
                C0[off] = 1
                if M == 1, score > maxScore {
                    maxScore = score
                    maxScorePos = off
                    if bonus >= bonusBoundary { break }
                }
                inGap = false
            } else {
                H0[off] = max(prevH0 + (inGap ? scoreGapExtension : scoreGapStart), 0)
                C0[off] = 0
                inGap = true
            }
            prevH0 = H0[off]
        }
        guard pidx == M else { return nil }
        if M == 1 { return FuzzyMatch(score: maxScore, positions: [minIdx + maxScorePos]) }

        // The score matrix, one row per pattern character, over the columns F[0]...lastIdx.
        let f0 = F[0]
        let width = lastIdx - f0 + 1
        var H = [Int](repeating: 0, count: width * M)
        var C = [Int](repeating: 0, count: width * M)
        H.replaceSubrange(0..<width, with: H0[f0...lastIdx])
        C.replaceSubrange(0..<width, with: C0[f0...lastIdx])
        for i in 1..<M {
            let f = F[i]
            let pchar = pattern[i]
            let row = i * width
            var inGap = false
            for col in f...lastIdx {
                let at = row + col - f0
                let s2 = (col > f ? H[at - 1] : 0) + (inGap ? scoreGapExtension : scoreGapStart)
                var s1 = 0, consecutive = 0
                if pchar == T[col] {
                    s1 = H[at - 1 - width] + scoreMatch
                    var b = B[col]
                    consecutive = C[at - 1 - width] + 1
                    if consecutive > 1 {
                        let fb = B[col - consecutive + 1]
                        // A stronger boundary here starts a new chunk; otherwise the chunk keeps its first bonus.
                        if b >= bonusBoundary, b > fb { consecutive = 1 } else { b = max(b, bonusConsecutive, fb) }
                    }
                    if s1 + b < s2 {
                        s1 += B[col]
                        consecutive = 0
                    } else {
                        s1 += b
                    }
                }
                C[at] = consecutive
                inGap = s1 < s2
                let score = max(s1, s2, 0)
                if i == M - 1, score > maxScore {
                    maxScore = score
                    maxScorePos = col
                }
                H[at] = score
            }
        }

        // Backtrace from the best cell of the last row; on a tie it keeps a match when the chunk is consecutive.
        var positions: [Int] = []
        var i = M - 1, j = maxScorePos, preferMatch = true
        while true {
            let I = i * width
            let j0 = j - f0
            let s = H[I + j0]
            let s1 = i > 0 && j >= F[i] ? H[I - width + j0 - 1] : 0
            let s2 = j > F[i] ? H[I + j0 - 1] : 0
            let row = i
            if s > s1, s > s2 || (s == s2 && preferMatch) {
                positions.append(j + minIdx)
                if i == 0 { break }
                i -= 1
            }
            preferMatch = C[I + j0] > 1
                || (row + 1 < M && j < lastIdx && j + 1 >= F[row + 1] && C[I + width + j0 + 1] > 0)
            j -= 1
        }
        return FuzzyMatch(score: maxScore, positions: positions.reversed())
    }

    static func charClass(_ character: Character) -> CharClass {
        if character.isASCII {
            switch character {
            case "a"..."z": return .lower
            case "A"..."Z": return .upper
            case "0"..."9": return .number
            case " ", "\t", "\n", "\u{0B}", "\u{0C}", "\r": return .white
            default: return delimiters.contains(character) ? .delimiter : .nonWord
            }
        }
        if character.isLowercase { return .lower }
        if character.isUppercase { return .upper }
        if character.isNumber { return .number }
        if character.isLetter { return .letter }
        if character.isWhitespace { return .white }
        return delimiters.contains(character) ? .delimiter : .nonWord
    }

    static func bonus(_ previous: CharClass, _ current: CharClass, scheme: FuzzyScheme = .default) -> Int {
        if current.rawValue >= CharClass.nonWord.rawValue {
            switch previous {
            case .white: return scheme.boundaryWhite
            case .delimiter: return scheme.boundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if previous == .lower && current == .upper || previous != .number && current == .number { return bonusCamel123 }
        switch current {
        case .nonWord, .delimiter: return bonusNonWord
        case .white: return scheme.boundaryWhite
        default: return 0
        }
    }
}
