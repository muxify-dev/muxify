import Foundation
import MuxifyCore

/// The link to this Mac: the local tmux server through `TmuxConnection`, the Topic records through `TopicWatcher`,
/// the local `EnvironmentService` and the Git View's scripts, as they run today. It serves every feature.
@MainActor
final class LocalEnvironmentLink: TmuxConnectionLink, EnvironmentLink {
    let isOnThisMac = true
    let features = EnvironmentFeatures.all
    private let topicWatcher: TopicWatcher

    /// The first read of the records is now, so a subscriber starts with them and not with an empty list.
    init(topics: TopicStore = TopicStore(paths: MuxifyPaths())) {
        topicWatcher = TopicWatcher(store: topics)
        super.init { TmuxConnection() }
        topicWatcher.onShow = { [weak self] contents in self?.events.send(.topics(contents)) }
    }

    override func connect() throws {
        try super.connect()
        topicWatcher.start()
    }

    override func initialEvents() -> [EnvironmentEvent] {
        [.topics(topicWatcher.contents)]
    }

    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String? {
        await Task.detached(priority: .userInitiated) { SessionPathDiscovery.output(for: roots) }.value
    }

    override func reloadTopics() {
        topicWatcher.reload()
    }

    override func topicsReloaded() async {
        await topicWatcher.reloaded()
    }

    override func topicsCaughtUp() async {
        await topicWatcher.caughtUp()
    }

    override func writeTopics<T>(locks: [SessionLock], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        try await topicWatcher.write(locks: locks, body)
    }

    /// The service on the Local server, with the SessionPaths as git reported them last.
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService? {
        EnvironmentService(paths: topicWatcher.store.paths, server: TmuxServer.app, sessionPaths: sessionPaths, topics: topics,
                           notifications: notifications, worktreesRoot: worktreesRoot)
    }

    func makeGitWatcher(run: @escaping GitRemoteProbe.Run) -> GitWatcher {
        GitFileWatcher()
    }

    override func didRetire() {
        super.didRetire()
        topicWatcher.stop()
    }
}
