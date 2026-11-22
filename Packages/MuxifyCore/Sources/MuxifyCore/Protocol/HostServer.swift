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
    /// What names this server's own socket, `<tmux socket>.muxify-browser.<id>` (ADR 0091): its pid. A test that runs
    /// several servers in one process gives each its own.
    public var socketID: String
    /// Runs the Git View's reads on the Host.
    public var git: GitReader
    /// Runs the Git View's writes that need no network on the Host.
    public var gitWriter: GitWriter
    /// Runs the Git View's commands that talk to a remote on the Host, with this `muxify` as their askpass helper.
    public var gitNetwork: GitNetworkRunner
    /// Where uploads go: the Host's `TMPDIR`, else `/tmp`.
    public var temporaryDirectory: String

    public init(paths: MuxifyPaths = MuxifyPaths(), tmux: TmuxServer = .local,
                config: (@Sendable () async throws -> Config)? = nil,
                startControlClient: @escaping TmuxControlClientStart = PipeControlClient.start,
                home: String = NSHomeDirectory(),
                socketID: String = String(getpid()),
                git: GitReader = GitReader(), gitWriter: GitWriter = GitWriter(), gitNetwork: GitNetworkRunner? = nil,
                temporaryDirectory: String? = nil) {
        self.paths = paths
        self.tmux = tmux
        self.home = home
        self.config = config ?? { [paths] in try Self.configFile(paths) }
        self.startControlClient = startControlClient
        self.socketID = socketID
        self.git = git
        self.gitWriter = gitWriter
        // The helper's script goes in the state folder: a Host may mount /tmp noexec.
        self.gitNetwork = gitNetwork ?? GitNetworkRunner(helper: Bundle.main.executablePath ?? CommandLine.arguments[0], scratch: paths.state)
        self.temporaryDirectory = temporaryDirectory
            ?? ProcessInfo.processInfo.environment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
    }

    /// The Config file alone, without finding SessionPaths.
    static func configFile(_ paths: MuxifyPaths) throws -> Config {
        switch Config.load(path: paths.configFile.path, read: { try? String(contentsOfFile: $0, encoding: .utf8) }) {
        case .success(let config): return config
        case .failure(let error): throw ProtocolError(.failed, error.problem.description)
        }
    }
}

/// `muxify server`: the Host Server's requests (ADR 0087). It serves `ping` and `shutdown`, the `environment`,
/// `config`, `repository`, `topic`, `snapshot` and `focus` subscriptions, `environment` requests, `mark_read`, the view
/// commands, the Topic and Worktree start choices, `adopt_worktrees`, `claim_open`, `release_open`, the Git View's reads,
/// writes and network commands, `session_paths`, `visit_session_path`, `upload`, `browser_tabs`, `colours` and `status_line`. Programs on the Host reach its
/// Mac through its own socket, whose requests it sends the Mac as `MacRequest`s (ADR 0091); an askpass helper's `ask`
/// goes to the network command that runs it, which asks the Mac.
public enum HostServer {
    /// A server on these handles that serves `HostRequest` against `context`.
    public static func make(input: FileHandle, output: FileHandle, build: String, silence: TimeInterval = HostProtocol.serverSilence,
                            context: HostServerContext = HostServerContext(),
                            log: @escaping (String) -> Void = { _ in }) -> ProtocolServer {
        let box = ServerBox()
        let asks = GitAskpassRoutes()
        let socket = HostServerSocket(tmux: context.tmux, server: context.socketID, log: log) { request in
            if case .ask(let ask) = request { return await asks.reply(to: ask) }
            guard let server = box.server else { return .failure("cannot reach Muxify: the Host Server has exited") }
            return await forward(request, to: server)
        }
        let config = HostConfigFeed(path: context.paths.configFile.path, home: context.home)
        let host = HostEnvironment(context: context, socket: socket, asks: asks, config: config, log: log)
        let server = ProtocolServer(input: input, output: output, build: build, silence: silence, log: log) { request, server in
            serve(request, server: server, host: host, config: config)
        }
        box.server = server
        // Before `wait` returns, so a process that exits then has removed its socket and cleared the option.
        server.onExit {
            box.server = nil
            socket.stop()
        }
        socket.listen()
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
        // A server stopped by a signal exits as on EOF, so it removes its socket and clears the option it named.
        let signals = [SIGTERM, SIGHUP, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { server.stop(.failed("signal \(number)")) }
            source.resume()
            return source
        }
        server.start()
        let exit = await server.wait()
        signals.forEach { $0.cancel() }
        return exit
    }

