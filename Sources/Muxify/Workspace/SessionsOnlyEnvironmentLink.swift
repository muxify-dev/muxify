import Foundation
import MuxifyCore

/// The link to a Remote Environment over today's `RemoteSSH` execs: the remote `TmuxConnection` and its scripts.
/// It serves what a Remote App Window offers today: its Sessions and the Git View, which runs its scripts there.
/// Topics stay on this Mac (ADR 0062), so it has no `.topics` and no records.
@MainActor
final class SessionsOnlyEnvironmentLink: TmuxConnectionLink, EnvironmentLink {
    let isOnThisMac = false
    let features: EnvironmentFeatures = [.git]
    /// The store polls the remote server and keeps its Watch Session through `startListening` (task 06 moves this
    /// onto the Host Server's publisher).
    let publishesChanges = false
    let environment: RemoteEnvironment
    private let tmuxEvents = TmuxEvents()

    init(environment: RemoteEnvironment, sshExecutable: String = "/usr/bin/ssh") {
        self.environment = environment
        super.init { try TmuxConnection(environment: environment, sshExecutable: sshExecutable) }
        tmuxEvents.onEvent = { [weak self] _ in self?.events.send(.changed) }
    }

    var isListening: Bool { tmuxEvents.isRunning }

    func startListening() {
        guard let connection else { return }
        tmuxEvents.start(invocation: connection.invocation)
    }

    func stopListening() {
        tmuxEvents.stop()
    }

    override func didRetire() {
        super.didRetire()
        tmuxEvents.stop()
    }

    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String? {
        try await script(SessionPathDiscovery.script, arguments: arguments, timeout: 20)
    }

    /// The machine's own `muxify`, for the phone and its Agents.
    override func installHostCLI(environmentName: String) {
        guard let connection else { return }
        HostCLI.install(over: connection, environmentName: environmentName,
                        baseURL: HostCLI.baseURL(environment: ProcessInfo.processInfo.environment),
                        report: Diagnostics.report)
    }

    /// The service on the Remote Environment. It has no Topics, so it runs only the requests that need no Topic
    /// record. Its Muxify Worktree scripts run over the connection, on that machine (ADR 0062).
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService? {
        guard let connection else { return nil }
        return EnvironmentService(paths: MuxifyPaths(), server: connection, topics: topics, notifications: notifications,
                                  topicsAvailable: false, scripts: connection, environmentName: environment.name,
                                  worktreesRoot: worktreesRoot)
    }

    /// A probe every 2 seconds over the owned ssh connection.
    func makeGitWatcher(run: @escaping GitRemoteProbe.Run) -> GitWatcher {
        GitRemoteProbe(run: run)
    }
}
