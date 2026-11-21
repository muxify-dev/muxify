import Foundation

extension TopicRecord {
    /// Save the current layout. Only a confirmed removal may replace a remembered layout with empty;
    /// startup, server loss and reconnect do not establish that the user closed anything. A live Session's Windows
    /// replace its remembered ones: tmux lists all of them, and a remembered Window from an earlier server is one
    /// that Reopen already made again under a new id.
    public func remembering(_ snapshot: TmuxSnapshot, order: SessionOrder,
                            branches: TopicBranches = TopicBranches(),
                            previously: [TmuxWindow] = []) -> TopicRecord? {
        let windows = snapshot.windows.filter { $0.topicID == id }
        let observed = previously.filter { $0.topicID == id }
        guard settledAt == nil, snapshot.serverRunning, !windows.isEmpty || !observed.isEmpty else { return nil }
        let sessionIDs = TopicSessionOrder.firstWindows(windows, record: self, order: hasManualSessionOrder ? order : .oldestFirst)
            .map(\.sessionID)
        var remembered = sessionIDs.compactMap { sessionID -> JSONValue? in
            let members = windows.filter { $0.sessionID == sessionID }
            guard let first = members.first else { return nil }
            var session = Self.remembered(self.session(of: first)?.object ?? [:], id: first.sessionRecordID, members: members, snapshot: snapshot)
            session["base_name"] = .string(baseName(of: first))
            if let tree = session["worktree_path"]?.string.map(Folder.local) {
                session["branch"] = branches[tree].map(JSONValue.string) ?? session["branch"]
            }
            return .object(session)
        }
        let liveIDs = Set(remembered.compactMap { $0["id"]?.string })
        let observedIDs = Set(observed.map(\.sessionRecordID))
        remembered += sessions.filter { entry in entry["id"]?.string.map { !liveIDs.contains($0) && !observedIDs.contains($0) } ?? false }
        guard remembered != sessions else { return nil }
        var updated = self
        updated.sessions = remembered
        return updated
    }

    /// `fields`, a Session's earlier entry, with what `members`, the Windows of that live Session, show now: its id,
    /// name and folder, and each Window with its Panes, Browser and Agent. A Window keeps the fields of its earlier entry.
    static func remembered(_ fields: [String: JSONValue], id: String, members: [TmuxWindow], snapshot: TmuxSnapshot) -> [String: JSONValue] {
        var session = fields
        guard let first = members.first else { return session }
        session["id"] = .string(id)
        session["name"] = .string(first.sessionName)
        session["directory"] = .string(first.sessionPath.isEmpty ? first.path : first.sessionPath)
        let previousWindows = session["windows"]?.array ?? []
        session["windows"] = .array(members.enumerated().map { index, window in
            let previous = previousWindows.first { $0["window_id"]?.string == window.id }
                ?? (previousWindows.indices.contains(index) && previousWindows[index]["window_id"] == nil
                    ? previousWindows[index] : nil)
            var fields = previous?.object ?? [:]
            fields["window_id"] = .string(window.id)
            fields["directory"] = .string(window.path)
            fields["name"] = .string(window.name)
            fields["pane_count"] = nil
            fields["start_command"] = .string(window.startCommand)
            fields["browser_tabs"] = .array(window.storedBrowser.tabURLs.map(JSONValue.string))
            fields["browser_active_tab"] = .integer(Int64(window.storedBrowser.activeTab))
            fields["browser_open"] = .bool(window.storedBrowser.layout.shown != .terminal)
            fields["terminal_open"] = .bool(window.storedBrowser.layout.shown != .browser)
            let pane = snapshot.panes.first { $0.id == window.activePaneID && $0.windowID == window.id }
            let agent = pane.flatMap { Agent.runs(in: $0) ? $0 : nil }
            fields["agent"] = agent.map { .string($0.agent) }
            fields["agent_conversation"] = agent.flatMap { $0.agentConversation.isEmpty ? nil : .string($0.agentConversation) }
            let panes = snapshot.panes.filter { $0.windowID == window.id }.sorted { $0.index < $1.index }
            fields["layout"] = panes.isEmpty || window.layout.isEmpty ? nil : .string(window.layout)
            fields["panes"] = panes.isEmpty ? nil : .array(panes.map { Self.remembered($0, in: window, commandLines: snapshot.commandLines) })
            return .object(fields)
        })
        return session
    }

    /// Remove exactly one Session, even when several Sessions share its directory.
    func forgetting(_ window: TmuxWindow) -> TopicRecord? {
        var updated = self
        updated.sessions.removeAll { $0["id"]?.string == window.sessionRecordID }
        return updated.sessions == sessions ? nil : updated
    }

    /// An Agent Pane keeps its conversation, a Pane that runs another program keeps its command line, and a shell
    /// keeps only its folder.
    private static func remembered(_ pane: TmuxPane, in window: TmuxWindow, commandLines: PaneCommandLines) -> JSONValue {
        var fields: [String: JSONValue] = ["index": .integer(Int64(pane.index)), "directory": .string(pane.path.isEmpty ? window.path : pane.path),
                                           "active": .bool(pane.isActive)]
        if Agent.runs(in: pane) {
            fields["agent"] = .string(pane.agent)
            if !pane.agentConversation.isEmpty { fields["agent_conversation"] = .string(pane.agentConversation) }
        } else if let line = commandLines[pane] {
            fields["command"] = .string(line)
        }
        return .object(fields)
    }
}

extension SessionLock {
    /// A new Lock for the live No Topic Session of `window`, at `order`. Its id is the Session's `sessionRecordID`, so
    /// two Make a Guest of one Session make one Lock, and it remembers the Session as `snapshot` shows it.
    public init(session window: TmuxWindow, order: Double, snapshot: TmuxSnapshot) {
        let members = snapshot.windows.filter { $0.sessionID == window.sessionID }
        var fields = TopicRecord.remembered([:], id: window.sessionRecordID, members: members, snapshot: snapshot)
        fields["base_name"] = .string(window.sessionName)
        self.init(id: window.sessionRecordID, order: order, session: .object(fields))
    }

    /// What a read of the server changes in a Lock.
    public enum Memory: Equatable, Sendable {
        /// The live Session's layout, to save as the Lock's Remembered Session.
        case remembered(JSONValue)
        /// The Session ended on the same server: the user closed it, or it went into a Topic.
        case ended
    }

    /// What `snapshot` changes in the Lock, by the rule of `TopicRecord.remembering`: a live Session's layout replaces
    /// the remembered one, and only a confirmed end, a Session live in `previously`, an earlier read of the same server,
    /// and gone now, ends the Lock. Startup, server loss and a reconnect end nothing, so after a tmux restart the Guest
    /// Session is Dormant. `open` are the open Topics. Nil when nothing changes.
    public func remembering(_ snapshot: TmuxSnapshot, open: Set<String>, previously: [TmuxWindow] = []) -> Memory? {
        guard snapshot.serverRunning else { return nil }
        let members = windows(in: snapshot.windows, open: open)
        guard let first = members.first else {
            return windows(in: previously, open: open).isEmpty ? nil : .ended
        }
        var fields = TopicRecord.remembered(session.object ?? [:], id: id, members: members, snapshot: snapshot)
        fields["base_name"] = .string(first.sessionName)
        let remembered = JSONValue.object(fields)
        return remembered == session ? nil : .remembered(remembered)
    }
}

extension JSONValue {
    var object: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
