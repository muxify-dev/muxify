/// The Agent mark that a card, a row or a Command Palette result shows: the Working mark, or a Notification of
/// one Status. Every surface takes its mark from here, so one Agent shows the same mark everywhere.
public enum AgentMark: String, Codable, CaseIterable, Comparable, Sendable {
    // Weakest first: a group of Agents shows the mark of its strongest member.
    case working, done, failed, blocked

    /// The mark of one Agent. A blocked Agent shows its Notification while it stays blocked, read or Unread; done and
    /// failed show theirs only while Unread. Each type shows only while its `notifications.*_enabled` is on.
    public init?(_ agent: Agent, notifications: Config.Notifications) {
        switch agent.status {
        case .working?:
            self = .working
        case .blocked? where notifications.blockedEnabled:
            self = .blocked
        case .failed? where agent.unread && notifications.failedEnabled:
            self = .failed
        case .done? where agent.unread && notifications.doneEnabled:
            self = .done
        default:
            return nil
        }
    }

    public var isNotification: Bool { self != .working }

    public static func < (lhs: AgentMark, rhs: AgentMark) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The Agent marks of one set of Agents, by Pane, Window and Session ID. A Window, a Session and a card show the
/// strongest mark of the Agents in them.
public struct AgentMarks: Equatable, Sendable {
    public let panes: [String: AgentMark]
    public let windows: [String: AgentMark]
    public let sessions: [String: AgentMark]

    public init(_ agents: [Agent], notifications: Config.Notifications) {
        let marked = agents.compactMap { agent in AgentMark(agent, notifications: notifications).map { (agent: agent, mark: $0) } }
        panes = Dictionary(marked.map { ($0.agent.paneID, $0.mark) }, uniquingKeysWith: { first, _ in first })
        windows = Dictionary(marked.map { ($0.agent.windowID, $0.mark) }, uniquingKeysWith: max)
        sessions = Dictionary(marked.map { ($0.agent.sessionID, $0.mark) }, uniquingKeysWith: max)
    }

    /// The Agent mark of a card that holds these Sessions.
    public func card(sessions ids: [String]) -> AgentMark? { ids.compactMap { sessions[$0] }.max() }
}
