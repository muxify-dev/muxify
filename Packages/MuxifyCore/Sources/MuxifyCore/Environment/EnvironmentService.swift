import Foundation

/// The one way to read or change the Environment. The app's palette, the muxify://topic URL and the command line tool
/// all send an `EnvironmentRequest` here, so each change takes the same locks and fails in the same way, by its
/// command's `lane`. It blocks, so call it off the main thread.
public struct EnvironmentService: Sendable {
    public let paths: MuxifyPaths
    public let server: any TmuxRunning
    /// The SessionPaths a request may name, with the layouts that git reported.
    public let sessionPaths: [SessionPath]
    /// The Config's `topics`: where a new Session and a new Topic go, and the Tags a request may add.
    public let topics: Config.Topics
    /// False on a Remote Environment: Topic records are local, so a command that reads or writes one fails there.
    public let topicsAvailable: Bool
    let store: TopicStore
    let editLockTimeout: TimeInterval

    public init(paths: MuxifyPaths, server: any TmuxRunning = TmuxServer.local, sessionPaths: [SessionPath] = [],
                topics: Config.Topics = Config.Topics(), topicsAvailable: Bool = true) {
        self.init(paths: paths, server: server, sessionPaths: sessionPaths, topics: topics, topicsAvailable: topicsAvailable, editLockTimeout: 10)
    }

    init(paths: MuxifyPaths, server: any TmuxRunning, sessionPaths: [SessionPath], topics: Config.Topics = Config.Topics(),
         topicsAvailable: Bool = true, editLockTimeout: TimeInterval) {
        self.paths = paths
        self.server = server
        self.sessionPaths = sessionPaths
        self.topics = topics
        self.topicsAvailable = topicsAvailable
        self.editLockTimeout = editLockTimeout
        store = TopicStore(paths: paths)
    }

    /// `client` is the host's tmux client: the one that types keys for a plan and that switches to the result.
    /// It is a fact of the host, not of the request, so it is not on the wire. Nil switches nothing.
    /// A failure is returned, never thrown: its phase says how far the request got.
    public func handle(_ request: EnvironmentRequest, client: String? = nil) -> EnvironmentResponse {
        guard request.version == EnvironmentRequest.currentVersion else {
            return .failed(TopicFailure(kind: .unsupported, phase: .nothingChanged,
                                        message: "The Topic request has version \(request.version). This Muxify reads version \(EnvironmentRequest.currentVersion)."))
        }
        guard topicsAvailable || !request.needsRecords else {
            return .failed(failure(TopicRequestError.topicsUnavailable, phase: .nothingChanged))
        }
        switch request.command.lane {
        case .read:
            if case .list = request.command { return list() }
            return show(request, client: client)
        case .records:
            return changeRecords(request, client: client)
        case .edit:
            do {
                return try FileLock.withLock(paths.editLock, .exclusive, rank: .edit, timeout: editLockTimeout) {
                    switch request.command {
                    case .lock: return changeLock(request, locked: true, client: client)
                    case .unlock: return changeLock(request, locked: false, client: client)
                    case .moveSession(.up): return stepSession(request, .up, client: client)
                    case .moveSession(.down): return stepSession(request, .down, client: client)
                    default: return edit(request, client: client)
                    }
                }
            } catch {
                return .failed(failure(error, phase: .nothingChanged))
            }
        }
    }

