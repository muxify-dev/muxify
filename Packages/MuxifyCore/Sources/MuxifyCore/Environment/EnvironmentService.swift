import Foundation

/// The one way to read or change the Environment. The app's palette, the muxify://topic URL and the command line tool
/// all send an `EnvironmentRequest` here, so each change runs and fails in the same way, by its command's `lane`.
/// No request takes a lock: each record write is one short transaction of the columns it changed, and the last write
/// to a field wins. It blocks, so call it off the main thread.
public struct EnvironmentService: Sendable {
    public let paths: MuxifyPaths
    public let server: any TmuxRunning
    /// The SessionPaths a request may name, with the layouts that git reported.
    public let sessionPaths: [SessionPath]
    /// The Config's `topics`: where a new Session and a new Topic go, and the Tags a request may add.
    public let topics: Config.Topics
    /// The Config's `notifications`: which Agent marks `environment show` shows.
    public let notifications: Config.Notifications
    /// The Config's `worktrees.root_path` on the machine whose records this service keeps: a Host's own, never the
    /// Mac's (ADR 0090).
    public let worktreesRoot: String?
    /// The Request that the command line runs through this service; nil for every other caller. The store writes
    /// its ledger row, and a new Topic takes its id.
    public let request: PendingRequest?
    let store: TopicStore

    public init(paths: MuxifyPaths, server: any TmuxRunning = TmuxServer.local, sessionPaths: [SessionPath] = [],
                topics: Config.Topics = Config.Topics(), notifications: Config.Notifications = Config.Notifications(),
                worktreesRoot: String? = nil, request: PendingRequest? = nil) {
        self.paths = paths
        self.server = server
        self.sessionPaths = sessionPaths
        self.topics = topics
        self.notifications = notifications
        self.worktreesRoot = worktreesRoot
        self.request = request
        store = TopicStore(paths: paths, inPlay: topics.inPlay, request: request)
    }

    /// `client` is the host's tmux client: the one that types keys for a plan and that switches to the result.
    /// It is a fact of the host, not of the request, so it is not on the wire. Nil switches nothing.
    /// A failure is returned, never thrown: its phase says how far the request got.
    public func handle(_ request: EnvironmentRequest, client: String? = nil) -> EnvironmentResponse {
        guard request.version == EnvironmentRequest.currentVersion else {
            return .failed(TopicFailure(kind: .unsupported, phase: .nothingChanged,
                                        message: "The Topic request has version \(request.version). This Muxify reads version \(EnvironmentRequest.currentVersion)."))
        }
        switch request.command.lane {
        case .read(let read):
            switch read {
            case .list: return list()
            case .show: return show(request, client: client)
            case .environmentShow: return environmentShow()
            case .listWorktrees(let all, let from): return listWorktrees(request, all: all, from: from, client: client)
            }
        case .records:
            return changeRecords(request, client: client)
        case .edit:
            switch request.command {
            case .moveSession(.up): return stepSession(request, .up, client: client)
            case .moveSession(.down): return stepSession(request, .down, client: client)
            case .createWorktree(let name, let from, let start, let open):
                return createWorktree(request, name: name, from: from, start: start, open: open, client: client)
            case .removeWorktree(let worktree, let kill, let force):
                return removeWorktree(request, worktree, kill: kill, force: force, client: client)
            case .forgetSettled(let days, let asOf): return forgetSettled(olderThan: days, asOf: asOf, client: client)
            default: return edit(request, client: client)
            }
        }
    }

    /// The tmux server as a request reads it. A Lock that an older Muxify kept in tmux moves into the state database
    /// first (`BoardSession.importLegacy`), so a Guest Session from before keeps its card; a request that also reads
    /// the records reads them after this, so it finds the new Lock. The import writes through a store without the
    /// Request, so the Request's ledger row still marks only its own write. A failed import leaves the snapshot as
    /// tmux gave it.
    func serverSnapshot() throws -> TmuxSnapshot {
        var snapshot = try server.snapshot()
        _ = try? BoardSession.importLegacy(from: &snapshot, into: TopicStore(paths: paths, inPlay: topics.inPlay)) { try server.run($0) }
        return snapshot
    }