    /// Sends a program's request to the Mac and turns the Mac's answer into the reply line for the program. A Mac
    /// that serves none, or a channel that ended, is "cannot reach Muxify", as a socket that nobody listens on is.
    static func forward(_ request: MacRequest, to server: ProtocolServer) async -> BrowserAgentReply {
        do {
            switch request {
            case .browser:
                let (reply, bytes) = try await server.callStreaming(request, as: BrowserAgentReply.self)
                if case .png = reply { return .png(bytes) }
                return reply
            case .select:
                _ = try await server.call(request, as: ProtocolEmpty.self)
                return .done
            case .ask:
                // An askpass question goes to the network command that runs its helper, which asks the Mac itself.
                return .failure("Muxify: no Git View command waits for this question")
            }
        } catch let error as ProtocolError {
            switch error.code {
            case .unavailable, .unsupported, .cancelled:
                return .failure("cannot reach Muxify: \(error.message). Run muxify browser available to check that Muxify shows this tmux server.")
            case .invalid, .failed:
                return .failure(error.message)
            }
        } catch {
            return .failure("\(error)")
        }
    }

    static func serve(_ request: ProtocolIncomingRequest, server: ProtocolServer, host: HostEnvironment, config: HostConfigFeed) {
        do {
            let nonce = server.client?.nonce
            func declared(_ capability: HostCapability) -> Bool { server.client?.capabilities.contains(capability.rawValue) == true }
            let body = try request.body(HostRequest.self)
            if let needed = body.capability, server.client?.capabilities.contains(needed.rawValue) != true {
                throw ProtocolError(.unsupported, "this client did not declare the capability \(needed.rawValue)")
            }
            switch body {
            case .ping:
                request.finish()
            case .shutdown:
                request.finish()
                server.stop(.shutdown)
            case .subscribe(.environment):
                host.subscribe(request, nonce: nonce, boardSessions: declared(.board))
            case .subscribe(.config):
                config.subscribe(request)
            case .subscribe(.repository(let repository)):
                host.watch(repository, for: request)
            case .subscribe(.topic(let topic)):
                host.subscribe(topic, for: request, nonce: nonce)
            case .subscribe(.snapshot):
                host.subscribeSnapshot(request, nonce: nonce, boardSessions: declared(.board))
            case .subscribe(.focus):
                host.subscribeFocus(request, nonce: nonce)
            case .environment(let environmentRequest):
                host.run(environmentRequest, for: request, nonce: nonce, boardSessions: declared(.board))
            case .markRead(let mark):
                host.markRead(mark, for: request, nonce: nonce)
            case .view(let command):
                host.view(command, for: request, nonce: nonce)
            case .topicChoices(let choices):
                host.choices(choices, for: request)
            case .worktreeStarts(let starts):
                host.worktreeStarts(starts, for: request)
            case .adoptWorktrees(let adopt):
                host.adoptWorktrees(adopt, for: request)
            case .claimOpen:
                host.socket.claim()
                request.finish()
            case .releaseOpen:
                host.socket.release()
                request.finish()
            case .git(let read):
                host.git(read, for: request)
            case .gitWrite(let write):
                host.gitWrite(write, for: request)
            case .gitNetwork(let network):
                host.gitNetwork(network, for: request, server: server)
            case .sessionPaths(let sessionPaths):
                host.sessionPaths(sessionPaths, for: request)
            case .visitSessionPath(let visit):
                host.visit(visit, for: request)
            case .upload(let chunk):
                host.uploads.receive(chunk, for: request)
            case .browserTabs(let tabs):
                host.browserTabs(tabs, for: request)
            case .colours(let colours):
                host.colours(colours, for: request, nonce: nonce)
            case .statusLine(let statusLine):
                host.statusLine(statusLine, for: request, nonce: nonce)
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
    /// What the server itself runs on each Config it reads, such as the `snapshot` subscription's `sidebar`.
    private var observers: [(HostConfig) -> Void] = []
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
            watch()
            if let state, !request.sendEvent(state, key: "config") { subscribers[id] = nil }
        }
        request.onCancel { self.queue.async { self.subscribers[id] = nil } }
    }

    /// Runs `observer` on this feed's queue with the Config that reads now, then with each one that differs, until
    /// the server stops. It starts the watch as a subscriber does.
    func observe(_ observer: @escaping (HostConfig) -> Void) {
        queue.async { [self] in
            guard !stopped else { return }
            observers.append(observer)
            watch()
            if let state { observer(state) }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            watcher?.stop()
            watcher = nil
            subscribers = [:]
            observers = []
        }
    }

    /// The watch of the Config's folders, with the first read, once.
    private func watch() {
        guard watcher == nil else { return }
        watcher = FolderWatcher(queue: queue) { [weak self] in self?.heard() }
        read()
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
        for observer in observers { observer(next) }
    }
}

/// One Host Server's Environment: the `environment` publisher, run against the Host's tmux and `muxify.db`, its
/// subscribers, and the commands that write. Every write it makes reads again before its request ends, so the
/// write's events go out before the `end`; other processes' writes arrive through `data_version`.
final class HostEnvironment: @unchecked Sendable {
    private let context: HostServerContext
    /// The server's own socket, which `@muxify_browser_socket` names while its App Window consumes `@muxify_open`.
    let socket: HostServerSocket
    /// The network commands that wait for askpass answers, which come in on `socket`.
    private let asks: GitAskpassRoutes
    /// The Host's Config as the `config` subscription reads it, which gives the `snapshot` items their Config.
    private let config: HostConfigFeed
    private let log: (String) -> Void
    /// Where the publisher delivers, and where the subscribers and the state live.
    private let delivery = DispatchQueue(label: "dev.muxify.host-server.environment")
    private let lock = NSLock()
    // `lock` guards these.
    private var publisherStorage: EnvironmentPublisher?
    private var stopped = false
    /// The id of the `colours` request whose colours the publisher has.
    private var coloursID = 0
    /// The id of the `status_line` request that the publisher follows.
    private var statusLineID = 0

