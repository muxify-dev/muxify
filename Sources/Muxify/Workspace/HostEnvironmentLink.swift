import Foundation
import MuxifyCore

/// The link to a Host through its Host Server (ADRs 0086 and 0087): one
/// `muxify server` on a `-T` channel of the attachment's own SSH master, which the Mac opens once the master is ready
/// and the Host CLI install chain has run. The terminal never waits for it.
///
/// Until the server's first state arrives, and whenever it is down, the link is its `SessionsOnlyEnvironmentLink` on
/// the same master, so the App Window shows Sessions as it does without a server. Once it arrives, the Topics, the
/// Sessions and every change come only from the server's `environment` events, and Topic requests, Unread on visit
/// and view commands go over the channel; the Mac keeps no copy of the Host's records. Git, the Config, Session
/// paths, uploads and Worktrees still go to the Sessions-only link until later tasks move them onto the server.
@MainActor
final class HostEnvironmentLink: EnvironmentLink {
    let isOnThisMac = false
    let environmentName: String
    /// The same master's Sessions-only link: the master, the attach, the execs.
    nonisolated(unsafe) private let inner: EnvironmentLink
    private let build: String
    private let nonce: () -> String?
    private let helloTimeout: TimeInterval
    private let pingInterval: TimeInterval
    private let openChannel: () throws -> HostServerChannel
    private let install: (@escaping @Sendable (String) -> Void) -> Void
    private let masterAlive: @Sendable () -> Bool
    private let hostCLIVersion: @Sendable () -> String?

    private let events = EnvironmentEvents()
    private let id = UUID()
    private let transport = Transport()
    private var innerSubscription: EnvironmentSubscription?
    /// The client of the current channel, from its start until it ends.
    private var client: ProtocolClient?
    private var errors = HostServerErrors()
    /// Whether the current channel's server answered `hello`.
    private var session: ProtocolClient.Session?
    /// Whether the server's first state arrived, so the server, not the Sessions-only link, serves.
    private var serving = false
    private var state = EnvironmentState()
    private var subscription: Task<Void, Never>?
    private var pinger: Timer?
    private var lastSent = Date()
    /// The install chain's result line, for the reason when no Host CLI is found.
    private var installLine: String?
    /// Once the server named the App Window's own Client, its going away is the end of the attachment.
    private var sawOwnClient = false

    init(environmentName: String, inner: EnvironmentLink, build: String = AppBuild.line, nonce: @escaping () -> String?,
         helloTimeout: TimeInterval = HostProtocol.helloTimeout, pingInterval: TimeInterval = 15,
         openChannel: @escaping () throws -> HostServerChannel,
         install: @escaping (@escaping @Sendable (String) -> Void) -> Void,
         masterAlive: @escaping @Sendable () -> Bool, hostCLIVersion: @escaping @Sendable () -> String?) {
        self.environmentName = environmentName
        self.inner = inner
        self.build = build
        self.nonce = nonce
        self.helloTimeout = helloTimeout
        self.pingInterval = pingInterval
        self.openChannel = openChannel
        self.install = install
        self.masterAlive = masterAlive
        self.hostCLIVersion = hostCLIVersion
    }

    /// The link of the app: the Host Server on a channel of the Sessions-only link's master.
    static func overSSH(environment: RemoteEnvironment, sshExecutable: String) -> HostEnvironmentLink {
        let inner = SessionsOnlyEnvironmentLink(environment: environment, sshExecutable: sshExecutable)
        let baseURL = HostCLI.baseURL(environment: ProcessInfo.processInfo.environment)
        let name = environment.name
        return HostEnvironmentLink(
            environmentName: name, inner: inner, nonce: { inner.connection?.remote?.nonce },
            openChannel: {
                guard let remote = inner.connection?.remote else { throw TmuxError.notReady }
                return try HostServerChannel.process(remote.serverInvocation())
            },
            install: { done in
                guard let connection = inner.connection else { return done("failed: not connected") }
                HostCLI.install(over: connection, environmentName: name, baseURL: baseURL, report: Diagnostics.report, completion: done)
            },
            masterAlive: {
                guard let remote = inner.connection?.remote else { return false }
                return (try? CommandRunner().run(remote.control("check"), timeout: 1)) != nil
            },
            hostCLIVersion: {
                (try? inner.connection?.runScript(RemoteSSH.hostCLIVersionScript, arguments: [], timeout: 10))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            })
    }

