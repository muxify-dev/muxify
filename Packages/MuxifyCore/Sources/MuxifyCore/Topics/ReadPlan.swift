import Foundation

/// Which place of the target a Mark Read or Mark Unread changes. The target names a Topic, Session, Window or Pane,
/// and the scope says which of the places that contain it changes, so `session mark-read` from a Pane reads its Session.
public enum ReadScope: String, Codable, Hashable, Sendable {
    /// The target's Topic, open or Settled when the target names it, else the open Topic of the target's Pane: its
    /// Topic Unread and the Agents in its Sessions.
    case topic
    /// The Agents in the target's Session.
    case session
    /// The Agents in the target's Window.
    case window
    /// The Agent in the target's Pane.
    case pane
}

/// Records and Agents in; the Topic records and the Agent Panes that one Read change writes out. The service runs it
/// for a request, and the app runs it to know if Mark Read or Mark Unread would change anything.
public enum ReadPlan {
    public enum Place: Equatable, Sendable {
        case environment
        case topic(String)
        case session(String)
        case window(String)
        case pane(String)
    }

    /// Topic Unread changes only for a Topic, and for the whole Environment when it is marked Read. An Agent changes
    /// when `change` applies to it: Read clears an Unread Agent, Unread marks an Agent that is not working.
    public static func changes(_ change: ReadChange, in place: Place, records: [TopicRecord], agents: [Agent], windows: [TmuxWindow]) -> TopicReadChange {
        let unread = change == .unread
        let topicIDs: [String]
        switch place {
        case .topic(let id): topicIDs = records.filter { $0.id == id && $0.isUnread != unread }.map(\.id)
        case .environment: topicIDs = unread ? [] : records.filter(\.isUnread).map(\.id)
        case .session, .window, .pane: topicIDs = []
        }
        let agents = agents.filter { agent in
            guard change.applies(unread: agent.unread, status: agent.status) else { return false }
            switch place {
            case .environment: return true
            case .topic(let id): return windows.contains { $0.id == agent.windowID && $0.topicID == id }
            case .session(let id): return agent.sessionID == id
            case .window(let id): return agent.windowID == id
            case .pane(let id): return agent.paneID == id
            }
        }
        return TopicReadChange(topicIDs: topicIDs, paneIDs: agents.compactMap { PaneID(rawValue: $0.paneID) })
    }
}
