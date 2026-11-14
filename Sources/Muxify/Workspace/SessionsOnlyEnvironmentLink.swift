import Foundation
import MuxifyCore

/// The link to a Remote Environment over `RemoteSSH` execs: the remote `TmuxConnection` and its scripts. It serves
/// the Sessions and the Git View, which runs its scripts there, and has no `.topics` and no records. It is the
/// `HostEnvironmentLink`'s link to the same master, which serves until the Host Server answers and whatever the
/// server does not serve yet, and the App Window's whole link once no Host Server can run (ADR 0087).
@MainActor
final class SessionsOnlyEnvironmentLink: TmuxConnectionLink, EnvironmentLink {
    let isOnThisMac = false
    let features: EnvironmentFeatures = [.git]
    /// The store polls the remote server and keeps its Watch Session through `startListening`; once a Host Server
    /// serves, its publisher does both.
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

    /// The machine's own `muxify`, for the phone and its Agents: the install chain without a Debug build.
    override func installHostCLI(environmentName: String) {
        guard let connection else { return }
        let baseURL = HostCLI.baseURL(environment: ProcessInfo.processInfo.environment)
        DispatchQueue.global(qos: .utility).async {
            _ = HostCLIChain.run(over: connection, environmentName: environmentName, baseURL: baseURL, debug: nil,
                                 report: Diagnostics.report)
        }
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
