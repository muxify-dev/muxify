import Foundation

extension TopicRecord {
    /// Save the current layout. Only a confirmed removal may replace a remembered layout with empty;
    /// startup, server loss and reconnect do not establish that the user closed anything.
    public func remembering(_ snapshot: TmuxSnapshot, order: SessionOrder,
                            branches: TopicBranches = TopicBranches(),
                            previously: [TmuxWindow] = []) -> TopicRecord? {
        let windows = snapshot.windows.filter { $0.topicID == id }
        let observed = previously.filter { $0.topicID == id }
        guard settledAt == nil, snapshot.serverRunning, !windows.isEmpty || !observed.isEmpty else { return nil }
        var seen: Set<String> = []
        let sessionIDs = TopicSessionOrder.ordered(windows.filter { seen.insert($0.sessionID).inserted }, record: self,
                                                   order: hasManualSessionOrder ? order : .oldestFirst) {
            TopicSessionKey(of: $0)
        }.map(\.sessionID)
        var remembered = sessionIDs.compactMap { sessionID -> JSONValue? in
            let members = windows.filter { $0.sessionID == sessionID }
            guard let first = members.first else { return nil }
            var session = self.session(of: first)?.object ?? [:]
            session["id"] = .string(first.sessionRecordID)
            session["name"] = .string(first.sessionName)
            session["base_name"] = .string(baseName(of: first))
            session["directory"] = .string(first.sessionPath.isEmpty ? first.path : first.sessionPath)
            if let tree = session["worktree_path"]?.string.map(Folder.local) {
                session["branch"] = branches[tree].map(JSONValue.string) ?? session["branch"]
            }
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
            let liveWindows = Set(members.map(\.id))
            let observedWindows = Set(observed.map(\.id))
            let missing = previousWindows.filter { entry in
                entry["window_id"]?.string.map { !liveWindows.contains($0) && !observedWindows.contains($0) } ?? false
            }
            session["windows"] = .array((session["windows"]?.array ?? []) + missing)
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

extension JSONValue {
    var object: [String: JSONValue]? {
        if case .object(let fields) = self { return fields }
        return nil
    }
}
