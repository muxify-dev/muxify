public enum AgentReading {
    case away, viewing, visiting
}

public enum ReadChange: String, Codable, Hashable, Sendable {
    case read, unread

    public func applies(unread: Bool, status: AgentStatus?) -> Bool {
        switch self {
        case .read: return unread
        case .unread: return !unread && status?.needsAttention == true
        }
    }
}

public enum AgentUnread {
    /// Sets or clears the Unread of the Agent in `paneID`. tmux keeps it, so every client sees the same Unread.
    public static func command(_ unread: Bool, paneID: String) -> [String] {
        unread
            ? ["set-option", "-pq", "-t", paneID, Tmux.agentUnreadOption, "1"]
            : ["set-option", "-pqu", "-t", paneID, Tmux.agentUnreadOption]
    }

    public static func change(for pane: TmuxPane, previousStatus: String?, reading: AgentReading, manualRead: Bool) -> Bool? {
        let suppressUpdate = reading != .away && !manualRead
        let isAgent = Agent.runs(in: pane)
        if pane.unread {
            return !isAgent || (reading == .visiting && !manualRead) ? false : nil
        }
        if isAgent, !suppressUpdate, let previousStatus, previousStatus != pane.agentStatus,
           AgentStatus(rawValue: pane.agentStatus)?.needsAttention == true {
            return true
        }
        return nil
    }
}
