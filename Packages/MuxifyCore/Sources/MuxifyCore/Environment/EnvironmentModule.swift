import Foundation
import Observation

/// Orders Environment writes and publishes observations made after those writes.
@MainActor @Observable
public final class EnvironmentModule {
    public let id: UUID
    public private(set) var revision: EnvironmentRevision
    public private(set) var state: EnvironmentState?
    public private(set) var isWriting = false
    public private(set) var isRetired = false
    private struct Write {
        let requiredPersistence: Bool
        let reader: UUID?
        let run: () -> Void
        let cancel: () -> Void
    }
    @ObservationIgnored private var writes: [Write] = []
    @ObservationIgnored private var retirementCompletions: [() -> Void] = []
    @ObservationIgnored private var activeWrite: UUID?
    @ObservationIgnored private var activeRead: UUID?
    @ObservationIgnored private var readWork: (() -> Void)?
    @ObservationIgnored private var needsRead = false
    @ObservationIgnored private var clientMarkers: Set<UUID> = []
    /// Counts the queued operations that finished or were cancelled, so a read can tell a write from an invalidation.
    @ObservationIgnored private var finishedWrites = 0

    public private(set) var records = TopicContents()
    @ObservationIgnored private let io = DispatchQueue(label: "muxify.environment", qos: .userInitiated)
    @ObservationIgnored private let rules: EnvironmentRules
    @ObservationIgnored private var recordsTimer: DispatchSourceTimer?
    @ObservationIgnored private var pollingRecords = false
    @ObservationIgnored private var closingRules = false
    @ObservationIgnored private var rulesClosed = false
    private let server: any TmuxRunning
    private let paths: MuxifyPaths
    private let topicsAvailable: Bool
    private let scripts: any ScriptRunning
    private let environmentName: String?
    private let attachmentDriver: (any EnvironmentAttachmentDriver)?

    public init(id: UUID = UUID(), paths: MuxifyPaths = MuxifyPaths(), server: any TmuxRunning = TmuxServer.local,
                topicsAvailable: Bool = true, scripts: any ScriptRunning = LocalScripts(), environmentName: String? = nil,
                rulesScope: EnvironmentRulesScope? = nil, ruleSettings: EnvironmentRuleSettings? = nil, attachmentDriver: (any EnvironmentAttachmentDriver)? = nil) {
        self.paths = paths
        self.server = server
        self.topicsAvailable = topicsAvailable
        self.scripts = scripts
        self.environmentName = environmentName
        self.attachmentDriver = attachmentDriver
        self.id = id
        rules = EnvironmentRules(paths: paths, server: server, topicsAvailable: topicsAvailable, scope: rulesScope, settings: ruleSettings)
        revision = EnvironmentRevision(moduleID: id, number: 0)
    }

    public static func withCommand<Value>(paths: MuxifyPaths = MuxifyPaths(), server: any TmuxRunning = TmuxServer.local,
                                          topicsAvailable: Bool = true, _ body: @MainActor (EnvironmentModule) async throws -> Value) async rethrows -> Value {
        let module = EnvironmentModule(paths: paths, server: server, topicsAvailable: topicsAvailable)
        do {
            let value = try await body(module)
            await withCheckedContinuation { continuation in module.retire { continuation.resume() } }
            return value
        } catch {
            await withCheckedContinuation { continuation in module.retire { continuation.resume() } }
            throw error
        }
    }

    public func perform(_ request: EnvironmentRequest, client: String? = nil, sessionPaths: [SessionPath] = [],
                        topics: Config.Topics = Config.Topics(), worktreesRoot: String? = nil) async -> EnvironmentWriteReceipt<EnvironmentResponse> {
        await withCheckedContinuation { continuation in
            perform(request, client: client, sessionPaths: sessionPaths, topics: topics, worktreesRoot: worktreesRoot) { continuation.resume(returning: $0) }
        }
    }

    /// Captures records and Inventory without starting rules or a poll.
    public func readNow() async -> EnvironmentRead {
        await withCheckedContinuation { continuation in
            let cancelled = EnvironmentRead(inventory: .failure(TmuxError.cancelled), records: .failure(TmuxError.cancelled))
            enqueue(requiredPersistence: false, cancelled: cancelled, { finish in
                self.io.async { [rules = self.rules, server = self.server] in
                    let result = rules.readNow(inventory: server.snapshot)
                    DispatchQueue.main.async { finish(result) }
                }
            }, completion: { continuation.resume(returning: $0.value) })
        }
    }