    // Only `delivery` touches these.
    private var state = EnvironmentState()
    private var hasState = false
    private var subscribers: [Int: ProtocolIncomingRequest] = [:]
    /// The `environment` and `snapshot` subscribers whose client declared `board`.
    private var boardSubscribers: Set<Int> = []
    /// The `snapshot` subscribers, the Config their items are computed with once it was read, and the JSON of the
    /// last item computed of each view, keyed by whether the client declared `board`, so an item goes out
    /// only when the view that its client gets differs.
    private var snapshotSubscribers: [Int: ProtocolIncomingRequest] = [:]
    private var snapshotConfig: Config?
    private var observesConfig = false
    private var lastShown: [Bool: Data] = [:]
    /// The `focus` subscribers, which get what the Listener heard of the focus in the Terminal's Window.
    private var focusSubscribers: [Int: ProtocolIncomingRequest] = [:]
    /// The `repository` subscriptions by request; `lock` guards it.
    private var watches: [Int: RepositoryWatch] = [:]
    let uploads: HostUploads
    /// The `topic` subscriptions, which read again on each change of the publisher.
    private let details: HostTopicDetails

    init(context: HostServerContext, socket: HostServerSocket, asks: GitAskpassRoutes, config: HostConfigFeed,
         log: @escaping (String) -> Void) {
        self.context = context
        self.socket = socket
        self.asks = asks
        self.config = config
        self.log = log
        uploads = HostUploads(directory: context.temporaryDirectory)
        details = HostTopicDetails { [context] topics in await Self.details(of: topics, context: context, log: log) }
    }

    func stop() {
        lock.lock()
        stopped = true
        let publisher = publisherStorage
        let watches = Array(self.watches.values)
        self.watches = [:]
        lock.unlock()
        publisher?.stop()
        watches.forEach { $0.stop() }
        uploads.stop()
        details.stop()
    }

    // MARK: - The Git View

    /// The `repository` subscription of a folder: one watch per request, until it is cancelled or falls behind.
    func watch(_ repository: RepositorySubscription, for request: ProtocolIncomingRequest) {
        let id = request.id
        let watch = RepositoryWatch(path: repository.path, reader: context.git) { [weak self] event in
            guard request.sendEvent(event, key: "repository") else {
                self?.endWatch(id)
                return
            }
        }
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return request.fail(ProtocolError(.unavailable, "the Host Server is stopping"))
        }
        watches[id] = watch
        lock.unlock()
        request.onCancel { [weak self] in self?.endWatch(id) }
        watch.start()
    }

    private func endWatch(_ id: Int) {
        lock.lock()
        let watch = watches.removeValue(forKey: id)
        lock.unlock()
        watch?.stop()
    }

