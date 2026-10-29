import Foundation

/// One Browser command from a Pane, as the CLI sends it to the app (ADR 0057, ADR 0058). `window` is the
/// caller's tmux Window. `tab` names a Tab of it; without it, the command acts on the Window's active Tab, and
/// `open` opens a new Tab.
public struct BrowserAgentRequest: Codable, Equatable, Sendable {
    public var window: String
    public var tab: UUID?
    public var command: BrowserAgentCommand

    public init(window: String, tab: UUID? = nil, command: BrowserAgentCommand) {
        self.window = window
        self.tab = tab
        self.command = command
    }
}

public enum BrowserAgentCommand: Codable, Equatable, Sendable {
    case tabs
    case open(url: String)
    case eval(script: String)
    case screenshot
    case snapshot
    case click(ref: String)
    case fill(ref: String, text: String)
    /// Without `ref`, the key goes to the element that has the page's focus.
    case press(key: String, ref: String?)
    case wait(BrowserAgentWait, timeout: TimeInterval)

    /// The longest time the app can take to reply, so the CLI does not give up first.
    public var replyTimeout: TimeInterval {
        if case .wait(_, let timeout) = self { return timeout + 10 }
        return 60
    }
}

public enum BrowserAgentWait: Codable, Equatable, Sendable {
    case load
    case text(String)
    case selector(String)
}

public struct BrowserAgentTab: Codable, Equatable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var active: Bool

    public init(id: UUID, url: String, title: String, active: Bool) {
        self.id = id
        self.url = url
        self.title = title
        self.active = active
    }
}

public enum BrowserAgentReply: Codable, Equatable, Sendable {
    case tabs([BrowserAgentTab])
    case opened(BrowserAgentTab)
    /// `eval`'s result as JSON, or `undefined`.
    case value(String)
    case snapshot(String)
    case png(Data)
    case done
    case failure(message: String, exitCode: Int32)

    public static func failure(_ message: String) -> Self { .failure(message: message, exitCode: 1) }
}
