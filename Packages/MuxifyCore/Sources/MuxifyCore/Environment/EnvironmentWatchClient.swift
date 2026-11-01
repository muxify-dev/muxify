import Foundation
import Darwin
import Observation

@MainActor @Observable public final class EnvironmentWatchClient {
    public private(set) var state: EnvironmentState?
    public private(set) var isConnected = false
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private let writing = DispatchQueue(label: "muxify.watch.client.output")
    @ObservationIgnored private let invocation: CommandInvocation?
    @ObservationIgnored private let fallback: (server: any TmuxRunning, scope: EnvironmentRulesScope, scripts: any ScriptRunning,
                                               environmentName: String?, commandLines: @Sendable () -> String?)?
    @ObservationIgnored private var embeddedWatch: EnvironmentWatch?
    @ObservationIgnored private var launchActive = false
    @ObservationIgnored private var settings: EnvironmentRuleSettings
    @ObservationIgnored private var started = false
    @ObservationIgnored private var token = UUID()
    @ObservationIgnored private var readers: [UUID: WeakReader] = [:]
    @ObservationIgnored private var viewing: [UUID: EnvironmentViewing] = [:]
    @ObservationIgnored private var performs: [UUID: (EnvironmentWriteReceipt<EnvironmentResponse>) -> Void] = [:]
    @ObservationIgnored private var queries: [UUID: (EnvironmentQueryResponse) -> Void] = [:]
    @ObservationIgnored private var closes: [UUID: () -> Void] = [:]
    @ObservationIgnored private var completions: [() -> Void] = []
    @ObservationIgnored private var closingReaders: Set<UUID> = []
    @ObservationIgnored private var waitingForFull = false
    @ObservationIgnored private var moduleID: UUID?

    private struct WeakReader { weak var value: EnvironmentReader? }

    public init(executable: URL, socketPath: String, configPath: String? = nil, settings: EnvironmentRuleSettings) {
        invocation = CommandInvocation(executable: executable.path, arguments: ["environment", "watch", "--socket", socketPath] + (configPath.map { ["--tmux-config", $0] } ?? []))
        fallback = nil
        self.settings = settings
    }

    public init(invocation: CommandInvocation, settings: EnvironmentRuleSettings) {
        self.invocation = invocation
        fallback = nil
        self.settings = settings
    }

    /// `scripts` runs the Muxify Worktree scripts on the Remote machine, and `environmentName` names it in their records.
    public init(fallback server: any TmuxRunning, rulesScope: EnvironmentRulesScope, settings: EnvironmentRuleSettings,
                scripts: any ScriptRunning = LocalScripts(), environmentName: String? = nil,
                commandLines: @escaping @Sendable () -> String? = { nil }) {
        invocation = nil
        fallback = (server, rulesScope, scripts, environmentName, commandLines)
        self.settings = settings
    }

    public func start() {
        guard !started else { return }
        started = true
        launch()
    }

    public func updateSettings(_ settings: EnvironmentRuleSettings) {
        guard self.settings != settings else { return }
        self.settings = settings
        if isConnected { send(.settings(settings)) }
    }

    func register(_ reader: EnvironmentReader) {
        readers[reader.id] = WeakReader(value: reader)
        viewing[reader.id] = EnvironmentViewing()
        if isConnected { send(.viewing(reader: reader.id, facts: EnvironmentViewing())) }
        if let state { reader.accept(state) }
    }

    func updateViewing(reader: UUID, facts: EnvironmentViewing) {
        guard !closingReaders.contains(reader) else { return }
        guard viewing[reader] != facts else { return }
        viewing[reader] = facts
        if isConnected {
            send(.viewing(reader: reader, facts: facts))
            synchronize(reader: reader)
        }
    }

    func read() { if isConnected { send(.read) } }

    func synchronize(reader: UUID) {
        guard isConnected else { return }
        readers[reader]?.value?.awaitSynchronization()
        send(.synchronize(reader: reader))
    }

    func perform(reader: UUID, request: EnvironmentRequest, client: String?, sessionPaths: [SessionPath],
                 topics: Config.Topics, worktreesRoot: String?, browsers: [EnvironmentBrowserState],
                 completion: @escaping (EnvironmentWriteReceipt<EnvironmentResponse>) -> Void) {
        guard isConnected, !closingReaders.contains(reader) else { completion(failureReceipt()); return }
        let id = UUID()
        performs[id] = completion
        send(.perform(id: id, reader: reader, request: request, client: client, sessionPaths: sessionPaths,
                      topics: EnvironmentTopicSettings(topics), worktreesRoot: worktreesRoot, browsers: browsers))
    }

