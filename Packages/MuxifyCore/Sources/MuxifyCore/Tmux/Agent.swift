import Foundation

/// Which coding-agent CLI an Agent is, as its Extension names it in the Pane's
/// `@muxify_agent` option (ADR 0004). The raw value is also its icon's name.
public enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude, codex, opencode, pi

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        }
    }
}

/// What an Agent is doing, from the Pane's `@muxify_agent_status` option.
public enum AgentStatus: String, Codable, Sendable {
    case working, blocked, done, failed

    /// Reaching this Status makes the Agent Unread unless automatic reading applies.
    public var needsAttention: Bool { self != .working }
}

/// An Agent running in a Pane, as listed in the sidebar's Agents section.
public struct Agent: Identifiable, Hashable {
    /// The Pane the Agent runs in, e.g. "%42".
    public let paneID: String
    public let kind: AgentKind
    /// nil until the Agent has run a turn.
    public let status: AgentStatus?
    /// A done, failed or blocked update that has not been marked read.
    public let unread: Bool
    public let windowID: String
    public let sessionID: String
    public let sessionName: String
    public let windowIndex: Int
    /// The Window's `displayTitle`.
    public let windowTitle: String
    public var sourceID = ""
    /// The `label` of the Agent's own Pane, not of its Window's active Pane,
    /// which may be running vim next to it.
    public let label: String
    /// The Pane's current folder.
    public var path = ""

    public var id: String { paneID }
    public var location: String { "\(sessionName):\(windowIndex)" }

    /// Whether the Pane runs an Agent. A Pane back at a plain shell doesn't:
    /// an Agent killed without cleaning up leaves its options behind.
    public static func runs(in pane: TmuxPane) -> Bool {
        AgentKind(rawValue: pane.agent) != nil && !Tmux.shellNames.contains(pane.command)
    }

    /// One Agent per running Pane. Ordering puts Unread first, then working;
    /// without ordering, the result follows the snapshot's Pane order.
    public static func list(panes: [TmuxPane], windows: [TmuxWindow], ordered: Bool = true) -> [Agent] {
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agents = panes.compactMap { pane -> Agent? in
            guard runs(in: pane),
                  let kind = AgentKind(rawValue: pane.agent),
                  let window = windowsByID[pane.windowID]
            else { return nil }
            return Agent(
                paneID: pane.id,
                kind: kind,
                status: AgentStatus(rawValue: pane.agentStatus),
                unread: pane.unread,
                windowID: window.id,
                sessionID: window.sessionID,
                sessionName: window.sessionName,
                windowIndex: window.index,
                windowTitle: window.displayTitle,
                sourceID: window.sourceID,
                label: pane.label,
                path: pane.path
            )
        }
        guard ordered else { return agents }
        return agents.filter(\.unread)
            + agents.filter { !$0.unread && $0.status == .working }
            + agents.filter { !$0.unread && $0.status != .working }
    }
}
