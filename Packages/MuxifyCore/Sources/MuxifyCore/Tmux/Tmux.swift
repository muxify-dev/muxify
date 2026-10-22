import Foundation
import Darwin

/// A tmux window as shown in the sidebar.
public struct TmuxWindow: Identifiable, Hashable {
    /// Server-unique window id, e.g. "@27".
    public let id: String
    public let sessionID: String
    public let sessionName: String
    public let index: Int
    public let name: String
    public let paneTitle: String
    public let path: String
    public let command: String
    public let isActive: Bool
    public let paneCount: Int
    public let hasBell: Bool
    public let sessionActivity: Int
    /// The active Pane's Agent kind, empty when no Agent reports there.
    public var agent: String
    /// The Window's Browser as last written to its tmux options.
    public var storedBrowser: StoredBrowser
    /// URLs a program asked to open via `@muxify_open` (not yet consumed).
    public var openRequests: [String]
    public var homeDirectory = NSHomeDirectory()
    public var hostName = Tmux.hostName
    public var isRemote = false
    /// Connection/server ownership, so a stale UI item cannot address reused IDs.
    public var sourceID = ""
    public var topicID: String? = nil
    /// Durable remembered identity. New/restored Sessions carry it in a Session option.
    public var savedSessionID = ""
    public var sessionRecordID: String { savedSessionID.isEmpty ? sessionID : savedSessionID }
    /// The Session's `@muxify_lock`: its place in the Topics list while it is Locked (ADR 0018).
    public var lockOrder: Double? = nil
    public var sessionPath: String = ""
    public var activePaneID: String = ""
    public var startCommand: String = ""
    /// tmux `#{session_created}` of the Window's Session, in seconds since 1970.
    public var sessionCreated = 0
    /// tmux `#{window_layout}`: where each Pane sits, as `select-layout` takes it. tmux gives the unzoomed layout.
    public var layout = ""

    /// The pane title is what shells and TUIs set via OSC 0/2 (fish sets it to
    /// `~/w/sessionPath`), so it is the best human label. tmux defaults it to the
    /// hostname, in which case we fall back to the window name or the path.
    public var displayTitle: String {
        let visibleTitle = command == "codex" ? CodexReports.titleForDisplay(paneTitle) : paneTitle
        if let title = Tmux.label(fromPaneTitle: withoutSSHHostPrefix(visibleTitle.trimmingCharacters(in: .whitespaces)), hostName: hostName) { return title }
        if !Tmux.shellNames.contains(name) { return name }
        return Paths.fishStyle(path, home: homeDirectory)
    }

    public var abbreviatedPath: String { Paths.tildify(path, home: homeDirectory) }

