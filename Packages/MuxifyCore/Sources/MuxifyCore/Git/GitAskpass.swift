#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// A question that git or ssh asks through askpass: one of lazygit's credential prompts, ssh's about a host it doesn't
/// know, or another. askpass is not told whether the answer is a secret, so the prompt's words decide; a question that
/// no pattern knows is taken as a secret. The Git View asks it in a Git View prompt.
public struct GitCredentialPrompt: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case password, username, passphrase, pin, token, hostKey, other
    }

    public let kind: Kind
    /// The question, the prompt's last line, such as "Password for 'https://example.com':".
    public let question: String
    /// The lines before it, such as the host and fingerprint that ssh doesn't know.
    public var context: [String] = []
    /// A password, passphrase, PIN, token or an unknown question, whose answer the prompt hides.
    public var isSecret: Bool

    public init(kind: Kind, question: String, context: [String] = []) {
        self.kind = kind
        self.question = question
        self.context = context
        isSecret = kind != .username && kind != .hostKey
    }

    /// The prompt that askpass got, as git or ssh wrote it. `secret` is what the helper decided, when the Mac has it.
    public init(askpass prompt: String, secret: Bool? = nil) {
        let lines = prompt.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let question = lines.last ?? ""
        self.init(kind: Self.kind(of: question) ?? .other, question: question, context: Array(lines.dropLast()))
        if let secret { isSecret = secret }
    }

    /// Whether the answer to askpass's prompt is a secret.
    public static func isSecret(_ prompt: String) -> Bool {
        GitCredentialPrompt(askpass: prompt).isSecret
    }

    /// lazygit's prompts (`getCheckForCredentialRequestFunc` in `cmd_obj_runner.go`), then ssh's unknown-host question.
    private static let patterns: [(NSRegularExpression, Kind)] = [
        (#"Password:"#, .password),
        (#".+'s password:"#, .password),
        (#"Password\s*for\s*'.+':"#, .password),
        (#"Username\s*for\s*'.+':"#, .username),
        (#"Enter\s*passphrase\s*for\s*key\s*'.+':"#, .passphrase),
        (#"Enter\s*PIN\s*for\s*.+\s*key\s*.+:"#, .pin),
        (#"Enter\s*PIN\s*for\s*'.+':"#, .pin),
        (#".*2FA Token.*"#, .token),
        (#"Are you sure you want to continue connecting \(yes/no(/\[fingerprint\])?\)\?"#, .hostKey),
    ].map { (try! NSRegularExpression(pattern: $0), $1) }

    /// The kind of question that `line` asks, or nil when no pattern knows it.
    static func kind(of line: String) -> Kind? {
        let range = NSRange(line.startIndex..., in: line)
        return patterns.first { $0.0.firstMatch(in: line, range: range) != nil }?.1
    }
}

/// What the askpass helper asks: git's or ssh's prompt, whether its answer is a secret, and the operation that the
/// command's environment named. The helper sends it to its socket as the `MacRequest` `{"ask": {…}}`; on a Host, the
/// Host Server sends it on to its Mac (ADR 0091), which asks it in the Git View that started the operation.
public struct AskRequest: Codable, Equatable, Sendable {
    public var prompt: String
    public var secret: Bool
    public var operation: String

    public init(prompt: String, secret: Bool, operation: String) {
        self.prompt = prompt
        self.secret = secret
        self.operation = operation
    }
}

/// The `ok` of an `ask`: what the user typed.
public struct AskAnswer: Codable, Equatable, Sendable {
    public var answer: String

    public init(answer: String) { self.answer = answer }
}

/// Answers an askpass question, or nil when the user cancelled it or nobody can answer it, which stops the command.
public typealias GitAsk = @Sendable (AskRequest) async -> String?

/// The askpass helper's half: `muxify askpass <prompt>`, which git runs as `GIT_ASKPASS` and ssh as `SSH_ASKPASS`.
public enum GitAskpass {
    /// The socket the helper sends its question to: a one-off socket locally, the Host Server's own on a Host.
    public static let socketVariable = "MUXIFY_ASKPASS_SOCKET"
    /// The operation that the question belongs to.
    public static let operationVariable = "MUXIFY_ASKPASS_OPERATION"
    /// How long the helper waits for the user. The command's own timeout ends the wait sooner.
    static let replyTimeout: TimeInterval = 3600

    /// Asks `prompt` through the socket in `environment` and answers what the user typed. It throws at once when the
    /// socket is gone, and when the question was cancelled or nobody can answer it, so git and ssh stop.
    public static func ask(_ prompt: String, environment: [String: String]) throws -> String {
        guard let socket = environment[socketVariable], !socket.isEmpty, let operation = environment[operationVariable] else {
            throw BrowserAgentChannel.Failure.unreachable("muxify askpass runs only under a Git View command, which names its socket")
        }
        let request = MacRequest.ask(AskRequest(prompt: prompt, secret: GitCredentialPrompt.isSecret(prompt), operation: operation))
        switch try BrowserAgentChannel.send(request, replyTimeout: replyTimeout, to: socket) {
        case .value(let answer): return answer
        case .failure(let message, _): throw BrowserAgentChannel.Failure.broken(message)
        default: throw BrowserAgentChannel.Failure.broken("Muxify sent an unexpected answer to the question")
        }
    }
}

/// The operations that wait for askpass answers, by their operation: a socket's `ask` lines come here. Once the user
/// cancels a question, the operation's later questions are refused at once, so ssh's next tries stop as fast; once the
/// command ends, a question still waiting is refused, so no helper outlives it.
public final class GitAskpassRoutes: @unchecked Sendable {
    private let lock = NSLock()
    // `lock` guards it.
    private var operations: [String: Operation] = [:]

    public init() {}

    /// Answers a helper's question: what the user typed, as the socket reply, or a failure that makes the helper exit
    /// non-zero.
    public func reply(to request: AskRequest) async -> BrowserAgentReply {
        if let answer = await answer(request) { return .value(answer) }
        return .failure("Muxify: nobody answered \"\(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))\"")
    }

    func answer(_ request: AskRequest) async -> String? {
        guard let operation = operation(request.operation) else { return nil }
        return await operation.answer(request)
    }

    private func operation(_ name: String) -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        return operations[name]
    }

    /// Starts taking the questions of `operation`; false when one of that name already waits.
    func open(_ operation: String, ask: @escaping GitAsk, onCancel: @escaping @Sendable () -> Void) -> Operation? {
        lock.lock()
        defer { lock.unlock() }
        guard operations[operation] == nil else { return nil }
        let opened = Operation(ask: ask, onCancel: onCancel)
        operations[operation] = opened
        return opened
    }

    func close(_ operation: String) {
        lock.lock()
        let closed = operations.removeValue(forKey: operation)
        lock.unlock()
        closed?.finish()
    }

    /// One command's questions.
    final class Operation: @unchecked Sendable {
        private let ask: GitAsk
        private let onCancel: @Sendable () -> Void
        private let lock = NSLock()
        // `lock` guards these.
        private var waiting: [Int: CheckedContinuation<String?, Never>] = [:]
        private var nextID = 0
        private var finished = false
        private var cancelled = false

        init(ask: @escaping GitAsk, onCancel: @escaping @Sendable () -> Void) {
            self.ask = ask
            self.onCancel = onCancel
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func answer(_ request: AskRequest) async -> String? {
            let answer: String? = await withCheckedContinuation { continuation in
                lock.lock()
                guard !finished, !cancelled else {
                    lock.unlock()
                    return continuation.resume(returning: nil)
                }
                let id = nextID
                nextID += 1
                waiting[id] = continuation
                lock.unlock()
                let ask = ask
                Task { [weak self] in
                    let answer = await ask(request)
                    self?.resume(id, with: answer)
                }
            }
            if answer == nil { cancel() }
            return answer
        }

        private func resume(_ id: Int, with answer: String?) {
            lock.lock()
            let continuation = waiting.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(returning: answer)
        }

        /// A question went unanswered: the command stops.
        private func cancel() {
            lock.lock()
            let first = !cancelled && !finished
            cancelled = true
            lock.unlock()
            if first { onCancel() }
        }

        /// The command ended: what still waits is refused.
        func finish() {
            lock.lock()
            finished = true
            let all = Array(waiting.values)
            waiting = [:]
            lock.unlock()
            all.forEach { $0.resume(returning: nil) }
        }
    }
}

/// Runs a `GitNetwork` on this machine, with git's and ssh's questions going to an `ask` callback through askpass:
/// `GIT_ASKPASS` and `SSH_ASKPASS` name the helper, `muxify askpass`, with `SSH_ASKPASS_REQUIRE=force` and a
/// placeholder `DISPLAY` for OpenSSH before 8.4, and git never asks on a terminal. The helper reaches the socket named
/// in `MUXIFY_ASKPASS_SOCKET`. A cancelled question stops the command: its helper exits non-zero at once, later
/// questions are refused, and a command still running a moment later is stopped. The command then ends
/// `TmuxError.cancelled`.
public struct GitNetworkRunner: Sendable {
    /// The `muxify` executable, whose `askpass` verb is the helper.
    public var helper: String
    /// Where each command gets a private folder for the helper's script and, locally, its one-off socket.
    public var scratch: URL
    /// The environment git runs in, before the askpass variables.
    public var environment: [String: String]
    /// How long a command may go on after a cancelled question before it is stopped.
    var grace: TimeInterval = 1

    public init(helper: String, scratch: URL = FileManager.default.temporaryDirectory,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.helper = helper
        self.scratch = scratch
        self.environment = environment
    }

    /// The C locale, so git's and ssh's prompts are in English, as the prompt patterns are.
    static let locale = ["LANG": "C", "LC_ALL": "C", "LC_MESSAGES": "C"]

    /// Runs `network` with a one-off socket of its own for the helper, as the Local Environment does.
    public func run(_ network: GitNetwork, ask: @escaping GitAsk) async throws -> String {
        var folder = try makeFolder(in: scratch)
        // A socket's path must fit in `sun_path`, 104 bytes on a Mac: a deep scratch folder gives way to /tmp.
        if folder.appendingPathComponent("s").path.utf8.count >= 100 {
            try? FileManager.default.removeItem(at: folder)
            folder = try makeFolder(in: URL(fileURLWithPath: "/tmp", isDirectory: true))
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let routes = GitAskpassRoutes()
        let path = folder.appendingPathComponent("s").path
        let listener = try BrowserAgentListener.lines(at: path) { line, respond in
            guard case .ask(let request)? = try? JSONDecoder().decode(MacRequest.self, from: line) else {
                return respond(.failure(message: "Muxify cannot read this request; update the CLI and the app together", exitCode: 2))
            }
            Task { respond(await routes.reply(to: request)) }
        }
        defer { listener.stop() }
        return try await run(network, operation: UUID().uuidString, socket: path, routes: routes, folder: folder, ask: ask)
    }

    /// Runs `network` with its helper sending its questions to `socket`, whose `ask` lines go to `routes`: the Host
    /// Server's own socket. `operation` names the questions; one that already runs is refused.
    public func run(_ network: GitNetwork, operation: String, socket: String, routes: GitAskpassRoutes,
                    ask: @escaping GitAsk) async throws -> String {
        let folder = try makeFolder(in: scratch)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await run(network, operation: operation, socket: socket, routes: routes, folder: folder, ask: ask)
    }

    private func run(_ network: GitNetwork, operation: String, socket: String, routes: GitAskpassRoutes, folder: URL,
                     ask: @escaping GitAsk) async throws -> String {
        let script = folder.appendingPathComponent("askpass")
        try ("#!/bin/sh\nexec " + Tmux.shellQuote(helper) + " askpass \"$@\"\n").write(to: script, atomically: true, encoding: .utf8)
        guard chmod(script.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }

        var variables = environment.merging(Self.locale) { $1 }
        variables[GitAskpass.socketVariable] = socket
        variables[GitAskpass.operationVariable] = operation
        variables["GIT_ASKPASS"] = script.path
        variables["SSH_ASKPASS"] = script.path
        variables["SSH_ASKPASS_REQUIRE"] = "force"
        variables["GIT_TERMINAL_PROMPT"] = "0"
        if (variables["DISPLAY"] ?? "").isEmpty { variables["DISPLAY"] = "muxify:0" }

        let runner = CommandRunner()
        let grace = grace
        guard let opened = routes.open(operation, ask: ask, onCancel: {
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { runner.cancel() }
        }) else { throw GitViewError(message: "The \(network.action) is running already.") }
        defer { routes.close(operation) }

        let command = network.script
        let arguments = ["-c", command.text, "muxify"] + command.arguments
        do {
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let invocation = CommandInvocation(executable: "/bin/sh", arguments: arguments)
                    continuation.resume(with: Result { try runner.run(invocation, timeout: network.timeout, environment: variables) })
                }
            }
        } catch {
            if opened.isCancelled { throw TmuxError.cancelled }
            throw error
        }
    }

    /// A folder only this user can read, for one command.
    private func makeFolder(in scratch: URL) throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var template = Array(scratch.appendingPathComponent("mxa.XXXXXX").path.utf8CString)
        let made: String? = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let made else { throw CocoaError(.fileWriteUnknown) }
        return URL(fileURLWithPath: made, isDirectory: true)
    }
}
