import Foundation
import MuxifyCore

/// The link to a Host through its Host Server (ADRs 0088 and 0089): one
/// `muxify server` on a `-T` channel of the attachment's own SSH master, which the Mac opens once the master is ready
/// and the Host CLI install chain has run. The terminal never waits for it.
///
/// Until the server's first state arrives, and whenever it is down, the App Window shows the Sessions of its
/// `SessionsOnlyEnvironmentLink` on the same master, so connecting is never slower than without a server; that link
/// serves nothing else here. Once the state arrives, the Topics, the Sessions and every change come only from the
/// server's `environment` events, and Topic requests, Unread on visit, view commands, Session Path discovery and
/// Attachment uploads go over the channel; the Mac keeps no copy of the Host's records. The Config comes from the
/// server's `config` subscription, which pushes each edit on the Host. The Muxify Worktrees are the Host's too
/// (ADR 0090). The Git View's reads, changes and network commands and the `repository` subscription go to the server
/// too; a network command's askpass questions come back as `ask` requests of its operation. Without a server, each of
/// these is unavailable.
///
/// Programs on the Host reach this App Window through the server's own socket (ADR 0091): the server sends each
/// `browser` and `select` request over the channel, and the link hands it to its store's handler. While this App
/// Window consumes `@muxify_open`, the link tells the server with `claim_open`, so `@muxify_browser_socket` names it.
@MainActor
final class HostEnvironmentLink: EnvironmentLink {
    let isOnThisMac = false
    let environmentName: String
    /// The same master's Sessions-only link: the master, the attach, the Client marker, and the Sessions shown until
    /// the server's first state.
    nonisolated(unsafe) private let inner: EnvironmentLink
    private let build: String
    private let nonce: () -> String?
    private let helloTimeout: TimeInterval
    private let pingInterval: TimeInterval
    /// Opens a channel running the server from the given path, or from the Host CLI that it finds when nil.
    private let openChannel: (String?) throws -> HostServerChannel
    private let install: (@escaping @Sendable (HostCLIReady) -> Void) -> Void
    private let masterAlive: @Sendable () -> Bool
    private let hostCLIVersion: @Sendable (String?) -> String?
    /// The Mac's Muxify Worktree records, whose rows that wait for this Environment move to the Host on connect.
    private let macWorktrees: MuxifyWorktreeStore

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
    private var configSubscription: Task<Void, Never>?
    /// The server's last `config` item, which Reload Config sends again.
    private var servedConfig: HostConfig?
    private var pinger: Timer?
    private var lastSent = Date()
    /// The install chain's result line, for the reason when no Host CLI is found.
    private var installLine: String?
    /// The Debug app's own upload, which the server runs from; nil runs the Host CLI.
    private var serverPath: String?
    /// Once the server named the App Window's own Client, its going away is the end of the attachment.
    private var sawOwnClient = false
    /// The store's handler for the server's requests.
    private var hostRequests: HostRequestHandler?
    /// The network commands that run on the server, by operation, whose askpass questions come back as `ask`.
    private var asks: [String: GitAsk] = [:]
    /// Whether this App Window consumes `@muxify_open`, as the store last said.
    private var consumesOpen = false
    /// What the current server was last told: `claim_open` or `release_open`. Nil for a server told nothing yet.
    private var toldConsumes: Bool?

    init(environmentName: String, inner: EnvironmentLink, build: String = AppBuild.line, nonce: @escaping () -> String?,
         helloTimeout: TimeInterval = HostProtocol.helloTimeout, pingInterval: TimeInterval = 15,
         openChannel: @escaping (String?) throws -> HostServerChannel,
         install: @escaping (@escaping @Sendable (HostCLIReady) -> Void) -> Void,
         masterAlive: @escaping @Sendable () -> Bool, hostCLIVersion: @escaping @Sendable (String?) -> String?,
         macWorktrees: MuxifyWorktreeStore = MuxifyWorktreeStore(paths: MuxifyPaths())) {
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
        self.macWorktrees = macWorktrees
    }