    /// The Sessions the Settle sheet offers, as the Topic's live Sessions are now. It writes nothing, beyond the import
    /// that each read of the server makes (`serverSnapshot`).
    public func settleChoices(for target: EnvironmentTarget) -> Result<[TopicSettleSession], TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = try serverSnapshot()
            let topic = try openTopic(target, caller: nil, records: records, snapshot: snapshot, client: nil)
            let record = topic.remembering(snapshot, order: topics.sessionOrder) ?? topic
            return .success(TopicSettleSession.choices(topic: record, snapshot: snapshot, sessionPaths: sessionPaths,
                                                       mergedWorktrees: TopicWorktrees.merged(in: record, paths: paths)))
        } catch {
            return .failure(failure(error, phase: .nothingChanged))
        }
    }

    public func sessionPathChoices(for target: EnvironmentTarget) -> Result<TopicSessionPathChoices, TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = try serverSnapshot()
            let topic = try openTopic(target, caller: nil, records: records, snapshot: snapshot, client: nil)
            return .success(TopicSessionPathChoices(topic: topic, records: records, windows: snapshot.windows, sessionPaths: sessionPaths))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    public func forgetChoices(for target: EnvironmentTarget) -> Result<TopicForgetChoices, TopicFailure> {
        do {
            let records = try store.read().records
            let snapshot = try serverSnapshot()
            let topic = try forgetTopic(target, caller: nil, records: records, snapshot: snapshot, client: nil)
            return .success(TopicForgetChoices(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, paths: paths))
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
            let snapshot = try serverSnapshot()
            let window = try sessionWindow(target, caller: nil, snapshot: snapshot, client: nil)
            guard let topic = TopicMembershipPlan.openTopic(of: window, records: records) else { throw TopicRequestError.sourceHasNoTopic }
            return .success(madeWorktree(of: window, topic: topic, snapshot: snapshot))
        } catch { return .failure(failure(error, phase: .nothingChanged)) }
    }

    func madeWorktree(of window: TmuxWindow, topic: TopicRecord, snapshot: TmuxSnapshot) -> TopicForgetChoices.Worktree? {
        guard let worktree = topic.session(of: window)?["worktree_path"]?.string.map(Folder.local) else { return nil }
        return TopicForgetChoices(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, paths: paths)
            .worktrees.first { Folder.local($0.spec.path) == worktree }
    }

    /// A window of the Session that the target names, or of the Session of the Pane that the target or the caller names.
    /// A Guest Session named by its Lock id names its live Session.
    func sessionWindow(_ target: EnvironmentTarget?, caller: TopicCaller?, snapshot: TmuxSnapshot, client: String?) throws -> TmuxWindow {
        let sessionID: String
        if case .session(let id)? = target { sessionID = id.rawValue }
        else if case .boardSession(let id)? = target {
            let contents = try store.read()
            let lock = try boardSessionRow(id, in: contents)
            guard let live = lock.windows(in: snapshot.windows, open: contents.records.openTopicIDs).first else {
                throw TopicRequestError.boardSessionDormant(id)
            }
            sessionID = live.sessionID
        }
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

    /// The Lock that a `guest_session` target names. With none, the Guest Session was Benched or ended.
    func boardSessionRow(_ id: String, in contents: TopicContents) throws -> BoardSession {
        guard let lock = contents.boardSessions.first(where: { $0.id == id }) else { throw TopicRequestError.boardSessionUnavailable(id) }
        return lock
    }

    var executor: TopicExecutor { TopicExecutor(server: server, paths: paths) }

    func list() -> EnvironmentResponse {
        do {
            // The order of the Topics list: Pinned first, then the order the user gave.
            let records = try store.read().records
            let labels = TopicLabels(records)
            return .topics(TopicOrder.sorted(records.filter { $0.settledAt == nil }.map(BoardCard.topic)).compactMap { entry in
                guard case .topic(let record) = entry else { return nil }
                return TopicSummary(record: record, labels: labels)
            })
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    func show(_ request: EnvironmentRequest, client: String?) -> EnvironmentResponse {
        do {
            let records = try store.read().records
            let snapshot = try serverSnapshot()
            let topic = try openTopic(request.target, caller: request.caller, records: records, snapshot: snapshot, client: client)
            let branches = TopicBranches(records: [topic]) { try? String(contentsOfFile: $0, encoding: .utf8) }
            return .topic(TopicDetail(record: topic, label: TopicLabels(records).label(of: topic), snapshot: snapshot,
                                      sessionPaths: sessionPaths, topics: topics, notifications: notifications, branches: branches))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
    }

    /// One tmux snapshot, then one read of the records, which an import from the snapshot may have changed.
    func environmentShow() -> EnvironmentResponse {
        do {
            let tmux = try serverSnapshot()
            return .snapshot(EnvironmentSnapshot(contents: try store.read(), tmux: tmux, topics: topics, notifications: notifications))
        } catch {
            return .failed(failure(error, phase: .nothingChanged))
        }
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
        case .topic?, .session?, .sessionName?, .boardSession?: return nil
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
        // An NSError's description is the raw form, and so is POSIXError's and CocoaError's on Linux; on macOS they
        // have none.
        if !(type(of: error) is NSObject.Type), !(error is POSIXError), !(error is CocoaError),
           let ours = (error as Any) as? CustomStringConvertible { return ours.description }
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
            case .baseUnavailable, .worktreeBaseMissing, .worktreeHasChanges: return .gitFailed
            case .branchUnavailable: return .branchUnavailable
            case .branchCheckedOut: return .branchCheckedOut
            case .chooseSession: return .chooseSession
            case .topicEmpty: return .topicEmpty
            case .sessionNameInvalid: return .sessionNameInvalid
            case .sessionNameTaken: return .duplicateSession
            case .panesChanged: return .panesChanged
            case .cardAtEnd: return .cardAtEnd
            case .sessionAtEnd: return .sessionAtEnd
            case .cardHidden: return .cardHidden
            case .windowNotInSession: return .windowNotInSession
            case .boardSessionUnavailable, .boardSessionDormant: return .sourceUnavailable
            // As Start Fresh of a live Topic fails.
            case .boardSessionLive: return .topicUnavailable
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
        case let error as TopicOrder.Failure:
            switch error {
            case .sourceUnavailable, .anchorUnavailable: return .topicUnavailable
            case .notInPlay: return .cardNotInPlay
            case .notBenched: return .cardNotBenched
            case .pinned: return .cardPinned
            case .chosenTwice: return .unsupported
            case .notOpenPlace: return .placeNotOpen
            case .cannotFill: return .cardCannotFill
            case .notInPlayTopic: return .cardNotInPlay
            }
        case let error as MuxifyWorktreeError:
            switch error {
            case .script: return .gitFailed
            case .setupInvalid: return .worktreeSetupInvalid
            case .hookFailed: return .hookFailed
            case .exists, .pathTaken: return .worktreeExists
            case .unavailable: return .worktreeUnavailable
            case .ambiguous: return .worktreeAmbiguous
            case .inUse: return .worktreeInUse
            case .hasChanges: return .worktreeHasChanges
            case .nameInvalid: return .worktreeNameInvalid
            }
        case is TopicTransaction.Failure: return .topicUnavailable
        case let error as SQLiteError where error.isBusy: return .storeBusy
        case is TmuxError: return .tmuxFailed
        case is ShellError: return .gitFailed
        default: return .storeFailed
        }
    }
}

extension EnvironmentCommand {
    enum Lane {
        case read(Read)
        case records, edit
    }

    /// The read commands, one case for each answer.
    enum Read {
        case list, show, environmentShow
        case listWorktrees(all: Bool, from: String?)
    }

    /// How a command runs; none takes a lock. `read`: reads only. `records`: one write of record columns and the tmux
    /// options that go with it. `edit`: read, plan, git, record, tmux, show. A new command does not compile until it
    /// chooses its lane.
    var lane: Lane {
        switch self {
        case .list: return .read(.list)
        case .show: return .read(.show)
        case .environmentShow: return .read(.environmentShow)
        case .listWorktrees(let all, let from): return .read(.listWorktrees(all: all, from: from))
        case .tags, .note, .pin, .unpin, .moveCard, .chooseInPlay, .replaceFromBench, .makeGuest, .benchTopic, .fillOpenPlace, .markRead, .markAllRead:
            return .records
        case .create, .addSession, .settle, .forget, .move, .removeFromTopic, .removeAndKill, .rename,
             .reopen, .startFresh, .moveSession, .sortSessions, .newWindow, .newSession, .renameSession,
             .renameWindow, .moveWindow, .zoomPane, .killWindow, .killSession, .createWorktree, .removeWorktree, .forgetSettled: return .edit
        }
    }

    /// Whether the command only reads. A command that is not a read changes something, so a channel that ends
    /// before its answer leaves it uncertain.
    public var onlyReads: Bool {
        if case .read = lane { return true }
        return false
    }

    /// What a Request id means for this command, as `muxify --request` decides it for the verb that sends it. A new
    /// command does not compile until it chooses.
    public var requestPolicy: RequestPolicy {
        switch self {
        case .list, .show, .environmentShow, .listWorktrees:
            return .read
        // Each of these gives one end state however many times it runs: it sets a value, or it finds what its first
        // run made. A new Topic takes the Request's id, so a second run finds it.
        case .create, .tags, .note, .rename, .pin, .unpin, .markRead, .markAllRead, .chooseInPlay, .sortSessions:
            return .rerun
        // With its exact name and no new Worktree, a second run finds the Session. A new Worktree has setup that only
        // the first run can type into the Session.
        case .addSession(_, .newWorktree, _, _): return .inDoubt
        case .addSession(_, _, _, let chosenName): return chosenName != nil ? .rerun : .inDoubt
        // A second run could apply these twice: a move from the place where the first run left the card, a Session or
        // a Window that tmux makes again, a Topic that is no longer where the first run found it.
        case .settle, .forget, .forgetSettled, .move, .removeFromTopic, .removeAndKill, .reopen, .startFresh, .moveSession, .newWindow,
             .newSession, .renameSession, .renameWindow, .moveWindow, .zoomPane, .killWindow, .killSession, .moveCard, .replaceFromBench,
             .makeGuest, .benchTopic, .fillOpenPlace, .createWorktree, .removeWorktree:
            return .inDoubt
        }
    }

    /// Whether the command acts on Muxify Worktree records.
    public var isWorktreeCommand: Bool {
        switch self {
        case .createWorktree, .removeWorktree, .listWorktrees: true
        default: false
        }
    }

    /// The Action's name, as a message about it says it: "<Environment> disconnected before Settle Topic finished."
    public var actionName: String {
        switch self {
        case .list: "List Topics"
        case .show: "Show Topic"
        case .environmentShow: "Show Environment"
        case .listWorktrees: "List Worktrees"
        case .tags: "Change Tags"
        case .note: "Set Topic Note"
        case .pin: "Pin Topic"
        case .unpin: "Unpin Topic"
        case .moveCard: "Move Topic"
        case .chooseInPlay: "Choose In Play"
        case .replaceFromBench: "Replace from Bench"
        case .makeGuest: "Make Guest"
        case .benchTopic: "Bench Topic"
        case .fillOpenPlace: "Fill Open Place"
        case .markRead: "Mark as Read"
        case .markAllRead: "Mark All as Read"
        case .create: "New Topic"
        case .addSession: "Add Session"
        case .settle: "Settle Topic"
        case .forget: "Forget Topic"
        case .move: "Move"
        case .removeFromTopic: "Remove from Topic"
        case .removeAndKill: "Remove and Kill"
        case .rename: "Rename Topic"
        case .reopen: "Reopen Topic"
        case .startFresh: "Start Fresh"
        case .moveSession: "Move Session"
        case .sortSessions: "Sort Sessions"
        case .newWindow: "New Window"
        case .newSession: "New Session"
        case .renameSession: "Rename Session"
        case .renameWindow: "Rename Window"
        case .moveWindow: "Move Window"
        case .zoomPane: "Zoom Pane"
        case .killWindow: "Kill Window"
        case .killSession: "Kill Session"
        case .createWorktree: "New Worktree"
        case .removeWorktree: "Remove Worktree"
        case .forgetSettled: "Forget Settled Topics"
        }
    }

    /// Whether the command reads or writes a Topic record whatever its target.
    public var needsRecords: Bool {
        switch self {
        case .newWindow, .newSession, .renameSession, .renameWindow, .moveWindow, .zoomPane, .killWindow, .killSession: return false
        // A Muxify Worktree request is refused on its own where the Worktrees are unavailable (ADR 0090); where they
        // are served, it also updates the Topics.
        case .createWorktree, .removeWorktree, .listWorktrees: return false
        // Agent Unread is in tmux. Only a Topic's Read state is in its record; Mark All as Read leaves the records
        // out where there are none.
        case .markRead(_, let scope): return scope == .topic || scope == .topicMark
        case .markAllRead: return false
        case .list, .show, .environmentShow, .create, .addSession, .settle, .forget, .move, .removeFromTopic, .removeAndKill, .rename, .reopen, .startFresh,
             .moveSession, .sortSessions, .tags, .note, .pin, .unpin, .moveCard, .chooseInPlay, .replaceFromBench,
             .makeGuest, .benchTopic, .fillOpenPlace, .forgetSettled:
            return true
        }
    }
}

extension EnvironmentRequest {
    /// Whether the request reads or writes a Topic record. Only the others run where there are no Topics, in a
    /// Sessions-only App Window. A `.topic` target is found through the records, so it needs them with any command.
    public var needsRecords: Bool {
        if case .topic? = target { return true }
        return command.needsRecords
    }
}

extension TopicRef {
    /// The record this names. `.named` takes an open Topic's id first, then the one open Topic with that slug, title or
    /// label (`TopicLabels`). `open` false also finds a Settled Topic.
    public func resolve(in records: [TopicRecord], open: Bool = true) throws -> TopicRecord {
        let candidates = open ? records.filter { $0.settledAt == nil } : records
        switch self {
        case .id(let id):
            guard let topic = candidates.first(where: { $0.id == id }) else { throw TopicRequestError.topicUnavailable(id) }
            return topic
        case .named(let value):
            if let exact = candidates.first(where: { $0.id == value }) { return exact }
            let labels = TopicLabels(records)
            let matches = candidates.filter { $0.slug == value || $0.title == value || labels.label(of: $0) == value }
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
    case targetAndTopics
    case undefinedTags([Tag])
    case branchUnavailable(branch: String, worktree: String)
    case branchCheckedOut(branch: String, worktree: String)
    case chooseSession(topic: String, sessions: [String])
    case topicEmpty(topic: String, id: String, dormant: Bool)
    case sessionNameInvalid(String)
    /// A Session outside the Topic has the name that the caller chose for a new Session of the Topic.
    case sessionNameTaken(String)
    case panesChanged
    case cardAtEnd(card: String, up: Bool, pinned: Bool)
    case sessionAtEnd(session: String, topic: String, up: Bool)
    case cardHidden(String)
    case windowNotInSession(window: String, anchor: String)
    /// No Lock has this id: the Guest Session was Benched or ended.
    case boardSessionUnavailable(String)
    /// The Guest Session with this Lock id has no live Session, so a command that needs one cannot run.
    case boardSessionDormant(String)
    /// The Guest Session with this Lock id has a live Session, so Start Fresh, which needs a Dormant one, cannot run.
    case boardSessionLive(String)
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
        case .targetAndTopics: return "The request names a target and a list of Topics. Name only one of them."
        case .removedForm(let message): return message
        case .chooseSession(let topic, let sessions):
            return "The Topic \(topic) has more than one Session: \(sessions.joined(separator: ", ")). Choose one with --session."
        case .topicEmpty(let topic, let id, let dormant):
            return dormant ? "The Topic \(topic) has no live Session. Reopen it first: muxify topic reopen --topic \(id). "
                             + "Or add one: muxify topic add-session <dir> --topic \(id)."
                           : "The Topic \(topic) has no Session. Add one first: muxify topic add-session <dir> --topic \(id)."
        case .panesChanged: return "The Windows or Panes changed. Review them and confirm again."
        case .cardAtEnd(let card, let up, let pinned):
            return "\(card) is the \(up ? "first" : "last") card among the \(pinned ? "Pinned Topics" : "Topics that are not Pinned")."
        case .sessionAtEnd(let session, let topic, let up):
            return "The Session \(session) is the \(up ? "first" : "last") Session of the Topic \(topic)."
        case .cardHidden(let message): return message
        case .windowNotInSession(let window, let anchor): return "The Window \(anchor) is not in the Session of the Window \(window)."
        case .boardSessionUnavailable(let id): return "No Guest Session has the id \(id)."
        case .boardSessionDormant(let id):
            return "The Guest Session \(id) is Dormant: it has no live Session. Reopen it first: muxify topic reopen --guest-session \(id)."
        case .boardSessionLive(let id):
            return "The Guest Session \(id) has a live Session. Start Fresh makes only a Dormant Guest Session again."
        case .sessionNameInvalid(let name): return "\(name) cannot name a tmux Session: it is empty, or it has a period, a colon or a control character."
        case .sessionNameTaken(let name): return "A tmux Session that is not in the Topic has the name \(name)."
        case .branchUnavailable(let branch, let worktree): return "No local branch \(branch) is in the repository of \(worktree)."
        case .branchCheckedOut(let branch, let worktree):
            return "The branch \(branch) is checked out in the Worktree \(worktree). git checks out a branch in one Worktree only."
        case .undefinedTags(let tags):
            return "The Config does not define \(tags.map(\.description).joined(separator: ", ")) in topics.tags. Add a Tag there first."
        }
    }
}
