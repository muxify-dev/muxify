import Foundation

/// What `muxify server` serves: the Host's tmux server, its `muxify.db` and its Config.
public struct HostServerContext: @unchecked Sendable {
    public var paths: MuxifyPaths
    public var tmux: TmuxServer
    /// The Host's Config, with its SessionPaths, read again for each `environment` request so an edit on the Host
    /// takes effect at once.
    public var config: @Sendable () async throws -> Config
    public var startControlClient: TmuxControlClientStart
    /// The Host's home: the `config` subscription shows the Config's path under it as `~/…`, and an Override's `~/`
    /// starts there.
    public var home: String

    public init(paths: MuxifyPaths = MuxifyPaths(), tmux: TmuxServer = .local,
                config: (@Sendable () async throws -> Config)? = nil,
                startControlClient: @escaping TmuxControlClientStart = PipeControlClient.start,
                home: String = NSHomeDirectory()) {
        self.paths = paths
        self.tmux = tmux
        self.home = home
        self.config = config ?? { [paths] in try Self.configFile(paths) }
        self.startControlClient = startControlClient
    }

    /// The Config file alone, without finding SessionPaths.
    static func configFile(_ paths: MuxifyPaths) throws -> Config {
        switch Config.load(path: paths.configFile.path, read: { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        case .success(let config): return config
        case .failure(let error): throw ProtocolError(.failed, error.problem.description)
        }
    }
}

/// `muxify server`: the Host Server's requests (ADR 0085). It serves `ping` and `shutdown`, the `environment` and
/// `config` subscriptions, `environment` requests, `mark_read` and the view commands.
public enum HostServer {
    /// A server on these handles that serves `HostRequest` against `context`.
    public static func make(input: FileHandle, output: FileHandle, build: String, silence: TimeInterval = HostProtocol.serverSilence,
                            context: HostServerContext = HostServerContext(),
                            log: @escaping (String) -> Void = { _ in }) -> ProtocolServer {
        let host = HostEnvironment(context: context, log: log)
        let config = HostConfigFeed(path: context.paths.configFile.path, home: context.home)
        let server = ProtocolServer(input: input, output: output, build: build, silence: silence, log: log) { request, server in
            serve(request, server: server, host: host, config: config)
        }
        Task {
            _ = await server.wait()
            host.stop()
            config.stop()
        }
        return server
    }

    /// Runs a server on stdin and stdout until it exits, logging to stderr.
    public static func run(build: String, silence: TimeInterval = HostProtocol.serverSilence,
                           context: HostServerContext = HostServerContext()) async -> ProtocolServer.Exit {
        let server = make(input: .standardInput, output: .standardOutput, build: build, silence: silence, context: context) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        server.start()
        return await server.wait()
    }

    static func serve(_ request: ProtocolIncomingRequest, server: ProtocolServer, host: HostEnvironment, config: HostConfigFeed) {
        do {
            let nonce = server.client?.nonce
            switch try request.body(HostRequest.self) {
            case .ping:
                request.finish()
            case .shutdown:
                request.finish()
                server.stop(.shutdown)
            case .subscribe(.environment):
                host.subscribe(request, nonce: nonce)
            case .subscribe(.config):
                config.subscribe(request)
            case .environment(let environmentRequest):
                host.run(environmentRequest, for: request, nonce: nonce)
            case .markRead(let mark):
                host.markRead(mark, for: request, nonce: nonce)
            case .view(let command):
                host.view(command, for: request, nonce: nonce)
            case .topicChoices(let choices):
                host.choices(choices, for: request)
            }
        } catch let error as ProtocolError {
            request.fail(error)
        } catch {
            request.fail(ProtocolError(.invalid, "\(error)"))
        }
    }
}

/// The `config` subscription: the Host's Config, its path and its Overrides, pushed whole as one `config` item first
/// and again each time a change in their folders changes what reads. The watch starts with the first subscriber.
final class HostConfigFeed: @unchecked Sendable {
    private let path: String
    private let home: String
    /// Where the watcher's events, the reads and the subscribers live.
    private let queue = DispatchQueue(label: "dev.muxify.host-server.config")
    // Only `queue` touches these.
    private var watcher: FolderWatcher?
    private var state: HostConfig?
    private var subscribers: [Int: ProtocolIncomingRequest] = [:]
    private var readPending = false
    private var stopped = false

    init(path: String, home: String) {
        self.path = path
        self.home = home
    }

    func subscribe(_ request: ProtocolIncomingRequest) {
        let id = request.id
        queue.async { [self] in
            guard !request.isCancelled, !stopped else { return }
            subscribers[id] = request
            if watcher == nil {
                watcher = FolderWatcher(queue: queue) { [weak self] in self?.heard() }
                read()
            }
            if let state, !request.sendEvent(state, key: "config") { subscribers[id] = nil }
        }
        request.onCancel { self.queue.async { self.subscribers[id] = nil } }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            watcher?.stop()
            watcher = nil
            subscribers = [:]
        }
    }