    public func perform(_ request: EnvironmentRequest, client: String? = nil,
                        sessionPaths: [SessionPath] = [], topics: Config.Topics = Config.Topics(), worktreesRoot: String? = nil,
                        preparing browsers: [EnvironmentBrowserState] = [], reader: UUID? = nil,
                        completion: @escaping (EnvironmentWriteReceipt<EnvironmentResponse>) -> Void = { _ in }) {
        let cancelled = EnvironmentResponse.failed(TopicFailure(kind: .cancelled, phase: .nothingChanged,
                                                                message: "The Environment has closed."))
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: sessionPaths, topics: topics,
                                         topicsAvailable: topicsAvailable, scripts: scripts, environmentName: environmentName,
                                         worktreesRoot: worktreesRoot)
        let required: Bool
        if case .runtime(let operation) = request.command { required = operation.requiredPersistence }
        else { required = false }
        enqueue(requiredPersistence: required, reader: reader, cancelled: cancelled, { [self] finish in
            if case .runtime(.registerClient(let marker)) = request.command {
                self.clientMarkers.insert(marker.id)
            }
            Task {
                let response = await withCheckedContinuation { continuation in
                    self.io.async { [rules = self.rules] in
                        do { try rules.flushMemory() }
                        catch {
                            continuation.resume(returning: EnvironmentResponse.failed(service.failure(error, phase: .changesStarted)))
                            return
                        }
                        let response: EnvironmentResponse = {
                            if !browsers.isEmpty {
                                let preparation = service.handle(EnvironmentRequest(.runtime(.browser(browsers))))
                                if case .failed = preparation { return preparation }
                            }
                            var response = service.handle(request, client: client)
                            if !browsers.isEmpty, case .failed(var failure) = response, failure.phase == .nothingChanged {
                                failure.phase = .changesStarted
                                response = .failed(failure)
                            }
                            return response
                        }()
                        if rules.scope != nil { _ = try? rules.records(force: true) }
                        continuation.resume(returning: response)
                    }
                }
                if case .runtime(.removeClient(let id)) = request.command, case .changed = response {
                    self.clientMarkers.remove(id)
                }
                if case .runtime(.attach(let plan)) = request.command, case .changed = response {
                    guard !self.isRetired, let driver = self.attachmentDriver else {
                        finish(.failed(TopicFailure(kind: .cancelled, phase: .changesStarted, message: "The Terminal cannot attach.")))
                        return
                    }
                    driver.attach(plan) { result in
                        switch result {
                        case .success: finish(response)
                        case .failure(let error):
                            let kind: TopicFailure.Kind = (error as? TmuxError) == .cancelled ? .cancelled : .tmuxFailed
                            finish(.failed(TopicFailure(kind: kind, phase: .changesStarted, message: String(describing: error))))
                        }
                    }
                } else { finish(response) }
            }
        }, completion: completion)
    }

    deinit { recordsTimer?.cancel() }

    public func updateRules(settings: EnvironmentRuleSettings, viewing: EnvironmentViewing, reader: UUID? = nil) {
        guard !isRetired else { return }
        rules.updateInput(settings: settings, viewing: viewing, reader: reader ?? id)
    }

    public func removeReader(_ reader: UUID) { rules.removeReader(reader) }

    public func retireReader(_ reader: UUID, completion: @escaping () -> Void) {
        rules.removeReader(reader)
        let cancelled = writes.filter { $0.reader == reader && !$0.requiredPersistence }
        writes.removeAll { $0.reader == reader && !$0.requiredPersistence }
        for write in cancelled { write.cancel() }
        write(requiredPersistence: true, { finish in finish(()) }, completion: { _ in completion() })
    }

    func query(_ query: EnvironmentQuery, sessionPaths: [SessionPath], topics: Config.Topics,
               completion: @escaping (EnvironmentQueryResponse) -> Void) {
        let service = EnvironmentService(paths: paths, server: server, sessionPaths: sessionPaths, topics: topics,
                                         topicsAvailable: topicsAvailable, scripts: scripts, environmentName: environmentName)
        let cancelled = EnvironmentQueryResponse.failed(TopicFailure(kind: .cancelled, phase: .nothingChanged,
                                                                     message: "The Environment has closed."))
        enqueue(requiredPersistence: false, cancelled: cancelled, { finish in
            self.io.async {
                let response = service.answer(query)
                DispatchQueue.main.async { finish(response) }
            }
        }, completion: { completion($0.value) })
    }

    /// The module owns records and rules. The transport supplies a fresh Inventory, including command lines.
    public func read<Context>(context: @escaping () -> Context,
                              inventory: @escaping () throws -> TmuxSnapshot,
                              receive: @escaping (EnvironmentState, Context) -> Void) {
        guard !isRetired else { return }
        refresh({ [weak self] finish in
            guard let self else { return }
            let context = context()
            self.io.async { [rules = self.rules, topicsAvailable = self.topicsAvailable] in
                var result = rules.read(inventory: inventory)
                result.ruleSettings = rules.lease?.effectiveSettings() ?? rules.settings
                result.ownsRules = rules.lease?.ownsRules == true
                result.ruleFailure = rules.lastFailure
                result.branches = rules.branches
                if topicsAvailable, case .success(let records) = result.records {
                    result.existingWorktrees = Set(records.records.flatMap { TopicReopening.existingWorktrees(of: $0) }).sorted()
                }
                DispatchQueue.main.async { finish(result, context) }
            }
        }, receive: receive)
        if recordsTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in self?.pollRecords() }
            timer.resume()
            recordsTimer = timer
        }
    }

    public func reloadRecords() {
        guard topicsAvailable, !isRetired else { return }
        invalidateRead()
        if readWork != nil { needsRead = true; drain() }
        else { read(context: { () }, inventory: { [server] in try server.snapshot() }, receive: { _, _ in }) }
    }

    private func pollRecords() {
        guard !isRetired, !pollingRecords, readWork != nil else { return }
        pollingRecords = true
        io.async { [rules] in
            let changed = rules.needsPoll
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pollingRecords = false
                if changed, !self.isRetired { self.needsRead = true; self.drain() }
            }
        }
    }

    public func queries(sessionPaths: [SessionPath] = [], topics: Config.Topics = Config.Topics()) -> EnvironmentQueries {
        EnvironmentQueries { query in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    self.query(query, sessionPaths: sessionPaths, topics: topics) { continuation.resume(returning: $0) }
                }
            }
        }
    }

    public var isReady: Bool {
        !isRetired && !isWriting && state?.revision == revision && state?.isConfirmed == true
    }

    /// The driver does I/O outside the main actor and calls back on the main actor.
    public func refresh<Context>(
        _ operation: @escaping (@escaping (EnvironmentRead, Context) -> Void) -> Void,
        receive: @escaping (EnvironmentState, Context) -> Void
    ) {
        guard !isRetired else { return }
        readWork = { [weak self] in
            guard let self else { return }
            let token = UUID()
            let started = self.revision
            let writes = self.finishedWrites
            self.activeRead = token
            operation { [weak self] result, context in
                guard let self, !self.isRetired, self.activeRead == token else { return }
                self.activeRead = nil
                if self.revision == started, !self.isWriting {
                    let state = self.publish(result)
                    receive(state, context)
                } else if !self.isWriting, self.finishedWrites == writes, case .failure = result.inventory {
                    // Old data must not confirm a newer revision, but a failed Inventory read that only an invalidation
                    // made old is still true: tmux did not answer. Show it now, and read again, so a hung server is not
                    // hidden behind a second timeout. After a write, the failure may predate the change, so it waits.
                    let state = self.publish(result)
                    receive(state, context)
                    self.needsRead = true
                } else {
                    self.needsRead = true
                }
                self.drain()
            }
        }
        needsRead = true
        drain()
    }

    /// Completion is delivered before any post-write read can publish, including reentrant writes.
    func write<Value>(
        requiredPersistence: Bool = false,
        _ operation: @escaping (@escaping (Value) -> Void) -> Void,
        completion: @escaping (EnvironmentWriteReceipt<Value>) -> Void = { _ in }
    ) {
        enqueue(requiredPersistence: requiredPersistence, cancelled: nil, operation, completion: completion)
    }

    private func enqueue<Value>(requiredPersistence: Bool, reader: UUID? = nil, cancelled: Value?,
                                _ operation: @escaping (@escaping (Value) -> Void) -> Void,
                                completion: @escaping (EnvironmentWriteReceipt<Value>) -> Void) {
        let cancel = { [self] in
            guard let cancelled else { return }
            finishedWrites += 1
            advance()
            completion(EnvironmentWriteReceipt(revision: revision, value: cancelled))
        }
        guard !isRetired else { cancel(); return }
        advance()
        isWriting = true
        writes.append(Write(requiredPersistence: requiredPersistence, reader: reader, run: { [weak self] in
            guard let self else { return }
            let token = UUID()
            self.activeWrite = token
            var completed = false
            operation { [self] value in
                guard !completed, self.activeWrite == token else { return }
                completed = true
                self.finishedWrites += 1
                self.advance()
                if !self.isRetired || cancelled != nil {
                    completion(EnvironmentWriteReceipt(revision: self.revision, value: value))
                }
                self.activeWrite = nil
                self.isWriting = !self.writes.isEmpty
                self.needsRead = self.readWork != nil
                self.drain()
            }
        }, cancel: cancel))
        drain()
    }

    /// Final Remote data has no capture revision, so it can be displayed but cannot confirm a write.
    public func finishReading(lastKnownInventory: TmuxSnapshot? = nil) -> EnvironmentState? {
        guard !isRetired else { return nil }
        activeRead = nil
        readWork = nil
        needsRead = false
        recordsTimer?.cancel()
        recordsTimer = nil
        io.async { [rules] in rules.close() }
        advance()
        let failure = EnvironmentFailure.inventory(.connectionLost)
        let final = EnvironmentState(revision: revision,
            inventory: .unavailable(lastKnown: state?.inventory.lastKnown ?? lastKnownInventory, failure: failure),
            records: state?.records ?? .unavailable(lastKnown: nil, failure: failure))
        state = final
        return final
    }

    public func invalidateRead() {
        guard !isRetired else { return }
        advance()
    }

    /// Retirement returns cancellation receipts and drains admitted record and Browser saves before cleanup.
    public func retire(completion: @escaping () -> Void = {}) {
        if !isRetired {
            for id in clientMarkers {
                perform(EnvironmentRequest(.runtime(.removeClient(id)))) { receipt in
                    if case .failed(let failure) = receipt.value {
                        NSLog("Client marker cleanup failed: %@", failure.message)
                    }
                }
            }
        }
        recordsTimer?.cancel()
        recordsTimer = nil
        isRetired = true
        retirementCompletions.append(completion)
        let cancelled = writes.filter { !$0.requiredPersistence }
        writes.removeAll { !$0.requiredPersistence }
        for write in cancelled { write.cancel() }
        activeRead = nil
        readWork = nil
        needsRead = false
        isWriting = activeWrite != nil || !writes.isEmpty
        drain()
    }

    private func drain() {
        guard activeWrite == nil else { return }
        if !writes.isEmpty {
            let work = writes.removeFirst()
            work.run()
        } else if isRetired {
            if rules.scope != nil, !rulesClosed {
                guard !closingRules else { return }
                closingRules = true
                io.async { [rules] in
                    do { try rules.flushMemory() }
                    catch { NSLog("muxify: final Topic memory: %@", String(describing: error)) }
                    rules.close()
                    DispatchQueue.main.async { [self] in rulesClosed = true; drain() }
                }
                return
            }
            let completions = retirementCompletions
            retirementCompletions.removeAll()
            for completion in completions { completion() }
        } else if activeRead == nil, needsRead, let readWork {
            needsRead = false
            readWork()
        }
    }

    private func advance() {
        revision = EnvironmentRevision(moduleID: id, number: revision.number + 1)
    }

    private func publish(_ result: EnvironmentRead) -> EnvironmentState {
        advance()
        let next = EnvironmentState(revision: revision,
                                    inventory: observation(result.inventory, previous: state?.inventory),
                                    records: observation(result.records, previous: state?.records),
                                    ruleSettings: result.ruleSettings, ownsRules: result.ownsRules,
                                    ruleFailure: result.ruleFailure, branches: result.branches, existingWorktrees: result.existingWorktrees)
        if let current = next.records.current { records = current }
        state = next
        return next
    }

    private func observation<Value>(_ result: Result<Value, Error>, previous: EnvironmentObservation<Value>?) -> EnvironmentObservation<Value> {
        switch result {
        case .success(let value): return .current(value)
        case .failure(let error): return .unavailable(lastKnown: previous?.lastKnown, failure: EnvironmentFailure(error))
        }
    }
}
