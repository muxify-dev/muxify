import Foundation
import MuxifyCore

/// What an Environment serves beyond its Sessions, which every Environment serves. A guard that asks what the
/// App Window may offer reads these, never whether the window is remote.
struct EnvironmentFeatures: OptionSet, Sendable {
    let rawValue: Int

    /// Topic records, the Board and every Topic Action.
    static let topics = EnvironmentFeatures(rawValue: 1 << 0)
    /// The Git View's reads, changes and network commands.
    static let git = EnvironmentFeatures(rawValue: 1 << 1)
    /// Muxify Worktree records and their Actions.
    static let worktrees = EnvironmentFeatures(rawValue: 1 << 2)

    static let all: EnvironmentFeatures = [.topics, .git, .worktrees]
}

/// One event of a link's subscription. Each is keyed by what it replaces: a later event of the same key replaces
/// the earlier one whole, so a store that missed some needs only the last.
enum EnvironmentEvent {
    /// The Topic records and the Open Places: they replace the store's `records` and `openPlaces`.
    case topics(TopicContents)
    /// A whole read of the server: it replaces the store's `windows`, its Panes and its Agents.
    case snapshot(TmuxSnapshot)
    /// The server changed in a way the store reads again.
    case changed
    /// A read of the server failed: the store shows it as it shows a read of its own that failed.
    case unreachable(Error)
    /// What the link serves changed: its Host Server answered, or stopped. The store offers what `features` now
    /// says, and polls only a link that does not publish its changes.
    case featuresChanged
    /// The Host Server stopped while the master lives: the store starts it again, or after 3 stops within 60 s
    /// falls back to Sessions only (ADR 0088). `lastLine` is its last stderr line.
    case serverStopped(lastLine: String)
    /// No Host Server can run on this attachment: the store falls back to Sessions only at once.
    case serverUnavailable(HostServerUnavailable)
    /// The Config the App Window runs with: it replaces the store's `remoteConfig` whole.
    case config(EnvironmentConfig)
    /// The focus changed in `window`, the Window that the Terminal shows. tmux does not say whose screen changed it:
    /// the store decides whether this Mac's user did, and then writes the Window's colours.
    case focusChanged(window: String)
    /// Another screen took `window`, the Window that the Terminal shows: the Terminal's next key or click writes its
    /// colours again.
    case windowTaken(window: String)
}

/// Which Config an App Window runs with (ADR 0010).
enum EnvironmentConfig: Equatable {
    /// The app-wide `ConfigStore`, which owns this Mac's Config file and hears its changes.
    case local
    /// The Host's own Config as read there. One with no text says the Host has none, and the store uses the local
    /// Config.
    case host(HostConfig)
}

/// Why a Remote App Window shows Sessions only. Its `reason` ends the Sidebar's "Topics are unavailable on
/// <Environment>: <reason>."
enum HostServerUnavailable: Equatable {
    /// No Host CLI was found after the install chain: the install's result line.
    case notInstalled(String)
    /// The Host CLI has no server mode, or shares no protocol with this app: its build line.
    case tooOld(String)
    /// The Host Server's `hello` did not come in time.
    case noAnswer
    /// It stopped 3 times within 60 s: its last stderr line.
    case stoppedRepeatedly(String)

    var reason: String {
        switch self {
        case .notInstalled(let line): "the Host CLI could not be installed (\(line))"
        case .tooOld(let build): "the Host's muxify is too old (\(build))"
        case .noAnswer: "the Host Server did not answer"
        case .stoppedRepeatedly(let line): "the Host Server stopped 3 times in a minute (\(line))"
        }
    }
}

/// How the App Window's attachment to a Remote Environment ended, read once its terminal process exited.
struct AttachmentEnd {
    let exitStatus: Int?
    let failureMessage: String
    let shouldReconnect: Bool
    /// The server as the attachment saw it last, from a clean exit only.
    let closedSnapshot: TmuxSnapshot?
}

