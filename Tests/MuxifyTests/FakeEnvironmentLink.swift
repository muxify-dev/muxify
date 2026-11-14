import Foundation
@testable import MuxifyCore

/// An `EnvironmentLink` for store tests: the test sends its events, sets its features and reads the commands the
/// store sent. It runs nothing: its reads fail `notReady`, so a store that uses it never attaches a terminal.
@MainActor
final class FakeEnvironmentLink: EnvironmentLink {
    let isOnThisMac: Bool
    var features: EnvironmentFeatures
    /// The state a new subscriber gets first.
    var initial: [EnvironmentEvent] = []
    private(set) var isConnected = false
    /// Every tmux command the store sent, in order.
    private(set) var commands: [ViewCommand] = []
    /// Every subscriber, kept after it cancels, so `send` can deliver late as a retired link's transport might.
    private var subscribers: [(EnvironmentEvent) -> Void] = []
    private var listening = false
    private let lock = NSLock()
    nonisolated(unsafe) private var retired = false

    init(isOnThisMac: Bool = true, features: EnvironmentFeatures = .all) {
        self.isOnThisMac = isOnThisMac
        self.features = features
    }

    nonisolated var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    /// Sends `event` to every subscriber the link ever had.
    func send(_ event: EnvironmentEvent) {
        subscribers.forEach { $0(event) }
    }

    func connect() throws { isConnected = true }

    func subscribe(_ onEvent: @escaping (EnvironmentEvent) -> Void) -> EnvironmentSubscription {
        subscribers.append(onEvent)
        initial.forEach(onEvent)
        return EnvironmentSubscription {}
    }

    func view(_ command: ViewCommand) async throws -> String {
        commands.append(command)
        return ""
    }

    func snapshot(updating commandLines: PaneCommandLines?) async throws -> TmuxSnapshot { throw TmuxError.notReady }
    func snapshotNow() throws -> TmuxSnapshot { throw TmuxError.notReady }
    func script(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String { throw TmuxError.notReady }
    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String? { nil }
    func pasteAttachments(_ attachments: TerminalAttachments, client: String) async throws -> String { throw TmuxError.notReady }

    func terminalCommand(_ arguments: [String], target: String?, picksLatestSession: Bool,
                         newSession: RemoteSSH.NewSession?) throws -> String {
        throw TmuxError.notReady
    }

    func updateLocalClient(_ client: TmuxClient?) {}
    var publishesChanges = false
    var isListening: Bool { listening }
    func startListening() { listening = true }
    func stopListening() { listening = false }
    var attachmentEnd: AttachmentEnd? { nil }
    func installHostCLI(environmentName: String) {}
    /// How many times the store asked for the Config again.
    private(set) var configReloads = 0
    func reloadConfig() { configReloads += 1 }

    func reloadTopics() {}
    func topicsReloaded() async {}
    func topicsCaughtUp() async {}

    func writeTopics<T>(locks: [SessionLock], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        throw EnvironmentLinkError.unsupported("Topics")
    }

    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService? { nil }

    func startGitNetworkScript(_ script: String, arguments: [String], timeout: TimeInterval,
                               onPrompt: @escaping (GitCredentialPrompt) -> Void,
                               completion: @escaping (Result<String, Error>) -> Void) -> TerminalCommand? {
        completion(.failure(TmuxError.notReady))
        return nil
    }

    func makeGitWatcher(run: @escaping GitRemoteProbe.Run) -> GitWatcher { GitFileWatcher() }

    /// The link a Host link hands over when its Host Server cannot run.
    var fallback: FakeEnvironmentLink?
    /// How many times the store started the Host Server again.
    private(set) var restarts = 0

    func restartServer() { restarts += 1 }
    func sessionsOnlyLink() -> EnvironmentLink? { fallback }

    nonisolated func retire(flushing commands: [ViewCommand]) {
        lock.lock()
        retired = true
        lock.unlock()
    }

    nonisolated func cleanup() {}
}