    /// One of the Git View's reads. A diff streams its text, so a large one goes out as chunks between other frames.
    func git(_ read: GitRead, for request: ProtocolIncomingRequest) {
        let reader = context.git
        Task {
            let answer: GitAnswer
            do {
                answer = try await Self.background { try reader.run(read) }
            } catch {
                return request.fail(ProtocolError(.failed, GitReader.message(for: error)))
            }
            switch answer {
            case .snapshot(let snapshot): request.finish(snapshot)
            case .log(let log): request.finish(log)
            case .remote(let remote): request.finish(remote)
            case .text(let text):
                if request.stream(Data(text.utf8)) { request.finish() }
            }
        }
    }

    /// One of the Git View's writes. The `repository` watch sees what it changed and pushes it.
    func gitWrite(_ write: GitWrite, for request: ProtocolIncomingRequest) {
        let writer = context.gitWriter
        Task {
            do {
                let output = try await Self.background { try writer.run(write) }
                request.finish(GitWritten(output: output))
            } catch {
                request.fail(ProtocolError(.failed, GitReader.message(for: error)))
            }
        }
    }

    /// One of the Git View's commands that talk to a remote. Its helper asks through this server's own socket, never
    /// the one that `@muxify_browser_socket` names, which may be another server's; each question goes to the Mac as an
    /// `ask` of the request's operation. The `repository` watch sees what it changed and pushes it.
    func gitNetwork(_ network: GitNetworkRequest, for request: ProtocolIncomingRequest, server: ProtocolServer) {
        guard socket.listen() else {
            return request.fail(ProtocolError(.unavailable, "the Host Server cannot listen on its socket for git's questions"))
        }
        let runner = context.gitNetwork, path = socket.path, asks = asks
        Task {
            do {
                let output = try await runner.run(network.network, operation: network.operation, socket: path, routes: asks) { ask in
                    try? await server.call(MacRequest.ask(ask), as: AskAnswer.self).answer
                }
                request.finish(GitWritten(output: output))
            } catch TmuxError.cancelled {
                request.fail(ProtocolError(.cancelled, "\(network.network.action) cancelled"))
            } catch {
                request.fail(ProtocolError(.failed, GitReader.message(for: error)))
            }
        }
    }

    // MARK: - The subscription

    func subscribe(_ request: ProtocolIncomingRequest, nonce: String?, boardSessions: Bool) {
        Task {
            let publisher = await self.publisher(nonce: nonce)
            let id = request.id
            delivery.async { [self] in
                guard !request.isCancelled else { return }
                subscribers[id] = request
                if boardSessions { boardSubscribers.insert(id) }
                // Before the publisher's first item, the subscriber gets that item whole.
                if hasState {
                    send(boardSessions ? state.all : state.olderClientChanges(state.all, lockOrdersBefore: state.lockOrders), to: id, first: true)
                }
            }
            request.onCancel { self.delivery.async { self.subscribers[id] = nil; self.boardSubscribers.remove(id) } }
            start(publisher)
        }
    }

    /// The `topic` subscription of one Topic: its detail now, then again after each change of the publisher that
    /// changes it.
    func subscribe(_ topic: TopicSubscription, for request: ProtocolIncomingRequest, nonce: String?) {
        details.subscribe(request, topic: topic.id)
        Task {
            start(await self.publisher(nonce: nonce))
        }
    }

    /// What `environment { show }` answers for each Topic, read with the Host's Config. A Topic that is not open is
    /// gone; one that cannot be read now has no entry.
    private static func details(of topics: Set<String>, context: HostServerContext, log: @escaping (String) -> Void) async
        -> [String: HostTopicDetails.Read] {
        let config: Config
        do { config = try await context.config() } catch {
            log("muxify server: topic: \(message(error))")
            return [:]
        }
        return await background {
            let service = EnvironmentService(paths: context.paths, server: context.tmux, sessionPaths: config.sessionPaths,
                                             topics: config.topics, notifications: config.notifications,
                                             worktreesRoot: config.worktreesRoot)
            var found: [String: HostTopicDetails.Read] = [:]
            for topic in topics.sorted() {
                let response = service.handle(EnvironmentRequest(.show, target: .topic(.id(topic))))
                switch response {
                case .failed(let failure) where failure.kind == .topicUnavailable: found[topic] = .gone
                case .failed(let failure): log("muxify server: topic \(topic): \(failure.message)")
                default: found[topic] = .shown(response)
                }
            }
            return found
        }
    }

