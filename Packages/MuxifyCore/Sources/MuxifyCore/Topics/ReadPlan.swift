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

extension ReadPlan {
    /// Why Mark Read or Mark Unread on a target changes nothing. Only Mark Read on the current target shows it, in a Pill.
    public enum Refusal: Equatable, Sendable {
        /// A navigation or an earlier Read change has not ended yet.
        case busy
        /// The app cannot write Agent Unread to tmux, and the target has no Topic mark to change.
        case disconnected
        case nothingToChange
        /// Read on a Zoomed Pane with nothing Unread, while other Panes of its Window have Unread Agents.
        case onlyHiddenByZoom(hiddenPanes: Int)
    }

    public enum Decision: Equatable, Sendable {
        /// `hiddenUnreadPanes` counts the Unread Agents that a Read of a Zoomed Pane leaves in the other Panes of
        /// its Window; 0 for every other change.
        case change(TopicReadChange, hiddenUnreadPanes: Int)
        case refused(Refusal)
    }

    /// What Mark Read or Mark Unread does to `place` now. A known Topic always takes the change, as its row action
    /// and its Empty Topic page offer it. `agentsWritable` is false when the app cannot write Agent Unread to tmux.
    public static func decide(_ change: ReadChange, in place: Place, records: [TopicRecord], agents: [Agent], windows: [TmuxWindow],
                              busy: Bool, agentsWritable: Bool) -> Decision {
        if busy { return .refused(.busy) }
        let changes = changes(change, in: place, records: records, agents: agentsWritable ? agents : [], windows: windows)
        let hidden = change == .read ? hiddenUnreadPanes(behind: place, agents: agents, windows: windows) : 0
        if case .topic(let id) = place, records.contains(where: { $0.id == id }) { return .change(changes, hiddenUnreadPanes: 0) }
        if !changes.topicIDs.isEmpty || !changes.paneIDs.isEmpty { return .change(changes, hiddenUnreadPanes: hidden) }
        if !agentsWritable { return .refused(.disconnected) }
        if hidden > 0 { return .refused(.onlyHiddenByZoom(hiddenPanes: hidden)) }
        return .refused(.nothingToChange)
    }

    /// The Unread Agents in the Panes that Zoom hides, when `place` is the Zoomed Pane of its Window.
    private static func hiddenUnreadPanes(behind place: Place, agents: [Agent], windows: [TmuxWindow]) -> Int {
        guard case .pane(let paneID) = place,
              let window = windows.first(where: { $0.isZoomed && $0.activePaneID == paneID }) else { return 0 }
        return agents.filter { $0.windowID == window.id && $0.paneID != paneID && $0.unread }.count
    }
}