    /// The link of the app: the Host Server on a channel of the Sessions-only link's master.
    static func overSSH(environment: RemoteEnvironment, sshExecutable: String) -> HostEnvironmentLink {
        let inner = SessionsOnlyEnvironmentLink(environment: environment, sshExecutable: sshExecutable)
        let baseURL = HostCLI.baseURL(environment: ProcessInfo.processInfo.environment)
        let name = environment.name
        return HostEnvironmentLink(
            environmentName: name, inner: inner, nonce: { inner.connection?.remote?.nonce },
            openChannel: { path in
                guard let remote = inner.connection?.remote else { throw TmuxError.notReady }
                return try HostServerChannel.process(remote.serverInvocation(executable: path))
            },
            install: { done in
                guard let connection = inner.connection else { return done(HostCLIReady(line: "failed: not connected")) }
                DispatchQueue.global(qos: .utility).async {
                    done(HostCLIChain.run(over: connection, environmentName: name, baseURL: baseURL, debug: DebugHostCLI.app,
                                          report: Diagnostics.report))
                }
            },
            masterAlive: {
                guard let remote = inner.connection?.remote else { return false }
                return (try? CommandRunner().run(remote.control("check"), timeout: 1)) != nil
            },
            hostCLIVersion: { path in
                (try? inner.connection?.runScript(RemoteSSH.hostCLIVersionScript(at: path), arguments: [], timeout: 10))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            })
    }

    // MARK: What it serves

    var features: EnvironmentFeatures { serving ? [.topics, .git, .worktrees] : [] }
    var publishesChanges: Bool { serving }
    var runsRequests: Bool { serving }
    var remembersTopics: Bool { serving }

    func connect() throws {
        try inner.connect()
        // The Sessions-only link's Sessions reach the store only while no server serves them. Its Config does not:
        // the server's `config` subscription is the Host's Config.
        innerSubscription = inner.subscribe { [weak self] event in
            guard let self, !self.serving else { return }
            if case .config = event { return }
            self.events.send(event)
        }
    }

    func subscribe(_ onEvent: @escaping (EnvironmentEvent) -> Void) -> EnvironmentSubscription {
        let topics: [EnvironmentEvent] = serving ? [.topics(state.topicContents)] : []
        return events.subscribe(initial: topics + (servedConfig.map { [.config(.host($0))] } ?? []), onEvent)
    }

    /// The server's last Config, which needs no read: it pushes every change. Until its first item, the App Window
    /// keeps the Config it has.
    func reloadConfig() {
        guard let servedConfig else { return }
        events.send(.config(.host(servedConfig)))
    }

    // MARK: The server's lifecycle

