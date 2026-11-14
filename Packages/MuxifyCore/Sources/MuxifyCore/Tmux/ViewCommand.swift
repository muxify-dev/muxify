import Foundation

/// A way out of a Pane, as tmux's `select-pane` and `resize-pane` take it.
public enum PaneDirection: String, Codable, Hashable, Sendable {
    case up, down, left, right

    var flag: String {
        switch self {
        case .up: "-U"
        case .down: "-D"
        case .left: "-L"
        case .right: "-R"
        }
    }
}

/// Where `select_pane` goes from its target: a neighbour, or the Window's previous or next Pane.
public enum PaneMove: String, Codable, Hashable, Sendable {
    case up, down, left, right, previous, next
}

/// What `resize_pane` does to its Pane.
public enum PaneResize: Codable, Hashable, Sendable {
    /// Zooms the Pane, or unzooms its Window.
    case zoom
    /// Moves the Pane's border that faces `direction` by `cells`.
    case border(PaneDirection, cells: Int)

    private enum BorderCodingKeys: String, CodingKey {
        case _0 = "direction"
        case cells
    }
}

/// One Agent's Unread, as `set_agent_unread` writes it.
public struct PaneUnread: Codable, Hashable, Sendable {
    public let pane: String
    public let unread: Bool

    public init(pane: String, unread: Bool) {
        self.pane = pane
        self.unread = unread
    }
}

/// The App Window's own tmux commands, which ADR 0039 gives no mirror: what it does to the Window it shows, its
/// Panes, its Client and the Browser state on its Windows (ADR draft `09-message-surface`). The app sends these and
/// never a raw tmux argument list; `ViewCommandExecutor` turns each into tmux commands on whatever machine runs it.
public enum ViewCommand: Codable, Hashable, Sendable {
    /// Makes `target` its Window's active Pane, or, with `move`, the Pane in that direction from it. For
    /// `previous` and `next`, `target` is the Window.
    case selectPane(target: String, move: PaneMove? = nil)
    /// Shows `target` in the App Window's own Client `client`, keeping a Zoomed Pane zoomed. Refused when `client`
    /// no longer names that Client.
    case switchClient(client: String, target: String)
    /// Splits `target`, putting the new Pane on its `side`, started in `directory`, else in the Pane's folder.
    case splitPane(target: String, side: PaneDirection, directory: String? = nil)
    case resizePane(target: String, by: PaneResize)
    /// Spreads the Panes of `target`'s Window out evenly.
    case selectLayout(target: String)
    /// Remembers the App Window's Window on the server, so it cannot outlive the server and name a reused id.
    case setLastWindow(window: String)
    /// Sets or clears each Agent's Unread, in one tmux call.
    case setAgentUnread([PaneUnread])
    /// Writes a Window's Browser onto it (ADR 0003).
    case setBrowser(window: String, browser: StoredBrowser)
    /// Clears the `@muxify_open` URLs of a Window once they are opened.
    case clearOpenRequests(window: String)
    /// Names the socket that serves Browser commands, or clears it with nil.
    case setBrowserSocket(path: String?)
    /// The active Pane of `window`, answered as `<pane id> <window id>`.
    case activePane(window: String)
    /// Whether `pane` is its Window's active Pane, answered `1` or `0`.
    case paneIsActive(pane: String)
    /// A step of Find in Pane in `target` through copy mode (ADR 0051), answered as a `PaneSearch.Status`.
    case findInPane(PaneSearch.Step, query: String, target: String, styles: PaneSearch.Styles)
    /// Leaves Find in Pane's copy mode and its highlight.
    case cancelFind(pane: String)
    /// The text of `pane` from `fromLine`, counted as `capture-pane` counts lines, to its bottom.
    case capturePane(pane: String, fromLine: Int)
    /// Types `keys` into `target` as the client `client`, or as no client with nil; `literal` types them as text.
    case sendKeys(target: String, keys: [String], literal: Bool, client: String?)
    /// Starts `command` in a new Window in the background at `target`, a Session or, with `after`, right after
    /// a Window, in `directory`. Answered with the new Window's id.
    case newWindow(target: String, after: Bool, directory: String, command: String)
    case killSession(session: String)
    /// The current Pane of the App Window's own Client `client`. Refused when `client` no longer names that Client.
    case clientPane(client: String)
    /// Pastes `text` into `pane` as a bracketed paste.
    case paste(pane: String, text: String)

