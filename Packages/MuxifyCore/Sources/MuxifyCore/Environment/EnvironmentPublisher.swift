import Foundation

/// The producer of the `environment` subscription (ADR draft `09-message-surface`): it reads a whole `TmuxSnapshot`
/// and the Topic records on this machine whenever something may have changed, compares them per key with what it sent
/// last, and sends only the keys that changed. Its first item holds every key. The Host Server runs it on a Host, and
/// the Local Environment's link runs it in the app.
///
/// What makes it read:
/// - the notifications of its control Client, which sits alone in the Watch Session;
/// - one format subscription of that Client that loops over every Session, Window and Pane (tmux 3.2), which tmux
///   checks each second and which sees the changes that have no notification: options, Agent Status, splits, a Pane's
///   program and folder;
/// - `PRAGMA data_version` every 0.25 s, for another connection's writes, and each write made through `write`;
/// - a whole read every 5 s.
///
/// It installs no tmux hook. It keeps the Watch Session's rule: with no user Session left it kills the Watch Session,
/// so the server can exit, and it joins or makes it again once a user Session appears.
///
/// Every read runs on one serial queue, so writes and reads keep the order they were asked in. Events go out on the
/// delivery queue, in that order.
public final class EnvironmentPublisher: @unchecked Sendable {
    public let server: TmuxServer
    public let topics: TopicStore
    private let startControlClient: TmuxControlClientStart
    private let delivery: DispatchQueue
    private let report: (String) -> Void
    private let queue = DispatchQueue(label: "dev.muxify.environment-publisher", qos: .userInitiated)
    private let home = NSHomeDirectory()

    // Only `queue` touches these.
    /// Gets each item, and whether a notification that `news` was told of made its read.
    private var handler: (([EnvironmentChange], Bool) -> Void)?
    private var sent = EnvironmentState()
    private var sentSessions = false
    private var sentTopics = false
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var client: TmuxControlClient?
    /// Tells the current control Client's exit from that of one it replaced.
    private var clientNumber = 0
    private var nextAttach = Date.distantPast
    /// `TopicStore.changeToken` at the last good read of the records.
    private var token: Int?
    private var commandLines = PaneCommandLines()
    private var serverRunning = false
    private var readFailed = false
    private var codexPrefixes: [String] = []
    private var codexReports: [String]?

    private let lock = NSLock()
    // `lock` guards these.
    private var running = false
    private var readQueued = false
    private var news: ((News) -> Void)?

    /// The tick of the `data_version` check, and how many ticks make the whole read and, without a control Client,
    /// the look for a server to attach to.
    static let tick: TimeInterval = 0.25
    static let ticksPerWholeRead = 20
    static let ticksPerAttachCheck = 4
    static let notificationDelay: TimeInterval = 0.05
    static let readTimeout: TimeInterval = 5

    /// `startControlClient` starts the control Client; the app passes one on a pty. Events go to the handler on
    /// `delivery`.
    public init(server: TmuxServer, topics: TopicStore, delivery: DispatchQueue,
                startControlClient: @escaping TmuxControlClientStart = PipeControlClient.start,
                report: @escaping (String) -> Void = { _ in }) {
        self.server = server
        self.topics = topics
        self.delivery = delivery
        self.startControlClient = startControlClient
        self.report = report
    }