    /// The Host CLI install chain, then the server. Nothing waits for either. A server that already runs keeps
    /// running: a newer binary never restarts it (ADR 0086).
    func installHostCLI(environmentName: String) {
        install { [weak self] ready in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.installLine = ready.line
                    self.serverPath = ready.server
                    self.startServer()
                }
            }
        }
    }

    /// Opens a new channel and starts `muxify server` on it.
    func startServer() {
        guard !transport.isRetired, client == nil else { return }
        let channel: HostServerChannel
        do { channel = try openChannel(serverPath) } catch {
            Diagnostics.report("Host Server: \(environmentName): the channel did not open: \(error)")
            events.send(.serverStopped(lastLine: "\(error)"))
            return
        }
        let errors = HostServerErrors()
        errors.read(channel.errors)
        self.errors = errors
        let client = ProtocolClient(input: channel.input, output: channel.output, build: build, helloTimeout: helloTimeout,
                                    nonce: nonce(), onRequest: { [weak self] request in
                                        Task { @MainActor in
                                            guard let self else { return request.fail(.channelEnded) }
                                            await self.serve(request)
                                        }
                                    })
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
        let configs = client.subscribe(HostRequest.subscribe(.config), as: HostConfig.self)
        configSubscription = Task { [weak self] in
            do {
                for try await config in configs { self?.receive(config, from: client) }
            } catch {
                // A server whose subscription ended: the App Window keeps the Config it has until the next one.
            }
            self?.configEnded(from: client)
        }
        startPinging(client)
        adoptWaitingWorktrees(on: client)
    }

    /// Once after each `hello`: the Mac's Muxify Worktree rows that wait for this Environment go to the Host, which
    /// makes each its own record unless it has its id or its path already (ADR 0090). The Mac deletes only the rows the
    /// Host took. A skipped row stays, and so does every row when the channel ends before the answer: the next connect
    /// sends them again.
    private func adoptWaitingWorktrees(on client: ProtocolClient) {
        let store = macWorktrees
        let name = environmentName
        Task { [weak self] in
            let rows = await Task.detached(priority: .utility) { (try? store.waiting(for: name)) ?? [] }.value
            guard !rows.isEmpty, let self, client === self.client else { return }
            self.lastSent = Date()
            let answer: AdoptedWorktrees
            do {
                answer = try await client.call(HostRequest.adoptWorktrees(AdoptWorktrees(rows: rows)), as: AdoptedWorktrees.self)
            } catch {
                return Diagnostics.report("Host Server: \(name): kept the Mac's \(rows.count) Muxify Worktree records for the next connect: \(error)")
            }
            let taken = answer.rows.filter { $0.result == .taken }.map(\.id)
            let removed: Error? = await Task.detached(priority: .utility) {
                do { try store.removeWaiting(taken, for: name); return nil } catch { return error }
            }.value
            let skipped = answer.rows.filter { $0.result == .skipped }
            Diagnostics.report("Host Server: \(name): moved \(taken.count) Muxify Worktree records to the Host"
                + (skipped.isEmpty ? "" : "; kept " + skipped.map { "\($0.id) (\($0.reason ?? "skipped"))" }.joined(separator: ", "))
                + (removed.map { "; the Mac's rows stay: \($0)" } ?? ""))
        }
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
            tellOpenConsumer()
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

    /// The Host's Config, pushed first at once and then after each edit on the Host.
    private func receive(_ config: HostConfig, from client: ProtocolClient) {
        guard client === self.client else { return }
        servedConfig = config
        events.send(.config(.host(config)))
    }

    private func configEnded(from client: ProtocolClient) {
        guard client === self.client else { return }
        servedConfig = nil
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
        configSubscription?.cancel()
        configSubscription = nil
        // The store keeps the Config it has until the next server's first item.
        servedConfig = nil
        pinger?.invalidate()
        pinger = nil
        sawOwnClient = false
        toldConsumes = nil
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
        let serverPath = serverPath
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
                case 2: unavailable = .tooOld(hostCLIVersion(serverPath).flatMap { $0.isEmpty ? nil : $0 } ?? "it prints no build line")
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

    // MARK: Requests from the Host

    func serveHostRequests(_ handler: @escaping HostRequestHandler) {
        hostRequests = handler
    }

    func setOpenConsumer(_ consumes: Bool) {
        consumesOpen = consumes
        tellOpenConsumer()
    }

    /// Tells the serving server when this App Window became, or stopped being, the consumer of `@muxify_open`. A new
    /// server hears only a claim: it names no socket of its own before one.
    private func tellOpenConsumer() {
        guard serving, toldConsumes != consumesOpen, toldConsumes != nil || consumesOpen else { return }
        toldConsumes = consumesOpen
        let request: HostRequest = consumesOpen ? .claimOpen : .releaseOpen
        Task { [weak self] in try? await self?.call(request, as: ProtocolEmpty.self) }
    }

    /// A request that the server sent: a program on the Host asked this App Window for a Browser command or to show
    /// something. Nothing here takes focus; `select` brings the App Window to the front through the store.
    private func serve(_ request: ProtocolIncomingRequest) async {
        let mac: MacRequest
        do { mac = try request.body(MacRequest.self) } catch {
            return request.fail(error as? ProtocolError ?? ProtocolError(.invalid, "\(error)"))
        }
        if case .ask(let ask) = mac { return await answer(ask, for: request) }
        guard let handler = hostRequests, let reply = await handler(mac) else {
            return request.fail(ProtocolError(.unavailable, "no App Window of \(environmentName) serves this request"))
        }
        switch mac {
        case .select, .ask: request.finish()
        case .browser:
            // A picture goes as chunks, each waiting for room in the writer's queue, so off the main thread.
            await Task.detached(priority: .userInitiated) { request.finish(browser: reply) }.value
        }
    }

    /// An askpass question of a network command: asked in the Git View that started it. One that no command of this
    /// link waits for ends `unavailable`, and a cancelled one `cancelled`, so the helper exits at once.
    private func answer(_ ask: AskRequest, for request: ProtocolIncomingRequest) async {
        guard let handler = asks[ask.operation] else {
            return request.fail(ProtocolError(.unavailable, "no Git View of \(environmentName) waits for this question"))
        }
        guard let answer = await handler(ask) else {
            return request.fail(ProtocolError(.cancelled, "the question was cancelled"))
        }
        request.finish(AskAnswer(answer: answer))
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
        snapshot.stampHost(home: server.home, hostName: server.hostName)
        for index in snapshot.windows.indices {
            snapshot.windows[index].sourceID = "\(id.uuidString):\(server.serverID ?? "")"
        }
        return snapshot
    }

    /// Session Path discovery runs on the Host, through `session_paths`, as soon as the server answered `hello`: the
    /// Host's Config, which names the roots, comes before its first state.
    func sessionPathOutput(roots: [SessionPathRoot], arguments: [String]) async throws -> String? {
        guard let client, session != nil else { throw TmuxError.notReady }
        lastSent = Date()
        return try await client.call(HostRequest.sessionPaths(SessionPathsRequest(roots: roots)), as: SessionPathsOutput.self).output
    }

    /// Finds the Client's Pane first, so a later switch does not move the paste, uploads each file through `upload`,
    /// then pastes the Host paths into that Pane. A failed chunk fails the paste, and the server deletes the partial file.
    func pasteAttachments(_ attachments: TerminalAttachments, client: String) async throws -> String {
        defer { attachments.removeLocalCopy() }
        guard serving, let protocolClient = self.client else { throw TmuxError.notReady }
        do {
            let pane = try await call(.view(.clientPane(client: client)), as: ViewOutput.self).output.trimmingCharacters(in: .newlines)
            guard TerminalAttachments.isPane(pane) else { throw TmuxError.notReady }
            var words: [String] = []
            for item in attachments.items {
                switch item {
                case .text(let text): words.append(text)
                case .file(let file):
                    lastSent = Date()
                    let path = try await protocolClient.upload(file, name: file.lastPathComponent)
                    guard path.hasPrefix("/") else { throw TmuxError.notReady }
                    words.append(TerminalAttachments.word(forPath: path))
                }
            }
            try await call(.view(.paste(pane: pane, text: words.joined(separator: " "))), as: ViewOutput.self)
            return pane
        } catch let error as ProtocolError {
            throw TmuxError.failed(status: 1, stderr: error.message)
        }
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

    /// Every request runs in the Host Server: the Mac builds no service for a Host.
    func environmentService(sessionPaths: [SessionPath], topics: Config.Topics, notifications: Config.Notifications,
                            worktreesRoot: String?) -> EnvironmentService? {
        nil
    }

    func run(_ request: EnvironmentRequest, client: String?, local: EnvironmentService?) async -> EnvironmentResponse? {
        guard serving else { return nil }
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

    func worktreeStarts(from folder: String, local: EnvironmentService?) async -> Result<[WorktreeStartChoice], TopicFailure>? {
        guard serving else { return .failure(EnvironmentLinkError.worktreesRefused) }
        do {
            return .success(try await call(.worktreeStarts(WorktreeStartsRequest(from: folder)), as: WorktreeStarts.self).starts)
        } catch {
            return .failure(failure(error, changes: false, action: "New Worktree"))
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
                return TopicFailure(kind: .disconnected, phase: .changesStarted, message: disconnected(before: action))
            }
            return TopicFailure(kind: .unsupported, phase: .nothingChanged, message: error.message)
        }
        return TopicFailure(kind: .tmuxFailed, phase: .nothingChanged, message: String(describing: error))
    }

    /// What a change whose channel ended before its answer says: it is never retried.
    private func disconnected(before action: String) -> String {
        "\(environmentName) disconnected before \(action) finished. It may or may not have happened."
    }

    // MARK: Git

    /// The Git View's reads run in the Host Server; a diff arrives as chunks. Before the server serves, and once it
    /// stops, they are `unsupported`.
    func git(_ read: GitRead) async throws -> GitAnswer {
        guard serving, let client else { throw EnvironmentLinkError.unsupported("The Git View") }
        lastSent = Date()
        do {
            switch read.answer {
            case .snapshot: return .snapshot(try await client.call(HostRequest.git(read), as: GitSnapshot.self))
            case .log: return .log(try await client.call(HostRequest.git(read), as: GitLog.self))
            case .remote: return .remote(try await client.call(HostRequest.git(read), as: GitRemote.self))
            case .text:
                var data = Data()
                for try await chunk in client.stream(HostRequest.git(read)) { data.append(chunk) }
                return .text(String(decoding: data, as: UTF8.self))
            }
        } catch let error as ProtocolError {
            throw GitViewError(message: error.message)
        }
    }

    /// The Git View's writes run in the Host Server. One whose channel ends before its answer is never sent again:
    /// it may or may not have happened, and says so.
    func writeGit(_ write: GitWrite) async throws -> String {
        guard serving, let client else { throw EnvironmentLinkError.unsupported("The Git View") }
        lastSent = Date()
        do {
            return try await client.call(HostRequest.gitWrite(write), as: GitWritten.self).output
        } catch let error as ProtocolError {
            if error.code == .unavailable {
                throw GitViewError(message: disconnected(before: write.action))
            }
            throw GitViewError(message: error.message)
        }
    }

    /// The Git View's network commands run in the Host Server, with its own socket for their askpass helper. Each
    /// question comes back as an `ask` of the command's operation, which goes to `ask`. One whose channel ends before
    /// its answer is never sent again: it may or may not have happened, and says so.
    func runGitNetwork(_ network: GitNetwork, ask: @escaping GitAsk) async throws -> String {
        guard serving, let client else { throw EnvironmentLinkError.unsupported("The Git View") }
        let operation = UUID().uuidString
        asks[operation] = ask
        defer { asks[operation] = nil }
        lastSent = Date()
        do {
            return try await client.call(HostRequest.gitNetwork(GitNetworkRequest(network: network, operation: operation)),
                                         as: GitWritten.self).output
        } catch let error as ProtocolError {
            switch error.code {
            case .cancelled: throw TmuxError.cancelled
            case .unavailable:
                throw GitViewError(message: disconnected(before: network.action))
            case .unsupported, .invalid, .failed: throw GitViewError(message: error.message)
            }
        }
    }

    /// The server's `repository` subscription. Its events stop when the channel ends; the store subscribes again when
    /// the link's features change.
    func watchRepository(_ path: String, _ onEvent: @escaping (RepositoryEvent) -> Void) -> EnvironmentSubscription {
        guard serving, let client else { return EnvironmentSubscription {} }
        lastSent = Date()
        let events = client.subscribe(HostRequest.subscribe(.repository(RepositorySubscription(path: path))), as: RepositoryEvent.self)
        let task = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    guard let self, client === self.client else { return }
                    onEvent(event)
                }
            } catch {}
        }
        return EnvironmentSubscription { task.cancel() }
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