    // MARK: What it serves

    var features: EnvironmentFeatures { serving ? [.topics, .git] : inner.features }
    var publishesChanges: Bool { serving }
    var runsRequests: Bool { serving }
    var remembersTopics: Bool { serving }

    func connect() throws {
        try inner.connect()
        // The Sessions-only link's events reach the store only while no server serves.
        innerSubscription = inner.subscribe { [weak self] event in
            guard let self, !self.serving else { return }
            self.events.send(event)
        }
    }

    func subscribe(_ onEvent: @escaping (EnvironmentEvent) -> Void) -> EnvironmentSubscription {
        events.subscribe(initial: serving ? [.topics(state.topicContents)] : [], onEvent)
    }

    // MARK: The server's lifecycle

    /// The Host CLI install chain, then the server. Nothing waits for either.
    func installHostCLI(environmentName: String) {
        install { [weak self] line in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.installLine = line
                    self.startServer()
                }
            }
        }
    }

    /// Opens a new channel and starts `muxify server` on it.
    func startServer() {
        guard !transport.isRetired, client == nil else { return }
        let channel: HostServerChannel
        do { channel = try openChannel() } catch {
            Diagnostics.report("Host Server: \(environmentName): the channel did not open: \(error)")
            events.send(.serverStopped(lastLine: "\(error)"))
            return
        }
        let errors = HostServerErrors()
        errors.read(channel.errors)
        self.errors = errors
        let client = ProtocolClient(input: channel.input, output: channel.output, build: build, helloTimeout: helloTimeout,
                                    nonce: nonce())
        guard transport.open(client, channel) else {
            client.close()
            channel.close()
            return
        }
        self.client = client
        lastSent = Date()
        let token = ObjectIdentifier(client)
        client.onClose { [weak self] reason in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.channelEnded(token, reason: reason, channel: channel) } }
        }
        Task { [weak self] in
            do {
                let session = try await client.connect()
                self?.answered(session, by: client)
            } catch {
                // `channelEnded` handles a handshake that failed: the channel ends with it.
            }
        }
    }

    func restartServer() {
        startServer()
    }

    /// The server answered `hello`: its first state follows on the `environment` subscription.
    private func answered(_ session: ProtocolClient.Session, by client: ProtocolClient) {
        guard client === self.client else { return }
        self.session = session
        let missing = HostProtocol.capabilities.filter { !session.supports($0) }
        Diagnostics.report("Host Server: \(environmentName): protocol \(session.protocolVersion), missing capabilities: "
            + (missing.isEmpty ? "none" : missing.joined(separator: ", ")) + "; Mac \(build); Host \(session.peerBuild)")
        let stream = client.subscribe(HostRequest.subscribe(.environment), as: EnvironmentItem.self)
        subscription = Task { [weak self] in
            do {
                for try await item in stream { self?.receive(item.changes, from: client) }
            } catch {}
        }
        startPinging(client)
    }

    /// The server's events: the first holds every key, and the server serves from then on.
    private func receive(_ changes: [EnvironmentChange], from client: ProtocolClient) {
        guard client === self.client else { return }
        let topics = state.topicContents
        let hadOwnClient = state.server?.ownClient != nil
        state.apply(changes)
        guard serving else {
            serving = true
            // The Sessions-only link stops listening: the server's publisher hears tmux and keeps the Watch Session.
            inner.stopListening()
            events.send(.featuresChanged)
            events.send(.topics(state.topicContents))
            events.send(.changed)
            noteOwnClient()
            return
        }
        if state.topicContents != topics { events.send(.topics(state.topicContents)) }
        if changes.contains(where: { if case .topic = $0 { false } else if case .openPlaces = $0 { false } else { true } }) {
            events.send(.changed)
        }
        if hadOwnClient, state.server?.ownClient == nil, sawOwnClient {
            // The attachment ended: its master waits for this channel, so the Terminal sees SSH exit only once it closes.
            end()
        } else {
            noteOwnClient()
        }
    }

    private func noteOwnClient() {
        if state.server?.ownClient != nil { sawOwnClient = true }
    }

    /// Pings while the link has sent nothing else, so the server's 45 s silence rule never ends a live channel.
    private func startPinging(_ client: ProtocolClient) {
        pinger?.invalidate()
        pinger = Timer.scheduledTimer(withTimeInterval: pingInterval / 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, client === self.client, Date().timeIntervalSince(self.lastSent) >= self.pingInterval else { return }
                self.lastSent = Date()
                Task { try? await client.ping() }
            }
        }
    }

    /// Closes the channel on purpose: nothing after it counts as a stop.
    private func end() {
        let (client, channel) = transport.close()
        stopServing(sendingEvents: false)
        client?.close()
        channel?.close()
    }

    /// Forgets the server's state. With `sendingEvents`, the store goes back to the Sessions-only link's reads.
    private func stopServing(sendingEvents: Bool) {
        client = nil
        session = nil
        subscription?.cancel()
        subscription = nil
        pinger?.invalidate()
        pinger = nil
        sawOwnClient = false
        let wasServing = serving
        serving = false
        state = EnvironmentState()
        if sendingEvents, wasServing {
            events.send(.featuresChanged)
            events.send(.topics(TopicContents(records: [])))
            events.send(.changed)
        }
    }

    /// The channel ended. Unless the link closed it, it decides between a drop, a stop and a server that cannot run.
    private func channelEnded(_ token: ObjectIdentifier, reason: ProtocolChannel.CloseReason, channel: HostServerChannel) {
        guard self.client.map(ObjectIdentifier.init) == token, transport.ended(token) else { return }
        let answered = session != nil
        stopServing(sendingEvents: true)
        let errors = self.errors
        let name = environmentName
        let masterAlive = masterAlive
        let hostCLIVersion = hostCLIVersion
        Task.detached(priority: .utility) { [weak self] in
            let status = channel.exitStatus(waiting: 2)
            channel.close()
            let alive = masterAlive()
            let last = errors.last ?? reason.message
            Diagnostics.report("Host Server: \(name): the channel failed: \(reason.message)"
                + (status.map { ", exit \($0)" } ?? "") + "; last stderr line: \"\(errors.last ?? "")\""
                + (errors.lines.isEmpty ? "" : "\n" + errors.lines.joined(separator: "\n")))
            // A master that died is a drop: the Terminal's own end reconnects, with a new master and a new server.
            guard alive else { return }
            var unavailable: HostServerUnavailable?
            if !answered {
                switch status {
                case 2: unavailable = .tooOld(hostCLIVersion().flatMap { $0.isEmpty ? nil : $0 } ?? "it prints no build line")
                case 127: unavailable = .notInstalled("")
                default:
                    switch reason {
                    case .handshake(let what) where what.hasPrefix("no shared protocol with "):
                        unavailable = .tooOld(String(what.dropFirst("no shared protocol with ".count)))
                    case .handshake: unavailable = .noAnswer
                    default: break
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, !self.transport.isRetired else { return }
                if case .notInstalled = unavailable { unavailable = .notInstalled(self.installLine ?? "no muxify was found") }
                if let unavailable {
                    self.events.send(.serverUnavailable(unavailable))
                } else {
                    self.events.send(.serverStopped(lastLine: last))
                }
            }
        }
    }

    func sessionsOnlyLink() -> EnvironmentLink? {
        end()
        innerSubscription?.cancel()
        innerSubscription = nil
        return inner
    }

    // MARK: Sessions

    func view(_ command: ViewCommand) async throws -> String {
        guard serving else { return try await inner.view(command) }
        return try await call(.view(command), as: ViewOutput.self).output
    }

    /// The server as its events left it, stamped as a read of this link. Before the server's Client marker names an
    /// attached Client, the read is not ready, as a Sessions-only read is not.
    func snapshot(updating commandLines: PaneCommandLines?) async throws -> TmuxSnapshot {
        guard serving else { return try await inner.snapshot(updating: commandLines) }
        return try servedSnapshot()
    }

    func snapshotNow() throws -> TmuxSnapshot {
        guard serving else { return try inner.snapshotNow() }
        return try servedSnapshot()
    }

    private func servedSnapshot() throws -> TmuxSnapshot {
        guard var snapshot = state.snapshot, let server = state.server, server.ownClient != nil else { throw TmuxError.notReady }
        for index in snapshot.windows.indices {
            snapshot.windows[index].homeDirectory = server.home
            snapshot.windows[index].hostName = server.hostName
            snapshot.windows[index].isRemote = true
            snapshot.windows[index].sourceID = "\(id.uuidString):\(server.serverID ?? "")"
        }
        return snapshot
    }

    func script(_ script: String, arguments: [String], timeout: TimeInterval) async throws -> String {
        try await inner.script(script, arguments: arguments, timeout: timeout)
    }

    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String? {
        try await inner.sessionPathOutput(roots: roots, arguments: arguments)
    }

    func pasteAttachments(_ attachments: TerminalAttachments, client: String) async throws -> String {
        try await inner.pasteAttachments(attachments, client: client)
    }

    func terminalCommand(_ arguments: [String], target: String?, picksLatestSession: Bool,
                         newSession: RemoteSSH.NewSession?) throws -> String {
        try inner.terminalCommand(arguments, target: target, picksLatestSession: picksLatestSession, newSession: newSession)
    }

    func updateLocalClient(_ client: TmuxClient?) { inner.updateLocalClient(client) }
    var isListening: Bool { serving || inner.isListening }

    func startListening() {
        if !serving { inner.startListening() }
    }

    func stopListening() { inner.stopListening() }
    var attachmentEnd: AttachmentEnd? { inner.attachmentEnd }

    // MARK: Topics

    // The server sends its events before it answers, so nothing waits for a read of the records.
    func reloadTopics() {}
    func topicsReloaded() async {}
    func topicsCaughtUp() async {}

    func writeTopics<T>(locks: [SessionLock], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        throw EnvironmentLinkError.unsupported("Writing Topic records on the Mac")
    }

    /// The Sessions-only link's service, for the Worktrees until they move onto the server.
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService? {
        inner.environmentService(sessionPaths: sessionPaths, topics: topics, notifications: notifications, worktreesRoot: worktreesRoot)
    }

    func run(_ request: EnvironmentRequest, client: String?, local: EnvironmentService?) async -> EnvironmentResponse? {
        guard serving, !request.command.isWorktreeCommand else { return await EnvironmentLinks.run(request, client: client, local: local) }
        do {
            return try await call(.environment(request), as: EnvironmentResponse.self)
        } catch {
            return .failed(failure(error, changes: !request.command.onlyReads, action: request.command.actionName))
        }
    }

    func settleChoices(for target: EnvironmentTarget, local: EnvironmentService?) async -> Result<[TopicSettleSession], TopicFailure>? {
        guard serving else { return nil }
        do {
            return .success(try await call(.topicChoices(TopicChoicesRequest(.settle, target: target)), as: TopicChoices.self).sessions)
        } catch {
            return .failure(failure(error, changes: false, action: "Settle Topic"))
        }
    }

    func forgetChoices(for target: EnvironmentTarget, local: EnvironmentService?)
        async -> Result<(sessions: [TopicSettleSession], worktrees: [TopicForgetChoices.Worktree]), TopicFailure>? {
        guard serving else { return nil }
        do {
            let choices = try await call(.topicChoices(TopicChoicesRequest(.forget, target: target)), as: TopicChoices.self)
            return .success((sessions: choices.sessions, worktrees: []))
        } catch {
            return .failure(failure(error, changes: false, action: "Forget Topic"))
        }
    }

    /// An older Muxify's Locked Sessions are a Mac's records only: nothing to gather on a Host.
    func gatherGuests(local: EnvironmentService?) async -> TopicFailure? { nil }

    func markTopicsRead(_ ids: Set<String>) async throws {
        guard serving else { throw EnvironmentLinkError.unsupported("Topics") }
        do {
            try await call(.markRead(MarkRead(topics: ids.sorted())), as: ProtocolEmpty.self)
        } catch {
            throw failure(error, changes: true, action: "Mark as Read")
        }
    }

    /// Sends a request on the current channel. A request whose channel ends fails at once and is never sent again.
    @discardableResult
    private func call<Response: Decodable>(_ request: HostRequest, as response: Response.Type) async throws -> Response {
        guard let client, serving else { throw TmuxError.notReady }
        lastSent = Date()
        return try await client.call(request, as: Response.self)
    }

    /// What the store shows for a request that failed. A change whose channel ended before its answer may or may
    /// not have happened, and is never retried.
    private func failure(_ error: Error, changes: Bool, action: String) -> TopicFailure {
        if let error = error as? ProtocolError {
            if let failure = error.topicFailure { return failure }
            if error.code == .unavailable, changes {
                return TopicFailure(kind: .disconnected, phase: .changesStarted,
                                    message: "\(environmentName) disconnected before \(action) finished. It may or may not have happened.")
            }
            return TopicFailure(kind: .unsupported, phase: .nothingChanged, message: error.message)
        }
        return TopicFailure(kind: .tmuxFailed, phase: .nothingChanged, message: String(describing: error))
    }

    // MARK: Git

    func startGitNetworkScript(_ script: String, arguments: [String], timeout: TimeInterval,
                               onPrompt: @escaping (GitCredentialPrompt) -> Void,
                               completion: @escaping (Result<String, Error>) -> Void) -> TerminalCommand? {
        inner.startGitNetworkScript(script, arguments: arguments, timeout: timeout, onPrompt: onPrompt, completion: completion)
    }

    func makeGitWatcher(run: @escaping GitRemoteProbe.Run) -> GitWatcher {
        inner.makeGitWatcher(run: run)
    }

    // MARK: Retiring

    /// Ends the channel, so every waiting request fails at once, then retires the master.
    nonisolated func retire(flushing commands: [ViewCommand]) {
        let (client, channel) = transport.retire()
        client?.close()
        channel?.close()
        inner.retire(flushing: commands)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopServing(sendingEvents: false)
                self.innerSubscription?.cancel()
                self.events.finish()
            }
        }
    }

    nonisolated func cleanup() {
        inner.cleanup()
    }
}

/// The current channel, for `retire`, which runs off the main thread.
private final class Transport: @unchecked Sendable {
    private let lock = NSLock()
    private var client: ProtocolClient?
    private var channel: HostServerChannel?
    private var retired = false

    var isRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    /// False once retired.
    func open(_ client: ProtocolClient, _ channel: HostServerChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return false }
        self.client = client
        self.channel = channel
        return true
    }

    /// True when `client`'s channel ended on its own: neither closed by the link nor retired.
    func ended(_ token: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired, client.map(ObjectIdentifier.init) == token else { return false }
        self.client = nil
        channel = nil
        return true
    }

    func close() -> (ProtocolClient?, HostServerChannel?) {
        lock.lock()
        defer { lock.unlock() }
        let taken = (client, channel)
        client = nil
        channel = nil
        return taken
    }

    func retire() -> (ProtocolClient?, HostServerChannel?) {
        lock.lock()
        defer { lock.unlock() }
        retired = true
        let taken = (client, channel)
        client = nil
        channel = nil
        return taken
    }
}

extension TopicFailure.Kind {
    /// The channel to the Environment's server ended before the request's answer: it may or may not have happened.
    static let disconnected = TopicFailure.Kind(rawValue: "disconnected")
}
