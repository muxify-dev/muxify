import Foundation

/// Where a new Window of a Topic goes. ADR 0039: the request never chooses a Session for the caller and never makes one.
enum NewWindowPlace: Equatable {
    /// The Topic's only live Session, by its active Window.
    case session(TmuxWindow)
    /// The Topic's live Sessions in its Session order, each as `name (id)`.
    case chooseSession([String])
    /// No live Session. A Dormant Topic remembers some; an Empty Topic remembers none.
    case emptyTopic(dormant: Bool)
}

/// Plans for the tmux objects themselves: snapshot and records in, `TopicEdit` out.
enum TmuxObjectPlan {
    static func place(in topic: TopicRecord, windows: [TmuxWindow], order: SessionOrder) -> NewWindowPlace {
        let members = windows.filter { $0.topicID == topic.id }
        var sessions: [TmuxWindow] = []
        for window in members where !sessions.contains(where: { $0.sessionID == window.sessionID }) {
            sessions.append(members.first { $0.sessionID == window.sessionID && $0.isActive } ?? window)
        }
        sessions = TopicSessionOrder.ordered(sessions, record: topic, order: order, key: TopicSessionKey.init(of:))
        switch sessions.count {
        case 0: return .emptyTopic(dormant: !topic.sessions.isEmpty)
        case 1: return .session(sessions[0])
        default: return .chooseSession(sessions.map { "\($0.sessionName) (\($0.sessionID))" })
        }
    }

    /// A Window in the Session of `window`, in its folder. tmux shows it only to the client that the service
    /// switches. `command` runs in place of the default shell.
    static func newWindow(beside window: TmuxWindow, command: [String]?) -> TopicEdit {
        var arguments = ["new-window", "-d", "-t", window.sessionID + ":", "-c", window.path]
        if let command { arguments.append(shellCommand(command)) }
        return TopicEdit(record: nil, commands: [.tmuxMaking(arguments)], selection: .made)
    }

    /// A No Topic Session. The name is free: the service chose it under the edit lock.
    static func newSession(named name: String, in directory: String) -> TopicEdit {
        TopicEdit(record: nil, commands: [.tmuxMaking(["new-session", "-d", "-s", name, "-c", directory])], selection: .made)
    }

    /// Puts `window` before or after the anchor Window, which must be in its Session. `-d` keeps the Session's
    /// current Window.
    static func moveWindow(_ window: TmuxWindow, to placement: WindowPlacement, windows: [TmuxWindow]) -> Result<TopicEdit, TopicRequestError> {
        let (anchorID, side) = switch placement {
        case .before(let id): (id.rawValue, "-b")
        case .after(let id): (id.rawValue, "-a")
        }
        guard windows.contains(where: { $0.id == anchorID && $0.sessionID == window.sessionID }) else {
            return .failure(.windowNotInSession(window: window.id, anchor: anchorID))
        }
        let commands: [TopicPlan.Command] = anchorID == window.id ? [] : [.tmux(["move-window", "-d", side, "-s", window.id, "-t", anchorID])]
        return .success(TopicEdit(record: nil, commands: commands, selection: .unchanged))
    }

    /// Kills `window`, or its whole Session, while its Panes are `expectedPaneIDs` when the user reviewed them. `topic`
    /// remembers what is left; with no Session left it is Empty, because the user stopped it. The record is written
    /// before the kill, because the kill can close the caller's own Pane and stop the process that sent the request.
    static func kill(_ window: TmuxWindow, session: Bool, snapshot: TmuxSnapshot, expectedPaneIDs: Set<PaneID>?, topic: TopicRecord?,
                     order: SessionOrder) -> Result<TopicEdit, TopicRequestError> {
        let killed = snapshot.windows.filter { session ? $0.sessionID == window.sessionID : $0.id == window.id }
        let windowIDs = Set(killed.map(\.id))
        let paneIDs = Set(snapshot.panes.filter { windowIDs.contains($0.windowID) }.compactMap { PaneID(rawValue: $0.id) })
        if let expectedPaneIDs, expectedPaneIDs != paneIDs { return .failure(.panesChanged) }
        var remaining = snapshot
        remaining.windows.removeAll { windowIDs.contains($0.id) }
        remaining.panes.removeAll { windowIDs.contains($0.windowID) }
        let remembered = topic.flatMap { $0.remembering(remaining, order: order, previously: snapshot.windows) }
        return .success(TopicEdit(record: remembered, commands: [.tmux(session ? ["kill-session", "-t", window.sessionID] : ["kill-window", "-t", window.id])],
                                  selection: .unchanged))
    }

    /// The Agent Panes that the kill stops, for the answer.
    static func agents(killedBy window: TmuxWindow, session: Bool, in snapshot: TmuxSnapshot) -> [PaneID] {
        let windowIDs = Set(snapshot.windows.filter { session ? $0.sessionID == window.sessionID : $0.id == window.id }.map(\.id))
        return snapshot.panes.filter { windowIDs.contains($0.windowID) && !$0.agent.isEmpty }.compactMap { PaneID(rawValue: $0.id) }
    }

    /// tmux joins the words after the options of `new-window` with spaces and gives the line to the shell, so an
    /// argument vector goes to it as one line with each word quoted where the shell would split or expand it.
    static func shellCommand(_ argv: [String]) -> String {
        argv.map { word in
            let plain = !word.isEmpty && word.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "-_./:=@%+,".unicodeScalars.contains($0)
            }
            return plain ? word : "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
    }
}