    /// The logo for what the active Pane runs (`Resources/Logos`): the Agent
    /// it reports, else its command. Claude Code shows up as its version
    /// number (`2.1.289`) until its Extension reports. A command's version
    /// suffix and case don't matter (`python3.12`, `Python` → `python`).
    /// Shells get the terminal logo.
    public var logoName: String {
        if AgentKind(rawValue: agent) != nil { return agent }
        if Tmux.shellNames.contains(command) { return "terminal" }
        if command.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil { return AgentKind.claude.rawValue }
        if let alias = Self.commandAliases[command] { return alias }
        let name = command.lowercased().replacingOccurrences(of: #"[\d.]+$"#, with: "", options: .regularExpression)
        return Self.commandAliases[name] ?? (name.isEmpty ? command : name)
    }

    /// Commands that share another command's logo.
    private static let commandAliases = [
        "vim": "nvim", "vi": "nvim",
        "cargo": "rust", "rustc": "rust",
        "postgres": "psql",
        "redis-cli": "redis", "redis-server": "redis",
    ]

    /// fish prefixes SSH titles with `[hostname]` (truncated to 10 characters).
    /// The Environment selector already identifies this host. Keep prefixes
    /// for other hosts/tasks and leave the underlying tmux title untouched.
    private func withoutSSHHostPrefix(_ title: String) -> String {
        guard isRemote, !hostName.isEmpty else { return title }
        let shortHost = hostName.split(separator: ".").first.map(String.init) ?? hostName
        for host in Set([hostName, shortHost, String(hostName.prefix(10)), String(shortHost.prefix(10))]) {
            let prefix = "[\(host)]"
            if title == prefix { return "" }
            if title.hasPrefix(prefix + " ") {
                return String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return title
    }

}

/// A Window's Browser as stored in tmux window options (ADR 0003). Tab URLs
/// are space-separated (URLs never contain spaces); an empty Tab is
/// `about:blank`. `@muxify_browser` holds the toggles (`off`: the Terminal,
/// `on`: both, `only`: the Browser) and `@muxify_maximize` the Maximized side.
public struct StoredBrowser: Hashable {
    public var tabURLs: [String] = []
    public var activeTab = 0
    public var layout = PanelLayout()

    public init(tabURLs: [String] = [], activeTab: Int = 0, layout: PanelLayout = PanelLayout()) {
        self.tabURLs = tabURLs
        self.activeTab = activeTab
        self.layout = layout
    }

    public init(tabs: String, activeTab: String, shown: String, maximized: String) {
        tabURLs = tabs.split(separator: " ").map(String.init)
        self.activeTab = Int(activeTab) ?? 0
        layout = PanelLayout(shown: Self.shownValues.first { $0.value == shown }?.key ?? .terminal,
                             maximized: Self.maximizeValues.first { $0.value == maximized }?.key)
    }

    private static let shownValues: [PanelLayout.Shown: String] = [.terminal: "off", .both: "on", .browser: "only"]
    private static let maximizeValues: [PanelLayout.Side: String] = [.terminal: "terminal", .browser: "browser"]

    /// `set-option` arguments that write this state onto `windowID`.
    public func setOptionArgs(windowID: String) -> [String] {
        let values: [(option: String, value: String?)] = [
            (Tmux.tabsOption, tabURLs.isEmpty ? nil : tabURLs.joined(separator: " ")),
            (Tmux.activeTabOption, tabURLs.isEmpty ? nil : String(activeTab)),
            (Tmux.shownOption, layout.shown == .terminal ? nil : Self.shownValues[layout.shown]),
            (Tmux.maximizeOption, layout.maximized.flatMap { Self.maximizeValues[$0] }),
        ]
        return Array(values.flatMap { option, value in
            value.map { ["set-option", "-wq", "-t", windowID, option, $0, ";"] }
                ?? ["set-option", "-wqu", "-t", windowID, option, ";"]
        }.dropLast())
    }
}

/// A client attached to the tmux server (one of them is ours).
public struct TmuxClient: Hashable {
    public let tty: String
    public let sessionID: String
    public let windowID: String
    public var pid = 0
    public var isControl = false
}

/// A tmux Pane, with the options an Agent's Extension writes onto it (ADR 0004).
public struct TmuxPane: Hashable {
    /// Server-unique pane id, e.g. "%42".
    public let id: String
    public let windowID: String
    public var index = 0
    /// The Window's active Pane, the one tmux sends keys to.
    public var isActive = false
    /// `#{pane_title}`, which shells and TUIs set via OSC 0/2.
    public var title = ""
    public var path = ""
    /// `#{pane_current_command}`. It can't identify an Agent (Claude Code's is
    /// its version number), but a plain shell here means no Agent is running.
    public let command: String
    /// The reported Agent kind, or Codex identified by its foreground command.
    public var agent: String
    /// The Extension's Status, empty before a report or after SessionEnd.
    public var agentStatus: String
    /// `@muxify_agent_unread`, which Muxify itself sets.
    public let unread: Bool
    public var agentConversation: String = ""
    /// `#{pane_tty}`, such as `/dev/ttys003`.
    public var tty = ""

    /// What the Sidebar calls this Pane.
    public var label: String {
        let visibleTitle = command == "codex" ? CodexReports.titleForDisplay(title) : title
        if let title = Tmux.label(fromPaneTitle: visibleTitle) { return title }
        if Agent.runs(in: self) { return agent }
        if !Tmux.shellNames.contains(command) { return command }
        return Paths.fishStyle(path)
    }
}

public struct TmuxSnapshot {
    public var windows: [TmuxWindow]
    public var clients: [TmuxClient]
    public var panes: [TmuxPane]
    /// The Window last selected in Muxify (a server-wide option, so it can't
    /// outlive the server and point at a reused window id).
    public var lastWindowID: String?
    public var serverRunning: Bool
    public var serverID: String?
    public var ownClientTTY: String?
    public var homeDirectory: String?

    public init(windows: [TmuxWindow], clients: [TmuxClient], panes: [TmuxPane], lastWindowID: String? = nil, serverRunning: Bool, serverID: String? = nil, ownClientTTY: String? = nil, homeDirectory: String? = nil) {
        self.windows = windows
        self.clients = clients
        self.panes = panes
        self.lastWindowID = lastWindowID
        self.serverRunning = serverRunning
        self.serverID = serverID
        self.ownClientTTY = ownClientTTY
        self.homeDirectory = homeDirectory
    }

    /// The full command line of each Pane's program. tmux does not give it, so a snapshot has none until the
    /// caller reads `ps` for it.
    public var commandLines = PaneCommandLines()

    /// The Agents running in this snapshot's Panes, in tmux order.
    public var agents: [Agent] { Agent.list(panes: panes, windows: windows) }
}

public enum TmuxError: Error, Equatable, CustomStringConvertible {
    case notInstalled
    case failed(status: Int32, stderr: String)
    case cancelled
    case timedOut
    case notReady

    /// Permission errors and timeouts are not evidence that Sessions are gone.
    public var indicatesNoSessions: Bool {
        guard case .failed(_, let stderr) = self else { return false }
        let message = stderr.lowercased()
        return message.contains("no sessions") || indicatesNoServer
    }

    public var indicatesNoServer: Bool {
        guard case .failed(_, let stderr) = self else { return false }
        let message = stderr.lowercased()
        return message.contains("no server running")
            || (message.contains("error connecting") && message.contains("no such file or directory"))
    }

    public var description: String {
        switch self {
        case .notInstalled: return "tmux was not found on this Mac"
        case .failed(let status, let stderr): return "tmux exited with \(status): \(stderr)"
        case .cancelled: return "The Environment connection was closed"
        case .timedOut: return "The tmux command timed out"
        case .notReady: return "Waiting for the SSH connection and remote tmux client"
        }
    }
}

public enum Tmux {
    public static let binary: String? = locateBinary()
    public static let hostName: String = {
        var name = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&name, name.count) == 0 else { return "" }
        return String(cString: name)
    }()
    public static let shortHostName = hostName.split(separator: ".").first.map(String.init) ?? hostName
    public static let shellNames: Set<String> = ["fish", "zsh", "bash", "sh", "dash", "ash", "ksh", "csh", "tcsh", "nu", "elvish", "xonsh", "login"]

    // tmux user options Muxify keeps its state in.
    public static let tabsOption = "@muxify_tabs"
    public static let activeTabOption = "@muxify_active_tab"
    /// The Terminal and Browser toggles and Maximize (`PanelLayout`).
    public static let shownOption = "@muxify_browser"
    public static let maximizeOption = "@muxify_maximize"
    /// One-shot: programs set it to open a Tab; Muxify consumes and clears it.
    public static let openOption = "@muxify_open"
    public static let lastWindowOption = "@muxify_last_window"
    // Pane options an Agent's Extension writes (ADR 0004).
    public static let agentOption = "@muxify_agent"
    public static let agentStatusOption = "@muxify_agent_status"
    public static let agentConversationOption = "@muxify_agent_conversation"
    /// Set by Muxify, not the Extension: the Agent finished or got blocked
    /// while you weren't looking at its Window.
    public static let agentUnreadOption = "@muxify_agent_unread"

    /// A pane title as a label, or nil when it says nothing: tmux defaults it
    /// to the host name. Claude Code titles its terminal "✳ <conversation>" and
    /// animates the glyph while it works; the logo already says it's Claude.
    public static func label(fromPaneTitle paneTitle: String, hostName: String = Tmux.hostName) -> String? {
        let trimmed = paneTitle.trimmingCharacters(in: .whitespaces)
        let scalars = trimmed.unicodeScalars.drop { $0.properties.generalCategory == .otherSymbol || $0 == "·" }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        let title = text.isEmpty ? trimmed : text
        let shortHostName = hostName.split(separator: ".").first.map(String.init) ?? hostName
        guard !title.isEmpty, title != hostName, title != shortHostName else { return nil }
        return title
    }

    public static let separator = "\u{241F}"

    private static func locateBinary() -> String? {
        var candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/run/current-system/sw/bin/tmux",
            "\(NSHomeDirectory())/.nix-profile/bin/tmux",
            "/usr/bin/tmux",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/tmux" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The `send-keys` arguments that type `keys` into the target's pane as the client `client`, or as no
    /// client when nil. Without `-c` tmux types as its most recently active client, which may be the
    /// events client. The empty name matches no client, which send-keys accepts.
    public static func sendKeysArguments(target: String, keys: [String], literal: Bool, client: String?) -> [String] {
        ["send-keys", "-c", client ?? ""] + (literal ? ["-l", "-t", target, "--"] : ["-t", target]) + keys
    }

    /// Reads tmux inventory and the reports for its Codex conversations.
    public static func readSnapshot(using execute: ([String]) throws -> String) throws -> TmuxSnapshot {
        let output = try execute(snapshotArguments)
        let snapshot = parseSnapshot(output)
        let prefixes = CodexReports.prefixes(in: snapshot)
        guard !prefixes.isEmpty else { return snapshot }
        let reports = (try? execute(["run-shell", CodexReports.readScript(prefixes: prefixes)])) ?? ""
        return parseSnapshot(output + "\n" + reports)
    }

    /// The foreground SSH owner sends its final inventory on stdin before
    /// disconnecting. Read only reports that can belong to that inventory.
    public static var codexReportsForInventoryScript: String {
        """
        prefixes=$(awk -F '\(separator)' '$1 == "P" && $4 == "codex" { print $12 }' |
            grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{5}' | sort -u)
        directory="$HOME/.local/state/muxify/codex"
        for prefix in $prefixes; do
            for file in "$directory/$prefix"*.json; do
                [ -f "$file" ] || continue
                printf 'D\(separator)'
                head -c 512 "$file" 2>/dev/null | tr -d '\\n\\r'
                printf '\\n'
            done
        done
        """
    }

    /// Also used by the foreground SSH owner to report the final inventory
    /// before its master closes. No independent SSH probe is needed on exit.
    public static var snapshotArguments: [String] {
        let s = separator
        let windowFormat = [
            "W", "#{window_id}", "#{session_id}", "#{session_name}", "#{window_index}",
            "#{window_name}", "#{pane_title}", "#{pane_current_path}", "#{pane_current_command}",
            "#{window_active}", "#{window_panes}", "#{window_bell_flag}", "#{session_activity}",
            "#{\(tabsOption)}", "#{\(activeTabOption)}", "#{\(shownOption)}", "#{\(openOption)}",
            "#{\(lastWindowOption)}", "#{\(agentOption)}", "#{@muxify_topic}", "#{session_path}", "#{pane_id}", "#{pane_start_command}",
            "#{\(maximizeOption)}", "#{session_created}", "#{window_layout}", "#{@muxify_lock}", "#{@muxify_session_id}",
        ].joined(separator: s)
        let clientFormat = ["C", "#{client_tty}", "#{session_id}", "#{window_id}", "#{client_pid}", "#{client_control_mode}"].joined(separator: s)
        let paneFormat = [
            "P", "#{pane_id}", "#{window_id}", "#{pane_current_command}",
            "#{\(agentOption)}", "#{\(agentStatusOption)}", "#{\(agentUnreadOption)}", "#{\(agentConversationOption)}",
            "#{pane_index}", "#{pane_active}", "#{pane_current_path}", "#{pane_title}", "#{pane_tty}",
        ].joined(separator: s)

        return [
            "list-windows", "-a", "-F", windowFormat,
            ";", "list-clients", "-F", clientFormat,
            ";", "list-panes", "-a", "-F", paneFormat,
            ";", "display-message", "-p", "-F", "S\(s)#{pid}:#{start_time}",
        ]
    }

    /// Pure parser, shared by live snapshots and persistence/migration tests.
    public static func parseSnapshot(_ output: String) -> TmuxSnapshot {
        let s = separator
        var windows: [TmuxWindow] = []
        var clients: [TmuxClient] = []
        var panes: [TmuxPane] = []
        var lastWindowID: String?
        var serverID: String?
        var codexReports: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.components(separatedBy: s)
            // Fields Topics added are optional, so older recorded snapshots still parse.
            let field = { (index: Int) in index < f.count ? f[index] : "" }
            if f.first == "W", f.count >= 19 {
                windows.append(TmuxWindow(
                    id: f[1], sessionID: f[2], sessionName: f[3], index: Int(f[4]) ?? 0,
                    name: f[5], paneTitle: f[6], path: f[7], command: f[8],
                    isActive: f[9] == "1", paneCount: Int(f[10]) ?? 1,
                    hasBell: f[11] == "1",
                    sessionActivity: Int(f[12]) ?? 0,
                    agent: f[18],
                    storedBrowser: StoredBrowser(tabs: f[13], activeTab: f[14], shown: f[15], maximized: field(23)),
                    openRequests: f[16].split(separator: " ").map(String.init),
                    topicID: field(19).isEmpty ? nil : field(19), savedSessionID: field(27), lockOrder: Double(field(26)).flatMap { $0.isFinite ? $0 : nil },
                    sessionPath: field(20),
                    activePaneID: field(21), startCommand: field(22), sessionCreated: Int(field(24)) ?? 0,
                    layout: field(25)
                ))
                if !f[17].isEmpty { lastWindowID = f[17] }
            } else if f.first == "C", f.count >= 4 {
                clients.append(TmuxClient(tty: f[1], sessionID: f[2], windowID: f[3],
                                          pid: f.count > 4 ? Int(f[4]) ?? 0 : 0,
                                          isControl: f.count > 5 && f[5] == "1"))
            } else if f.first == "P", f.count >= 7 {
                panes.append(TmuxPane(
                    id: f[1], windowID: f[2], index: Int(field(8)) ?? 0, isActive: field(9) == "1",
                    title: field(11), path: field(10), command: f[3],
                    agent: f[4], agentStatus: f[5], unread: f[6] == "1", agentConversation: field(7), tty: field(12)
                ))
            } else if f.first == "S", f.count >= 2 {
                serverID = f[1]
            } else if f.first == "D", f.count == 2 {
                codexReports.append(f[1])
            }
        }
        for index in windows.indices where windows[index].savedSessionID.isEmpty {
            windows[index].savedSessionID = "tmux:\(serverID ?? "unknown"):\(windows[index].sessionID):\(windows[index].sessionCreated)"
        }
        var snapshot = TmuxSnapshot(
            windows: windows, clients: clients, panes: panes,
            lastWindowID: lastWindowID, serverRunning: true, serverID: serverID
        )
        CodexReports.apply(codexReports, to: &snapshot)
        return snapshot
    }

    public static func shellQuote(_ value: String) -> String {
        // Remote SSH commands first pass through the account's login shell.
        // Quote apostrophes/backslashes in separate double-quoted fragments:
        // unlike POSIX's '\\'' idiom, this also preserves bytes through fish.
        "'" + value.unicodeScalars.map { scalar in
            switch scalar {
            case "'": return "'\"'\"'"
            case "\\": return "'\"\\\\\"'"
            default: return String(scalar)
            }
        }.joined() + "'"
    }
}

public enum ShellError: Error, CustomStringConvertible {
    case failed(executable: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .failed(let executable, let status, let stderr):
            return "\((executable as NSString).lastPathComponent) exited with \(status): \(stderr)"
        }
    }
}

public enum Shell {
    /// Runs a program synchronously and returns stdout. Throws on non-zero exit.
    /// The long deadline leaves git room to check out a large Worktree.
    public static func run(_ executable: String, _ args: [String], directory: String? = nil) throws -> String {
        do {
            return try CommandRunner().run(CommandInvocation(executable: executable, arguments: args),
                                           timeout: 120, directory: directory)
        } catch let TmuxError.failed(status, stderr) {
            throw ShellError.failed(executable: executable, status: status, stderr: stderr)
        }
    }
}

public enum Paths {
    public static let home = NSHomeDirectory()

    /// `/Users/me/work/app` -> `~/work/app`
    public static func tildify(_ path: String, home: String = Paths.home) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// fish's `prompt_pwd`: `/Users/me/work/app` -> `~/w/app`
    public static func fishStyle(_ path: String, home: String = Paths.home) -> String {
        let parts = tildify(path, home: home).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return tildify(path, home: home) }
        let shortened = parts.enumerated().map { index, part -> String in
            if index == parts.count - 1 || part.isEmpty || part == "~" { return String(part) }
            let prefixLength = part.hasPrefix(".") ? 2 : 1
            return String(part.prefix(prefixLength))
        }
        return shortened.joined(separator: "/")
    }
}
