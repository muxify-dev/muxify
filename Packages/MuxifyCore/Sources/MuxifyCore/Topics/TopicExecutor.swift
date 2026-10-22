import Foundation

/// Runs a plan's commands on one tmux server, and finds the Pane or Window that a request or a plan names.
struct TopicExecutor {
    let server: TmuxServer
    /// Muxify's worktrees folder in the service's state folder. Settle removes a Worktree only inside it.
    let worktreesRoot: String

    /// `client` is the tmux client that types the keys of `sendKeys` commands. A Session that a failed run
    /// reopened is killed again, so a failed Reopen leaves no half of the Topic behind.
    func run(_ commands: [TopicPlan.Command], client: String?) throws {
        var placeholderWindowID: String?
        var reopenedSessionIDs: [String] = []
        do {
            for command in commands {
                switch command {
                case .restoreWorktree(let worktree, let base):
                    try TopicWorktrees.restore(worktree, base: base)
                case .removeCleanWorktree(let worktree):
                    let snapshot = server.snapshot()
                    guard snapshot.serverRunning else { throw TmuxError.notReady }
                    try TopicWorktrees.removeClean(worktree, root: worktreesRoot, windows: snapshot.windows, panes: snapshot.panes)
                case .removeMergedWorktree(let worktree):
                    let snapshot = server.snapshot()
                    guard snapshot.serverRunning else { throw TmuxError.notReady }
                    try TopicWorktrees.removeMerged(worktree, root: worktreesRoot, windows: snapshot.windows, panes: snapshot.panes)
                case .reopenSession(let name, let directory, let windowName):
                    let output = try server.run(["new-session", "-d", "-P", "-F", "#{session_id}", "-s", name, "-c", directory, "-n", windowName])
                    let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard id.hasPrefix("$"), !id.dropFirst().isEmpty, id.dropFirst().allSatisfy(\.isNumber) else {
                        throw TopicEditFailure.invalidTmuxResponse
                    }
                    reopenedSessionIDs.append(id)
                case .tmux(let arguments):
                    try server.run(arguments)
                case .sendKeys(let target, let keys, let literal):
                    try server.run(Tmux.sendKeysArguments(target: target, keys: keys, literal: literal, client: client))
                case .newTopicSession(let name, let directory):
                    let output = try server.run(["new-session", "-d", "-P", "-F", "#{window_id}", "-s", name, "-c", directory])
                    let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard id.hasPrefix("@"), !id.dropFirst().isEmpty, id.dropFirst().allSatisfy(\.isNumber) else {
                        throw TopicEditFailure.invalidTmuxResponse
                    }
                    placeholderWindowID = id
                case .removeTopicPlaceholder:
                    guard let placeholderWindowID else { throw TopicEditFailure.invalidTmuxResponse }
                    try server.run(["kill-window", "-t", placeholderWindowID])
                }
            }
        } catch {
            for id in reopenedSessionIDs { _ = try? server.run(["kill-session", "-t", id]) }
            throw error
        }
    }

    /// The Pane that `request` names, checked against a snapshot. tmux may answer for a Window that the
    /// snapshot does not list yet, so a miss reads one fresh snapshot before it fails.
    func pane(_ request: TopicPaneRequest, in initial: TmuxSnapshot, client: String?) throws -> (source: TopicPaneSource, snapshot: TmuxSnapshot) {
        var arguments = ["display-message", "-p"]
        switch request {
        case .currentClient:
            guard let client else { throw TopicEditFailure.sourceUnavailable }
            arguments += ["-c", client]
        case .window(let id), .pane(let id):
            arguments += ["-t", id]
        }
        arguments.append("#{pane_id} #{window_id} #{session_id} #{window_panes}")
        var snapshot = initial
        for attempt in 0..<2 {
            let identity = try TopicPaneIdentity(output: server.run(arguments))
            let matchesRequest: Bool
            switch request {
            case .currentClient: matchesRequest = true
            case .window(let id): matchesRequest = identity.windowID == id
            case .pane(let id): matchesRequest = identity.paneID == id
            }
            if matchesRequest, let source = try? identity.source(in: snapshot) {
                return (source, snapshot)
            }
            if attempt == 0 { snapshot = server.snapshot() }
        }
        throw TopicEditFailure.sourceUnavailable
    }

    /// Finds what a finished edit shows, and switches `client` to it when that client is on this server.
    func show(_ selection: TopicEdit.Selection, client: String?) throws -> TopicChange.Shown? {
        var snapshot = server.snapshot()
        let window: TmuxWindow?
        switch selection {
        case .unchanged:
            return nil
        case .emptyTopic(let id):
            return .emptyTopic(id: id)
        case .sessionID(let id):
            window = snapshot.windows.first { $0.sessionID == id && $0.isActive }
                ?? snapshot.windows.first { $0.sessionID == id }
        case .sessionName(let name):
            window = snapshot.windows.first { $0.sessionName == name && $0.isActive }
                ?? snapshot.windows.first { $0.sessionName == name }
        case .paneID(let id):
            let resolved = try pane(.pane(id), in: snapshot, client: client)
            snapshot = resolved.snapshot
            window = resolved.source.window
            try server.run(["select-pane", "-t", id])
        }
        guard let window, let id = WindowID(rawValue: window.id) else { throw TopicEditFailure.sourceUnavailable }
        if let client, snapshot.clients.contains(where: { $0.tty == client }) {
            try server.run(["switch-client", "-c", client, "-t", window.sessionID + ":" + window.id])
        }
        return .window(id)
    }
}
