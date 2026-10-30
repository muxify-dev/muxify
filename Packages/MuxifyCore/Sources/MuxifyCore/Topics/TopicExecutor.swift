import Foundation

/// What one plan made in tmux, as tmux printed it: the ids that the request's answer gives to the next request.
struct TmuxMade: Equatable {
    /// The session name goes last, so a name with a tab still parses.
    static let format = "#{session_id}\t#{window_id}\t#{pane_id}\t#{session_name}"

    let session: SessionID
    let window: WindowID
    let pane: PaneID
    let sessionName: String

    init(output: String) throws {
        let fields = output.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, let session = SessionID(rawValue: fields[0]), let window = WindowID(rawValue: fields[1]),
              let pane = PaneID(rawValue: fields[2]) else { throw TopicEditFailure.invalidTmuxResponse }
        (self.session, self.window, self.pane, sessionName) = (session, window, pane, fields[3])
    }
}

/// Runs a plan's commands on one tmux server, and finds the Pane or Window that a request or a plan names.
struct TopicExecutor {
    let server: any TmuxRunning
    /// Muxify's worktrees folder in the service's state folder. Settle removes a Worktree only inside it.
    let worktreesRoot: String

    /// `client` is the tmux client that types the keys of `sendKeys` commands. A Session that a failed run
    /// reopened is killed again, so a failed Reopen leaves no half of the Topic behind. Returns what the plan's
    /// `tmuxMaking` command made, or the first Session that a Reopen made.
    @discardableResult
    func run(_ commands: [TopicPlan.Command], client: String?) throws -> TmuxMade? {
        var placeholderWindowID: String?
        var reopenedSessionIDs: [String] = []
        var made: TmuxMade?
        // The postCreate command of each Worktree that Reopen made again, by folder, for the first Session there.
        var postCreates: [String: String] = [:]
        do {
            for command in commands {
                switch command {
                case .restoreWorktree(let worktree, let base):
                    guard !FileManager.default.fileExists(atPath: worktree.path) else { continue }
                    try TopicWorktrees.restore(worktree, base: base)
                    postCreates[worktree.path] = try setUpRestored(worktree, base: base)
                case .removeCleanWorktree(let worktree):
                    let snapshot = try server.snapshot()
                    guard snapshot.serverRunning else { throw TmuxError.notReady }
                    try preDelete(worktree)
                    try TopicWorktrees.removeClean(worktree, root: worktreesRoot, windows: snapshot.windows, panes: snapshot.panes)
                    try forgetRecord(of: worktree)
                case .removeMergedWorktree(let worktree):
                    let snapshot = try server.snapshot()
                    guard snapshot.serverRunning else { throw TmuxError.notReady }
                    try preDelete(worktree)
                    try TopicWorktrees.removeMerged(worktree, root: worktreesRoot, windows: snapshot.windows, panes: snapshot.panes)
                    try forgetRecord(of: worktree)
                case .reopenSession(let name, let directory, let windowName):
                    let session = try TmuxMade(output: server.run(["new-session", "-d", "-P", "-F", TmuxMade.format, "-s", name, "-c", directory,
                                                                    "-n", windowName]))
                    reopenedSessionIDs.append(session.session.rawValue)
                    made = made ?? session
                    if let postCreate = postCreates.removeValue(forKey: directory) {
                        try server.run(["send-keys", "-t", session.pane.rawValue, "-l", postCreate])
                        try server.run(["send-keys", "-t", session.pane.rawValue, "Enter"])
                    }
                case .tmux(let arguments):
                    try server.run(arguments)
                case .tmuxMaking(let arguments):
                    made = try TmuxMade(output: server.run(Array(arguments.prefix(1)) + ["-P", "-F", TmuxMade.format] + arguments.dropFirst()))
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
        return made
    }

    /// Topics are local, so their Worktree scripts run on this Mac.
    private var worktrees: MuxifyWorktrees { MuxifyWorktrees(scripts: LocalScripts()) }
    private var records: MuxifyWorktreeStore { MuxifyWorktreeStore(folder: URL(fileURLWithPath: worktreesRoot)) }

    /// A Worktree that Reopen made again is a new folder: it gets its sync again, and the command that runs its
    /// postCreate hooks (ADR 0062). Its record stays.
    private func setUpRestored(_ worktree: TopicPlan.WorktreeSpec, base: String?) throws -> String? {
        let repository = try worktrees.repository(at: worktree.repositoryPath)
        guard let folder = repository.setupFolder else { return nil }
        _ = try worktrees.sync(repository.setup, from: folder, to: worktree.path)
        guard !repository.setup.postCreate.isEmpty else { return nil }
        let record = (try? records.all())?.first { $0.environment == nil && $0.path == worktree.path }
            ?? MuxifyWorktreeRecord(environment: nil, repository: repository.main, name: (worktree.path as NSString).lastPathComponent,
                                    path: worktree.path, branch: worktree.branch, base: base ?? "")
        return try worktrees.postCreateCommand(record, hooks: repository.setup.postCreate, setupFile: folder + "/" + WorktreeSetup.fileName)
    }

    /// A failed hook keeps the Worktree: Settle and Forget have no --force.
    private func preDelete(_ worktree: TopicPlan.WorktreeSpec) throws {
        guard FileManager.default.fileExists(atPath: worktree.path) else { return }
        let hooks = try worktrees.repository(at: worktree.path).setup.preDelete
        guard !hooks.isEmpty else { return }
        let record = (try? records.all())?.first { $0.environment == nil && $0.path == worktree.path }
            ?? MuxifyWorktreeRecord(environment: nil, repository: worktree.repositoryPath, name: (worktree.path as NSString).lastPathComponent,
                                    path: worktree.path, branch: worktree.branch, base: "")
        _ = try worktrees.runPreDelete(record, hooks: hooks)
    }

    private func forgetRecord(of worktree: TopicPlan.WorktreeSpec) throws {
        for record in try records.all() where record.environment == nil && Folder.local(record.path) == Folder.local(worktree.path) {
            try records.remove(record.id)
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
            if attempt == 0 { snapshot = try server.snapshot() }
        }
        throw TopicEditFailure.sourceUnavailable
    }

    /// Finds what a finished edit shows, and switches `client` to it when that client is on this server.
    func show(_ selection: TopicEdit.Selection, client: String?) throws -> Location? {
        var snapshot = try server.snapshot()
        let window: TmuxWindow?
        switch selection {
        case .unchanged, .made:
            return nil
        case .emptyTopic(let id):
            return .emptyTopic(.topic(id))
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
