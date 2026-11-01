import Foundation

/// Find in Pane through tmux copy mode (ADR 0051): the commands that search a Pane's history, and the place in
/// its matches that tmux reports. tmux finds and highlights the matches and scrolls the Pane to each one.
public enum PaneSearch {
    public enum Step: Equatable, Sendable {
        /// A new query. tmux searches up from where the search began, so the newest match comes first.
        case query
        /// The next match up, in older output. It wraps to the newest.
        case next
        /// The next match down, in newer output. It wraps to the oldest.
        case previous
    }

    /// Where the search is after a step, from the line that `commands` ends with.
    public struct Status: Equatable, Sendable {
        public let pane: String
        /// The cursor is on a match.
        public let found: Bool
        /// Every match in the Pane's history and screen. Nil when tmux does not count them: a tmux older than 3.2,
        /// or a step down with emacs keys. The count of the query's earlier step still holds then.
        public let total: Int?
        /// The current match's cell column, and its line counted as `capture-pane` counts lines: 0 is the top
        /// line on screen, and the history is negative.
        public let column: Int
        public let line: Int

        /// Reads the output of the `display-message` that `commands` ends with.
        public init?(_ output: String) {
            let fields = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 6, fields[0].hasPrefix("%"),
                  let column = Int(fields[3]), let y = Int(fields[4]), let scroll = Int(fields[5]) else { return nil }
            pane = String(fields[0])
            found = fields[1] == "1"
            total = Int(fields[2])
            self.column = column
            line = y - scroll
        }
    }

    /// The highlight of the matches, as `copy-mode-match-style` and `copy-mode-current-match-style` take it.
    public struct Styles: Equatable, Sendable {
        public let match: String
        public let current: String

        public init(match: String, current: String) {
            self.match = match
            self.current = current
        }
    }

    /// A tmux style with the color as its background, and black or white text, whichever is easier to read on it.
    public static func style(red: UInt8, green: UInt8, blue: UInt8) -> String {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let text = (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? "#000000" : "#ffffff"
        return "bg=" + String(format: "#%02x%02x%02x", red, green, blue) + ",fg=" + text
    }

    static let statusFormat = "#{pane_id} #{search_present} #{search_count} #{copy_cursor_x} #{copy_cursor_y} #{scroll_position}"

    /// Runs `step` for `query` in `target`, a Pane or a Window's active Pane, as one tmux invocation. The Pane
    /// takes `styles` as its own options, so only it shows them, and the user's tmux styles stay for copy mode
    /// outside Find in Pane. It enters copy mode first: a Pane that left it, as `q` does, goes back to its last
    /// search. The output is a `Status`.
    public static func commands(_ step: Step, query: String, target: String, styles: Styles) -> [String] {
        let send = ["send-keys", "-X", "-t", target]
        let search: [String] = switch step {
        // The '=' prefix searches for plain text. A changed query goes back to where the search began.
        case .query: send + ["search-backward-incremental", argument("=" + query)]
        case .next: send + ["search-again"]
        // With emacs keys, which tmux takes when EDITOR names no vi, a search down finds the match under the
        // cursor too and leaves the cursor after it. One cell right skips the current match, and a search up
        // from the end of the next match puts the cursor on its start, as with vi keys. The cursor move makes
        // tmux forget its count of the matches, so `Status.total` is nil after this step.
        case .previous:
            ["if-shell", "-F", "-t", target, "#{==:#{mode-keys},emacs}",
             "send-keys -X -t \(target) cursor-right ; send-keys -X -t \(target) search-reverse ; send-keys -X -t \(target) search-again",
             "send-keys -X -t \(target) search-reverse"]
        }
        return ["set-option", "-p", "-t", target, "copy-mode-match-style", styles.match, ";",
                "set-option", "-p", "-t", target, "copy-mode-current-match-style", styles.current, ";",
                "copy-mode", "-t", target, ";"] + search + [";", "display-message", "-p", "-t", target, statusFormat]
    }


    /// Leaves copy mode, and the highlight with it, when the Pane is in copy mode, and gives the Pane back the
    /// styles of its Window.
    public static func cancel(pane: String) -> [String] {
        ["if-shell", "-F", "-t", pane, "#{==:#{pane_mode},copy-mode}", "send-keys -X -t \(pane) cancel", ";",
         "set-option", "-pu", "-t", pane, "copy-mode-match-style", ";",
         "set-option", "-pu", "-t", pane, "copy-mode-current-match-style"]
    }

    /// The text from the current match's line to the bottom of the Pane, for `index`.
    public static func capture(_ status: Status) -> [String] {
        ["capture-pane", "-p", "-J", "-t", status.pane, "-S", String(status.line), "-E", "-"]
    }

    /// The current match's place, 0 for the newest, from the `capture` text below it. tmux counts the `total`
    /// matches but does not say which one is current, so this counts the matches after it.
    public static func index(of query: String, in text: String, column: Int, total: Int) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, !query.isEmpty else { return 0 }
        let start = first.index(atColumn: column)
        let afterCurrent = first[start...].dropFirst(query.count)
        var after = matches(of: query, in: afterCurrent)
        for line in lines.dropFirst() { after += matches(of: query, in: line) }
        return min(after, max(total - 1, 0))
    }

    /// Matches as tmux finds them: plain text that ignores case unless the query has a capital letter.
    static func matches(of query: String, in line: Substring) -> Int {
        let options: String.CompareOptions = query.contains(where: \.isUppercase) ? [] : [.caseInsensitive]
        var count = 0
        var rest = line[...]
        while let range = rest.range(of: query, options: options) {
            count += 1
            rest = rest[range.upperBound...]
        }
        return count
    }

    /// tmux reads an argument that ends in `;` as the end of a command, unless a backslash comes before it.
    static func argument(_ text: String) -> String {
        text.hasSuffix(";") ? String(text.dropLast()) + "\\;" : text
    }
}

private extension Substring {
    /// The character at a cell column. A wide character, such as a CJK one, fills two cells.
    func index(atColumn column: Int) -> Index {
        var cells = 0
        var index = startIndex
        while index < endIndex, cells < column {
            cells += self[index].isWide ? 2 : 1
            index = self.index(after: index)
        }
        return index
    }
}

private extension Character {
    var isWide: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        if scalar.properties.isEmojiPresentation { return true }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
             0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
