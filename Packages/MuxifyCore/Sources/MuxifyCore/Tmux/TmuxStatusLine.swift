import Foundation

/// The tmux commands that hide tmux's status line in the Sessions that Muxify's Terminal shows, while the App Window's
/// header shows the Session and its Windows (`ui.status_line`, ADR 0099), and that give it back.
///
/// `status` belongs to a Session, not to a Client, so the last Client to arrive in a Session wins. Muxify marks each
/// Session where it turned `status` off with `@muxify_status_hidden`, and puts one entry of its own in the
/// `client-attached` and `client-session-changed` hooks: a Client that is neither a control Client nor a Muxify Terminal
/// gives a marked Session its status line back, also after Muxify quit. It undoes only Muxify's `status off`, never one
/// of the user's tmux config. tmux reads a Client's `MUXIFY_TERMINAL` from 3.8 on; an older tmux takes every Client for
/// another terminal, and the publisher hides the status line again after each move of the Terminal.
public enum TmuxStatusLine {
    /// The Session option that marks a `status off` as Muxify's.
    public static let marker = "@muxify_status_hidden"
    /// Muxify's own index in each hook's array, so the user's hooks keep theirs.
    static let hookIndex = 77
    static let hooks = ["client-attached", "client-session-changed"]

    /// Runs in the hooks' Client: true for another terminal that arrives in a Session that Muxify marked.
    static let anotherTerminal = "#{?\(marker),#{?client_control_mode,,#{?#{==:#{I/e:MUXIFY_TERMINAL},1},,1}},}"
    static let hookCommand = "if-shell -F \"\(anotherTerminal)\" \"set-option -u status ; set-option -u \(marker)\""

    /// Hides the status line in `session`, a Session id, and sets the hooks that give it back to another terminal.
    public static func hiding(_ session: String) -> [[String]] {
        [["set-option", "-t", session, "status", "off"], ["set-option", "-t", session, marker, "1"]]
            + hooks.map { ["set-hook", "-g", "\($0)[\(hookIndex)]", hookCommand] }
    }

    /// Gives the status line back to every Session that `listing` printed as marked, and removes the hooks.
    public static func showing(listed: String) -> [[String]] {
        let marked = listed.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ", maxSplits: 1)
            return fields.count == 2 && fields[1] == "1" ? String(fields[0]) : nil
        }
        return marked.flatMap { [["set-option", "-u", "-t", $0, "status"], ["set-option", "-u", "-t", $0, marker]] }
            + hooks.map { ["set-hook", "-gu", "\($0)[\(hookIndex)]"] }
    }

    /// The `list-sessions` that `showing` reads.
    public static let listing = ["list-sessions", "-F", "#{session_id} #{\(marker)}"]

    /// One command as a line of the Listener's control connection.
    static func line(_ arguments: [String]) -> String {
        arguments.map(Tmux.shellQuote).joined(separator: " ")
    }
}