enum EnvironmentLinkError: Error, Equatable, CustomStringConvertible {
    /// The Environment does not serve what was asked: the link lacks its feature.
    case unsupported(String)

    var description: String {
        switch self {
        case .unsupported(let what): "\(what) is unavailable on this Environment."
        }
    }

    /// What a link that lacks `.worktrees` answers a Muxify Worktree request: the Host's records are the Host CLI's
    /// alone, so the Mac never makes or removes a Host's Worktree without its server (ADR 0090).
    static var worktreesRefused: TopicFailure {
        TopicFailure(kind: .unsupported, phase: .nothingChanged, message: unsupported("Muxify Worktrees").description)
    }

    /// What a link without `.topics` answers a request that reads or writes a Topic record.
    static var topicsRefused: TopicFailure {
        TopicFailure(kind: .topicsUnavailable, phase: .nothingChanged, message: unsupported("Topics").description)
    }
}

/// One subscription to a link's events. Cancelling it stops delivery; a retired link ends it too.
@MainActor
final class EnvironmentSubscription {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        onCancel?()
        onCancel = nil
    }
}

/// A link's subscribers. Each new one gets the link's whole state first, then every event, on the main thread
/// and in the order they happened.
@MainActor
final class EnvironmentEvents {
    private var handlers: [UUID: (EnvironmentEvent) -> Void] = [:]

    func subscribe(initial: [EnvironmentEvent], _ onEvent: @escaping (EnvironmentEvent) -> Void) -> EnvironmentSubscription {
        let id = UUID()
        handlers[id] = onEvent
        initial.forEach(onEvent)
        return EnvironmentSubscription { [weak self] in self?.handlers[id] = nil }
    }

    func send(_ event: EnvironmentEvent) {
        for handler in handlers.values { handler(event) }
    }

    /// Ends every subscription.
    func finish() {
        handlers.removeAll()
    }
}

/// The one way an App Window's `WorkspaceStore` reaches its Active Environment: its tmux server, its Topic records,
/// its `EnvironmentService` and the Git View's typed reads and writes (ADR 0089). Commands are `async`; state
/// comes as keyed events per subscription.
///
/// A link never changes target. Changing the Active Environment retires the store's link: its waiting requests
/// end `cancelled`, its subscriptions end, and the store's `generation` drops any reply that still arrives.
@MainActor
protocol EnvironmentLink: AnyObject {
    /// A fact about the machine: Reveal Folder, Install Extensions, a local file paste, the Browser finding local
    /// servers, `FolderResolver` and the local Client marker work only on this Mac.
    var isOnThisMac: Bool { get }
    /// What the Environment serves.
    var features: EnvironmentFeatures { get }

    /// Opens the link's transport, once, when the store starts using it.
    func connect() throws
    /// The first events are the link's whole state; every change follows.
    func subscribe(_ onEvent: @escaping (EnvironmentEvent) -> Void) -> EnvironmentSubscription

    // MARK: Sessions