    public func queries(sessionPaths: [SessionPath], topics: Config.Topics) -> EnvironmentQueries {
        EnvironmentQueries { [weak self] query in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let self, self.isConnected else {
                        continuation.resume(returning: .failed(Self.disconnectedFailure)); return
                    }
                    let id = UUID()
                    self.queries[id] = { continuation.resume(returning: $0) }
                    self.send(.query(id: id, query: query, sessionPaths: sessionPaths, topics: EnvironmentTopicSettings(topics)))
                }
            }
        }
    }

    func close(reader: UUID, completion: @escaping () -> Void) {
        viewing[reader] = nil
        closingReaders.insert(reader)
        guard isConnected else {
            readers[reader] = nil
            closingReaders.remove(reader)
            completion()
            return
        }
        let id = UUID()
        closes[id] = { [weak self] in
            self?.readers[reader] = nil
            self?.closingReaders.remove(reader)
            completion()
        }
        send(.close(reader: reader, id: id))
    }

    public func stop(completion: @escaping () -> Void) {
        started = false
        completions.append(completion)
        guard let input else {
            if !launchActive { finishStop() }
            return
        }
        self.input = nil
        writing.async { try? input.close() }
    }

    private func launch() {
        guard started, !launchActive else { return }
        let stdin = Pipe(), stdout = Pipe()
        let token = UUID()
        self.token = token
        do {
            if let fallback {
                let watch = EnvironmentWatch(server: fallback.server, output: stdout.fileHandleForWriting,
                    rulesScope: fallback.scope, topicsAvailable: false, scripts: fallback.scripts,
                    environmentName: fallback.environmentName, commandLines: fallback.commandLines) {
                    try? stdout.fileHandleForWriting.close()
                }
                embeddedWatch = watch
                EnvironmentWatchLines.read(from: stdin.fileHandleForReading, as: EnvironmentWatchInput.self,
                    receive: { result in DispatchQueue.main.async {
                        switch result {
                        case .success(let message): watch.receive(message)
                        case .failure: watch.close()
                        }
                    } }, ended: { DispatchQueue.main.async { watch.close() } })
            } else if let invocation {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: invocation.executable)
                process.arguments = invocation.arguments
                var environment = ProcessInfo.processInfo.environment
                environment["TMUX"] = nil
                environment["TMUX_PANE"] = nil
                process.environment = environment
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = FileHandle.standardError
                try process.run()
                self.process = process
            }
            launchActive = true
            input = stdin.fileHandleForWriting
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            EnvironmentWatchLines.read(from: stdout.fileHandleForReading, as: EnvironmentWatchOutput.self,
                receive: { [weak self] result in DispatchQueue.main.async {
                    guard let self, self.token == token else { return }
                    switch result {
                    case .success(let output): self.receive(output)
                    case .failure: self.breakConnection()
                    }
                } }, ended: { [weak self] in DispatchQueue.main.async {
                    guard let self, self.token == token else { return }
                    if self.process?.isRunning == true { self.process?.terminate() }
                    self.disconnected(token: token)
                } })
            send(.hello(version: EnvironmentWatchProtocol.version, settings: settings))
        } catch {
            disconnected(token: token)
        }
    }

    private func receive(_ output: EnvironmentWatchOutput) {
        switch output {
        case .hello(let version, let moduleID):
            guard version == EnvironmentWatchProtocol.version, self.moduleID == nil else { breakConnection(); return }
            self.moduleID = moduleID
            isConnected = true
            waitingForFull = true
            send(.settings(settings))
            for (reader, facts) in viewing { send(.viewing(reader: reader, facts: facts)) }
            for reader in readers.values { reader.value?.restoreOwnership() }
            send(.full)
        case .full(let next):
            guard next.revision.moduleID == moduleID else { breakConnection(); return }
            waitingForFull = false
            publish(next)
        case .delta(let change):
            guard !waitingForFull, let state, let next = change.applying(to: state) else {
                if !waitingForFull { waitingForFull = true; send(.full) }
                return
            }
            publish(next)
        case .performed(let id, let receipt): performs.removeValue(forKey: id)?(receipt)
        case .queried(let id, let result): queries.removeValue(forKey: id)?(result)
        case .closed(let id): closes.removeValue(forKey: id)?()
        case .synchronized(let reader, let revision): readers[reader]?.value?.synchronized(revision)
        case .attach(let id, let reader, let plan):
            guard let target = readers[reader]?.value, !closingReaders.contains(reader) else {
                send(.attached(id: id, failure: .tmux(.cancelled))); return
            }
            let token = token
            target.attach(plan) { [weak self] result in
                guard let self, self.token == token else { return }
                self.send(.attached(id: id, failure: result.failure.map(EnvironmentFailure.init)))
            }
        case .rejected(let refusal):
            if refusal == .incompatibleVersion { started = false }
            isConnected = false
            if let input {
                self.input = nil
                writing.async { try? input.close() }
            }
        }
    }

    private func publish(_ state: EnvironmentState) {
        self.state = state
        for reader in readers.values { reader.value?.accept(state) }
    }

    private func send(_ message: EnvironmentWatchInput) {
        guard let input, let data = try? JSONEncoder().encode(message) else { return }
        let token = token
        writing.async { [weak self] in
            do { try input.write(contentsOf: data + Data([10])) }
            catch { Task { @MainActor in
                guard let self, self.token == token else { return }
                self.breakConnection()
            } }
        }
    }

    private func breakConnection() {
        if let embeddedWatch { embeddedWatch.close() }
        else if process?.isRunning == true { process?.terminate() }
        else { disconnected(token: token) }
    }

    private func disconnected(token: UUID) {
        guard self.token == token else { return }
        self.token = UUID()
        isConnected = false
        moduleID = nil
        let failure = failureReceipt()
        state = nil
        input = nil
        process = nil
        embeddedWatch = nil
        launchActive = false
        let performs = self.performs, queries = self.queries, closes = self.closes
        self.performs.removeAll()
        self.queries.removeAll()
        self.closes.removeAll()
        for reader in readers.values { reader.value?.disconnected() }
        performs.values.forEach { $0(failure) }
        queries.values.forEach { $0(.failed(Self.disconnectedFailure)) }
        closes.values.forEach { $0() }
        if started {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.launch()
            }
        } else { finishStop() }
    }

    private static var disconnectedFailure: TopicFailure {
        TopicFailure(kind: .cancelled, phase: .changesStarted, message: "The Environment connection was lost. Check its state before trying again.")
    }

    private func failureReceipt() -> EnvironmentWriteReceipt<EnvironmentResponse> {
        EnvironmentWriteReceipt(revision: state?.revision ?? EnvironmentRevision(moduleID: token, number: 0),
                                value: .failed(Self.disconnectedFailure))
    }

    private func finishStop() {
        let finished = completions
        completions.removeAll()
        finished.forEach { $0() }
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
