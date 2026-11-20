import Foundation

/// The producer of the `environment` subscription (ADR 0087): it reads a whole `TmuxSnapshot`
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
/// The Host Server's publisher also reads its Mac's Client marker, so its `server` event names that Mac's own Client,
/// and writes the Sessions that each read gives the Topics onto their records, so the Mac writes no record itself.
///
/// In the app it also writes the Colour Reports of ADR 0095 through its control Client: to each Session that one of
/// Muxify's Clients shows, before each switch that Muxify starts, and before Muxify types into a Session that it made.
/// It sends them and returns at once: nothing waits for tmux's answer, so a switch never waits for a Colour Report.
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
    /// The `@muxify_client_<nonce>` option of the subscriber's own Client, or nil.
    private let clientMarker: String?
    /// The Config's Session order, when each read writes the Topics' remembered Sessions.
    private let rememberingOrder: SessionOrder?
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
    private var ownClient: ViewCommandExecutor.Client?
    private var rememberedServerID: String?
    private var rememberedWindows: [TmuxWindow] = []
    private var colourReports = ColourReportState()
    /// The next read reports to every shown Session, not only to those that it newly finds shown.
    private var reportsAllSessions = true
    private let listener = ListenerCommands()

    private let lock = NSLock()
    // `lock` guards these.
    private var running = false
    private var readQueued = false
    private var news: ((News) -> Void)?
    private var colours: TerminalColours?

    /// The tick of the `data_version` check, and how many ticks make the whole read and, without a control Client,
    /// the look for a server to attach to.
    static let tick: TimeInterval = 0.25
    static let ticksPerWholeRead = 20
    static let ticksPerAttachCheck = 4
    static let notificationDelay: TimeInterval = 0.05
    static let readTimeout: TimeInterval = 5

    /// `startControlClient` starts the control Client; the app passes one on a pty. Events go to the handler on
    /// `delivery`. `clientMarker` names the server option of the subscriber's Client marker, whose Client the
    /// `server` event then carries. With `rememberingOrder`, each read writes the Sessions it gives each Topic onto the
    /// Topic's record (ADR 0080), as an App Window does for the Local Environment.
    public init(server: TmuxServer, topics: TopicStore, delivery: DispatchQueue,
                startControlClient: @escaping TmuxControlClientStart = PipeControlClient.start,
                clientMarker: String? = nil, rememberingOrder: SessionOrder? = nil,
                report: @escaping (String) -> Void = { _ in }) {
        self.server = server
        self.topics = topics
        self.delivery = delivery
        self.startControlClient = startControlClient
        self.clientMarker = clientMarker
        self.rememberingOrder = rememberingOrder
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

    // MARK: - Colour Reports (ADR 0095)

    /// Sets the colours of Muxify's Terminal, and reports them to every Pane of each Session that Muxify's Clients
    /// show. Nil reports nothing, as on a Host. The App Window calls it when it becomes key and when Ghostty's colours
    /// change, so the screen in use writes the report last.
    public func reportColours(_ colours: TerminalColours?) {
        lock.lock()
        self.colours = colours
        lock.unlock()
        queue.async { [self] in
            reportsAllSessions = true
            if handler != nil { readSessions() }
        }
    }

    /// Runs before tmux runs `arguments`: sends the colours' report to every Pane of the Session that each
    /// `switch-client` in them goes to, and returns without waiting for tmux. A report that lands just after the
    /// switch still turns a program to the right look, by the colour-scheme notice that it makes tmux send.
    public func reportColours(beforeRunning arguments: [String]) {
        for target in ColourReport.switchTargets(in: arguments) {
            reportColours(toPanesIn: ["list-panes", "-s", "-t", target, "-F", "#{pane_id}"])
        }
    }

    /// Runs before Muxify types a command into `target`, a Pane of a Session that it just made: reports the colours
    /// to the Pane, without waiting for tmux. No Client shows such a Session yet, so tmux has no other answer for a
    /// program that starts there.
    public func reportColours(beforeTypingInto target: String) {
        reportColours(toPanesIn: ["display-message", "-p", "-t", target, "#{pane_id}"])
    }

    /// `listing` prints one Pane id on each line. Off `queue`, so a read in progress does not hold the report up.
    /// Without a control Client the report waits for the next one, and the caller does not.
    private func reportColours(toPanesIn listing: [String]) {
        lock.lock()
        let colours = self.colours
        lock.unlock()
        guard let colours, let panes = try? run(listing) else { return }
        let lines = ColourReport.commands(panes: panes.split(separator: "\n").map(String.init), colours: colours)
        guard !listener.send(lines, hold: true) else { return }
        // A Session that Muxify just made can be the first user Session, before the control Client joins the Watch
        // Session: that Client takes the report first.
        queue.async { [self] in
            if client == nil, handler != nil { attach() }
        }
    }

    /// Reports the colours to the Sessions that Muxify's Clients show in `snapshot` and that the last read did not
    /// find shown, or to all of them after `reportColours(_:)` or a new control Client.
    private func reportShownSessions(_ snapshot: TmuxSnapshot) {
        lock.lock()
        let colours = self.colours
        lock.unlock()
        guard let colours, snapshot.serverRunning else { return }
        let options = snapshot.clients.contains { !$0.isControl } ? (try? run(["show-options", "-s"])) ?? "" : ""
        let shown = ColourReport.shownSessions(clients: snapshot.clients, serverOptions: options)
        let sessions = colourReports.sessionsToReport(shown: shown, all: reportsAllSessions)
        let windows = Set(snapshot.windows.filter { sessions.contains($0.sessionID) }.map(\.id))
        let panes = snapshot.panes.filter { windows.contains($0.windowID) }.map(\.id)
        // Without a control Client the reports are lost, so the next read sends them all.
        reportsAllSessions = !listener.send(ColourReport.commands(panes: panes, colours: colours))
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
        ownClient = clientMarker.flatMap { marker in
            snapshot.serverRunning ? (try? run(["show-option", "-sqv", marker])).flatMap { ClientMarker.client($0, in: snapshot.clients) } : nil
        }
        let changes = sent.changes(to: snapshot, home: home, ownClient: ownClient, all: !sentSessions)
        sentSessions = true
        sent.apply(changes)
        keepWatchSession(snapshot)
        reportShownSessions(snapshot)
        return changes + (remember(snapshot) ? topicChanges() : [])
    }

    /// Writes the Sessions that `snapshot` gives each Topic onto its record, as `WorkspaceStore` does for the Local
    /// Environment: the last write wins (ADR 0080). True when it wrote.
    private func remember(_ snapshot: TmuxSnapshot) -> Bool {
        guard let order = rememberingOrder else { return false }
        // A Window seen before counts only on the same server: on another, its id may name another Window.
        let continuous = snapshot.serverRunning && snapshot.serverID != nil && snapshot.serverID == rememberedServerID
        let previously = continuous ? rememberedWindows : []
        rememberedServerID = snapshot.serverRunning ? snapshot.serverID : nil
        rememberedWindows = snapshot.windows
        do {
            let updates = try topics.read().records.compactMap { $0.remembering(snapshot, order: order, previously: previously) }
            guard !updates.isEmpty else { return false }
            try topics.write { transaction in
                for record in updates { _ = try transaction.remember(record.sessions, of: record.id) }
            }
            return true
        } catch {
            report("remembering Topics: \(error)")
            return false
        }
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
        // Writing the Client marker makes no notification, so it is looked for until it names a Client.
        let awaitsOwnClient = clientMarker != nil && ownClient == nil && serverRunning && ticks % Self.ticksPerAttachCheck == 0
        if reportsChanged || mayAttach || awaitsOwnClient { readSessions() }
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
            listener.attach(client)
            reportsAllSessions = true
            listener.send(["refresh-client -B '\(Self.subscriptionName)::\(Self.subscriptionFormat)'"])
        } catch {
            report("tmux control client failed to start: \(error)")
            nextAttach = Date().addingTimeInterval(1)
        }
    }

    private func detach() {
        clientNumber += 1
        listener.detach()
        client?.stop()
        client = nil
    }

    private func clientExited(_ number: Int) {
        guard number == clientNumber else { return }
        listener.detach()
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
