import Foundation

public struct EnvironmentRuleSettings: Codable, Equatable, Sendable {
    public var manualRead: Bool
    public var sessionOrder: SessionOrder
    public var insertPosition: TopicInsertPosition
    public var inPlay: Int?

    public init(config: Config) {
        manualRead = config.notifications.manualRead
        sessionOrder = config.topics.sessionOrder
        insertPosition = config.topics.insertPosition
        inPlay = config.topics.inPlay
    }

    /// Where the record upgrade puts each Topic that an older Muxify had Snoozed.
    var arrival: TopicArrival { TopicArrival(inPlay: inPlay, insertPosition: insertPosition) }
}

/// Runs only on the module's I/O queue, which also runs Perform. The lease excludes other rule writers.
final class EnvironmentRules: @unchecked Sendable {
    struct PendingMemory {
        var sessions: [JSONValue]
        var expected: [JSONValue]
        var due: Date
    }
    let store: TopicStore
    let server: any TmuxRunning
    let topicsAvailable: Bool
    let scope: EnvironmentRulesScope?
    var lease: EnvironmentRulesLease?
    /// A command module never runs rules, so it never reads Config.
    lazy var settings: EnvironmentRuleSettings = {
        inputLock.lock()
        defer { inputLock.unlock() }
        return inputSettings
    }()
    private let inputLock = NSLock()
    private lazy var inputSettings = EnvironmentRuleSettings(config:
        (try? Config.load(path: store.paths.configFile.path, read: { try? String(contentsOfFile: $0, encoding: .utf8) }).get()) ?? Config())
    private var inputViewing: [UUID: EnvironmentViewing] = [:]
    private var readerLeases: [UUID: EnvironmentRulesLease] = [:]
    private var readerSnapshot: TmuxSnapshot?
    private var readerDirectory: URL?
    var previous: TmuxSnapshot?
    var pending: [String: PendingMemory] = [:]
    var stamp = ""
    var contents = TopicContents()
    var lastFailure: EnvironmentFailure?
    var branches = TopicBranches()
    var nextRead = Date.distantPast

    init(paths: MuxifyPaths, server: any TmuxRunning, topicsAvailable: Bool, scope: EnvironmentRulesScope?, settings: EnvironmentRuleSettings?) {
        self.store = TopicStore(paths: paths)
        self.server = server
        self.topicsAvailable = topicsAvailable
        self.scope = scope
        if let settings {
            self.settings = settings
            inputSettings = settings
        }
    }

    func records(force: Bool = false) throws -> TopicContents {
        guard topicsAvailable else { return TopicContents() }
        let next = store.stamp()
        if force || next != stamp {
            contents = try store.read()
            stamp = next
        }
        return contents
    }

    var needsPoll: Bool {
        (scope != nil && Date() >= nextRead) || (topicsAvailable && (store.stamp() != stamp || pending.values.contains { $0.due <= Date() }))
    }

    func updateInput(settings: EnvironmentRuleSettings, viewing: EnvironmentViewing, reader: UUID) {
        inputLock.lock()
        defer { inputLock.unlock() }
        inputSettings = settings
        inputViewing[reader] = viewing
        do { try updateReader(reader, viewing: viewing) }
        catch { NSLog("muxify: viewing facts: %@", String(describing: error)) }
    }

    func removeReader(_ reader: UUID) {
        inputLock.lock()
        defer { inputLock.unlock() }
        inputViewing[reader] = nil
        readerLeases[reader] = nil
    }

    private func updateReader(_ id: UUID, viewing: EnvironmentViewing) throws {
        if readerLeases[id] == nil, let directory = readerDirectory {
            readerLeases[id] = try EnvironmentRulesLease(directory: directory)
        }
        try readerLeases[id]?.update(viewing, serverID: readerSnapshot?.serverID,
            clientPID: readerSnapshot?.clients.first { $0.tty == viewing.client }?.pid)
    }

    private func acceptInput(snapshot: TmuxSnapshot) throws {
        inputLock.lock()
        defer { inputLock.unlock() }
        settings = inputSettings
        readerDirectory = lease?.directory
        // Keep the prior server identity until a subsequent read confirms the Client again.
        for (id, viewing) in inputViewing { try updateReader(id, viewing: viewing) }
        readerSnapshot = snapshot
    }

    /// A command reads without the edit lock, because an edit holds that lock for its whole length.
    /// Records still come from the record lock. A missing state directory reads as no Topics and is not created.
    func readNow(inventory: () throws -> TmuxSnapshot) -> EnvironmentRead {
        let snapshot = Result { try inventory() }
        guard topicsAvailable, FileManager.default.fileExists(atPath: store.paths.state.path) else {
            return EnvironmentRead(inventory: snapshot, records: .success(TopicContents()))
        }
        return EnvironmentRead(inventory: snapshot, records: Result { try records(force: true) })
    }