    /// Runs one of the App Window's own tmux commands, in the order asked, and returns tmux's answer.
    func view(_ command: ViewCommand) async throws -> String
    /// Reads the whole server; with `commandLines`, the Panes' command lines too.
    func snapshot(updating commandLines: PaneCommandLines?) async throws -> TmuxSnapshot
    /// `snapshot` for a caller that must answer before it returns.
    func snapshotNow() throws -> TmuxSnapshot
    /// The Session Path discovery output for `roots`, as `SessionPathDiscovery` reads it; nil when there is none.
    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String?
    /// Pastes the attachments into the Client's current Pane, uploading files first where they are not on this Mac.
    func pasteAttachments(_ attachments: TerminalAttachments, client: String) async throws -> String
    /// The command line that attaches the App Window's terminal.
    /// `hidesStatusLine`: the Terminal hides tmux's status line from its first frame (ADR 0104).
    func terminalCommand(_ arguments: [String], target: String?, picksLatestSession: Bool,
                         newSession: RemoteSSH.NewSession?, hidesStatusLine: Bool) throws -> String
    /// Whether the link hides tmux's status line when asked (`hideStatusLine`); a Sessions-only link does not.
    var hidesStatusLineWhenAsked: Bool { get }
    /// Marks the App Window's own Client on this Mac's server, or removes the mark with nil.
    func updateLocalClient(_ client: TmuxClient?)
    /// Whether the link hears every change of the server and the records itself and keeps its own Listener, so
    /// the store neither polls it nor starts its listening. The Local link's `EnvironmentPublisher` does; a
    /// Sessions-only link leaves both to the store.
    var publishesChanges: Bool { get }
    /// Whether the link hears tmux changes as they happen; it sends each as a `changed` event.
    var isListening: Bool { get }
    func startListening()
    func stopListening()
    /// How the attachment ended, for a link whose attachment owns its transport; nil on this Mac.
    var attachmentEnd: AttachmentEnd? { get }
    /// The exit status of the Terminal's tmux Client on this Mac, once it exited: 0 after its Session ended or it
    /// detached, 1 after the server was killed. Nil elsewhere.
    var localClientExitStatus: Int? { get }
    /// Puts the Host CLI on the Environment's machine once it connects. Nothing waits for it.
    func installHostCLI(environmentName: String)
    /// Sends the Config again as a `config` event: on connecting, on Reload Config and when a Command Palette opens.
    /// A link that hears its Config change sends what it has; a Sessions-only link reads it again first, and sends
    /// nothing when the read fails. This Mac's link sends nothing: the `ConfigStore` reloads itself.
    func reloadConfig()

    // MARK: Topics

