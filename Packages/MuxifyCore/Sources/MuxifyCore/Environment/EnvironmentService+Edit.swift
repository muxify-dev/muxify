import Foundation

// The edit lane: every command that runs under the edit lock.
extension EnvironmentService {
    /// A plan with what the host shows when the plan itself selects nothing.
    private struct Planned {
        var edit: TopicEdit
        var shown: TopicChange.Shown?
        /// The Locked Session whose place a new Topic takes.
        var replacedLockOf: String? = nil
        /// What the plan renames, for the answer. What a plan makes comes from tmux instead.
        var session: SessionID? = nil
        var sessionName: String? = nil
        var window: WindowID? = nil
        var stopped: [PaneID]? = nil
    }

    /// `session move up|down` has one meaning for each Session: a Session in an open Topic takes one place among the
    /// Topic's Sessions, and a Locked Session, which is always in no Topic, moves its card. Runs under the edit lock.
    func stepSession(_ request: EnvironmentRequest, _ move: CardMove, client: String?) -> EnvironmentResponse {
        do {
            let records = try store.read().records
            let window = try sessionWindow(request.target, caller: request.caller, snapshot: try server.snapshot(), client: client)
            if records.contains(where: { $0.id == window.topicID && $0.settledAt == nil }) { return edit(request, client: client) }
            return moveCard(request, move, client: client)
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    func edit(_ request: EnvironmentRequest, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let planned = try plan(request, records: records, snapshot: snapshot, client: client)
            let edit = planned.edit
            try TopicWorktrees.check(edit.commands)
            if let new = edit.newWorktree { try TopicWorktrees.add(new) }
            let read = edit.record.flatMap { record in records.first { $0.id == record.id } }
            // A new Topic takes its place among the Locks too, and may renumber them.
            var commands = edit.commands
            if let record = edit.record {
                let locks = SessionLock.locks(in: snapshot.windows, records: records)
                let moved = try store.write(locks: locks) { transaction -> [SessionLock] in
                    if let left = edit.leftTopic {
                        _ = try transaction.apply(TopicRecordChange(before: records.first { $0.id == left.id }, after: left))
                    }
                    return try transaction.apply(TopicRecordChange(before: read, after: record), insertPosition: topics.insertPosition,
                                                 replacingLockOf: planned.replacedLockOf)
                }
                commands += moved.map { .tmux($0.setOption) }
                phase = .recordSaved
            } else {
                phase = .changesStarted
            }
            let made = try executor.run(commands, client: client)
            switch edit.completion {
            case .save(let record):
                let before = edit.record ?? records.first { $0.id == record.id }
                let locks = SessionLock.locks(in: try server.snapshot().windows, records: try store.read().records)
                let moved = try store.write(locks: locks) {
                    try $0.apply(TopicRecordChange(before: before, after: record), insertPosition: topics.insertPosition)
                }
                try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            case .forget(let id):
                let locks = SessionLock.locks(in: try server.snapshot().windows, records: try store.read().records)
                let moved = try store.write(locks: locks) { try $0.forget(id, insertPosition: topics.insertPosition) }
                try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            case nil: break
            }
            phase = .selectionFailed
            let selection = edit.selection == .made ? made.map { .paneID($0.pane.rawValue) } ?? .unchanged : edit.selection
            let shown = try executor.show(selection, client: client) ?? planned.shown
            return .changed(TopicChange(topicID: edit.completion?.topicID ?? edit.record?.id,
                                        created: edit.record != nil && read == nil, shown: shown,
                                        session: made?.session ?? planned.session, sessionName: made?.sessionName ?? planned.sessionName,
                                        window: made?.window ?? planned.window, pane: made?.pane, stopped: planned.stopped))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    private func plan(_ request: EnvironmentRequest, records: [TopicRecord], snapshot: TmuxSnapshot, client: String?) throws -> Planned {
        func source() throws -> (TopicPaneSource, TmuxSnapshot) {
            guard let pane = paneRequest(request.target, caller: request.caller) else { throw TopicRequestError.noTarget }
            let resolved = try executor.pane(pane, in: snapshot, client: client)
            return (resolved.source, resolved.snapshot)
        }
        switch request.command {
        case .list, .show, .lock, .unlock, .snooze, .unsnooze, .tags, .pin, .unpin, .moveCard, .startZen, .endZen, .markRead, .markAllRead:
            throw TopicRequestError.noTarget
        case .create(let title, let tags):
            let tags = Set(tags ?? [])
            try checkDefined(.add(Array(tags)), on: [])
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            var record = TopicRecord(newTopic: UUID().uuidString.lowercased(), title: title, slug: TopicNaming.slug(title: title, records: records), now: Date())
            record.tags = tags
            return Planned(edit: TopicEdit(record: record, commands: [], selection: .emptyTopic(record.id)))
        case .addSession(let repositoryPath, let choice, let name):
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            let sessionPath = try sessionPath(at: repositoryPath)
            return Planned(edit: try TopicSessionPlan(topic: topic, sessionPath: sessionPath, workingCopy: workingCopy(choice, of: sessionPath),
                                                      windows: snapshot.windows, sessionPaths: sessionPaths, order: topics.sessionOrder, baseName: name).edit)
        case .settle(let choices, let outcome):
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            try checkMembership(request.expectedSessionIDs, choices: choices, topic: topic, snapshot: snapshot)
            var snapshot = snapshot
            snapshot.commandLines = PaneCommandLines().updating(for: snapshot) {
                try? CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", PaneCommandLines.script]))
            }
            return Planned(edit: TopicSettlePlan(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, choices: choices, outcome: outcome,
                                                 mergedWorktrees: TopicWorktrees.merged(in: topic, root: paths.worktrees.path),
                                                 order: topics.sessionOrder).edit)
        case .forget(let choices, let worktrees):
            let topic = try forgetTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            try checkMembership(request.expectedSessionIDs, choices: choices, topic: topic, snapshot: snapshot)
            return Planned(edit: TopicForgetPlan(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, choices: choices,
                                                  worktrees: worktrees, root: paths.worktrees.path).edit)
        case .move(let destination):
            if case .newWindow(let title) = destination {
                if case .session = request.target { throw TopicRequestError.noTarget }
                if case .window = request.target { throw TopicRequestError.noTarget }
                let (pane, _) = try source()
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                var commands: [TopicPlan.Command] = []
                if pane.window.paneCount > 1 {
                    var arguments = ["break-pane", "-d", "-s", pane.paneID, "-t", pane.window.sessionID + ":"]
                    if !title.isEmpty { arguments += ["-n", title] }
                    commands.append(.tmux(arguments))
                } else if !title.isEmpty {
                    commands.append(.tmux(["rename-window", "-t", pane.window.id, title]))
                }
                return Planned(edit: TopicEdit(record: nil, commands: commands, selection: .paneID(pane.paneID)))
            }
            let moved: TopicMembershipPlan.Source
            let selection: TopicEdit.Selection
            let windows: [TmuxWindow]
            let directory: String?
            if case .session(let id) = request.target {
                guard let window = snapshot.windows.first(where: { $0.sessionID == id.rawValue }) else { throw TopicEditFailure.sourceUnavailable }
                (moved, selection, windows) = (.session(window), .unchanged, snapshot.windows)
                directory = nil
            } else {
                let (pane, fresh) = try source()
                let paneTarget: Bool
                if case .window = request.target { paneTarget = false } else { paneTarget = true }
                guard let paneID = PaneID(rawValue: pane.paneID) else { throw TopicEditFailure.invalidTmuxResponse }
                (moved, selection, windows) = (paneTarget ? .pane(paneID, pane.window) : .window(pane.window),
                                                 paneTarget ? .paneID(pane.paneID) : .unchanged, fresh.windows)
                directory = paneTarget ? pane.directory : nil
            }
            let plan: TopicMembershipPlan
            switch destination {
            case .newWindow: throw TopicRequestError.noTarget
            case .session(let id):
                guard let target = windows.first(where: { $0.sessionID == id.rawValue }) else { throw TopicMembershipPlan.Failure.destinationUnavailable }
                let topic = records.first { $0.id == target.topicID && $0.settledAt == nil }
                plan = try TopicMembershipPlan(source: moved, destination: topic, records: records, windows: windows,
                    sessionPaths: sessionPaths, clientTTY: client, order: topics.sessionOrder, destinationSession: id.rawValue, launchDirectory: directory)
            case .newSession(let ref):
                let topic = try ref?.resolve(in: records, open: true)
                plan = try TopicMembershipPlan(source: moved, destination: topic, records: records, windows: windows,
                    sessionPaths: sessionPaths, clientTTY: client, order: topics.sessionOrder, createSession: true, launchDirectory: directory)
            case .topic(let ref):
                plan = try TopicMembershipPlan(source: moved, destination: ref.resolve(in: records, open: true), records: records,
                                               windows: windows, sessionPaths: sessionPaths, clientTTY: client, order: topics.sessionOrder, launchDirectory: directory)
            case .newTopic(let title):
                plan = try TopicMembershipPlan(source: moved, title: title.trimmingCharacters(in: .whitespacesAndNewlines), records: records, windows: windows,
                                               sessionPaths: sessionPaths, clientTTY: client, order: topics.sessionOrder, launchDirectory: directory)
            }
            var edit = TopicEdit(record: plan.record, commands: plan.commands, selection: selection)
            edit.leftTopic = plan.leftTopic
            return Planned(edit: edit, shown: WindowID(rawValue: moved.window.id).map { .window($0) }, replacedLockOf: plan.endedLockOf)
        case .removeFromTopic:
            if case .window = request.target { throw TopicRequestError.noTarget }
            let plan = TopicMembershipPlan(removingSession: try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client),
                                           records: records, sessionPaths: sessionPaths, windows: snapshot.windows)
            return Planned(edit: TopicEdit(record: plan.record, commands: plan.commands, selection: .unchanged))
        case .removeAndKill(let worktrees):
            let window = try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client)
            guard let topic = TopicMembershipPlan.openTopic(of: window, records: records) else { throw TopicRequestError.sourceHasNoTopic }
            let next = snapshot.windows.first { $0.topicID == topic.id && $0.sessionID != window.sessionID && $0.isActive }
                ?? snapshot.windows.first { $0.topicID == topic.id && $0.sessionID != window.sessionID }
            var commands: [TopicPlan.Command] = []
            if let client, let next { commands.append(.tmux(["switch-client", "-c", client, "-t", next.sessionID + ":" + next.id])) }
            commands.append(.tmux(["kill-session", "-t", window.sessionID]))
            if let tree = madeWorktree(of: window, topic: topic, snapshot: snapshot), tree.canRemove(killing: [window.sessionID]),
               worktrees.contains(tree.id) {
                commands.append(.removeCleanWorktree(tree.spec))
            }
            return Planned(edit: TopicEdit(record: topic.forgetting(window), commands: commands,
                                           selection: next.map { .sessionID($0.sessionID) } ?? .emptyTopic(topic.id)))
        case .rename(let title):
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            return Planned(edit: try TopicRenamePlan(topic: topic, title: title, records: records,
                                                     windows: snapshot.windows, sessionPaths: sessionPaths).edit)
        case .moveSession(let placement):
            let window = try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client)
            guard let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) else {
                throw TopicEditFailure.sessionUnavailable
            }
            return Planned(edit: try TopicSessionOrderPlan(moving: window.sessionID, to: placement, topic: topic, windows: snapshot.windows,
                                                           order: topics.sessionOrder).edit)
        case .sortSessions:
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            return Planned(edit: TopicSessionOrderPlan(sortingByCreation: topic).edit)
        case .newWindow(let command):
            let window: TmuxWindow
            switch request.target {
            case .topic(let ref)?:
                let topic = try ref.resolve(in: records, open: true)
                switch TmuxObjectPlan.place(in: topic, windows: snapshot.windows, order: topics.sessionOrder) {
                case .session(let found): window = found
                case .chooseSession(let sessions): throw TopicRequestError.chooseSession(topic: TopicSummary(record: topic).label, sessions: sessions)
                case .emptyTopic(let dormant): throw TopicRequestError.topicEmpty(topic: TopicSummary(record: topic).label, id: topic.id, dormant: dormant)
                }
            case .session?, .sessionName?:
                let found = try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client)
                window = snapshot.windows.first { $0.sessionID == found.sessionID && $0.isActive } ?? found
            case .window?, .pane?, nil:
                window = try source().0.window
            }
            return Planned(edit: TmuxObjectPlan.newWindow(beside: window, command: command))
        case .renameSession(let name):
            if case .topic = request.target { throw TopicRequestError.noTarget }
            let window = try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client)
            guard (try? SessionNaming.validate(name)) != nil else { throw TopicRequestError.sessionNameInvalid(name) }
            // Topics are local: a Remote Environment's Sessions are all No Topic Sessions.
            let topic = topicsAvailable ? records.first { $0.id == window.topicID && $0.settledAt == nil } : nil
            let taken = Set(snapshot.windows.filter { $0.sessionID != window.sessionID }.map(\.sessionName))
            let full = SessionNaming.available(name, topic: topic?.slug, taken: taken)
            return Planned(edit: TopicEdit(record: nil, commands: [.tmux(["rename-session", "-t", window.sessionID, full])], selection: .unchanged),
                           session: SessionID(rawValue: window.sessionID), sessionName: full)
        case .renameWindow(let name):
            switch request.target {
            case .topic?, .session?, .sessionName?: throw TopicRequestError.noTarget
            case .window?, .pane?, nil: break
            }
            let window = try source().0.window
            return Planned(edit: TopicEdit(record: nil, commands: [.tmux(["rename-window", "-t", window.id, name])], selection: .unchanged),
                           window: WindowID(rawValue: window.id))
        case .moveWindow(let placement):
            switch request.target {
            case .topic?, .session?, .sessionName?: throw TopicRequestError.noTarget
            case .window?, .pane?, nil: break
            }
            let window = try source().0.window
            return Planned(edit: try TmuxObjectPlan.moveWindow(window, to: placement, windows: snapshot.windows).get(), window: WindowID(rawValue: window.id))
        case .killWindow, .killSession:
            let session = request.command == .killSession
            let window: TmuxWindow
            switch request.target {
            case .topic?: throw TopicRequestError.noTarget
            case .session?, .sessionName?:
                guard session else { throw TopicRequestError.noTarget }
                window = try sessionWindow(request.target, caller: request.caller, snapshot: snapshot, client: client)
            case .window?, .pane?, nil:
                window = try source().0.window
            }
            let kill = TmuxObjectPlan.kill(window, session: session, snapshot: snapshot, expectedPaneIDs: request.expectedPaneIDs,
                                           topic: topicsAvailable ? records.first { $0.id == window.topicID && $0.settledAt == nil } : nil,
                                           order: topics.sessionOrder)
            return Planned(edit: try kill.get(), stopped: TmuxObjectPlan.agents(killedBy: window, session: session, in: snapshot))
        case .newSession(let path, let name):
            // A Remote Environment's folder is on its own machine, so only a local one is checked and named here.
            let launch = topicsAvailable ? try sessionPath(at: path) : nil
            let base = name ?? launch?.name ?? SessionPath.sessionName((path as NSString).lastPathComponent)
            guard (try? SessionNaming.validate(base)) != nil else { throw TopicRequestError.sessionNameInvalid(base) }
            return Planned(edit: TmuxObjectPlan.newSession(named: SessionNaming.available(base, taken: Set(snapshot.windows.map(\.sessionName))),
                                                           in: launch?.folder.path ?? path))
        case .reopen, .startFresh:
            guard case .topic(let ref) = request.target else { throw TopicRequestError.noTarget }
            let topic = try ref.resolve(in: records, open: false)
            return Planned(edit: try TopicReopenPlan(topic: topic, records: records, windows: snapshot.windows, sessionPaths: sessionPaths,
                                                     existingDirectories: TopicReopening.existingWorktrees(of: topic),
                                                     choice: request.command == .startFresh ? .startFresh : .reopen).edit)
        }
    }

    /// Lock and Unlock change only the Session option and, when a Lock renumbers the list, the Topic records.
    func changeLock(_ request: EnvironmentRequest, locked: Bool, client: String?) -> EnvironmentResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let window = try noTopicSession(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            let commands: [TopicPlan.Command]
            if locked {
                let locks = SessionLock.locks(in: snapshot.windows, records: records)
                let changed = try store.write(locks: locks) { $0.lock(window.sessionID) }
                commands = changed.map { .tmux($0.setOption) }
            } else {
                commands = window.lockOrder == nil ? [] : [.tmux(SessionLock.unsetOption(window.sessionID))]
            }
            phase = .changesStarted
            try executor.run(commands, client: client)
            return .changed(TopicChange(topicID: nil))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// `path` is a request's, given on this Mac, so it may reach the Config's folder through a symlink.
    private func sessionPath(at path: String) throws -> SessionPath {
        let folder = Folder.local(path)
        if let match = sessionPaths.first(where: { $0.folder == folder }) { return match }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TopicRequestError.sessionPathUnavailable(path)
        }
        return SessionPath(folder: folder, name: SessionPath.sessionName((folder.path as NSString).lastPathComponent), layout: RepositoryLayout.detect(at: folder.path))
    }

    private func workingCopy(_ choice: TopicWorkingCopyChoice, of sessionPath: SessionPath) throws -> TopicWorkingCopy {
        func worktree(at path: String) throws -> Worktree {
            let folder = Folder.local(path)
            guard let match = sessionPath.layout.worktrees.first(where: { $0.folder == folder }) else {
                throw TopicRequestError.sessionPathUnavailable(path)
            }
            return match
        }
        switch choice {
        case .directory: return .directory
        case .worktree(let path): return .worktree(try worktree(at: path))
        case .newWorktree(let path, .head):
            return .newWorktree(at: try TopicWorktrees.commit(nil, in: try worktree(at: path)), root: paths.worktrees.path)
        case .newWorktree(let path, .ref(let ref)):
            return .newWorktree(at: try TopicWorktrees.commit(ref, in: try worktree(at: path)), root: paths.worktrees.path)
        case .newWorktree(let path, .branch(let branch)):
            let commit = try TopicWorktrees.branchStart(branch, in: try worktree(at: path))
            return .branchWorktree(branch: branch, commit: commit, root: paths.worktrees.path)
        }
    }

    private func checkMembership(_ expected: [String]?, choices: [TopicSettleSession], topic: TopicRecord, snapshot: TmuxSnapshot) throws {
        if let expected {
            let current = Set(snapshot.windows.filter { $0.topicID == topic.id }.map(\.sessionID))
            guard current == Set(expected) else { throw TopicRequestError.topicMembershipChanged }
        }
        for choice in choices {
            if let reviewed = choice.reviewedWindows,
               reviewed.mapValues({ $0.sorted() }) != TopicSettleSession.windows(in: choice.id, snapshot: snapshot) {
                throw TopicRequestError.topicMembershipChanged
            }
        }
    }
}
