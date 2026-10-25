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

/// The Panes tmux shows in a Window, independent of the Sidebar's row display.
public enum AgentReadScope: Equatable {
    case window(String)
    case pane(windowID: String, paneID: String)

    public init(window: TmuxWindow) {
        self = window.isZoomed ? .pane(windowID: window.id, paneID: window.activePaneID) : .window(window.id)
    }

    public var windowID: String {
        switch self {
        case .window(let id), .pane(let id, _): return id
        }
    }

    public var target: ReadPlan.Place {
        switch self {
        case .window(let id): return .window(id)
        case .pane(_, let id): return .pane(id)
        }
    }

    public func paneIDs(in panes: [TmuxPane]) -> Set<String> {
        Set(panes.filter { pane in
            guard pane.windowID == windowID else { return false }
            if case .pane(_, let id) = self { return pane.id == id }
            return true
        }.map(\.id))
    }
}

/// Resolves completed navigation against the next confirmed Window snapshot. Only the shown Window's
/// entry survives, so a superseded navigation cannot read an unrelated Window later.
public struct AgentReadVisits {
    private var entries: Set<String> = []
    private var viewed: Set<String> = []

    public init() {}

    public mutating func hide() {
        viewed.removeAll()
        entries.removeAll()
    }

    public mutating func enter(windowID: String) {
        entries.insert(windowID)
    }

    public mutating func consume(showing scope: AgentReadScope?, panes: [TmuxPane], observing: Bool) -> Set<String> {
        let shown = scope?.paneIDs(in: panes) ?? []
        let visible = observing ? shown : []
        let explicit = scope.map { entries.contains($0.windowID) } ?? false
        let visited = explicit ? shown : visible.subtracting(viewed)
        viewed = visible
        entries.removeAll()
        return visited
    }
}