    /// Reads the Topic records again; a `topics` event follows when they changed.
    func reloadTopics()
    /// Reads the records again and returns once their event was sent, after every write asked for before.
    func topicsReloaded() async
    /// Returns once every read and write asked for before has sent its event.
    func topicsCaughtUp() async
    /// Writes the Topic records, then returns once the event of what it left was sent.
    func writeTopics<T>(_ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T
    /// The service that runs Environment requests there; nil while the link cannot run one.
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService?

    // MARK: Environment requests

    /// Runs an Environment request on the Environment's machine. `local` is the service the store built from its
    /// Config through `environmentService`; nil when the link can run none.
    func run(_ request: EnvironmentRequest, client: String?, local: EnvironmentService?) async -> EnvironmentResponse?
    /// Whether `run` runs requests itself, without the store's `EnvironmentService`.
    var runsRequests: Bool { get }
    /// The Sessions that Settle offers for the Topic.
    func settleChoices(for target: EnvironmentTarget, local: EnvironmentService?) async -> Result<[TopicSettleSession], TopicFailure>?
    /// The Sessions and Worktrees that Forget offers for the Topic.
    func forgetChoices(for target: EnvironmentTarget, local: EnvironmentService?)
        async -> Result<(sessions: [TopicSettleSession], worktrees: [TopicForgetChoices.Worktree]), TopicFailure>?
    /// Makes the Guests of an older Muxify's Board Sessions; nil when it changed nothing or failed nothing.
    func gatherGuests(local: EnvironmentService?) async -> TopicFailure?
    /// Unread on visit: clears the Unread of these Topics.
    func markTopicsRead(_ ids: Set<String>) async throws
    /// New Worktree's start choices from the checkout at `folder`, read with git on the Environment's machine; nil
    /// when the link can read none.
    func worktreeStarts(from folder: String, local: EnvironmentService?) async -> Result<[WorktreeStartChoice], TopicFailure>?
    /// Whether the Environment's server writes the Topics' remembered Sessions itself, so the store writes none.
    var remembersTopics: Bool { get }

    // MARK: The Host Server

    /// Starts the Host Server again on a new channel, after `serverStopped`.
    func restartServer()
    /// The link that takes over the same master when no Host Server can run, handed over without `retire`; nil
    /// when the link has none.
    func sessionsOnlyLink() -> EnvironmentLink?
    /// Hands the Host Server's requests (ADR 0091), what programs on the Host sent its socket, to `handler`: the
    /// store's own. A request that it answers nil, or that comes with no handler, ends `unavailable`.
    func serveHostRequests(_ handler: @escaping HostRequestHandler)
    /// Whether this App Window consumes `@muxify_open` on its Environment, so that its Host Server names its own
    /// socket in `@muxify_browser_socket`: it sends `claim_open` or `release_open` when this changes.
    func setOpenConsumer(_ consumes: Bool)
    /// Reports the Terminal's colours to the Panes of the Session that this App Window's Terminal shows, and again
    /// each time it moves (ADR 0098); nil writes none, as for an App Window that is not key. The Local Environment's
    /// publisher writes them; a Host's link sends them to its Host Server, whose Listener writes them.
    func reportColours(_ colours: TerminalColours?)
    /// Writes the colours to every Pane of `window`, as the store decided after a `focusChanged` or a `windowTaken`
    /// event, without waiting. It writes nothing while no colours were reported.
    func reportColours(toWindow window: String)
    /// While `hides`, tmux shows no status line in the Session that this App Window's Terminal shows, nor in each one
    /// it moves to, because the header shows the Session and its Windows (ADR 0099); false gives it back. The Local
    /// Environment's publisher hides it; a Host's link sends it to its Host Server. A Sessions-only link does nothing.
    func hideStatusLine(_ hides: Bool)

    // MARK: Git

    /// Runs one of the Git View's reads on the repository's machine (ADR 0087). A link without `.git` throws
    /// `unsupported`.
    func git(_ read: GitRead) async throws -> GitAnswer
    /// Runs one of the Git View's writes that need no network on the repository's machine (ADR 0087), and answers
    /// what git printed. It is never sent again: one whose answer the link lost may or may not have happened. A link
    /// without `.git` throws `unsupported`.
    func writeGit(_ write: GitWrite) async throws -> String
    /// The `repository` subscription of a folder: its first event is the whole state, then one comes whenever HEAD,
    /// the index or the working tree changed. Events come on the main thread. A link without `.git` sends none.
    func watchRepository(_ path: String, _ onEvent: @escaping (RepositoryEvent) -> Void) -> EnvironmentSubscription
    /// Runs one of the Git View's commands that talk to a remote on the repository's machine (ADR 0089), with git's
    /// and ssh's questions going to `ask` through askpass, and answers what git printed. A cancelled question ends it
    /// `TmuxError.cancelled`. It is never sent again. A link without `.git` throws `unsupported`.
    func runGitNetwork(_ network: GitNetwork, ask: @escaping GitAsk) async throws -> String

    // MARK: Retiring

    /// Ends every waiting request `cancelled` and every subscription, and flushes `commands`, which must be
    /// idempotent. Called off the main thread.
    nonisolated func retire(flushing commands: [ViewCommand])
    /// Removes what the transport left on this Mac. Called off the main thread, after `retire`.
    nonisolated func cleanup()
}

extension EnvironmentLink {
    // A link whose requests run on this Mac, through the store's `EnvironmentService`, takes these.

    func run(_ request: EnvironmentRequest, client: String?, local: EnvironmentService?) async -> EnvironmentResponse? {
        await EnvironmentLinks.run(request, client: client, local: local)
    }

    var runsRequests: Bool { false }

    func settleChoices(for target: EnvironmentTarget, local: EnvironmentService?) async -> Result<[TopicSettleSession], TopicFailure>? {
        guard let local else { return nil }
        return await Task.detached(priority: .userInitiated) { local.settleChoices(for: target) }.value
    }

    func forgetChoices(for target: EnvironmentTarget, local: EnvironmentService?)
        async -> Result<(sessions: [TopicSettleSession], worktrees: [TopicForgetChoices.Worktree]), TopicFailure>? {
        guard let local else { return nil }
        return await Task.detached(priority: .userInitiated) {
            local.forgetChoices(for: target).map { (sessions: $0.sessions, worktrees: $0.worktrees) }
        }.value
    }