    /// Something changed in a watched folder: the files are read once the events of one save have come.
    private func heard() {
        guard !readPending else { return }
        readPending = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            readPending = false
            guard watcher != nil else { return }
            read()
        }
    }

    /// Reads the Config and its Overrides, watches their folders, and pushes what reads when it changed. A change of
    /// the folders reads once more, so a file made before the new watch began is not missed.
    private func read() {
        var next = HostConfig.read(path: path, home: home)
        if watcher?.watch(next.watchedFolders()) == true { next = HostConfig.read(path: path, home: home) }
        guard next != state else { return }
        let first = state == nil
        state = next
        guard !first else { return }
        for (id, request) in subscribers where !request.sendEvent(next, key: "config") { subscribers[id] = nil }
    }
}

/// One Host Server's Environment: the `environment` publisher, run against the Host's tmux and `muxify.db`, its
/// subscribers, and the commands that write. Every write it makes reads again before its request ends, so the
/// write's events go out before the `end`; other processes' writes arrive through `data_version`.
final class HostEnvironment: @unchecked Sendable {
    private let context: HostServerContext
    private let log: (String) -> Void
    /// Where the publisher delivers, and where the subscribers and the state live.
    private let delivery = DispatchQueue(label: "dev.muxify.host-server.environment")
    private let lock = NSLock()
    // `lock` guards these.
    private var publisherStorage: EnvironmentPublisher?
    private var stopped = false

    // Only `delivery` touches these.
    private var state = EnvironmentState()
    private var hasState = false
    private var subscribers: [Int: ProtocolIncomingRequest] = [:]

    init(context: HostServerContext, log: @escaping (String) -> Void) {
        self.context = context
        self.log = log
    }

    func stop() {
        lock.lock()
        stopped = true
        let publisher = publisherStorage
        lock.unlock()
        publisher?.stop()
    }

    // MARK: - The subscription

    func subscribe(_ request: ProtocolIncomingRequest, nonce: String?) {
        Task {
            let publisher = await self.publisher(nonce: nonce)
            let id = request.id
            delivery.async { [self] in
                guard !request.isCancelled else { return }
                subscribers[id] = request
                // Before the publisher's first item, the subscriber gets that item whole.
                if hasState { send(state.all, to: id, first: true) }
            }
            request.onCancel { self.delivery.async { self.subscribers[id] = nil } }
            publisher.start { changes in self.receive(changes) }
        }
    }

    /// On `delivery`: the first item of the publisher holds every key, and goes whole to each subscriber; each later
    /// change goes as an event of its own key, which replaces an unsent one.
    private func receive(_ changes: [EnvironmentChange]) {
        state.apply(changes)
        let first = !hasState
        hasState = true
        for id in subscribers.keys.sorted() {
            if first { send(state.all, to: id, first: true) } else { send(changes, to: id, first: false) }
        }
    }

    private func send(_ changes: [EnvironmentChange], to id: Int, first: Bool) {
        guard let request = subscribers[id] else { return }
        let sent = first
            ? request.sendEvent(EnvironmentItem(changes: changes), key: "all")
            : changes.allSatisfy { request.sendEvent(EnvironmentItem(changes: [$0]), key: $0.key) }
        if !sent { subscribers[id] = nil }
    }

    // MARK: - Commands

    /// Runs an `EnvironmentRequest` with the Host's Config, as the App Window's own Client, then reads, so the
    /// events of what it changed go out before its answer.
    func run(_ environmentRequest: EnvironmentRequest, for request: ProtocolIncomingRequest, nonce: String?) {
        let reads: Bool = if case .read = environmentRequest.command.lane { true } else { false }
        Task {
            let config: Config
            do { config = try await context.config() } catch {
                return request.fail(ProtocolError(.failed, Self.message(error)))
            }
            let publisher = await self.publisher(nonce: nonce)
            let context = context
            guard reads || request.startMutation() else { return }
            let response = await Self.background {
                let service = EnvironmentService(paths: context.paths, server: context.tmux, sessionPaths: config.sessionPaths,
                                                 topics: config.topics, notifications: config.notifications,
                                                 worktreesRoot: config.worktreesRoot)
                let client = nonce.flatMap { Self.ownClient(on: context.tmux, nonce: $0) }
                return service.handle(environmentRequest, client: client?.tty)
            }
            if !reads { await publisher.read() }
            if case .failed(let failure) = response {
                request.fail(ProtocolError(.failed, failure.message, topicFailure: failure))
            } else {
                request.finish(response)
            }
        }
    }

    /// The Sessions that Settle or Forget offers, read with the Host's Config. It changes nothing.
    func choices(_ choices: TopicChoicesRequest, for request: ProtocolIncomingRequest) {
        Task {
            let config: Config
            do { config = try await context.config() } catch {
                return request.fail(ProtocolError(.failed, Self.message(error)))
            }
            let context = context
            let result = await Self.background {
                let service = EnvironmentService(paths: context.paths, server: context.tmux, sessionPaths: config.sessionPaths,
                                                 topics: config.topics, notifications: config.notifications,
                                                 worktreesRoot: config.worktreesRoot)
                switch choices.action {
                case .settle: return service.settleChoices(for: choices.target)
                case .forget: return service.forgetChoices(for: choices.target).map(\.sessions)
                }
            }
            switch result {
            case .success(let sessions): request.finish(TopicChoices(sessions: sessions))
            case .failure(let failure): request.fail(ProtocolError(.failed, failure.message, topicFailure: failure))
            }
        }
    }