    /// The Sessions the Settle sheet offers, as the Topic's live Sessions are now. It reads and writes nothing else.
    public func settleChoices(for target: EnvironmentTarget) -> Result<[TopicSettleSession], TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let topic = try openTopic(target, caller: nil, records: records, snapshot: snapshot, client: nil)
            let record = topic.remembering(snapshot, order: topics.sessionOrder) ?? topic
            return .success(TopicSettleSession.choices(topic: record, snapshot: snapshot, sessionPaths: sessionPaths,
                                                       mergedWorktrees: TopicWorktrees.merged(in: record, root: paths.worktrees.path)))
        } catch {
            return .failure(failure(error, phase: .nothingChanged))
        }
    }

    public func forgetChoices(for target: EnvironmentTarget) -> Result<TopicForgetChoices, TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let topic = try forgetTopic(target, caller: nil, records: records, snapshot: snapshot, client: nil)
            return .success(TopicForgetChoices(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, root: paths.worktrees.path))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    /// The local branches that a new Worktree from the Worktree at `path` can start from: the rows of the palette's
    /// start step. It reads git and changes nothing.
    public func worktreeStarts(from path: String) -> Result<[WorktreeStartChoice], TopicFailure> {
        let folder = Folder.local(path)
        guard let base = sessionPaths.lazy.flatMap(\.layout.worktrees).first(where: { $0.folder == folder }) else {
            return .failure(failure(TopicRequestError.sessionPathUnavailable(path), phase: .nothingChanged))
        }
        do { return .success(try TopicWorktrees.branches(in: base)) } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    /// The Worktree that the Topic made for the target's Session, which Remove and Kill can remove. Nil when the
    /// Session works in no such Worktree.
    public func removeAndKillWorktree(of target: EnvironmentTarget) -> Result<TopicForgetChoices.Worktree?, TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let window = try sessionWindow(target, caller: nil, snapshot: snapshot, client: nil)
            guard let topic = TopicMembershipPlan.openTopic(of: window, records: records) else { throw TopicRequestError.sourceHasNoTopic }
            return .success(madeWorktree(of: window, topic: topic, snapshot: snapshot))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    func madeWorktree(of window: TmuxWindow, topic: TopicRecord, snapshot: TmuxSnapshot) -> TopicForgetChoices.Worktree? {
        guard let worktree = topic.session(of: window)?["worktree_path"]?.string.map(Folder.local) else { return nil }
        return TopicForgetChoices(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, root: paths.worktrees.path)
            .worktrees.first { Folder.local($0.spec.path) == worktree }
    }

    /// A window of the Session that the target names, or of the Session of the Pane that the target or the caller names.
    func sessionWindow(_ target: EnvironmentTarget?, caller: TopicCaller?, snapshot: TmuxSnapshot, client: String?) throws -> TmuxWindow {
        let sessionID: String
        if case .session(let id)? = target { sessionID = id.rawValue }
        else if case .sessionName(let name)? = target {
            guard let named = snapshot.windows.first(where: { $0.sessionName == name }) else { throw TopicRequestError.sessionUnavailable(name) }
            sessionID = named.sessionID
        } else {
            guard let pane = paneRequest(target, caller: caller) else { throw TopicRequestError.noTarget }
            sessionID = try executor.pane(pane, in: snapshot, client: client).source.window.sessionID
        }
        guard let window = snapshot.windows.first(where: { $0.sessionID == sessionID }) else { throw TopicEditFailure.sourceUnavailable }
        return window
    }

    var executor: TopicExecutor { TopicExecutor(server: server, worktreesRoot: paths.worktrees.path) }

    func list() -> EnvironmentResponse {
        do {
            // The order of the Topics list: Pinned first, then the order the user gave.
            let open = try store.read().records.filter { $0.settledAt == nil }
            return .topics(TopicOrder.sorted(open.map(TopicListEntry.topic)).compactMap { entry in
                if case .topic(let record) = entry { return TopicSummary(record: record) } else { return nil }
            })
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    func show(_ request: EnvironmentRequest, client: String?) -> EnvironmentResponse {
        do {
            let records = try store.read().records
            let snapshot = try server.snapshot()
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            let branches = TopicBranches(records: [topic]) { try? String(contentsOfFile: $0, encoding: .utf8) }
            return .topic(TopicDetail(record: topic, snapshot: snapshot, sessionPaths: sessionPaths, order: topics.sessionOrder, branches: branches))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// The No Topic Session that the target names, or the Session of the caller's Pane.
    func noTopicSession(_ target: EnvironmentTarget?, caller: TopicCaller?, records: [TopicRecord], snapshot: TmuxSnapshot,
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

    func forgetTopic(_ target: EnvironmentTarget?, caller: TopicCaller?, records: [TopicRecord],
                             snapshot: TmuxSnapshot, client: String?) throws -> TopicRecord {
        if case .topic(let ref)? = target { return try ref.resolve(in: records, open: false) }
        return try openTopic(target, caller: caller, records: records, snapshot: snapshot, client: client)
    }

    /// The Pane a request acts on: its target, else its caller. One rule for every command.
    func paneRequest(_ target: EnvironmentTarget?, caller: TopicCaller?) -> TopicPaneRequest? {
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
    func openTopic(_ target: EnvironmentTarget?, caller: TopicCaller?, records: [TopicRecord], snapshot: TmuxSnapshot,
                           client: String?) throws -> TopicRecord {
        if case .topic(let ref)? = target { return try ref.resolve(in: records, open: true) }
        guard let pane = paneRequest(target, caller: caller) else { throw TopicRequestError.noTarget }
        let window = try executor.pane(pane, in: snapshot, client: client).source.window
        guard let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) else {
            throw TopicRequestError.sourceHasNoTopic
        }
        return topic
    }

    func failure(_ error: Error, phase: TopicFailure.Phase) -> TopicFailure {
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
            case .invalidURL, .targetAndTopics, .removedForm: return .unsupported
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
            case .branchUnavailable: return .branchUnavailable
            case .branchCheckedOut: return .branchCheckedOut
            case .chooseSession: return .chooseSession
            case .topicEmpty: return .topicEmpty
            case .topicsUnavailable: return .topicsUnavailable
            case .sessionNameInvalid: return .sessionNameInvalid
            case .panesChanged: return .panesChanged
            case .cardAtEnd: return .cardAtEnd
            case .sessionAtEnd: return .sessionAtEnd
            case .cardHidden: return .cardHidden
            case .zenOn: return .zenOn
            case .windowNotInSession: return .windowNotInSession
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

extension EnvironmentCommand {
    enum Lane { case read, records, edit }

    /// The locks a command takes. `read`: none. `records`: the record lock only, for one write of record keys and the tmux options that go with it.
    /// `edit`: the edit lock, then read, plan, git, record, tmux, show. A new command does not compile until it
    /// chooses its lane.
    var lane: Lane {
        switch self {
        case .list, .show: return .read
        case .snooze, .unsnooze, .tags, .pin, .unpin, .moveCard, .startZen, .endZen, .markRead, .markAllRead: return .records
        case .create, .addSession, .settle, .forget, .move, .removeFromTopic, .removeAndKill, .rename,
             .reopen, .startFresh, .moveSession, .sortSessions, .lock, .unlock, .newWindow, .newSession, .renameSession,
             .renameWindow, .moveWindow, .killWindow, .killSession: return .edit
        }
    }

    /// Whether the command reads or writes a Topic record whatever its target.
    var needsRecords: Bool {
        switch self {
        case .newWindow, .newSession, .renameSession, .renameWindow, .moveWindow, .killWindow, .killSession: return false
        // Agent Unread is in tmux. Only a Topic's Read state is in its record; Mark All as Read leaves the records
        // out where there are none.
        case .markRead(_, let scope): return scope == .topic
        case .markAllRead: return false
        case .list, .show, .create, .addSession, .settle, .forget, .move, .removeFromTopic, .removeAndKill, .rename, .reopen, .startFresh,
             .moveSession, .sortSessions, .lock, .unlock, .snooze, .unsnooze, .tags, .pin, .unpin, .moveCard, .startZen, .endZen:
            return true
        }
    }
}

extension EnvironmentRequest {
    /// Whether the request reads or writes a Topic record. Only the others run on a Remote Environment. A `.topic`
    /// target is found through the records, so it needs them with any command.
    var needsRecords: Bool {
        if case .topic? = target { return true }
        return command.needsRecords
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
    case branchUnavailable(branch: String, worktree: String)
    case branchCheckedOut(branch: String, worktree: String)
    case chooseSession(topic: String, sessions: [String])
    case topicEmpty(topic: String, id: String, dormant: Bool)
    case topicsUnavailable
    case sessionNameInvalid(String)
    case panesChanged
    case cardAtEnd(card: String, up: Bool, pinned: Bool)
    case sessionAtEnd(session: String, topic: String, up: Bool)
    case cardHidden(String)
    case zenOn
    case windowNotInSession(window: String, anchor: String)
    /// An old form of a request that now fails, with the message that names the new form.
    case removedForm(String)

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
        case .removedForm(let message): return message
        case .chooseSession(let topic, let sessions):
            return "The Topic \(topic) has more than one Session: \(sessions.joined(separator: ", ")). Choose one with --session."
        case .topicEmpty(let topic, let id, let dormant):
            return dormant ? "The Topic \(topic) has no live Session. Reopen it first: muxify topic reopen --topic \(id). "
                             + "Or add one: muxify topic add-session <dir> --topic \(id)."
                           : "The Topic \(topic) has no Session. Add one first: muxify topic add-session <dir> --topic \(id)."
        case .topicsUnavailable: return "Topics are not available in a Remote Environment."
        case .panesChanged: return "The Windows or Panes changed. Review them and confirm again."
        case .cardAtEnd(let card, let up, let pinned):
            return "\(card) is the \(up ? "first" : "last") card among the \(pinned ? "Pinned Topics" : "Topics that are not Pinned")."
        case .sessionAtEnd(let session, let topic, let up):
            return "The Session \(session) is the \(up ? "first" : "last") Session of the Topic \(topic)."
        case .cardHidden(let message): return message
        case .zenOn: return "Zen is on. One Zen at a time: end it first with muxify zen end."
        case .windowNotInSession(let window, let anchor): return "The Window \(anchor) is not in the Session of the Window \(window)."
        case .sessionNameInvalid(let name): return "\(name) cannot name a tmux Session: it is empty, or it has a period, a colon or a control character."
        case .branchUnavailable(let branch, let worktree): return "No local branch \(branch) is in the repository of \(worktree)."
        case .branchCheckedOut(let branch, let worktree):
            return "The branch \(branch) is checked out in the Worktree \(worktree). git checks out a branch in one Worktree only."
        case .undefinedTags(let tags):
            return "The Config does not define \(tags.map(\.description).joined(separator: ", ")) in topics.tags. Add a Tag there first."
        }
    }
}
