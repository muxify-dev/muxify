import Foundation

// Muxify Worktrees, in a Topic or not (ADR 0062). Create and Remove run under the edit lock, so a second request sees
// the first one's Sessions and records; List reads only.
extension EnvironmentService {
    var worktrees: MuxifyWorktrees { MuxifyWorktrees(scripts: scripts) }
    var worktreeStore: MuxifyWorktreeStore { MuxifyWorktreeStore(paths: paths) }

    /// Muxify's state folder on this Mac, where the records are too; on a Remote Environment, the one on its machine.
    var defaultWorktreesRoot: String? { environmentName == nil ? paths.worktrees.path : nil }

    /// This Environment's records.
    func worktreeRecords() throws -> [MuxifyWorktreeRecord] {
        try worktreeStore.all().filter { $0.environment == environmentName }
    }

    func createWorktree(_ request: EnvironmentRequest, name: String, from: String?, start: WorktreeStart, open: Bool,
                        client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            guard Self.isWorktreeName(name) else { throw MuxifyWorktreeError.nameInvalid(name) }
            let snapshot = try server.snapshot()
            guard let folder = try from ?? callerFolder(request, snapshot: snapshot, client: client) else { throw TopicRequestError.noTarget }
            let repository = try worktrees.repository(at: folder)
            let path = repository.folder(for: name, root: worktreesRoot, defaultRoot: defaultWorktreesRoot)
            let sessionBase = SessionPath.sessionName(repository.name + "/" + name)
            if let existing = try worktreeRecords().first(where: { $0.path == path || ($0.repository == repository.main && $0.name == name) }) {
                throw MuxifyWorktreeError.exists(name: name, path: existing.path, session: sessionBase)
            }
            let added = try worktrees.add(name: name, from: folder, at: path, start: start)
            phase = .changesStarted
            let branch: String = if case .branch(let branch) = start { branch } else { name }
            let record = MuxifyWorktreeRecord(environment: environmentName, repository: repository.main, name: name, path: added.path,
                                              branch: branch, base: added.commit)
            try worktreeStore.write(record)
            var output = try repository.setupFolder.map { try worktrees.sync(repository.setup, from: $0, to: record.path) } ?? []
            let sessionName = SessionNaming.available(sessionBase, taken: Set(snapshot.windows.map(\.sessionName)))
            let made = try TmuxMade(output: server.run(["new-session", "-d", "-P", "-F", TmuxMade.format, "-s", sessionName, "-c", record.path]))
            if let setupFolder = repository.setupFolder, !repository.setup.postCreate.isEmpty {
                let command = try worktrees.postCreateCommand(record, hooks: repository.setup.postCreate,
                                                              setupFile: setupFolder + "/" + WorktreeSetup.fileName)
                try server.run(["send-keys", "-t", made.pane.rawValue, "-l", command])
                try server.run(["send-keys", "-t", made.pane.rawValue, "Enter"])
                output.append("postCreate runs in \(made.sessionName)")
            }
            phase = .selectionFailed
            let shown = open ? try executor.show(.sessionID(made.session.rawValue), client: client) : nil
            return .changed(TopicChange(topicID: nil, created: true, shown: shown, session: made.session, sessionName: made.sessionName,
                                        window: made.window, pane: made.pane, worktreeID: record.id,
                                        output: output.isEmpty ? nil : output.joined(separator: "\n")))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    func removeWorktree(_ request: EnvironmentRequest, _ value: String, kill: Bool, force: Bool, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let record = try worktreeRecord(named: value)
            let snapshot = try server.snapshot()
            let users = Self.sessions(using: record.path, in: snapshot)
            if !users.isEmpty, !kill {
                throw MuxifyWorktreeError.inUse(path: record.path, sessions: users.map(\.sessionName))
            }
            let state = try worktrees.states([record.path]).first ?? .missing
            if state == .dirty, !force { throw MuxifyWorktreeError.hasChanges(record.path) }
            var output = ""
            if state != .missing {
                let repository = try worktrees.repository(at: record.path)
                do { output = try worktrees.runPreDelete(record, hooks: repository.setup.preDelete) }
                catch MuxifyWorktreeError.hookFailed(let printed, let reason) where force {
                    output = printed + "preDelete failed: \(reason) --force removes the Worktree anyway.\n"
                }
            }
            // The kills go last: the caller's own Pane may be one of them, and its process stops with it.
            let killed = Set(users.map(\.sessionID))
            var kills: [[String]] = []
            if let client, let current = snapshot.clients.first(where: { $0.tty == client }), killed.contains(current.sessionID) {
                if let next = snapshot.windows.first(where: { !killed.contains($0.sessionID) && $0.isActive }) {
                    kills.append(["switch-client", "-c", client, "-t", next.sessionID + ":" + next.id])
                }
            }
            let caller = callerSessionID(request, snapshot: snapshot)
            kills += users.map(\.sessionID).sorted { ($0 == caller ? 1 : 0, $0) < ($1 == caller ? 1 : 0, $1) }.map { ["kill-session", "-t", $0] }
            phase = .changesStarted
            try worktrees.remove(record, force: force)
            try worktreeStore.remove(record.id)
            if topicsAvailable { try forgetSessions(in: record) }
            for arguments in kills { try server.run(arguments) }
            return .changed(TopicChange(topicID: nil, worktreeID: record.id, output: output.isEmpty ? nil : output))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    func listWorktrees(_ request: EnvironmentRequest, all: Bool, from: String?, client: String?) -> EnvironmentResponse {
        do {
            var records = try worktreeRecords()
            let snapshot = try server.snapshot()
            let folder = all ? nil : try from ?? callerFolder(request, snapshot: snapshot, client: client)
            if let folder {
                let main = try worktrees.repository(at: folder).main
                records = records.filter { $0.repository == main }
            }
            let states = try worktrees.states(records.map(\.path))
            let topicRecords = topicsAvailable ? try store.read().records.filter { $0.settledAt == nil } : []
            return .worktrees(zip(records, states).map { record, state in
                let topic = topicRecords.first { $0.sessions.contains { $0[TopicWorktrees.idKey]?.string == record.id } }
                return MuxifyWorktreeSummary(record: record, state: state, sessions: Self.sessions(using: record.path, in: snapshot).map(\.sessionName),
                                             topic: topic.map { TopicSummary(record: $0).label })
            })
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// After git made a Topic's new Worktree: its record, then its sync. Returns the command that runs its postCreate
    /// hooks, which the new Session's Pane types.
    func setUpWorktree(_ new: TopicPlan.NewWorktree) throws -> String? {
        let spec = new.worktree
        let record = MuxifyWorktreeRecord(id: new.id, environment: environmentName, repository: new.setup.repository ?? spec.repositoryPath,
                                          name: (spec.path as NSString).lastPathComponent, path: spec.path, branch: spec.branch, base: new.commit)
        try worktreeStore.write(record)
        guard let folder = new.setup.folder else { return nil }
        _ = try worktrees.sync(new.setup.setup, from: folder, to: record.path)
        guard !new.setup.setup.postCreate.isEmpty else { return nil }
        return try worktrees.postCreateCommand(record, hooks: new.setup.setup.postCreate, setupFile: folder + "/" + WorktreeSetup.fileName)
    }

    /// The record that `value` names: its id, its path, else the one record with that name.
    func worktreeRecord(named value: String) throws -> MuxifyWorktreeRecord {
        let records = try worktreeRecords()
        if let record = records.first(where: { $0.id == value }) { return record }
        let path = Folder.lexical(value)
        if let record = records.first(where: { $0.path == path || (environmentName == nil && Folder.local($0.path) == Folder.local(path)) }) {
            return record
        }
        let named = records.filter { $0.name == value }
        guard let only = named.first else { throw MuxifyWorktreeError.unavailable(value) }
        guard named.count == 1 else { throw MuxifyWorktreeError.ambiguous(value, paths: named.map(\.path)) }
        return only
    }

    /// The open Topics stop remembering their Sessions in the removed Worktree, so Reopen does not make it again.
    private func forgetSessions(in record: MuxifyWorktreeRecord) throws {
        let records = try store.read().records
        for topic in records {
            var after = topic
            after.sessions.removeAll { $0[TopicWorktrees.idKey]?.string == record.id || $0["worktree_path"]?.string == record.path }
            guard after.sessions.count != topic.sessions.count else { continue }
            try store.write { _ = try $0.apply(TopicRecordChange(before: topic, after: after)) }
        }
    }

    /// The folder of the request's Pane: its target, else its caller.
    private func callerFolder(_ request: EnvironmentRequest, snapshot: TmuxSnapshot, client: String?) throws -> String? {
        guard let pane = paneRequest(request.target, caller: request.caller) else { return nil }
        let source = try executor.pane(pane, in: snapshot, client: client).source
        return source.directory ?? snapshot.panes.first { $0.id == source.paneID }?.path
    }

    private func callerSessionID(_ request: EnvironmentRequest, snapshot: TmuxSnapshot) -> String? {
        guard case .pane(let id)? = request.caller else { return nil }
        return snapshot.panes.first { $0.id == id.rawValue }.flatMap { pane in snapshot.windows.first { $0.id == pane.windowID }?.sessionID }
    }

    /// One Window of each live Session that has a Window or a Pane in the folder `path`.
    static func sessions(using path: String, in snapshot: TmuxSnapshot) -> [TmuxWindow] {
        func inside(_ folder: String) -> Bool { folder == path || folder.hasPrefix(path + "/") }
        let windowIDs = Set(snapshot.panes.filter { inside($0.path) }.map(\.windowID))
        var seen: Set<String> = []
        return snapshot.windows.filter { window in
            (inside(window.path) || inside(window.sessionPath) || windowIDs.contains(window.id)) && seen.insert(window.sessionID).inserted
        }
    }

    /// A Worktree's name is its folder's and, unless a branch is given, its branch's: git checks the branch.
    static func isWorktreeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix(".") && !name.hasSuffix("/")
            && name.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
            && !name.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }
}