    /// Unread on visit: one write of the Topic Unread keys, one tmux call for the Agents, then a read, which writes
    /// the Topics' remembered Sessions and sends the events of all of it before the answer.
    func markRead(_ mark: MarkRead, for request: ProtocolIncomingRequest, nonce: String?) {
        Task {
            let publisher = await self.publisher(nonce: nonce)
            guard request.startMutation() else { return }
            do {
                let ids = Set(mark.topics)
                if !ids.isEmpty {
                    try await publisher.write { transaction in
                        for record in transaction.records where ids.contains(record.id) && record.isUnread {
                            try transaction.update(record.id) { $0.isUnread = false }
                        }
                    }
                }
                if !mark.panes.isEmpty {
                    let tmux = context.tmux
                    _ = try await Self.background {
                        try ViewCommandExecutor(server: tmux).run(.setAgentUnread(mark.panes.map { PaneUnread(pane: $0, unread: false) }))
                    }
                }
                await publisher.read()
                request.finish()
            } catch {
                request.fail(ProtocolError(.failed, Self.message(error)))
            }
        }
    }

    /// Runs a view command on the Host's tmux. A command that acts as the App Window's own Client runs only while
    /// the Client marker names that Client. A command that changes tmux reads again before its answer.
    func view(_ command: ViewCommand, for request: ProtocolIncomingRequest, nonce: String?) {
        let tmux = context.tmux
        Task {
            var own: ViewCommandExecutor.Client?
            if command.ownClient != nil {
                own = await Self.background { nonce.flatMap { Self.ownClient(on: tmux, nonce: $0) } }
                guard own != nil else {
                    return request.fail(ProtocolError(.failed, "Muxify: the App Window's tmux client is not attached to the Host's server."))
                }
            }
            let changes = Self.changesTmux(command)
            guard !changes || request.startMutation() else { return }
            do {
                let output = try await Self.background { [own] in try ViewCommandExecutor(server: tmux, ownClient: own).run(command) }
                if changes, let publisher = runningPublisher { await publisher.read() }
                request.finish(ViewOutput(output: output))
            } catch {
                request.fail(ProtocolError(.failed, Self.message(error)))
            }
        }
    }

    // MARK: - Helpers

    /// The publisher, made once, with the Client marker of the first request's `hello` and the Config's Session order.
    private func publisher(nonce: String?) async -> EnvironmentPublisher {
        if let publisher = existingPublisher { return publisher }
        let order = (try? await context.config())?.topics.sessionOrder ?? Config.Topics().sessionOrder
        return makePublisher(nonce: nonce, order: order)
    }

    private func makePublisher(nonce: String?, order: SessionOrder) -> EnvironmentPublisher {
        lock.lock()
        defer { lock.unlock() }
        if let publisherStorage { return publisherStorage }
        let log = log
        let publisher = EnvironmentPublisher(server: context.tmux, topics: TopicStore(paths: context.paths), delivery: delivery,
                                             startControlClient: context.startControlClient,
                                             clientMarker: nonce.map(ClientMarker.option(nonce:)), rememberingOrder: order,
                                             report: { log("muxify server: \($0)") })
        publisherStorage = publisher
        if stopped { publisher.stop() }
        return publisher
    }

    private var existingPublisher: EnvironmentPublisher? {
        lock.lock()
        defer { lock.unlock() }
        return publisherStorage
    }

    /// The publisher once a subscriber started it: a view command reads again only for a subscriber to hear of it.
    private var runningPublisher: EnvironmentPublisher? {
        existingPublisher.flatMap { $0.isRunning ? $0 : nil }
    }

    /// The Client that the marker of `nonce` names, while it is attached.
    static func ownClient(on tmux: TmuxServer, nonce: String) -> ViewCommandExecutor.Client? {
        guard let value = try? tmux.run(["show-option", "-sqv", ClientMarker.option(nonce: nonce)]),
              let named = ClientMarker.named(by: value),
              let clients = try? tmux.run(["list-clients", "-F", "#{client_pid} #{client_tty} #{client_control_mode}"]) else { return nil }
        let attached = clients.split(separator: "\n").contains { $0 == "\(named.pid) \(named.tty) 0" }
        return attached ? named : nil
    }

    /// Whether a view command changes what the `environment` subscription shows.
    static func changesTmux(_ command: ViewCommand) -> Bool {
        switch command {
        case .activePane, .paneIsActive, .capturePane, .clientPane, .findInPane, .cancelFind: false
        case .selectPane, .switchClient, .splitPane, .resizePane, .selectLayout, .setLastWindow, .setAgentUnread, .setBrowser,
             .clearOpenRequests, .setBrowserSocket, .sendKeys, .newWindow, .killSession, .paste: true
        }
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// Runs blocking work, such as tmux and SQLite, off the cooperative pool.
    private static func background<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try body() }) }
        }
    }

    private static func background<T>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: body()) }
        }
    }
}