    /// Starts the publisher once, for every subscription: its items go to `receive`, and what its Listener heard of the
    /// focus to the `focus` subscribers.
    private func start(_ publisher: EnvironmentPublisher) {
        publisher.start(news: { [weak self] news in self?.heard(news) }, { [weak self] changes, _ in self?.receive(changes) })
    }

    /// On `delivery`: what the Listener heard of the focus in the Window that the Terminal shows goes to each `focus`
    /// subscriber, whose Mac decides whose screen made it (ADR 0098).
    private func heard(_ news: EnvironmentPublisher.News) {
        let event: FocusEvent
        switch news {
        case .heard, .readFailed: return
        case .focusChanged(let window): event = .focusChanged(window: window)
        case .taken(let window): event = .taken(window: window)
        }
        for (id, request) in focusSubscribers where !request.sendEvent(event, key: event.key) { focusSubscribers[id] = nil }
    }

    /// On `delivery`: the first item of the publisher holds every key, and goes whole to each subscriber; each later
    /// change goes as an event of its own key, which replaces an unsent one.
    private func receive(_ changes: [EnvironmentChange]) {
        let lockOrders = state.lockOrders
        state.apply(changes)
        let first = !hasState
        hasState = true
        if let server = state.server, first || changes.contains(where: { $0.key == "server" }) {
            let socket = socket
            DispatchQueue.global(qos: .utility).async { socket.noteOption(server.browserSocket, serverRunning: server.isRunning) }
        }
        let sent = first ? state.all : changes
        let older = state.olderClientChanges(sent, lockOrdersBefore: lockOrders)
        for id in subscribers.keys.sorted() {
            send(boardSubscribers.contains(id) ? sent : older, to: id, first: first)
        }
        details.changed()
        if !snapshotSubscribers.isEmpty { sendSnapshot() }
    }

    /// `changes` as the subscriber's client reads them: a client that did not declare `board` gets them as
    /// `EnvironmentState.olderClientChanges` gives them.
    private func send(_ changes: [EnvironmentChange], to id: Int, first: Bool) {
        guard let request = subscribers[id] else { return }
        let sent = first
            ? request.sendEvent(EnvironmentItem(changes: changes), key: "all")
            : changes.allSatisfy { request.sendEvent(EnvironmentItem(changes: [$0]), key: $0.key) }
        if !sent { subscribers[id] = nil }
    }

    // MARK: - The Mac's colours (ADR 0098)

    /// The `focus` subscription: what the Listener hears of the focus in the Window that the Terminal shows, from now
    /// on. It starts the publisher, whose Listener hears it.
    func subscribeFocus(_ request: ProtocolIncomingRequest, nonce: String?) {
        Task {
            let publisher = await self.publisher(nonce: nonce)
            let id = request.id
            delivery.async { [self] in
                guard !request.isCancelled else { return }
                focusSubscribers[id] = request
            }
            request.onCancel { self.delivery.async { self.focusSubscribers[id] = nil } }
            start(publisher)
        }
    }

    /// The Mac's colours: the publisher writes them by the rules it follows on the Mac, from its Listener and without
    /// waiting. With a Window, it writes that Window's Panes now; without one, the Terminal's Session's.
    /// Handlers run concurrently, so a request's id, which grows with each request on the channel, tells the Mac's last
    /// colours: an older request that comes late leaves them, and only writes its Window with them.
    func colours(_ colours: ColoursRequest, for request: ProtocolIncomingRequest, nonce: String?) {
        Task {
            let publisher = await self.publisher(nonce: nonce)
            lock.lock()
            let newest = request.id > coloursID
            if newest { coloursID = request.id }
            switch (newest, colours.window) {
            case (true, let window?): publisher.reportColours(colours.colours, toWindow: window)
            case (true, nil): publisher.reportColours(colours.colours)
            case (false, let window?): publisher.reportColours(toWindow: window)
            case (false, nil): break
            }
            lock.unlock()
            request.finish()
        }
    }

    /// The Mac's header shows the Session and its Windows, or no longer does: the publisher's Listener hides tmux's
    /// status line in the Terminal's Sessions, or gives it back (ADR 0099). The Mac sends it after each `hello` and
    /// when its Config changes; the last request's answer is what holds.
    func statusLine(_ statusLine: StatusLineRequest, for request: ProtocolIncomingRequest, nonce: String?) {
        Task {
            let publisher = await self.publisher(nonce: nonce)
            lock.withLock {
                guard request.id > statusLineID else { return }
                statusLineID = request.id
                publisher.hideStatusLine(statusLine.hidden)
            }
            request.finish()
        }
    }

    // MARK: - The snapshot subscription

