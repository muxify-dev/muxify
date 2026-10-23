import Foundation

/// How the Git View opens, from the Config's `git_view` section.
public struct GitViewConfig: Equatable {
    public enum Display: String {
        /// Floats over the whole App Window, like `tmux display-popup`.
        case popup
        /// Takes the terminal's place.
        case fullscreen
    }

    public var display = Display.popup
    /// The popup's share of the App Window's width and height, from 0.1 to 1.
    public var width = 0.8
    public var height = 0.8
    /// A shell command with `{file}` and `{line}`, which `e` runs in a new
    /// tmux Window. Nil runs `defaultEditor`.
    public var editor: String?

    public init(display: Display = .popup, width: Double = 0.8, height: Double = 0.8, editor: String? = nil) {
        self.display = display
        self.width = width
        self.height = height
        self.editor = editor
    }

    /// What `e` runs without `git_view.editor`.
    public static let defaultEditor = "${VISUAL:-${EDITOR:-vi}} +{line} {file}"

    /// A command that names `{file}`, and may name `{line}`.
    public static func isEditor(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty && text.contains("{file}")
    }

    /// The editor command with the file shell-quoted and the line as a
    /// number, for `sh -c`.
    public func editorCommand(file: String, line: Int) -> String {
        var command = ""
        var rest = Substring(editor ?? Self.defaultEditor)
        while let open = rest.firstIndex(of: "{") {
            command += rest[..<open]
            rest = rest[open...]
            if rest.hasPrefix("{file}") {
                command += Tmux.shellQuote(file)
                rest = rest.dropFirst("{file}".count)
            } else if rest.hasPrefix("{line}") {
                command += String(max(line, 1))
                rest = rest.dropFirst("{line}".count)
            } else {
                command += "{"
                rest = rest.dropFirst()
            }
        }
        return command + rest
    }

    /// What tmux runs in the new Window: plain words, because tmux's default
    /// shell may be fish.
    public func editorShellCommand(file: String, line: Int) -> String {
        "sh -c " + Tmux.shellQuote(editorCommand(file: file, line: line))
    }

    /// `80%` or `80` as 0.8, from 10% to 100%.
    public static func share(_ text: String) -> Double? {
        var number = text.trimmingCharacters(in: .whitespaces)
        if number.hasSuffix("%") { number.removeLast() }
        guard let percent = Double(number.trimmingCharacters(in: .whitespaces)), percent.isFinite,
              (10...100).contains(percent) else { return nil }
        return percent / 100
    }
}
