import Foundation
import Darwin

/// Owns one module until stdin closes. Readers own facts and attachment drivers, never the rules lease.
@MainActor public final class EnvironmentWatch: EnvironmentAttachmentDriver {
    private let server: any TmuxRunning
    private let controlServer: TmuxServer?
    private let rulesScope: EnvironmentRulesScope
    private let topicsAvailable: Bool
    private let scripts: any ScriptRunning
    private let environmentName: String?
    private let readCommandLines: @Sendable () -> String?
    private let paths: MuxifyPaths
    private var module: EnvironmentModule?
    private var settings: EnvironmentRuleSettings?
    private var readers: Set<UUID> = []
    private var attachments: [(id: UUID, reader: UUID)] = []
    private var attaching: (id: UUID, reader: UUID, finish: (Result<Void, Error>) -> Void)?
    private var pendingRequests = 0
    private var closing = false
    private var commandLines = PaneCommandLines()
    private var control: Process?
    private var controlInput: Pipe?
    private var controlToken = UUID()
    private var nextControlStart = Date.distantPast
    private var output: EnvironmentWatchOutputWriter!
    private let finished: () -> Void

    public init(server: any TmuxRunning, paths: MuxifyPaths = MuxifyPaths(), output: FileHandle = .standardOutput,
                rulesScope: EnvironmentRulesScope? = nil, topicsAvailable: Bool = true, scripts: any ScriptRunning = LocalScripts(),
                environmentName: String? = nil, controlServer: TmuxServer? = nil,
                commandLines: (@Sendable () -> String?)? = nil,
                finished: @escaping () -> Void) {
        self.server = server
        self.controlServer = controlServer ?? (server as? TmuxServer)
        self.rulesScope = rulesScope ?? .local(socketPath: (server as? TmuxServer)?.socketPath ?? TmuxServer.local.socketPath)
        self.topicsAvailable = topicsAvailable
        self.scripts = scripts
        self.environmentName = environmentName
        readCommandLines = commandLines ?? {
            try? CommandRunner().run(CommandInvocation(executable: "/bin/sh", arguments: ["-c", PaneCommandLines.script]))
        }
        self.paths = paths
        self.finished = finished
        signal(SIGPIPE, SIG_IGN)
        self.output = EnvironmentWatchOutputWriter(output: output) { [weak self] in
            Task { @MainActor in self?.close() }
        }
    }

    public func receive(_ input: EnvironmentWatchInput) {
        guard !closing else { return }
        if case .hello(let version, let settings) = input {
            guard module == nil, version == EnvironmentWatchProtocol.version else {
                output.send(.rejected(.incompatibleVersion)); close(); return
            }
            self.settings = settings
            let module = EnvironmentModule(paths: paths, server: server,
                topicsAvailable: topicsAvailable, scripts: scripts, environmentName: environmentName, rulesScope: rulesScope, ruleSettings: settings, attachmentDriver: self)
            self.module = module
            output.send(.hello(version: EnvironmentWatchProtocol.version, moduleID: module.id))
            read()
            return
        }
        guard let module, let settings else {
            output.send(.rejected(.missingHello)); close(); return
        }
        switch input {
        case .hello: break
        case .settings(let next):
            self.settings = next
            module.updateRules(settings: next, viewing: EnvironmentViewing())
            read()
        case .viewing(let reader, let facts):
            readers.insert(reader)
            module.updateRules(settings: settings, viewing: facts, reader: reader)
        case .synchronize(let reader):
            module.invalidateRead()
            output.send(.synchronized(reader: reader, revision: module.revision))
            read()
        case .close(let reader, let id):
            readers.remove(reader)
            module.removeReader(reader)
            module.retireReader(reader) { [output] in output?.send(.closed(id: id)) }
            attachments.removeAll { $0.reader == reader }
            if attaching?.reader == reader { finishAttachment(.failure(TmuxError.cancelled)) }
        case .read: read()
        case .full:
            if let state = module.state { output.publish(state, full: true) }
            else { read() }
        case .attached(let id, let failure):
            guard attaching?.id == id else { return }
            finishAttachment(failure.map { .failure($0) } ?? .success(()))
        case .perform(let id, let reader, let request, let client, let paths, let topics, let worktreesRoot, let browsers):
            guard admit() else { return }
            guard readers.contains(reader) else {
                pendingRequests -= 1
                module.write({ $0(EnvironmentResponse.failed(TopicFailure(kind: .cancelled, phase: .nothingChanged,
                    message: "The Environment reader has closed."))) }) { [output] receipt in
                    output?.send(.performed(id: id, receipt: receipt))
                }
                return
            }
            if case .runtime(.attach) = request.command { attachments.append((id, reader)) }
            module.perform(request, client: client, sessionPaths: paths, topics: topics.config, worktreesRoot: worktreesRoot,
                           preparing: browsers, reader: reader) { [weak self] receipt in
                guard let self else { return }
                self.pendingRequests -= 1
                self.attachments.removeAll { $0.id == id }
                self.output.send(.performed(id: id, receipt: receipt))
            }
        case .query(let id, let query, let paths, let topics):
            guard admit() else { return }
            module.query(query, sessionPaths: paths, topics: topics.config) { [weak self] response in
                guard let self else { return }
                self.pendingRequests -= 1
                let stamped: EnvironmentQueryResponse
                if case .inventory(let snapshot) = response {
                    stamped = .inventory(Self.stamped(snapshot, moduleID: module.id))
                } else { stamped = response }
                self.output.send(.queried(id: id, response: stamped))
            }
        }
    }