    /// The `snapshot` subscription (ADR 0093): `environment show`'s view, computed from the state that the
    /// `environment` publisher keeps and the Config that the `config` feed reads, so an item costs no read of its own.
    func subscribeSnapshot(_ request: ProtocolIncomingRequest, nonce: String?, boardSessions: Bool) {
        Task {
            let publisher = await self.publisher(nonce: nonce)
            let id = request.id
            delivery.async { [self] in
                guard !request.isCancelled else { return }
                snapshotSubscribers[id] = request
                if boardSessions { boardSubscribers.insert(id) }
                if !observesConfig {
                    observesConfig = true
                    config.observe { [weak self] hostConfig in self?.delivery.async { self?.configRead(hostConfig) } }
                }
                sendSnapshot(first: id)
            }
            request.onCancel { self.delivery.async { self.snapshotSubscribers[id] = nil; self.boardSubscribers.remove(id) } }
            start(publisher)
        }
    }

    /// On `delivery`: the Config that the feed read. One that does not parse leaves the last that did.
    private func configRead(_ hostConfig: HostConfig) {
        switch hostConfig.load(host: Tmux.hostName) ?? .success(Config()) {
        case .success(let config): snapshotConfig = config
        case .failure(let error):
            log("snapshot: \(error)")
            if snapshotConfig == nil { snapshotConfig = Config() }
        }
        sendSnapshot()
    }

    /// On `delivery`: computes the view once the state and the Config are there, and sends it to every subscriber whose
    /// view differs from the last one, and to the subscriber `first` in any case. A newer item replaces an unsent one.
    /// A client that did not declare `board` gets the view without its Dormant Board Sessions, so a change
    /// of only those sends it nothing.
    private func sendSnapshot(first: Int? = nil) {
        guard hasState, let config = snapshotConfig, let tmux = state.snapshot else { return }
        let whole = EnvironmentShown(contents: state.topicContents, tmux: tmux, config: config)
        var older = whole
        older.snapshot = whole.snapshot.withoutDormantSessions
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var changed: [Bool: Bool] = [:]
        for (boardSessions, shown) in [(true, whole), (false, older)] {
            guard let data = try? encoder.encode(shown) else { return }
            changed[boardSessions] = data != lastShown[boardSessions]
            lastShown[boardSessions] = data
        }
        for (id, request) in snapshotSubscribers {
            let boardSessions = boardSubscribers.contains(id)
            guard changed[boardSessions] == true || id == first else { continue }
            if !request.sendEvent(boardSessions ? whole : older, key: "snapshot") { snapshotSubscribers[id] = nil }
        }
    }

    // MARK: - Commands

    /// Runs an `EnvironmentRequest` with the Host's Config, as the App Window's own Client, then reads, so the
    /// events of what it changed go out before its answer. One with a Request id runs through the Request ledger, as
    /// `muxify --request` does (ADR 0093): a second send gets the first answer and changes nothing.
    func run(_ environmentRequest: EnvironmentRequest, for request: ProtocolIncomingRequest, nonce: String?, boardSessions: Bool) {
        let command = environmentRequest.command
        let reads = command.onlyReads
        let pending = PendingRequest(environmentRequest)
        if pending != nil, command.requestPolicy == .read {
            let failure = Self.requestOnRead(command)
            return request.fail(ProtocolError(.failed, failure.message, topicFailure: failure))
        }
        Task {
            let config: Config
            do { config = try await context.config() } catch {
                return request.fail(ProtocolError(.failed, Self.message(error)))
            }
            let publisher = await self.publisher(nonce: nonce)
            let context = context
            guard reads || request.startMutation() else { return }
            let handle = {
                await Self.background {
                    let service = EnvironmentService(paths: context.paths, server: context.tmux, sessionPaths: config.sessionPaths,
                                                     topics: config.topics, notifications: config.notifications,
                                                     worktreesRoot: config.worktreesRoot, request: pending)
                    let client = nonce.flatMap { Self.ownClient(on: context.tmux, nonce: $0) }
                    return service.handle(environmentRequest, client: client?.tty)
                }
            }
            let response: EnvironmentResponse
            if let pending {
                response = await Self.apply(pending, policy: command.requestPolicy, phrase: command.actionName, paths: context.paths,
                                            log: log, run: handle)
            } else {
                response = await handle()
            }
            if !reads { await readAgain(publisher) }
            if case .failed(let failure) = response {
                request.fail(ProtocolError(.failed, failure.message, topicFailure: failure))
            } else if case .snapshot(let snapshot) = response, !boardSessions {
                request.finish(EnvironmentResponse.snapshot(snapshot.withoutDormantSessions))
            } else {
                request.finish(response)
            }
        }
    }