    func gatherGuests(local: EnvironmentService?) async -> TopicFailure? {
        guard let local else { return nil }
        return await Task.detached(priority: .userInitiated) { local.gatherGuests() }.value
    }

    func markTopicsRead(_ ids: Set<String>) async throws {
        try await writeTopics { transaction in
            for record in transaction.records where ids.contains(record.id) && record.isUnread {
                try transaction.update(record.id) { $0.isUnread = false }
            }
        }
    }

    /// Runs on this Mac, the machine whose service it is.
    func worktreeStarts(from folder: String, local: EnvironmentService?) async -> Result<[WorktreeStartChoice], TopicFailure>? {
        guard local != nil else { return nil }
        return await Task.detached(priority: .userInitiated) {
            Result { try WorktreeStartChoice.read(from: folder, scripts: LocalScripts()) }
                .mapError { TopicFailure(kind: .tmuxFailed, phase: .nothingChanged, message: String(describing: $0)) }
        }.value
    }

    var remembersTopics: Bool { false }

    func restartServer() {}
    func sessionsOnlyLink() -> EnvironmentLink? { nil }
    func serveHostRequests(_ handler: @escaping HostRequestHandler) {}
    func setOpenConsumer(_ consumes: Bool) {}
    func reportColours(_ colours: TerminalColours?) {}
    func reportColours(toWindow window: String) {}
    func hideStatusLine(_ hides: Bool) {}
    var hidesStatusLineWhenAsked: Bool { false }
}

/// What answers a Host Server's request for its App Window: a Browser command's reply, `done` for a `select`, or
/// nil when nothing serves it.
typealias HostRequestHandler = @MainActor (MacRequest) async -> BrowserAgentReply?

/// The links of the app.
enum EnvironmentLinks {
    /// The link to `environment`, or to this Mac with nil.
    @MainActor
    static func make(_ environment: RemoteEnvironment?) -> EnvironmentLink {
        guard let environment else { return LocalEnvironmentLink() }
        var sshExecutable = "/usr/bin/ssh"
        #if DEBUG
        if TestDriver.isRunning, let fixture = ProcessInfo.processInfo.environment["MUXIFY_TEST_SSH"] {
            sshExecutable = fixture
        }
        #endif
        return HostEnvironmentLink.overSSH(environment: environment, sshExecutable: sshExecutable)
    }

    /// Runs a Git View read on this Mac, off the main thread.
    static func readGit(_ read: GitRead) async throws -> GitAnswer {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try GitReader().run(read) }) }
        }
    }

    /// Runs a Git View network command on this Mac, with the app's bundled `muxify` as its askpass helper and a one-off
    /// socket of its own.
    static func runGitNetwork(_ network: GitNetwork, ask: @escaping GitAsk) async throws -> String {
        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("bin/muxify").path,
              FileManager.default.isExecutableFile(atPath: helper) else {
            throw GitViewError(message: "The command line tool is missing from the app bundle (Contents/Resources/bin/muxify), so git cannot ask for credentials.")
        }
        return try await GitNetworkRunner(helper: helper).run(network, ask: ask)
    }

    static func writeGit(_ write: GitWrite) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try GitWriter().run(write) }) }
        }
    }

    /// Runs `request` with the store's service, off the main thread.
    static func run(_ request: EnvironmentRequest, client: String?, local: EnvironmentService?) async -> EnvironmentResponse? {
        guard let local else { return nil }
        return await Task.detached(priority: .userInitiated) { local.handle(request, client: client) }.value
    }
}