    func read(inventory: () throws -> TmuxSnapshot) -> EnvironmentRead {
        defer { nextRead = Date().addingTimeInterval(1) }
        lastFailure = nil
        func capture() -> (Result<TopicContents, Error>, Result<TmuxSnapshot, Error>) {
            let records = Result { try self.records() }
            return (records, Result { try inventory() })
        }
        var recordResult: Result<TopicContents, Error>
        var inventoryResult: Result<TmuxSnapshot, Error>
        do {
            (recordResult, inventoryResult) = try topicsAvailable
                ? FileLock.withLock(store.paths.editLock, .shared, rank: .edit, timeout: 10, capture)
                : capture()
        } catch {
            recordResult = .failure(error)
            inventoryResult = .failure(error)
        }
        var attemptedRules = false
        do {
            guard let scope else { return EnvironmentRead(inventory: inventoryResult, records: recordResult) }
            let snapshot = try inventoryResult.get()
            let records = try recordResult.get()
            branches = topicsAvailable ? TopicBranches(records: records.records,
                paths: (snapshot.windows.map(\.sessionPath) + snapshot.panes.map(\.path)).map(Folder.local)) {
                    try? String(contentsOfFile: $0, encoding: .utf8)
                } : TopicBranches()
            if lease == nil { lease = try EnvironmentRulesLease(directory: scope.directory(server: server)) }
            try acceptInput(snapshot: snapshot)
            guard try lease?.acquire(settings: settings) == true else {
                previous = snapshot
                return EnvironmentRead(inventory: inventoryResult, records: recordResult)
            }
            let now = Date()
            let continuous = snapshot.serverRunning && previous?.serverID != nil && snapshot.serverID == previous?.serverID
            let viewed = try lease?.viewed(in: snapshot) ?? []
            var changed = false
            if snapshot.serverRunning, let serverID = snapshot.serverID {
                for pane in snapshot.panes {
                    let prior: String? = pane.agentSeenStatus.isEmpty ? nil : (pane.agentSeenStatus == "~" ? "" : pane.agentSeenStatus)
                    let unread = AgentUnread.change(for: pane, previousStatus: prior,
                        reading: viewed.contains(pane.id) ? .viewing : .away, manualRead: settings.manualRead)
                    let seen = pane.agentStatus.isEmpty ? "~" : pane.agentStatus
                    if unread != nil || pane.agentSeenStatus != seen,
                       let command = AgentUnread.ruleCommand(pane, unread: unread ?? pane.unread, serverID: serverID) {
                        attemptedRules = true
                        try server.run(command)
                        changed = true
                    }
                }
            }
            if topicsAvailable {
                for record in records.records {
                    var current = record
                    if let memory = pending[record.id], memory.expected == record.sessions { current.sessions = memory.sessions }
                    else { pending[record.id] = nil }
                    if let updated = current.remembering(snapshot, order: settings.sessionOrder, branches: branches,
                                                         previously: continuous ? previous?.windows ?? [] : []) {
                        pending[record.id] = PendingMemory(sessions: updated.sessions, expected: record.sessions, due: now.addingTimeInterval(0.3))
                    }
                }
                attemptedRules = true
                try flushMemory(due: now)
                if records.needsUpgrade {
                    let moved = try store.upgrade(locks: SessionLock.locks(in: snapshot.windows, records: records.records), arrival: settings.arrival)
                    for lock in moved { try server.run(lock.command) }
                    changed = changed || !moved.isEmpty
                }
                recordResult = Result { try self.records() }
            }
            previous = snapshot
            if changed { inventoryResult = Result { try inventory() } }
        } catch {
            previous = nil
            inputLock.lock()
            readerSnapshot = nil
            for (id, viewing) in inputViewing { try? readerLeases[id]?.update(viewing, serverID: nil, clientPID: nil) }
            inputLock.unlock()
            lastFailure = EnvironmentFailure(error)
            if attemptedRules { inventoryResult = Result { try inventory() } }
            recordResult = Result { try records(force: true) }
        }
        return EnvironmentRead(inventory: inventoryResult, records: recordResult)
    }

    func flushMemory(due: Date = .distantFuture) throws {
        guard topicsAvailable, lease?.ownsRules == true, !pending.isEmpty else { return }
        try FileLock.withLock(store.paths.editLock, .shared, rank: .edit, timeout: 10) {
            for (id, memory) in pending where memory.due <= due {
                try store.write { transaction in
                    guard let record = transaction.records.first(where: { $0.id == id && $0.settledAt == nil }), record.sessions == memory.expected else { return }
                    try transaction.update(id) { $0.sessions = memory.sessions }
                }
                pending[id] = nil
            }
        }
    }

    func close() {
        inputLock.lock()
        readerLeases.removeAll()
        readerDirectory = nil
        readerSnapshot = nil
        inputLock.unlock()
        previous = nil
        pending.removeAll()
        lease = nil
    }
}