    /// The refusal of a Request id on a command that changes nothing, as `muxify --request` refuses it on a read.
    static func requestOnRead(_ command: EnvironmentCommand) -> TopicFailure {
        TopicFailure(kind: .requestOnRead, phase: .nothingChanged,
                     message: "A Request id names a change that Muxify applies one time only. \(command.actionName) is not such a change, "
                         + "so it takes no Request id.")
    }

    /// Runs one send of a Request through the ledger. The ledger keeps the response's JSON, which a second send
    /// answers again; a refusal of the ledger is a failure whose kind names it.
    private static func apply(_ pending: PendingRequest, policy: RequestPolicy, phrase: String, paths: MuxifyPaths, log: @escaping (String) -> Void,
                              run: () async -> EnvironmentResponse) async -> EnvironmentResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let reply = try await RequestLedger(paths: paths).apply(pending, policy: policy, phrase: phrase, unrecorded: { error in
                log("muxify server: the ledger could not record the Request \(pending.id): \(error)")
            }) {
                let response = await run()
                let stdout = String(decoding: try encoder.encode(response), as: UTF8.self)
                guard case .failed(let failure) = response else { return (RequestReply(stdout: stdout), true) }
                return (RequestReply(stdout: stdout, stderr: failure.message, exitCode: 1), failure.isRefusal)
            }
            return try JSONDecoder().decode(EnvironmentResponse.self, from: Data(reply.stdout.utf8))
        } catch let refusal as RequestRefusal {
            return .failed(refusal.failure)
        } catch {
            return .failed(TopicFailure(kind: .storeFailed, phase: .changesStarted, message: "Muxify could not read the answer of the Request \(pending.id): \(error)"))
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

    /// New Worktree's start choices, read with git on the Host. It changes nothing.
    func worktreeStarts(_ starts: WorktreeStartsRequest, for request: ProtocolIncomingRequest) {
        Task {
            do {
                let choices = try await Self.background { try WorktreeStartChoice.read(from: starts.from, scripts: LocalScripts()) }
                request.finish(WorktreeStarts(starts: choices))
            } catch {
                request.fail(ProtocolError(.failed, Self.message(error)))
            }
        }
    }

    /// The Mac's rows that wait to move to this Host become the Host's records, each unless the Host has its id or
    /// its path already (ADR 0090).
    func adoptWorktrees(_ adopt: AdoptWorktrees, for request: ProtocolIncomingRequest) {
        guard request.startMutation() else { return }
        let paths = context.paths
        Task {
            do {
                let rows = try await Self.background { try MuxifyWorktreeStore(paths: paths).adopt(adopt.rows) }
                for row in rows where row.result == .skipped {
                    log("muxify server: kept the Mac's Muxify Worktree record \(row.id) where it is: \(row.reason ?? "")")
                }
                request.finish(AdoptedWorktrees(rows: rows))
            } catch {
                request.fail(ProtocolError(.failed, Self.message(error)))
            }
        }
    }

    /// Session Path discovery on the Host's folders, `~` being the Host's home; or the Host's ranked rows, or a Topic's
    /// Add a Session rows, read with the Host's Config, as `muxify session-paths` and `muxify topic session-paths`
    /// answer them. It changes nothing.
    func sessionPaths(_ sessionPaths: SessionPathsRequest, for request: ProtocolIncomingRequest) {
        Task {
            if case .discovery(let roots) = sessionPaths.ask {
                let output = await Self.background { SessionPathDiscovery.output(for: roots) }
                return request.finish(SessionPathsOutput(output: output))
            }
            let config: Config, fromCache: Bool
            do { (config, fromCache) = try await sessionPathConfig() } catch {
                return request.fail(ProtocolError(.failed, Self.message(error)))
            }
            let context = context
            switch sessionPaths.ask {
            case .discovery: return
            case .ranked(let query):
                let result = await Self.background {
                    EnvironmentService(paths: context.paths, server: context.tmux, sessionPaths: config.sessionPaths, topics: config.topics)
                        .rankedSessionPaths(query: query, tiebreak: config.goToPalette.rules.tiebreak, home: context.home)
                }
                switch result {
                case .success(let ranked): request.finish(RankedSessionPathsAnswer(ranked))
                case .failure(let failure): request.fail(ProtocolError(.failed, failure.message, topicFailure: failure))
                }
                // As `muxify session-paths` does after an answer from the cache, so the next answer is up to date.
                let cache = SessionPathCache(file: context.paths.sessionPathCache(remote: nil))
                if fromCache { await Self.background { cache.refresh(config) } }
            case .topic(let topic):
                let result = await Self.background {
                    EnvironmentService(paths: context.paths, server: context.tmux, sessionPaths: config.sessionPaths, topics: config.topics)
                        .sessionPathChoices(for: .topic(.named(topic)))
                        .map { TopicSessionPathsAnswer($0, visits: (try? VisitStore(paths: context.paths).times()) ?? [:]) }
                }
                switch result {
                case .success(let answer): request.finish(answer)
                case .failure(let failure): request.fail(ProtocolError(.failed, failure.message, topicFailure: failure))
                }
            }
        }
    }

    /// The Host's Config with the SessionPaths of the discovery cache, as `muxify session-paths` reads them, and
    /// whether the cache had them. Without them it finds the SessionPaths and saves them.
    private func sessionPathConfig() async throws -> (config: Config, fromCache: Bool) {
        var config = try await context.config()
        let cache = SessionPathCache(file: context.paths.sessionPathCache(remote: nil))
        let found = await Self.background { [config] in cache.sessionPaths(of: config) }
        config.sessionPaths = found.sessionPaths
        return (config, found.fromCache)
    }

    /// Records a visit to a folder on the Host, as `muxify session-paths visit` does, so the Host's next ranking,
    /// the CLI's and the server's alike, puts its Session Path first.
    func visit(_ visit: VisitSessionPath, for request: ProtocolIncomingRequest) {
        Task {
            let config: Config
            do { config = try await sessionPathConfig().config } catch {
                return request.fail(ProtocolError(.failed, Self.message(error)))
            }
            guard let directory = Folder.existingDirectory(visit.folder) else {
                return request.fail(ProtocolError(.failed, "no directory '\(visit.folder)'"))
            }
            guard request.startMutation() else { return }
            let context = context
            let result = await Self.background {
                EnvironmentService(paths: context.paths, server: context.tmux, sessionPaths: config.sessionPaths).recordVisit(opening: directory, at: Date())
            }
            switch result {
            case .success: request.finish()
            case .failure(let failure): request.fail(ProtocolError(.failed, failure.message, topicFailure: failure))
            }
        }
    }

    /// A Window's stored Browser Tabs, read as `muxify browser tabs --window <id> --json` reads them with no Mac
    /// (ADR 0084), so both answer the same JSON. It changes nothing; the queued opens stay for the app.
    func browserTabs(_ tabs: BrowserTabsRequest, for request: ProtocolIncomingRequest) {
        let tmux = context.tmux
        Task {
            let read = await Self.background { () -> [BrowserAgentTab]? in
                (try? tmux.run(StoredBrowser.storedTabsArguments(target: tabs.window))).flatMap(StoredBrowser.agentTabs(listedPanes:))
            }
            guard let read else { return request.fail(ProtocolError(.failed, StoredBrowser.noWindow(tabs.window))) }
            request.finish(read)
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
                await readAgain(publisher)
                request.finish()
            } catch {
                request.fail(ProtocolError(.failed, Self.message(error)))
            }
        }
    }

    /// Runs a view command on the Host's tmux. A command that acts as the App Window's own Client runs only while
    /// the Client marker names that Client. A command that changes tmux reads again before its answer. A switch runs on
    /// the publisher's Listener after its Colour Report, as on the Mac, while a subscriber runs the publisher.
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
                let listener = runningPublisher
                let output = try await Self.background { [own] in
                    try ViewCommandExecutor(ownClient: own, run: { try tmux.run($0) }, switchOnListener: listener?.switchClient).run(command)
                }
                if changes, let publisher = runningPublisher { await readAgain(publisher) }
                request.finish(ViewOutput(output: output))
            } catch {
                request.fail(ProtocolError(.failed, Self.message(error)))
            }
        }
    }

    // MARK: - Helpers

    /// Reads everything again after a write, and returns once the events and the Topic details of what it changed
    /// went out, so they come before the write's answer.
    private func readAgain(_ publisher: EnvironmentPublisher) async {
        await publisher.read()
        await details.caughtUp()
    }

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

/// The server, for its socket's requests, which may come before it is made and after it exits.
private final class ServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProtocolServer?

    var server: ProtocolServer? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
