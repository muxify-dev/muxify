import Foundation
import MuxifyCore

/// What an Environment serves beyond its Sessions, which every Environment serves. A guard that asks what the
/// App Window may offer reads these, never whether the window is remote.
struct EnvironmentFeatures: OptionSet, Sendable {
    let rawValue: Int

    /// Topic records, the Topics list and every Topic Action.
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
    case changed(TmuxEvents.Event)
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
/// its `EnvironmentService` and the Git View's scripts (ADR draft `10-mac-side-seam`). Commands are `async`; state
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

    /// Runs one tmux command, in the order asked.
    func tmux(_ arguments: [String]) async throws -> String
    /// Reads the whole server; with `commandLines`, the Panes' command lines too.
    func snapshot(updating commandLines: PaneCommandLines?) async throws -> TmuxSnapshot
    /// `snapshot` for a caller that must answer before it returns.
    func snapshotNow() throws -> TmuxSnapshot
    /// Runs a /bin/sh script on the Environment's machine.
    func script(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String
    /// The Session Path discovery output for `roots`, as `SessionPathDiscovery` reads it; nil when there is none.
    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String?
    /// Pastes the attachments into the Client's current Pane, uploading files first where they are not on this Mac.
    func pasteAttachments(_ attachments: TerminalAttachments, client: String) async throws -> String
    /// The command line that attaches the App Window's terminal.
    func terminalCommand(_ arguments: [String], target: String?, picksLatestSession: Bool,
                         newSession: RemoteSSH.NewSession?) throws -> String
    /// Marks the App Window's own Client on this Mac's server, or removes the mark with nil.
    func updateLocalClient(_ client: TmuxClient?)
    /// Whether the link hears tmux changes as they happen; it sends each as a `changed` event.
    var isListening: Bool { get }
    func startListening()
    func stopListening()
    /// How the attachment ended, for a link whose attachment owns its transport; nil on this Mac.
    var attachmentEnd: AttachmentEnd? { get }
    /// Puts the Host CLI on the Environment's machine once it connects. Nothing waits for it.
    func installHostCLI(environmentName: String)

    // MARK: Topics

    /// Reads the Topic records again; a `topics` event follows when they changed.
    func reloadTopics()
    /// Reads the records again and returns once their event was sent, after every write asked for before.
    func topicsReloaded() async
    /// Returns once every read and write asked for before has sent its event.
    func topicsCaughtUp() async
    /// Writes the Topic records, then returns once the event of what it left was sent.
    func writeTopics<T>(locks: [SessionLock], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T
    /// The service that runs Environment requests there; nil while the link cannot run one.
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService?

    // MARK: Git

    /// Runs a Git View network command in a pseudo-terminal, so its credential prompts go to `onPrompt`.
    func startGitNetworkScript(_ script: String, arguments: [String], timeout: TimeInterval,
                               onPrompt: @escaping (GitCredentialPrompt) -> Void,
                               completion: @escaping (Result<String, Error>) -> Void) -> TerminalCommand?
    /// What tells a Git View that its repository changed. `run` runs the probe's script through the store.
    func makeGitWatcher(run: @escaping GitRemoteProbe.Run) -> GitWatcher

    // MARK: Retiring

    /// Ends every waiting request `cancelled` and every subscription, and flushes `commands`, which must be
    /// idempotent. Called off the main thread.
    nonisolated func retire(flushing commands: [[String]])
    /// Removes what the transport left on this Mac. Called off the main thread, after `retire`.
    nonisolated func cleanup()
}

extension EnvironmentLink {
    func writeTopics<T>(_ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        try await writeTopics(locks: [], body)
    }
}

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
        return SessionsOnlyEnvironmentLink(environment: environment, sshExecutable: sshExecutable)
    }
}

/// The part of a link that runs over today's `TmuxConnection`: here for this Mac, over `RemoteSSH` for a Remote
/// Environment. A subclass adds what its Environment serves.
@MainActor
class TmuxConnectionLink {
    /// Set once by `connect`, on the main thread, before anything reads it off it.
    nonisolated(unsafe) private(set) var connection: TmuxConnection?
    let events = EnvironmentEvents()
    private let tmuxEvents = TmuxEvents()
    private let makeConnection: () throws -> TmuxConnection

    init(makeConnection: @escaping () throws -> TmuxConnection) {
        self.makeConnection = makeConnection
        tmuxEvents.onEvent = { [weak self] event in self?.events.send(.changed(event)) }
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

    func tmux(_ arguments: [String]) async throws -> String {
        let connection = try connected()
        return try await withCheckedThrowingContinuation { continuation in
            connection.runAsync(arguments) { continuation.resume(with: $0) }
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

    func script(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        let connection = try connected()
        return try await withCheckedThrowingContinuation { continuation in
            connection.runScriptAsync(script, arguments: arguments, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    func pasteAttachments(_ attachments: TerminalAttachments, client: String) async throws -> String {
        let connection = try connected()
        return try await withCheckedThrowingContinuation { continuation in
            connection.pasteAttachments(attachments, client: client) { continuation.resume(with: $0) }
        }
    }

    func terminalCommand(_ arguments: [String], target: String?, picksLatestSession: Bool,
                         newSession: RemoteSSH.NewSession?) throws -> String {
        try connected().terminalCommand(arguments, target: target, picksLatestSession: picksLatestSession, newSession: newSession)
    }

    func updateLocalClient(_ client: TmuxClient?) {
        connection?.updateLocalClient(client)
    }

    var isListening: Bool { tmuxEvents.isRunning }

    func startListening() {
        guard let connection else { return }
        tmuxEvents.start(invocation: connection.invocation)
    }

    func stopListening() {
        tmuxEvents.stop()
    }

    var attachmentEnd: AttachmentEnd? {
        guard let connection, let remote = connection.remote else { return nil }
        return AttachmentEnd(exitStatus: remote.exitStatus, failureMessage: remote.failureMessage,
                             shouldReconnect: remote.shouldReconnect, closedSnapshot: connection.closedSnapshot)
    }

    func installHostCLI(environmentName: String) {}

    func reloadTopics() {}
    func topicsReloaded() async {}
    func topicsCaughtUp() async {}

    func writeTopics<T>(locks: [SessionLock], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        throw EnvironmentLinkError.unsupported("Topics")
    }

    func startGitNetworkScript(_ script: String, arguments: [String], timeout: TimeInterval,
                               onPrompt: @escaping (GitCredentialPrompt) -> Void,
                               completion: @escaping (Result<String, Error>) -> Void) -> TerminalCommand? {
        guard let connection else {
            DispatchQueue.main.async { completion(.failure(TmuxError.notReady)) }
            return nil
        }
        return connection.startTerminalScript(script, arguments: arguments, timeout: timeout, onPrompt: onPrompt, completion: completion)
    }

    nonisolated func retire(flushing commands: [[String]]) {
        connection?.retire(flushing: commands)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.didRetire() }
        }
    }

    /// On the main thread, once the transport is retired: ends the subscriptions and stops what listens.
    func didRetire() {
        tmuxEvents.stop()
        events.finish()
    }

    nonisolated func cleanup() {
        connection?.cleanup()
    }
}
