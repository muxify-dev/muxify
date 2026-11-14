import Foundation
import MuxifyCore

/// The link to a Remote Environment over `RemoteSSH` execs: the remote `TmuxConnection` and its scripts. It serves
/// the Sessions only: the snapshot, view commands, Attachment upload, the Config read and Session Path discovery, and
/// the Session requests that need no Topic record. Topics, the Git View, `repository` and the Muxify Worktrees answer
/// `unsupported`. It is the `HostEnvironmentLink`'s master, and its Sessions until the Host Server's first state, and
/// the App Window's whole link once no Host Server can run (ADR 0087).
@MainActor
final class SessionsOnlyEnvironmentLink: TmuxConnectionLink, EnvironmentLink {
    let isOnThisMac = false
    let features: EnvironmentFeatures = []
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
            guard let self, let output = try? await run(RemoteConfigFile.script, arguments: [], timeout: 20),
                  let file = RemoteConfigFile.parse(output) else { return }
            var config = HostConfig(path: file.path, home: file.home, text: file.text)
            if let text = file.text {
                // The Overrides are read on the remote, where `~/` is its home.
                let paths = HostConfig.overridePaths(in: text, shownPath: config.shownPath)
                if !paths.isEmpty {
                    let end = "muxify-override-end-\(UUID().uuidString)"
                    guard let output = try? await run(RemoteConfigFile.overridesScript,
                                                         arguments: RemoteConfigFile.overridesArguments(paths, end: end), timeout: 20),
                          let texts = RemoteConfigFile.parseOverrides(output, paths: paths, end: end) else { return }
                    config.overrides = paths.map { HostConfig.Override(path: $0, text: texts[$0] ?? nil) }
                }
            }
            events.send(.config(.host(config)))
        }
    }

    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String? {
        try await run(SessionPathDiscovery.script, arguments: arguments, timeout: 20)
    }

    /// Runs one of this link's own /bin/sh reads on the Remote Environment, off the main thread.
    private func run(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        guard let connection else { throw TmuxError.notReady }
        return try await Task.detached(priority: .userInitiated) {
            try connection.runScript(script, arguments: arguments, timeout: timeout)
        }.value
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

    /// The service for the Session requests on the Remote Environment's tmux. A Sessions-only App Window has no Topic
    /// records, so its records are an empty state folder of its own, never this Mac's.
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService? {
        guard let connection else { return nil }
        return EnvironmentService(paths: Self.noRecords, server: connection, topics: topics, notifications: notifications)
    }

    /// The state folder of the Sessions-only services, where no Topic record is ever written.
    static let noRecords = MuxifyPaths(environment: [
        "XDG_STATE_HOME": FileManager.default.temporaryDirectory.appendingPathComponent("muxify-sessions-only").path,
    ])

    /// Only the requests that need no Topic record run. Create Worktree, Remove Worktree and the list of Muxify
    /// Worktrees are refused: the Mac cannot write the Host's record, and a Worktree with no record could never be
    /// removed by Muxify (ADR 0088). A new Session's folder is on the Remote Environment, so it is taken as it is.
    func run(_ request: EnvironmentRequest, client: String?, local: EnvironmentService?) async -> EnvironmentResponse? {
        if request.command.isWorktreeCommand { return .failed(EnvironmentLinkError.worktreesRefused) }
        if request.needsRecords { return .failed(EnvironmentLinkError.topicsRefused) }
        guard let local, case .newSession(let path, _) = request.command else {
            return await EnvironmentLinks.run(request, client: client, local: local)
        }
        let folder = SessionPath(path: path, name: SessionPath.sessionName((path as NSString).lastPathComponent))
        let service = EnvironmentService(paths: local.paths, server: local.server, sessionPaths: [folder], topics: local.topics,
                                         notifications: local.notifications)
        return await EnvironmentLinks.run(request, client: client, local: service)
    }

    /// No Topic records, so no Locked Sessions to gather.
    func gatherGuests(local: EnvironmentService?) async -> TopicFailure? { nil }

    func worktreeStarts(from folder: String, local: EnvironmentService?) async -> Result<[WorktreeStartChoice], TopicFailure>? {
        .failure(EnvironmentLinkError.worktreesRefused)
    }

    /// The Git View runs only where a Host Server reads the repository: here it is unavailable.
    func git(_ read: GitRead) async throws -> GitAnswer {
        throw EnvironmentLinkError.unsupported("The Git View")
    }

    func writeGit(_ write: GitWrite) async throws -> String {
        throw EnvironmentLinkError.unsupported("The Git View")
    }

    func runGitNetwork(_ network: GitNetwork, ask: @escaping GitAsk) async throws -> String {
        throw EnvironmentLinkError.unsupported("The Git View")
    }

    func watchRepository(_ path: String, _ onEvent: @escaping (RepositoryEvent) -> Void) -> EnvironmentSubscription {
        EnvironmentSubscription {}
    }
}
