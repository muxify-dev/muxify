import Foundation

/// The tmux commands that hide tmux's status line in the Sessions that Muxify's Terminal shows, while the App Window's
/// header shows the Session and its Windows (`ui.status_line`, ADR 0099), and that give it back.
///
/// `status` belongs to a Session, not to a Client, so the last Client to arrive in a Session wins. tmux itself decides,
/// in one entry of Muxify's own in the `client-attached` and `client-session-changed` hooks: a Muxify Terminal that
/// arrives in a Session turns its `status` off, and another terminal that arrives in a Session Muxify marked gives it
/// back. tmux runs a hook before it draws the Client again, so the Terminal never draws a frame with the status line,
/// however the switch was made and however far away Muxify is (ADR 0104).
///
/// The hook knows a Muxify Terminal by its Client's pid in the global option `@muxify_terminals`: each Terminal's
/// command writes its own pid there before it runs `tmux attach`, and the publisher writes its Terminal's and removes
/// the pids of the processes that ended. Every tmux from 3.2 reads it; a Client's environment only 3.8 does.
/// Muxify marks each Session where it turned `status` off with `@muxify_status_hidden` and undoes only its own
/// `status off`, never one of the user's tmux config, also after Muxify quit.
public enum TmuxStatusLine {
    /// The Session option that marks a `status off` as Muxify's.
    public static let marker = "@muxify_status_hidden"
    /// The global option that lists the pids of Muxify's Terminals' Clients, each between spaces.
    public static let terminals = "@muxify_terminals"
    /// Muxify's own index in each hook's array, so the user's hooks keep theirs.
    static let hookIndex = 77
    static let hooks = ["client-attached", "client-session-changed"]

    /// Runs in the hooks' Client and Session. A Muxify Terminal hides a status line that shows; another terminal, not a
    /// control Client, gives a marked Session its status line back.
    static let hookCommand = "if-shell -F \"#{m:* #{client_pid} *,#{\(terminals)}}\" "
        + "\"if-shell -F '#{?#{==:#{status},off},,1}' 'set-option status off ; set-option \(marker) 1'\" "
        + "\"if-shell -F '#{?\(marker),#{?client_control_mode,,1},}' 'set-option -u status ; set-option -u \(marker)'\""

    /// The hooks that hide the status line for a Muxify Terminal and give it back to another terminal.
    public static let settingHooks: [[String]] = hooks.map { ["set-hook", "-g", "\($0)[\(hookIndex)]", hookCommand] }

    /// Hides the status line in `session`, a Session id, lists `terminal`, the pid of the Terminal's Client, and sets
    /// the hooks.
    public static func hiding(_ session: String, terminal: Int? = nil) -> [[String]] {
        [["set-option", "-t", session, "status", "off"], ["set-option", "-t", session, marker, "1"]]
            + (terminal.map { [registering($0)] } ?? []) + settingHooks
    }

    /// Lists `pid` as a Muxify Terminal's Client, unless it is listed.
    public static func registering(_ pid: Int) -> [String] {
        ["if-shell", "-F", "#{?#{m:* \(pid) *,#{\(terminals)}},,1}", "set-option -ga \(terminals) ' \(pid) '"]
    }

    /// The tmux commands of a Terminal's shell script before it runs `exec tmux attach-session`: they list the
    /// script's pid, which becomes the Client's, and set the hooks, so the first frame has no status line either.
    /// `tmux` is the command line of tmux with its server's arguments.
    public static func attachSetup(tmux: String) -> String {
        let commands = [["set-option", "-gaq", terminals]].map { $0.map(Tmux.shellQuote).joined(separator: " ") + " \" $$ \"" }
            + settingHooks.map { $0.map(Tmux.shellQuote).joined(separator: " ") }
        return "\(tmux) \(commands.joined(separator: " \\; ")) >/dev/null 2>&1"
    }

    /// The pids that `listed`, the value of `terminals`, names.
    public static func listedTerminals(_ listed: String) -> [Int] {
        listed.split(separator: " ").compactMap { Int($0) }
    }

    /// Removes `pid` from `terminals` in one tmux command, so a Terminal that lists itself meanwhile stays.
    public static func unregistering(_ pid: Int) -> [String] {
        ["set-option", "-gF", terminals, "#{s/ \(pid) //:\(terminals)}"]
    }

    /// Gives the status line back to every Session that `listing` printed as marked and to `terminalSession`, a Session
    /// id, and removes the hooks and the list of Terminals. Each Session's command checks the mark when tmux runs it,
    /// so on the Listener's connection it also undoes a hide sent there before it that tmux had not run when `listing`
    /// did.
    public static func showing(listed: String, terminalSession: String?) -> [[String]] {
        let marked = listed.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: " ", maxSplits: 1)
            return fields.count == 2 && fields[1] == "1" ? String(fields[0]) : nil
        }
        let sessions = marked + (terminalSession.map { marked.contains($0) ? [] : [$0] } ?? [])
        return sessions.map { session in
            ["if-shell", "-F", "-t", session, "#{\(marker)}",
             "set-option -u -t '\(session)' status ; set-option -u -t '\(session)' \(marker)"]
        } + hooks.map { ["set-hook", "-gu", "\($0)[\(hookIndex)]"] } + [["set-option", "-gqu", terminals]]
    }

    /// The `list-sessions` that `showing` reads.
    public static let listing = ["list-sessions", "-F", "#{session_id} #{\(marker)}"]

    /// One command as a line of the Listener's control connection.
    static func line(_ arguments: [String]) -> String {
        arguments.map(Tmux.shellQuote).joined(separator: " ")
    }
}
