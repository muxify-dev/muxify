import Foundation

/// The one way to read or change Topics. The app's sheets, the muxify://topic URL and the command line tool
/// all send a `TopicRequest` here, so every Topic edit runs the same steps: read, plan, git, record, tmux,
/// show. It blocks, so call it off the main thread.
public struct TopicService: Sendable {
    public let paths: MuxifyPaths
    public let server: TmuxServer
    /// The SessionPaths a request may name, with the layouts that git reported.
    public let sessionPaths: [SessionPath]
    /// The Config's `topics`: where a new Session and a new Topic go, and the Tags a request may add.
    public let topics: Config.Topics
    private let store: TopicStore
    private let editLockTimeout: TimeInterval

    public init(paths: MuxifyPaths, server: TmuxServer = .local, sessionPaths: [SessionPath] = [], topics: Config.Topics = Config.Topics()) {
        self.init(paths: paths, server: server, sessionPaths: sessionPaths, topics: topics, editLockTimeout: 10)
    }

    init(paths: MuxifyPaths, server: TmuxServer, sessionPaths: [SessionPath], topics: Config.Topics = Config.Topics(), editLockTimeout: TimeInterval) {
        self.paths = paths
        self.server = server
        self.sessionPaths = sessionPaths
        self.topics = topics
        self.editLockTimeout = editLockTimeout
        store = TopicStore(paths: paths)
    }

    /// `client` is the host's tmux client: the one that types keys for a plan and that switches to the result.
    /// It is a fact of the host, not of the request, so it is not on the wire. Nil switches nothing.
    /// A failure is returned, never thrown: its phase says how far the request got.
    public func handle(_ request: TopicRequest, client: String? = nil) -> TopicResponse {
        guard request.version == TopicRequest.currentVersion else {
            return .failed(TopicFailure(kind: .unsupported, phase: .nothingChanged,
                                        message: "The Topic request has version \(request.version). This Muxify reads version \(TopicRequest.currentVersion)."))
        }
        if case .list = request.command { return list() }
        if case .show = request.command { return show(request, client: client) }
        // A Snooze writes one key of each record, so it takes only the record lock, as the app's Snooze does.
        if case .snooze(let deadline, let topics) = request.command { return snooze(request, topics, until: deadline, client: client) }
        if case .unsnooze(let topics) = request.command { return snooze(request, topics, until: nil, client: client) }
        if case .tags(let change) = request.command { return changeTags(request, change, client: client) }
        do {
            return try FileLock.withLock(paths.editLock, .exclusive, rank: .edit, timeout: editLockTimeout) {
                switch request.command {
                case .lock: return changeLock(request, locked: true, client: client)
                case .unlock: return changeLock(request, locked: false, client: client)
                default: return edit(request, client: client)
                }
            }
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// The Sessions the Settle sheet offers, as the Topic's live Sessions are now. It reads and writes nothing else.
    public func settleChoices(for target: TopicTarget) -> Result<[TopicSettleSession], TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = server.snapshot()
            let topic = try openTopic(target, caller: nil, records: records, snapshot: snapshot, client: nil)
            let record = topic.remembering(snapshot, order: topics.sessionOrder) ?? topic
            return .success(TopicSettleSession.choices(topic: record, snapshot: snapshot, sessionPaths: sessionPaths,
                                                       mergedWorktrees: TopicWorktrees.merged(in: record, root: paths.worktrees.path)))
        } catch {
            return .failure(failure(error, phase: .nothingChanged))
        }
    }

    public func forgetChoices(for target: TopicTarget) -> Result<TopicForgetChoices, TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = server.snapshot()
            let topic = try forgetTopic(target, caller: nil, records: records, snapshot: snapshot, client: nil)
            return .success(TopicForgetChoices(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, root: paths.worktrees.path))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    /// The Worktree that the Topic made for the target Session, which Remove and Kill can remove. Nil when the
    /// Session works in no such Worktree.
    public func removeAndKillWorktree(of session: SessionID) -> Result<TopicForgetChoices.Worktree?, TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = server.snapshot()
            let window = try sessionWindow(.session(session), caller: nil, snapshot: snapshot, client: nil)
            guard let topic = TopicMembershipPlan.openTopic(of: window, records: records) else { throw TopicRequestError.sourceHasNoTopic }
            return .success(madeWorktree(of: window, topic: topic, snapshot: snapshot))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    private func madeWorktree(of window: TmuxWindow, topic: TopicRecord, snapshot: TmuxSnapshot) -> TopicForgetChoices.Worktree? {
        guard let worktree = topic.session(of: window)?["worktree_path"]?.string.map(Folder.local) else { return nil }
        return TopicForgetChoices(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, root: paths.worktrees.path)
            .worktrees.first { Folder.local($0.spec.path) == worktree }
    }

