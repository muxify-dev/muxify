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

    /// Reads the Host's Config and the Config Overrides it names over the master (ADR 0010, ADR 0075), then sends
    /// it. Not watched: a read happens at connect, on Reload Config and when a Command Palette opens. A failed read
    /// sends nothing, so the App Window keeps what it has.
    override func reloadConfig() {
        guard connection != nil else { return }
        Task { [weak self] in
            guard let self, let output = try? await script(RemoteConfigFile.script, arguments: [], timeout: 20),
                  let file = RemoteConfigFile.parse(output) else { return }
            var config = HostConfig(path: file.path, home: file.home, text: file.text)
            if let text = file.text {
                // The Overrides are read on the remote, where `~/` is its home.
                let paths = HostConfig.overridePaths(in: text, shownPath: config.shownPath)
                if !paths.isEmpty {
                    let end = "muxify-override-end-\(UUID().uuidString)"
                    guard let output = try? await script(RemoteConfigFile.overridesScript,
                                                         arguments: RemoteConfigFile.overridesArguments(paths, end: end), timeout: 20),
                          let texts = RemoteConfigFile.parseOverrides(output, paths: paths, end: end) else { return }
                    config.overrides = paths.map { HostConfig.Override(path: $0, text: texts[$0] ?? nil) }
                }
            }
            events.send(.config(.host(config)))
        }
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
