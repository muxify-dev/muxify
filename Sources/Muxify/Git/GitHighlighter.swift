import AppKit
import SwiftUI
import MuxifyCore

/// The Git View's colors: the Ghostty theme's, or system colors without a
/// theme. Labels and fills come from the system (`.primary`, `.secondary`)
/// in the theme's light or dark appearance.
struct GitColors {
    let background: NSColor
    let foreground: NSColor
    /// Line numbers and comments: the foreground faded toward the background.
    let dim: NSColor
    let red: NSColor
    let green: NSColor
    let yellow: NSColor
    let blue: NSColor
    let magenta: NSColor
    let cyan: NSColor
    let isDark: Bool

    init(_ theme: TerminalTheme?) {
        if let theme {
            background = theme.background
            foreground = theme.foreground
            isDark = theme.isDark
        } else {
            background = .textBackgroundColor
            foreground = .labelColor
            isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        let ansi = theme?.ansi ?? []
        func color(_ index: Int, _ fallback: NSColor) -> NSColor { ansi.indices.contains(index) ? ansi[index] : fallback }
        red = color(1, .systemRed)
        green = color(2, .systemGreen)
        yellow = color(3, .systemYellow)
        blue = color(4, .systemBlue)
        magenta = color(5, .systemPurple)
        cyan = color(6, .systemTeal)
        dim = foreground.blended(withFraction: 0.45, of: background) ?? .secondaryLabelColor
    }

    /// The toolbar and source list: the background shaded toward the
    /// foreground, like the Sidebar.
    var chrome: NSColor { background.blended(withFraction: 0.06, of: foreground) ?? background }
    /// Code in diffs, a little stronger than a light theme's foreground.
    var code: NSColor { isDark ? foreground : foreground.blended(withFraction: 0.15, of: .black) ?? foreground }
    var separator: NSColor { foreground.withAlphaComponent(isDark ? 0.12 : 0.22) }
    var softSeparator: NSColor { foreground.withAlphaComponent(isDark ? 0.065 : 0.13) }

    var addedText: NSColor { strong(green) }
    var removedText: NSColor { isDark ? red.blended(withFraction: 0.3, of: .white) ?? red : red.blended(withFraction: 0.12, of: .black) ?? red }
    var addedLine: NSColor { green.withAlphaComponent(isDark ? 0.15 : 0.14) }
    var addedGutter: NSColor { green.withAlphaComponent(isDark ? 0.26 : 0.25) }
    var removedLine: NSColor { red.withAlphaComponent(isDark ? 0.2 : 0.1) }
    var removedGutter: NSColor { red.withAlphaComponent(isDark ? 0.34 : 0.2) }
    /// A changed word, over its line's band: stronger, but light enough
    /// that syntax colors stay readable on it.
    var addedWord: NSColor { green.withAlphaComponent(isDark ? 0.3 : 0.26) }
    var removedWord: NSColor { red.withAlphaComponent(isDark ? 0.34 : 0.2) }

    /// A tag's text: `color` darkened on a light theme, lightened on a dark one.
    func strong(_ color: NSColor) -> NSColor {
        color.blended(withFraction: isDark ? 0.25 : 0.28, of: isDark ? .white : .black) ?? color
    }

    /// A tag's background.
    func tint(_ color: NSColor) -> NSColor { color.withAlphaComponent(isDark ? 0.18 : 0.15) }

    /// Initials get one color per author.
    func author(_ name: String) -> NSColor {
        let palette = [blue, magenta, cyan, green, yellow, red]
        let hash = name.unicodeScalars.reduce(UInt(5381)) { ($0 &* 33) &+ UInt($1.value) }
        return palette[Int(hash % UInt(palette.count))]
    }
}

/// Basic syntax highlighting of the code in a patch, in the theme's colors.
/// Sendable because its colors are never mutated, so big patches can be
/// highlighted off the main thread.
struct GitHighlighter: @unchecked Sendable {
    let colors: GitColors
    let fontSize: CGFloat

    func highlight(_ patch: inout GitPatch) {
        for file in patch.files.indices {
            let language = SyntaxLanguage.forPath(patch.files[file].path)
            for hunk in patch.files[file].hunks.indices {
                var context = SyntaxState()
                patch.files[file].hunks[hunk].styledContext = styled(patch.files[file].hunks[hunk].context, language, &context)
                // Comments and strings carry over lines within a hunk only.
                var state = SyntaxState()
                for line in patch.files[file].hunks[hunk].lines.indices {
                    let diffLine = patch.files[file].hunks[hunk].lines[line]
                    var text = styled(diffLine.shown, language, &state)
                    mark(&text, diffLine)
                    patch.files[file].hunks[hunk].lines[line].styled = text
                }
            }
        }
    }

    func styled(_ text: String, _ language: SyntaxLanguage?, _ state: inout SyntaxState) -> AttributedString {
        var result = AttributedString(text)
        guard let language else { return result }
        for (range, token) in language.tokens(in: Array(text.utf16), state: &state) {
            guard let characters = Range(range, in: text), let styledRange = Range(characters, in: result) else { continue }
            switch token {
            case .keyword: result[styledRange].foregroundColor = Color(nsColor: colors.magenta)
            case .type: result[styledRange].foregroundColor = Color(nsColor: colors.yellow)
            case .string: result[styledRange].foregroundColor = Color(nsColor: colors.green)
            case .number: result[styledRange].foregroundColor = Color(nsColor: colors.cyan)
            case .attribute, .key: result[styledRange].foregroundColor = Color(nsColor: colors.blue)
            case .comment:
                result[styledRange].foregroundColor = Color(nsColor: colors.dim)
                result[styledRange].font = .system(size: fontSize, design: .monospaced).italic()
            }
        }
        return result
    }

    /// The line's changed words on their own background, so they stay
    /// marked when the line wraps.
    func mark(_ text: inout AttributedString, _ line: GitDiffLine) {
        guard !line.marks.isEmpty else { return }
        let color = Color(nsColor: line.kind == .added ? colors.addedWord : colors.removedWord)
        let characters = text.characters
        for columns in line.marks {
            guard let lower = characters.index(characters.startIndex, offsetBy: columns.lowerBound, limitedBy: characters.endIndex),
                  let upper = characters.index(lower, offsetBy: columns.count, limitedBy: characters.endIndex) else { continue }
            text[lower..<upper].backgroundColor = color
        }
    }
}