    private enum CodingKeys: String, CodingKey {
        case selectPane = "select_pane"
        case switchClient = "switch_client"
        case splitPane = "split_pane"
        case resizePane = "resize_pane"
        case selectLayout = "select_layout"
        case setLastWindow = "set_last_window"
        case setAgentUnread = "set_agent_unread"
        case setBrowser = "set_browser"
        case clearOpenRequests = "clear_open_requests"
        case setBrowserSocket = "set_browser_socket"
        case activePane = "active_pane"
        case paneIsActive = "pane_is_active"
        case findInPane = "find_in_pane"
        case cancelFind = "cancel_find"
        case capturePane = "capture_pane"
        case sendKeys = "send_keys"
        case newWindow = "new_window"
        case killSession = "kill_session"
        case clientPane = "client_pane"
        case paste
    }

    private enum SetAgentUnreadCodingKeys: String, CodingKey { case _0 = "panes" }
    private enum FindInPaneCodingKeys: String, CodingKey {
        case _0 = "step"
        case query, target, styles
    }
    private enum CapturePaneCodingKeys: String, CodingKey {
        case pane
        case fromLine = "from_line"
    }

    /// The App Window's own Client that the command acts as, which must still be that Client when it runs.
    public var ownClient: String? {
        switch self {
        case .switchClient(let client, _), .clientPane(let client): client
        default: nil
        }
    }
}

extension StoredBrowser: Codable {
    private enum CodingKeys: String, CodingKey {
        case tabs
        case activeTab = "active_tab"
        case shown, maximized
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tabURLs: try values.decode([String].self, forKey: .tabs),
                  activeTab: try values.decode(Int.self, forKey: .activeTab),
                  layout: PanelLayout(shown: try values.decode(PanelLayout.Shown.self, forKey: .shown),
                                      maximized: try values.decodeIfPresent(PanelLayout.Side.self, forKey: .maximized)))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tabURLs, forKey: .tabs)
        try values.encode(activeTab, forKey: .activeTab)
        try values.encode(layout.shown, forKey: .shown)
        try values.encodeIfPresent(layout.maximized, forKey: .maximized)
    }
}

/// Why a view command did not run.
public enum ViewCommandError: Error, Equatable, CustomStringConvertible {
    /// The command's `-c <tty>` no longer names the App Window's own Client: that Client is gone, or another
    /// took its tty.
    case clientChanged(tty: String)

    public var description: String {
        switch self {
        case .clientChanged(let tty): "Muxify: the App Window's tmux client \(tty) changed."
        }
    }
}

/// Runs view commands as tmux commands on the machine it runs on: in the app for this Mac, over the app's exec
/// for a Remote Environment, and in the Host Server.
public struct ViewCommandExecutor {
    /// The App Window's own Client, as its marker names it.
    public struct Client: Hashable, Sendable {
        public let tty: String
        public let pid: Int

        public init(tty: String, pid: Int) {
            self.tty = tty
            self.pid = pid
        }
    }

    private let execute: ([String]) throws -> String
    private let ownClient: Client?

    /// `ownClient` is the Client that a command acting as a Client must still find at its tty; nil checks nothing,
    /// for a transport that checks it itself or before the Client is known.
    public init(ownClient: Client? = nil, run: @escaping ([String]) throws -> String) {
        self.ownClient = ownClient
        execute = run
    }

    public init(server: TmuxRunning, ownClient: Client? = nil) {
        self.init(ownClient: ownClient) { try server.run($0) }
    }

    /// Runs `command` and returns tmux's output.
    @discardableResult
    public func run(_ command: ViewCommand) throws -> String {
        if let tty = command.ownClient { try check(tty) }
        let arguments = Self.arguments(for: command)
        guard case .paste = command, let buffer = arguments.firstIndex(of: "-b").map({ arguments[$0 + 1] }) else {
            return try execute(arguments)
        }
        // `paste-buffer -d` deletes the buffer; this deletes it when the paste fails after `set-buffer`.
        defer { _ = try? execute(["delete-buffer", "-b", buffer]) }
        return try execute(arguments)
    }

