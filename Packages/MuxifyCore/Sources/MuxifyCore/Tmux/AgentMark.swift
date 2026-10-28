/// The Agent mark that a card, a row or a Command Palette result shows: the Working mark, or a Notification of
/// one Status. Every surface takes its mark from here, so one Agent shows the same mark everywhere.
public enum AgentMark: String, CaseIterable, Comparable, Sendable {
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
