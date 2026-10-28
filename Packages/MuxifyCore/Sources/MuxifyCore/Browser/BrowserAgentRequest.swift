import Foundation

/// One Browser command from a Pane, as the CLI sends it to the app (ADR 0057). `window` and `pane` are the
/// caller's tmux ids. `tab` names a Tab; without it, the command acts on the Pane's Agent Tab.
public struct BrowserAgentRequest: Codable, Equatable, Sendable {
    public var window: String
    public var pane: String?
    public var tab: UUID?
    public var command: BrowserAgentCommand

    public init(window: String, pane: String?, tab: UUID? = nil, command: BrowserAgentCommand) {
        self.window = window
        self.pane = pane
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
    /// The caller's Agent Tab.
    public var agent: Bool

    public init(id: UUID, url: String, title: String, active: Bool, agent: Bool) {
        self.id = id
        self.url = url
        self.title = title
        self.active = active
        self.agent = agent
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