    /// The one tmux invocation of `command`, without the own-Client check. Commands are joined by `;`.
    public static func arguments(for command: ViewCommand) -> [String] {
        switch command {
        case .selectPane(let target, let move):
            switch move {
            case nil: return ["select-pane", "-t", target]
            case .previous: return ["select-pane", "-t", target + ".-"]
            case .next: return ["select-pane", "-t", target + ".+"]
            case .up: return ["select-pane", PaneDirection.up.flag, "-t", target]
            case .down: return ["select-pane", PaneDirection.down.flag, "-t", target]
            case .left: return ["select-pane", PaneDirection.left.flag, "-t", target]
            case .right: return ["select-pane", PaneDirection.right.flag, "-t", target]
            }
        case .switchClient(let client, let target):
            return ["switch-client", "-Z", "-c", client, "-t", target]
        case .splitPane(let target, let side, let directory):
            let flags: [String] = switch side {
            case .left: ["-h", "-b"]
            case .right: ["-h"]
            case .up: ["-v", "-b"]
            case .down: ["-v"]
            }
            return ["split-window"] + flags + ["-t", target, "-c", directory ?? "#{pane_current_path}"]
        case .resizePane(let target, .zoom):
            return ["resize-pane", "-Z", "-t", target]
        case .resizePane(let target, .border(let direction, let cells)):
            return ["resize-pane", direction.flag, "-t", target, String(cells)]
        case .selectLayout(let target):
            return ["select-layout", "-E", "-t", target]
        case .setLastWindow(let window):
            return ["set-option", "-gq", Tmux.lastWindowOption, window]
        case .setAgentUnread(let changes):
            return Array(changes.map { AgentUnread.command($0.unread, paneID: $0.pane) }.joined(separator: [";"]))
        case .setBrowser(let window, let browser):
            return browser.setOptionArgs(windowID: window)
        case .clearOpenRequests(let window):
            return ["set-option", "-wqu", "-t", window, Tmux.openOption]
        case .setBrowserSocket(let path):
            return path.map { ["set-option", "-sq", BrowserAgentChannel.option, $0] } ?? ["set-option", "-squ", BrowserAgentChannel.option]
        case .activePane(let window):
            return ["display-message", "-p", "-t", window, "#{pane_id} #{window_id}"]
        case .paneIsActive(let pane):
            return ["display-message", "-p", "-t", pane, "#{pane_active}"]
        case .findInPane(let step, let query, let target, let styles):
            return PaneSearch.commands(step, query: query, target: target, styles: styles)
        case .cancelFind(let pane):
            return PaneSearch.cancel(pane: pane)
        case .capturePane(let pane, let line):
            return ["capture-pane", "-p", "-J", "-t", pane, "-S", String(line), "-E", "-"]
        case .sendKeys(let target, let keys, let literal, let client):
            return Tmux.sendKeysArguments(target: target, keys: keys, literal: literal, client: client)
        case .newWindow(let target, let after, let directory, let command):
            return ["new-window", "-d", "-P", "-F", "#{window_id}"] + (after ? ["-a"] : []) + ["-t", target, "-c", directory, command]
        case .killSession(let session):
            return ["kill-session", "-t", session]
        case .clientPane(let client):
            return ["display-message", "-p", "-c", client, "#{pane_id}"]
        case .paste(let pane, let text):
            let buffer = "muxify-paste-" + UUID().uuidString
            return ["set-buffer", "-b", buffer, "--", text, ";", "paste-buffer", "-d", "-p", "-b", buffer, "-t", pane]
        }
    }

    /// Refuses a command whose `-c <tty>` no longer names the own Client: the client at that tty must have its pid.
    private func check(_ tty: String) throws {
        guard let ownClient else { return }
        let clients = try execute(["list-clients", "-F", "#{client_pid} #{client_tty}"])
        let pid = clients.split(separator: "\n").lazy.compactMap { line -> Int? in
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2, fields[1] == tty else { return nil }
            return Int(fields[0])
        }.first
        guard pid == ownClient.pid else { throw ViewCommandError.clientChanged(tty: tty) }
    }
}