    deinit {
        timer?.cancel()
        client?.stop()
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Starts reading and sends every change to `handler`; the first item holds every key.
    public func start(_ handler: @escaping ([EnvironmentChange]) -> Void) {
        start(handler: { changes, _ in handler(changes) }, news: nil)
    }

    /// What an in-process subscriber that reads the server itself hears before the publisher's own read.
    public enum News {
        /// The control Client told of a change, or the server answers again after a failed read: read it now.
        case heard
        /// A read of the server failed, such as one that timed out on a stopped server.
        case readFailed(Error)
    }

    /// `start` for an in-process subscriber that reads the server itself: `news` runs on the delivery queue as soon
    /// as the control Client tells of a change, before the read that the publisher makes for it, and when a read
    /// fails. The handler learns which items a notification's read found, which that subscriber has already read for.
    public func start(news: @escaping (News) -> Void,
                      _ handler: @escaping (_ changes: [EnvironmentChange], _ afterNotification: Bool) -> Void) {
        start(handler: handler, news: news)
    }

    private func start(handler: @escaping ([EnvironmentChange], Bool) -> Void, news: ((News) -> Void)?) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        self.news = news
        lock.unlock()
        queue.async { [self] in
            self.handler = handler
            sent = EnvironmentState()
            sentSessions = false
            sentTopics = false
            readWhole()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.tick, repeating: Self.tick)
            timer.setEventHandler { [weak self] in self?.tickRead() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Stops reading and sending, and ends the control Client.
    public func stop() {
        lock.lock()
        running = false
        news = nil
        lock.unlock()
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            handler = nil
            detach()
        }
    }

    /// Reads the records again; an event follows when they changed. The caller does not wait.
    public func readTopics() {
        queue.async { self.readTopics(then: nil) }
    }

    /// Reads the records again and returns once their events were delivered, after every write asked for before.
    public func topicsRead() async {
        await withCheckedContinuation { continuation in
            queue.async { self.readTopics { continuation.resume() } }
        }
    }

    /// Reads everything again and returns once its events were delivered.
    public func read() async {
        await withCheckedContinuation { continuation in
            queue.async { self.readWhole { continuation.resume() } }
        }
    }

    /// Returns once every read and write asked for before has delivered its events. It reads nothing itself.
    public func caughtUp() async {
        await withCheckedContinuation { continuation in
            queue.async { self.deliver([]) { continuation.resume() } }
        }
    }

    /// Writes the records, then reads them, and returns once the events of what it left were delivered. This
    /// process's own write does not move `data_version` on this connection, so the read after it sends its events.
    @discardableResult
    public func write<T>(locks: [SessionLock] = [], _ body: @escaping (inout TopicTransaction) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let result = Result { try self.topics.write(locks: locks, body) }
                self.readTopics { continuation.resume(with: result) }
            }
        }
    }

    // MARK: - Reads, on `queue`

    private func readWhole(then done: (() -> Void)? = nil) {
        deliver(snapshotChanges() + topicChanges(), then: done)
    }

    private func readSessions(afterNotification: Bool = false) {
        deliver(snapshotChanges(), afterNotification: afterNotification)
    }

    private func readTopics(then done: (() -> Void)?) {
        deliver(topicChanges(), then: done)
    }

    private func snapshotChanges() -> [EnvironmentChange] {
        var snapshot: TmuxSnapshot
        do { snapshot = try server.snapshot(using: run) } catch {
            report("environment: \(error)")
            readFailed = true
            tell(.readFailed(error))
            return []
        }
        if readFailed {
            readFailed = false
            tell(.heard)
        }
        commandLines = commandLines.updating(for: snapshot) {
            try? CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", PaneCommandLines.script]))
        }
        snapshot.commandLines = commandLines
        serverRunning = snapshot.serverRunning
        codexPrefixes = CodexReports.prefixes(in: snapshot)
        codexReports = codexReportFiles()
        let changes = sent.changes(to: snapshot, home: home, all: !sentSessions)
        sentSessions = true
        sent.apply(changes)
        keepWatchSession(snapshot)
        return changes
    }

    private func topicChanges() -> [EnvironmentChange] {
        let token = topics.changeToken()
        let contents: TopicContents
        do { contents = try topics.read() } catch {
            report("topics: \(error)")
            return []
        }
        self.token = token
        let changes = sent.changes(to: contents, all: !sentTopics)
        sentTopics = true
        sent.apply(changes)
        return changes
    }

    private func deliver(_ changes: [EnvironmentChange], afterNotification: Bool = false, then done: (() -> Void)? = nil) {
        let handler = self.handler
        guard !changes.isEmpty || done != nil else { return }
        delivery.async {
            if !changes.isEmpty { handler?(changes, afterNotification) }
            done?()
        }
    }

    private func tell(_ item: News) {
        lock.lock()
        let news = self.news
        lock.unlock()
        if let news { delivery.async { news(item) } }
    }

    /// Runs a tmux command on the server, as `TmuxServer.run` does, but gives up after `readTimeout`: a stopped server
    /// must not hold the queue, and every write behind it, for long.
    private func run(_ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        return try CommandRunner().run(server.invocation(arguments), timeout: Self.readTimeout, environment: environment)
    }

    private func tickRead() {
        guard handler != nil else { return }
        ticks += 1
        if ticks % Self.ticksPerWholeRead == 0 { return readWhole() }
        if topics.changeToken() != token { readTopics(then: nil) }
        let reportsChanged = !codexPrefixes.isEmpty && codexReportFiles() != codexReports
        let mayAttach = client == nil && ticks % Self.ticksPerAttachCheck == 0
            && (serverRunning || FileManager.default.fileExists(atPath: server.socketPath))
        if reportsChanged || mayAttach { readSessions() }
    }

    /// The Codex reports of the snapshot's Codex Panes, by name, time and size: a report that changes has no
    /// notification, so the tick looks for one.
    private func codexReportFiles() -> [String]? {
        guard !codexPrefixes.isEmpty else { return nil }
        let folder = (ProcessInfo.processInfo.environment["HOME"] ?? home) + "/.local/state/muxify/codex"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { name in codexPrefixes.contains { name.hasPrefix($0) } }.sorted().map { name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: folder + "/" + name)
            let time = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(name) \(time) \((attributes?[.size] as? NSNumber)?.intValue ?? 0)"
        }
    }

    // MARK: - The control Client and the Watch Session, on `queue`

    /// No user Session left: the Watch Session goes, so it does not keep the server running. Every control Client in
    /// it exits. A user Session there and no control Client: it joins or makes the Watch Session.
    private func keepWatchSession(_ snapshot: TmuxSnapshot) {
        guard snapshot.serverRunning else { return }
        if snapshot.windows.isEmpty {
            if let watch = snapshot.watchSessionID { _ = try? run(["kill-session", "-t", watch]) }
        } else if client == nil, Date() >= nextAttach {
            attach()
        }
    }

    private func attach() {
        clientNumber += 1
        let number = clientNumber
        var environment = ProcessInfo.processInfo.environment
        // tmux uses the socket in $TMUX before the one in $TMUX_TMPDIR.
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        do {
            let invocation = try server.invocation(["-C", "new-session", "-A", "-s", Tmux.watchSessionName,
                                                    "-f", "no-output,ignore-size", "cat"])
            let client = try startControlClient(invocation, environment, { [weak self] lines in
                if lines.contains(where: Self.isChange) { self?.heardChange() }
            }, { [weak self] in
                self?.queue.async { self?.clientExited(number) }
            })
            self.client = client
            client.send("refresh-client -B '\(Self.subscriptionName)::\(Self.subscriptionFormat)'")
        } catch {
            report("tmux control client failed to start: \(error)")
            nextAttach = Date().addingTimeInterval(1)
        }
    }

    private func detach() {
        clientNumber += 1
        client?.stop()
        client = nil
    }

    private func clientExited(_ number: Int) {
        guard number == clientNumber else { return }
        client = nil
        // A Client that ends on its own (Watch Session killed, server gone) waits a moment before the next start.
        nextAttach = Date().addingTimeInterval(1)
        if handler != nil { readSessions() }
    }

    /// One read for any number of notifications that arrive before it starts. It waits a moment, so a burst of
    /// notifications makes one read, and a subscriber that heard of the change reads tmux before it.
    private func heardChange() {
        lock.lock()
        if let news { delivery.async { news(.heard) } }
        guard !readQueued else { lock.unlock(); return }
        readQueued = true
        lock.unlock()
        queue.asyncAfter(deadline: .now() + Self.notificationDelay) { [self] in
            lock.lock()
            readQueued = false
            lock.unlock()
            if handler != nil { readSessions(afterNotification: true) }
        }
    }

    /// Whether a control Client's line may tell of a change: any notification but a command's reply and Pane output.
    static func isChange(_ line: String) -> Bool {
        guard line.hasPrefix("%") else { return false }
        let kind = line.prefix { $0 != " " }
        return !["%begin", "%end", "%error", "%output", "%extended-output", "%exit"].contains(kind)
    }

    static let subscriptionName = "muxify"

    /// Every field of the snapshot that changes without a notification, over every Session, Window and Pane. No
    /// comma: in `#{W:…}` and `#{P:…}` a second format after a comma is the active item's.
    static let subscriptionFormat: String = {
        let fields = { (names: [String]) in names.map { "#{\($0)}" }.joined(separator: Tmux.separator) }
        let session = fields(["session_id", "session_name", "session_activity", "session_path", "@muxify_topic",
                              "@muxify_lock", "@muxify_session_id"])
        let window = fields(["window_id", "window_index", "window_name", "window_active", "window_panes",
                             "window_bell_flag", "window_layout", "window_zoomed_flag", Tmux.tabsOption,
                             Tmux.activeTabOption, Tmux.shownOption, Tmux.maximizeOption, Tmux.openOption,
                             Tmux.lastWindowOption, Tmux.agentOption])
        let pane = fields(["pane_id", "pane_index", "pane_active", "pane_title", "pane_current_path",
                           "pane_current_command", "pane_tty", Tmux.agentOption, Tmux.agentStatusOption,
                           Tmux.agentUnreadOption, Tmux.agentConversationOption])
        return "#{S:\(session)#{W:\(window)#{P:\(pane)/}|}^}"
    }()
}