    /// A window of the Session that the target names, or of the Session of the Pane that the target or the caller names.
    private func sessionWindow(_ target: TopicTarget?, caller: TopicCaller?, snapshot: TmuxSnapshot, client: String?) throws -> TmuxWindow {
        let sessionID: String
        if case .session(let id)? = target { sessionID = id.rawValue }
        else {
            guard let pane = paneRequest(target, caller: caller) else { throw TopicRequestError.noTarget }
            sessionID = try executor.pane(pane, in: snapshot, client: client).source.window.sessionID
        }
        guard let window = snapshot.windows.first(where: { $0.sessionID == sessionID }) else { throw TopicEditFailure.sourceUnavailable }
        return window
    }

    private var executor: TopicExecutor { TopicExecutor(server: server, worktreesRoot: paths.worktrees.path) }

    private func list() -> TopicResponse {
        do {
            return .topics(try store.read().records.filter { $0.settledAt == nil }.map(TopicSummary.init(record:)))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    private func show(_ request: TopicRequest, client: String?) -> TopicResponse {
        do {
            let records = try store.read().records
            let snapshot = server.snapshot()
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            let branches = TopicBranches(records: [topic]) { try? String(contentsOfFile: $0, encoding: .utf8) }
            return .topic(TopicDetail(record: topic, snapshot: snapshot, sessionPaths: sessionPaths, branches: branches))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// A nil `deadline` is an Unsnooze. Every Topic resolves before the one write, so a bad ref changes nothing.
    private func snooze(_ request: TopicRequest, _ topics: [TopicRef], until deadline: SnoozeDeadline?, client: String?) -> TopicResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            if !topics.isEmpty, request.target != nil { throw TopicRequestError.targetAndTopics }
            let records = try store.read().records
            let resolved = topics.isEmpty
                ? [try openTopic(request.target, caller: request.caller, records: records, snapshot: server.snapshot(), client: client)]
                : try topics.map { try $0.resolve(in: records) }
            var ids: [String] = []
            for topic in resolved where !ids.contains(topic.id) { ids.append(topic.id) }
            let locks = SessionLock.locks(in: server.snapshot().windows, records: records)
            let (shortened, moved) = try store.write(locks: locks) { transaction -> ([String], [SessionLock]) in
                guard let deadline else {
                    let saves = try ids.map { id in
                        guard var record = transaction.records.first(where: { $0.id == id && $0.settledAt == nil }) else {
                            throw TopicRequestError.topicUnavailable(id)
                        }
                        record.snoozedUntil = nil
                        return record
                    }
                    return ([], try transaction.setSnoozes(saves, insertPosition: self.topics.insertPosition))
                }
                let set = SnoozeSet(ids, until: deadline, records: transaction.records)
                // A Topic that was Settled after the read has no save.
                if let settled = ids.first(where: { id in !set.saves.contains { $0.id == id } }) {
                    throw TopicRequestError.topicUnavailable(settled)
                }
                return (set.shortened, try transaction.setSnoozes(set.saves, insertPosition: self.topics.insertPosition))
            }
            phase = .changesStarted
            try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            return .snoozeChanged(TopicSnoozeChange(topicIDs: ids, shortened: shortened))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    /// Tags are one key of one record, so a Tag change also takes only the record lock.
    private func changeTags(_ request: TopicRequest, _ change: TopicTagChange, client: String?) -> TopicResponse {
        do {
            let records = try store.read().records
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: server.snapshot(), client: client)
            try checkDefined(change, on: topic.tags)
            try store.write { try $0.changeTags(of: topic.id, change) }
            return .changed(TopicChange(topicID: topic.id))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// Only the Tags in `topics.tags` can be added; a Tag the Config no longer defines can stay on its Topic.
    private func checkDefined(_ change: TopicTagChange, on tags: Set<Tag>) throws {
        let undefined = topics.tags?.undefinedTags(added: change, to: tags) ?? change.applied(to: tags).subtracting(tags).sorted()
        guard undefined.isEmpty else { throw TopicRequestError.undefinedTags(undefined) }
    }

    /// A plan with what the host shows when the plan itself selects nothing.
    private struct Planned {
        var edit: TopicEdit
        var shown: TopicChange.Shown?
        /// The Locked Session whose place a new Topic takes.
        var replacedLockOf: String? = nil
    }

    private func edit(_ request: TopicRequest, client: String?) -> TopicResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = try store.read().records
            let snapshot = server.snapshot()
            let planned = try plan(request, records: records, snapshot: snapshot, client: client)
            let edit = planned.edit
            try TopicWorktrees.check(edit.commands)
            if let new = edit.newWorktree { try TopicWorktrees.add(new.worktree, at: new.commit) }
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
            try executor.run(commands, client: client)
            switch edit.completion {
            case .save(let record):
                let before = edit.record ?? records.first { $0.id == record.id }
                let locks = SessionLock.locks(in: server.snapshot().windows, records: try store.read().records)
                let moved = try store.write(locks: locks) {
                    try $0.apply(TopicRecordChange(before: before, after: record), insertPosition: topics.insertPosition)
                }
                try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            case .forget(let id):
                let locks = SessionLock.locks(in: server.snapshot().windows, records: try store.read().records)
                let moved = try store.write(locks: locks) { try $0.forget(id, insertPosition: topics.insertPosition) }
                try executor.run(moved.map { .tmux($0.setOption) }, client: client)
            case nil: break
            }
            phase = .selectionFailed
            let shown = try executor.show(edit.selection, client: client) ?? planned.shown
            return .changed(TopicChange(topicID: edit.completion?.topicID ?? edit.record?.id,
                                        created: edit.record != nil && read == nil, shown: shown))
        } catch {
            return .failed(failure(error, phase: phase))
        }
    }

    private func plan(_ request: TopicRequest, records: [TopicRecord], snapshot: TmuxSnapshot, client: String?) throws -> Planned {
        func source() throws -> (TopicPaneSource, TmuxSnapshot) {
            guard let pane = paneRequest(request.target, caller: request.caller) else { throw TopicRequestError.noTarget }
            let resolved = try executor.pane(pane, in: snapshot, client: client)
            return (resolved.source, resolved.snapshot)
        }
        switch request.command {
        case .list, .show, .lock, .unlock, .snooze, .unsnooze, .tags:
            throw TopicRequestError.noTarget
        case .create(let title, let repositoryPath, let tags):
            let tags = Set(tags ?? [])
            try checkDefined(.add(Array(tags)), on: [])
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let launch: SessionPath
            if let repositoryPath {
                launch = try sessionPath(at: repositoryPath)
            } else if paneRequest(request.target, caller: request.caller) != nil {
                let (pane, _) = try source()
                let directory = Folder.local(pane.directory ?? pane.window.path)
                launch = SessionPath(folder: directory, name: SessionNaming.base(of: pane.window.sessionName,
                    topic: TopicMembershipPlan.sourceRecord(for: pane.window, records: records)))
            } else {
                let slug = TopicNaming.slug(title: title, records: records)
                var record = TopicRecord(newTopic: UUID().uuidString.lowercased(), title: title, slug: slug, now: Date())
                record.tags = tags
                return Planned(edit: TopicEdit(record: record, commands: [], selection: .emptyTopic(record.id)))
            }
            let plan = TopicPlan(title: title, sessionPath: launch, records: records,
                                 sessionNames: Set(snapshot.windows.map(\.sessionName)), clientTTY: client)
            var record = plan.record
            record.tags = tags
            return Planned(edit: TopicEdit(record: record, commands: plan.commands, selection: .sessionName(plan.sessionName)))
        case .extract(let repositoryPath, let title):
            let (pane, fresh) = try source()
            let launch = try repositoryPath.map { try sessionPath(at: $0) }
            return Planned(edit: try TopicPanePlan(source: pane, sessionPath: launch, title: title ?? "", records: records, windows: fresh.windows,
                                                   sessionPaths: sessionPaths, clientTTY: client).edit)
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
                plan = try TopicMembershipPlan(source: moved, title: title, records: records, windows: windows,
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
            guard case .session(let id) = request.target else { throw TopicRequestError.noTarget }
            guard let topic = snapshot.windows.first(where: { $0.sessionID == id.rawValue })
                .flatMap({ window in records.first { $0.id == window.topicID && $0.settledAt == nil } }) else {
                throw TopicEditFailure.sessionUnavailable
            }
            return Planned(edit: try TopicSessionOrderPlan(moving: id.rawValue, to: placement, topic: topic, windows: snapshot.windows,
                                                           sessionPaths: sessionPaths, order: topics.sessionOrder).edit)
        case .sortSessions:
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            return Planned(edit: TopicSessionOrderPlan(sortingByCreation: topic).edit)
        case .reopen, .startFresh:
            guard case .topic(let ref) = request.target else { throw TopicRequestError.noTarget }
            let topic = try ref.resolve(in: records, open: false)
            return Planned(edit: try TopicReopenPlan(topic: topic, records: records, windows: snapshot.windows, sessionPaths: sessionPaths,
                                                     existingDirectories: TopicReopening.existingWorktrees(of: topic),
                                                     choice: request.command == .startFresh ? .startFresh : .reopen).edit)
        }
    }

    /// Lock and Unlock change only the Session option and, when a Lock renumbers the list, the Topic records.
    private func changeLock(_ request: TopicRequest, locked: Bool, client: String?) -> TopicResponse {
        var phase = TopicFailure.Phase.nothingChanged
        do {
            let records = try store.read().records
            let snapshot = server.snapshot()
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

    /// The No Topic Session that the target names, or the Session of the caller's Pane.
    private func noTopicSession(_ target: TopicTarget?, caller: TopicCaller?, records: [TopicRecord], snapshot: TmuxSnapshot,
                                client: String?) throws -> TmuxWindow {
        let found: TmuxWindow?
        switch target {
        case .session(let id)?: found = snapshot.windows.first { $0.sessionID == id.rawValue }
        case .sessionName(let name)?:
            guard let named = snapshot.windows.first(where: { $0.sessionName == name }) else {
                throw TopicRequestError.sessionUnavailable(name)
            }
            found = named
        case .topic?: throw TopicRequestError.noTarget
        default:
            guard let pane = paneRequest(target, caller: caller) else { throw TopicRequestError.noTarget }
            let sessionID = try executor.pane(pane, in: snapshot, client: client).source.window.sessionID
            found = snapshot.windows.first { $0.sessionID == sessionID }
        }
        guard let window = found else { throw TopicEditFailure.sourceUnavailable }
        if let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) {
            throw TopicRequestError.sessionInTopic(session: window.sessionName, topic: TopicSummary(record: topic).label)
        }
        return window
    }

    private func forgetTopic(_ target: TopicTarget?, caller: TopicCaller?, records: [TopicRecord],
                             snapshot: TmuxSnapshot, client: String?) throws -> TopicRecord {
        if case .topic(let ref)? = target { return try ref.resolve(in: records, open: false) }
        return try openTopic(target, caller: caller, records: records, snapshot: snapshot, client: client)
    }

    /// The Pane a request acts on: its target, else its caller. One rule for every command.
    private func paneRequest(_ target: TopicTarget?, caller: TopicCaller?) -> TopicPaneRequest? {
        switch target {
        case .pane(let id)?: return .pane(id.rawValue)
        case .window(let id)?: return .window(id.rawValue)
        case .topic?, .session?, .sessionName?: return nil
        case nil: break
        }
        switch caller {
        case .pane(let id)?: return .pane(id.rawValue)
        case .currentClient?: return .currentClient
        case nil: return nil
        }
    }

    /// The open Topic of the target, or of the Pane that the target or the caller names.
    private func openTopic(_ target: TopicTarget?, caller: TopicCaller?, records: [TopicRecord], snapshot: TmuxSnapshot,
                           client: String?) throws -> TopicRecord {
        if case .topic(let ref)? = target { return try ref.resolve(in: records, open: true) }
        guard let pane = paneRequest(target, caller: caller) else { throw TopicRequestError.noTarget }
        let window = try executor.pane(pane, in: snapshot, client: client).source.window
        guard let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) else {
            throw TopicRequestError.sourceHasNoTopic
        }
        return topic
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
        case .newWorktree(let path, let base):
            return .newWorktree(at: try TopicWorktrees.commit(base, in: try worktree(at: path)), root: paths.worktrees.path)
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

    private func failure(_ error: Error, phase: TopicFailure.Phase) -> TopicFailure {
        TopicFailure(kind: Self.kind(of: error), phase: phase, message: message(error))
    }

    /// Our failure types say what went wrong in Topic words. A Foundation error only says what the system
    /// refused, and its own description is `Error Domain=… Code=…`, so it gets the state folder and a plain reason.
    private func message(_ error: Error) -> String {
        // POSIXError and CocoaError have no description of their own; an NSError has one, but it is the raw form.
        if !(type(of: error) is NSObject.Type), let ours = (error as Any) as? CustomStringConvertible { return ours.description }
        let foundation = error as NSError
        var reason = foundation.domain == NSPOSIXErrorDomain ? String(cString: strerror(Int32(foundation.code)))
                                                            : foundation.localizedDescription
        if !reason.hasSuffix(".") { reason += "." }
        return "Muxify could not read or write the Topic records in \(paths.state.path). \(reason)"
    }

    private static func kind(of error: Error) -> TopicFailure.Kind {
        switch error {
        case let error as TopicRequestError:
            switch error {
            case .invalidURL, .targetAndTopics: return .unsupported
            case .undefinedTags: return .tagUndefined
            case .noTarget: return .noTarget
            case .sessionPathUnavailable: return .sessionPathUnavailable
            case .sourceHasNoTopic: return .sourceHasNoTopic
            case .topicUnavailable: return .topicUnavailable
            case .topicAmbiguous: return .topicAmbiguous
            case .topicMembershipChanged: return .topicMembershipChanged
            case .sessionUnavailable: return .sourceUnavailable
            case .sessionInTopic: return .sessionInTopic
            case .baseUnavailable, .worktreeBaseMissing, .worktreeHasChanges: return .gitFailed
            }
        case let error as TopicEditFailure:
            switch error {
            case .destinationUnavailable: return .topicUnavailable
            case .sourceUnavailable, .sessionUnavailable: return .sourceUnavailable
            case .invalidSessionPath: return .sessionPathUnavailable
            case .invalidTmuxResponse: return .tmuxFailed
            }
        case let error as TopicMembershipPlan.Failure:
            switch error {
            case .sourceUnavailable: return .sourceUnavailable
            case .destinationUnavailable: return .topicUnavailable
            case .chooseSession: return .unsupported
            }
        case is TopicTransaction.Failure: return .topicUnavailable
        case is FileLock.Busy: return .storeBusy
        case is TmuxError: return .tmuxFailed
        case is ShellError: return .gitFailed
        default: return .storeFailed
        }
    }
}

extension TopicRef {
    /// The record this names. `.named` takes an open Topic's id first, then the one open Topic with that slug or title.
    /// `open` false also finds a Settled Topic.
    public func resolve(in records: [TopicRecord], open: Bool = true) throws -> TopicRecord {
        let candidates = open ? records.filter { $0.settledAt == nil } : records
        switch self {
        case .id(let id):
            guard let topic = candidates.first(where: { $0.id == id }) else { throw TopicRequestError.topicUnavailable(id) }
            return topic
        case .named(let value):
            if let exact = candidates.first(where: { $0.id == value }) { return exact }
            let matches = candidates.filter { $0.slug == value || $0.title == value }
            guard let only = matches.first else { throw TopicRequestError.topicUnavailable(value) }
            guard matches.count == 1 else { throw TopicRequestError.topicAmbiguous(value) }
            return only
        }
    }
}

public enum TopicRequestError: Error, CustomStringConvertible {
    case invalidURL
    case noTarget
    case sessionPathUnavailable(String)
    case sourceHasNoTopic
    case topicUnavailable(String)
    case topicAmbiguous(String)
    case topicMembershipChanged
    case baseUnavailable(ref: String, worktree: String)
    case worktreeBaseMissing(base: String, worktree: String)
    case worktreeHasChanges(String)
    case sessionUnavailable(String)
    case sessionInTopic(session: String, topic: String)
    case targetAndTopics
    case undefinedTags([Tag])

    public var description: String {
        switch self {
        case .invalidURL: return "The Topic URL is invalid."
        case .noTarget: return "The request names no Topic, Window or Pane, and it does not come from a Pane."
        case .sessionPathUnavailable(let path): return "No launch directory is available at \(path)."
        case .sourceHasNoTopic: return "The Pane is not in an open Topic."
        case .topicUnavailable(let value): return "No open Topic matches \(value)."
        case .topicMembershipChanged: return "The Topic Sessions, Windows or Panes changed. Review them and confirm again."
        case .topicAmbiguous(let value): return "More than one open Topic matches \(value). Use an id."
        case .baseUnavailable(let ref, let worktree): return "No commit matches \(ref) in \(worktree)."
        case .worktreeBaseMissing(let base, let worktree):
            return "The Worktree \(worktree) and its branch are gone, and the repository does not have their base commit \(base). Muxify did not make the Worktree again."
        case .worktreeHasChanges(let worktree):
            return "The Worktree \(worktree) has uncommitted changes. Commit or remove them, or keep the Worktree."
        case .sessionUnavailable(let name): return "No tmux Session has the name \(name)."
        case .sessionInTopic(let session, let topic):
            return "The Session \(session) is in the Topic \(topic). Only a No Topic Session can be Locked."
        case .targetAndTopics: return "The request names a target and a list of Topics. Name only one of them."
        case .undefinedTags(let tags):
            return "The Config does not define \(tags.map(\.description).joined(separator: ", ")) in topics.tags. Add a Tag there first."
        }
    }
}