/// The part of a link that runs over today's `TmuxConnection`: here for this Mac, over `RemoteSSH` for a Remote
/// Environment. A subclass adds what its Environment serves.
@MainActor
class TmuxConnectionLink {
    /// Set once by `connect`, on the main thread, before anything reads it off it.
    nonisolated(unsafe) private(set) var connection: TmuxConnection?
    let events = EnvironmentEvents()
    private let makeConnection: () throws -> TmuxConnection
    /// The App Window's own Client on this Mac's server, which a view command acting as a Client must still name.
    /// Nil for a Remote Environment, whose `RemoteSSH` checks each such command against its marker.
    private var ownClient: ViewCommandExecutor.Client?

    init(makeConnection: @escaping () throws -> TmuxConnection) {
        self.makeConnection = makeConnection
    }

    func connect() throws {
        guard connection == nil else { return }
        connection = try makeConnection()
    }

    /// What a new subscriber gets first.
    func initialEvents() -> [EnvironmentEvent] { [] }

    func subscribe(_ onEvent: @escaping (EnvironmentEvent) -> Void) -> EnvironmentSubscription {
        events.subscribe(initial: initialEvents(), onEvent)
    }

    private func connected() throws -> TmuxConnection {
        guard let connection else { throw TmuxError.notReady }
        return connection
    }

    func view(_ command: ViewCommand) async throws -> String {
        let connection = try connected()
        let ownClient = self.ownClient
        return try await withCheckedThrowingContinuation { continuation in
            connection.view(command, ownClient: ownClient) { continuation.resume(with: $0) }
        }
    }

    func snapshot(updating commandLines: PaneCommandLines?) async throws -> TmuxSnapshot {
        let connection = try connected()
        return try await Task.detached(priority: .userInitiated) {
            var snapshot = try connection.snapshot()
            if let commandLines {
                snapshot.commandLines = commandLines.updating(for: snapshot) { try? connection.runScript(PaneCommandLines.script) }
            }
            return snapshot
        }.value
    }

    func snapshotNow() throws -> TmuxSnapshot {
        try connected().snapshot()
    }

    func pasteAttachments(_ attachments: TerminalAttachments, client: String) async throws -> String {
        let connection = try connected()
        return try await withCheckedThrowingContinuation { continuation in
            connection.pasteAttachments(attachments, client: client, ownClient: ownClient) { continuation.resume(with: $0) }
        }
    }

    func terminalCommand(_ arguments: [String], target: String?, picksLatestSession: Bool,
                         newSession: RemoteSSH.NewSession?, hidesStatusLine: Bool) throws -> String {
        try connected().terminalCommand(arguments, target: target, picksLatestSession: picksLatestSession, newSession: newSession,
                                        hidesStatusLine: hidesStatusLine)
    }

    func updateLocalClient(_ client: TmuxClient?) {
        connection?.updateLocalClient(client)
        guard connection?.isOnThisMac == true else { return }
        ownClient = client.flatMap { $0.isControl || $0.pid <= 0 ? nil : ViewCommandExecutor.Client(tty: $0.tty, pid: $0.pid) }
    }

    var localClientExitStatus: Int? { connection?.localClientExitStatus }

    var attachmentEnd: AttachmentEnd? {
        guard let connection, let remote = connection.remote else { return nil }
        return AttachmentEnd(exitStatus: remote.exitStatus, failureMessage: remote.failureMessage,
                             shouldReconnect: remote.shouldReconnect, closedSnapshot: connection.closedSnapshot)
    }

    func installHostCLI(environmentName: String) {}
    func reloadConfig() {}

    func reloadTopics() {}
    func topicsReloaded() async {}
    func topicsCaughtUp() async {}

    func writeTopics<T>(_ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        throw EnvironmentLinkError.unsupported("Topics")
    }

    nonisolated func retire(flushing commands: [ViewCommand]) {
        connection?.retire(flushing: commands.map(ViewCommandExecutor.arguments(for:)))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.didRetire() }
        }
    }

    /// On the main thread, once the transport is retired: ends the subscriptions. A subclass also stops what listens.
    func didRetire() {
        events.finish()
    }

    nonisolated func cleanup() {
        connection?.cleanup()
    }
}
