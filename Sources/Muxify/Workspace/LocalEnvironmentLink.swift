import Foundation
import MuxifyCore

/// The link to this Mac: the local tmux server through `TmuxConnection`, the local `EnvironmentService`, and the Git
/// View's reads, run in-process by MuxifyCore's `GitReader`. It serves every feature. The `EnvironmentPublisher` hears the server and the
/// Topic records, in-process, as the Host Server does on a Host: the store reads the server again when a Session or
/// the server changed, and takes the records from its Topic events. Nothing polls.
@MainActor
final class LocalEnvironmentLink: TmuxConnectionLink, EnvironmentLink {
    let isOnThisMac = true
    let features = EnvironmentFeatures.all
    let publishesChanges = true
    private let publisher: EnvironmentPublisher
    /// What the publisher's events left.
    private var state = EnvironmentState()

    /// The first read of the records is now, so a subscriber starts with them and not with an empty list.
    init(topics: TopicStore = TopicStore(paths: MuxifyPaths())) {
        // The App Window's Client marker: the publisher's Listener follows the Client that it names.
        let marker = ClientMarker.option(nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let publisher = EnvironmentPublisher(server: .app, topics: topics, delivery: .main,
                                             startControlClient: ControlClient.start, clientMarker: marker,
                                             report: Diagnostics.report)
        self.publisher = publisher
        // A switch runs on the Listener after its Colour Report, so a program that tmux tells of the new colour scheme
        // at the switch gets these colours.
        super.init { TmuxConnection(clientMarker: marker, switchOnListener: publisher.switchClient) }
        do {
            state.apply(state.changes(to: try topics.read(), all: true))
        } catch {
            Diagnostics.report("topics: \(error)")
        }
    }

    override func connect() throws {
        try super.connect()
        startListening()
    }

    /// The Config is the app-wide `ConfigStore`'s, which the store reads as it changes.
    override func initialEvents() -> [EnvironmentEvent] {
        [.topics(state.topicContents), .config(.local)]
    }

    var isListening: Bool { publisher.isRunning }

    func startListening() {
        // A tmux notification makes the store read at once, as the publisher does; what that read of the publisher
        // finds, the store has already read for. A read that failed shows as the store's own would.
        publisher.start(news: { [weak self] news in
            MainActor.assumeIsolated {
                switch news {
                case .heard: self?.events.send(.changed)
                case .readFailed(let error): self?.events.send(.unreachable(error))
                }
            }
        }, { [weak self] changes, afterNotification in
            MainActor.assumeIsolated { self?.receive(changes, readAlready: afterNotification) }
        })
    }

    func stopListening() {
        publisher.stop()
    }

    /// Topic events replace the records the store shows; a Session or server event makes it read the server again,
    /// unless a notification already made it read.
    private func receive(_ changes: [EnvironmentChange], readAlready: Bool) {
        let contents = state.topicContents
        state.apply(changes)
        if state.topicContents != contents { events.send(.topics(state.topicContents)) }
        if !readAlready, changes.contains(where: { if case .session = $0 { true } else if case .server = $0 { true } else { false } }) {
            events.send(.changed)
        }
    }

    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String? {
        await Task.detached(priority: .userInitiated) { SessionPathDiscovery.output(for: roots) }.value
    }

    override func reloadTopics() {
        publisher.readTopics()
    }

    override func topicsReloaded() async {
        await publisher.topicsRead()
    }

    override func topicsCaughtUp() async {
        await publisher.caughtUp()
    }

    override func writeTopics<T>(locks: [SessionLock], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        try await publisher.write(locks: locks, body)
    }

    /// The service on the Local server, with the SessionPaths as git reported them last.
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService? {
        EnvironmentService(paths: publisher.topics.paths, server: ColourReportingTmux(server: TmuxServer.app, publisher: publisher),
                           sessionPaths: sessionPaths, topics: topics,
                           notifications: notifications, worktreesRoot: worktreesRoot)
    }

    func reportColours(_ colours: TerminalColours?) {
        publisher.reportColours(colours)
    }

    func git(_ read: GitRead) async throws -> GitAnswer {
        try await EnvironmentLinks.readGit(read)
    }

    func writeGit(_ write: GitWrite) async throws -> String {
        try await EnvironmentLinks.writeGit(write)
    }

    /// Opens a one-off socket for the command, whose path the bundled CLI's askpass helper gets.
    func runGitNetwork(_ network: GitNetwork, ask: @escaping GitAsk) async throws -> String {
        try await EnvironmentLinks.runGitNetwork(network, ask: ask)
    }

    /// ADR 0072's FSEvents watcher, with the HEAD read of each change.
    func watchRepository(_ path: String, _ onEvent: @escaping (RepositoryEvent) -> Void) -> EnvironmentSubscription {
        let watch = LocalRepositoryWatch(path: path, onEvent: onEvent)
        watch.start()
        return EnvironmentSubscription { watch.stop() }
    }

    override func didRetire() {
        super.didRetire()
        publisher.stop()
    }
}