    private func admit() -> Bool {
        guard pendingRequests < 128 else {
            output.send(.rejected(.overloaded)); close(); return false
        }
        pendingRequests += 1
        return true
    }

    private func read() {
        guard let module, !closing else { return }
        var commandLines = self.commandLines
        module.read(context: { () }, inventory: { [server, readCommandLines, moduleID = module.id] in
            var state = Self.stamped(try server.snapshot(), moduleID: moduleID)
            commandLines = commandLines.updating(for: state, ps: readCommandLines)
            state.commandLines = commandLines
            return state
        }, receive: { [weak self] state, _ in
            guard let self else { return }
            self.commandLines = state.inventory.lastKnown?.commandLines ?? self.commandLines
            self.output.publish(state)
            if let snapshot = state.inventory.current { self.listen(snapshot) }
        })
    }

    nonisolated private static func stamped(_ value: TmuxSnapshot, moduleID: UUID) -> TmuxSnapshot {
        var snapshot = value
        for index in snapshot.windows.indices {
            snapshot.windows[index].sourceID = "\(moduleID.uuidString):\(snapshot.serverID ?? "")"
        }
        return snapshot
    }

    public func attach(_ plan: EnvironmentAttachment, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !closing, let request = attachments.first, readers.contains(request.reader) else {
            completion(.failure(TmuxError.cancelled)); return
        }
        attaching = (request.id, request.reader, completion)
        output.send(.attach(id: request.id, reader: request.reader, plan: plan))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.attaching?.id == request.id else { return }
            self.finishAttachment(.failure(TmuxError.timedOut))
        }
    }

    private func finishAttachment(_ result: Result<Void, Error>) {
        let completion = attaching?.finish
        attaching = nil
        completion?(result)
    }

    public func close() {
        guard !closing else { return }
        closing = true
        stopControl()
        for reader in readers { module?.removeReader(reader) }
        let finish = { [self] in output.finish { DispatchQueue.main.async { self.finished() } } }
        if let module {
            module.retire(completion: finish)
            finishAttachment(.failure(TmuxError.cancelled))
        } else { finish() }
    }

    /// The control client makes the watch read at once when tmux changes. It runs only while the user has a Session,
    /// so the Watch Session alone never keeps the server running: with no user Session left, the watch removes it.
    private func listen(_ snapshot: TmuxSnapshot) {
        guard snapshot.serverRunning else { return }
        if !snapshot.windows.isEmpty { startControl() }
        else if let watch = snapshot.watchSessionID, let controlServer {
            stopControl()
            DispatchQueue.global(qos: .utility).async { _ = try? controlServer.run(["kill-session", "-t", watch]) }
        }
    }

    /// Attaches to the Watch Session alone, and makes it when it is not there. tmux answers a Pane's background color
    /// query from the first client on the Pane's Session, and a control client answers black, so the client must never
    /// share a Session with the user's Panes. Notifications cover every Session. The Session runs `cat`, so no shell
    /// startup file runs in it.
    private func startControl() {
        guard control == nil, Date() >= nextControlStart,
              let invocation = try? controlServer?.invocation(["-C", "new-session", "-A", "-s", Tmux.watchSessionName,
                                                                "-f", "no-output,ignore-size", "cat"]) else { return }
        let process = Process(), input = Pipe(), output = Pipe()
        let token = UUID()
        controlToken = token
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX"] = nil
        environment["TMUX_PANE"] = nil
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.controlToken == token else { return }
                self.control = nil
                self.controlInput = nil
                self.nextControlStart = Date().addingTimeInterval(2)
            }
        }
        do {
            try process.run()
            control = process
            controlInput = input
            try input.fileHandleForWriting.write(contentsOf: Data("refresh-client -B 'status::#{S:#{W:#{P:#{pane_id}=#{@muxify_agent_status};}}}'\n".utf8))
            DispatchQueue(label: "muxify.watch.control").async { [weak self] in
                var buffer = Data()
                var bytes = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    buffer.append(contentsOf: bytes[..<count])
                    var changed = false
                    while let end = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<end], as: UTF8.self)
                        buffer.removeSubrange(...end)
                        if line.hasPrefix("%"), !["%begin", "%end", "%error", "%output", "%extended-output", "%exit"].contains(where: line.hasPrefix) { changed = true }
                    }
                    if changed { Task { @MainActor in
                        guard let self, self.controlToken == token else { return }
                        self.read()
                    } }
                }
            }
        } catch {
            nextControlStart = Date().addingTimeInterval(2)
        }
    }

    private func stopControl() {
        controlToken = UUID()
        try? controlInput?.fileHandleForWriting.close()
        if control?.isRunning == true { control?.terminate() }
        control = nil
        controlInput = nil
    }
}
