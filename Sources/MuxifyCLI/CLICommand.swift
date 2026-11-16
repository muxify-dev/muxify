import Foundation
import MuxifyCore

enum CLICommand: Equatable {
    /// The help for the verbs whose words start with `scope`. An empty scope asks for every verb.
    case help(scope: [String])
    /// `muxify <short-sha> <commit-unix-time>`, or `muxify dev 0` for a build with no stamp.
    case version
    case browserAvailable(pane: String?)
    /// `window` is a Window or a Pane id. With `tab`, the one URL loads in that Tab; without it, each URL opens a Tab.
    case browserOpen(window: String, tab: UUID?, urls: [String], json: Bool)
    case browser(BrowserAgentInvocation)
    case sessionOpen(name: String)
    /// `target` is a Window or a Pane id.
    case windowOpen(target: String)
    case extensionsInstall
    case request(RequestInvocation)
    case sessionList(SessionListInvocation)
    case topicSessionPaths(TopicSessionPathsInvocation)
    case sessionPaths(SessionPathsInvocation)
    case agent(AgentInvocation)
    case agentConversation(AgentConversationInvocation)
    case diagnosticsSummary(DiagnosticsSummaryInvocation)
    /// The Host Server on stdin and stdout, which exits after `silence` seconds with no frame.
    case server(silence: TimeInterval, paths: MuxifyPaths)
    /// git's or ssh's question, asked through the socket that a Git View command names in `environment`.
    case askpass(prompt: String, environment: [String: String])

    static var usage: String { CLIVerbs.usage }

    /// A help option before `--` asks for help on the verbs that the words before it name. A usage error shows the
    /// help of the verb that the words name, else of the verbs that they start, so `muxify browser` shows only Browser.
    ///
    /// `--request <uuid>` before `--` goes with any verb, so it is taken here, before the verb reads its words. Only a
    /// verb that sends a request to the Environment keeps it; every other verb refuses it.
    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date(),
         workingDirectory: String = FileManager.default.currentDirectoryPath) throws {
        let (arguments, requestID) = try Self.takingRequest(from: arguments)
        let args = ArraySlice(arguments)
        let options = args.prefix { $0 != "--" }
        let scope = CLIVerbs.scope(of: args)
        if args == ["--version"] { self = .version; return }
        guard let noun = args.first, !["-h", "--help", "help"].contains(noun) else {
            guard args.isEmpty else { self = .help(scope: []); return }
            throw CLIError.usage(for: [])
        }
        if options.contains(where: { $0 == "-h" || $0 == "--help" }), !scope.isEmpty {
            self = .help(scope: scope)
            return
        }
        guard let (verb, rest) = CLIVerbs.verb(for: args) else { throw CLIError.usage(for: scope) }
        do {
            let request = requestID.map {
                PendingRequest(id: $0, verb: verb.path.rawValue, words: Array(rest),
                               callerPane: environment["TMUX_PANE"].flatMap { $0.isEmpty ? nil : $0 }, workingDirectory: workingDirectory)
            }
            let parsed = try ParsedArguments(rest, for: verb, environment: environment, now: now, request: request)
            if let form = verb.removed.first(where: { $0.matches(parsed) }) { throw CLIError(form.message(parsed), exitCode: 2) }
            self = try verb.build(parsed)
            if request != nil {
                guard case .request = self else {
                    throw CLIError("--request names a change that Muxify applies one time only. \(verb.path.rawValue) is not such a change, "
                                   + "so it does not take --request.", exitCode: 2)
                }
            }
        } catch let error as CLIError where error.isUsage {
            throw CLIError.usage(for: verb.words)
        }
    }

    /// The arguments without `--request <uuid>` or `--request=<uuid>`, and the id. The words after `--` stay.
    private static func takingRequest(from arguments: [String]) throws -> ([String], RequestID?) {
        var kept: [String] = [], values: [String] = []
        var rest = ArraySlice(arguments)
        while let word = rest.popFirst() {
            if word == "--" {
                kept += [word] + rest
                break
            }
            if word == "--request" {
                guard let value = rest.popFirst() else { throw CLIError.usage(for: []) }
                values.append(value)
            } else if word.hasPrefix("--request=") {
                values.append(String(word.dropFirst("--request=".count)))
            } else {
                kept.append(word)
            }
        }
        guard values.count <= 1 else { throw CLIError("give --request one time only", exitCode: 2) }
        guard let value = values.first else { return (kept, nil) }
        guard let id = RequestID(value) else {
            throw CLIError("--request takes a UUID, e.g. 3f2b8c1e-7a4d-4e9b-9c0a-5d6e7f8a9b0c", exitCode: 2)
        }
        return (kept, id)
    }

    @discardableResult
    func execute(using runner: any CLICommandRunning = CLIProcessRunner(),
                 executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) async throws -> Int32 {
        switch self {
        case .browserAvailable(let pane):
            let result = try BrowserAvailability.check(pane: pane, using: runner)
            print(result.rawValue)
            return result.exitCode
        case .help(let scope): print(CLIVerbs.usage(for: scope))
        case .version: print(BuildStamp.versionLine)
        case .extensionsInstall:
            // Installed links point into the app bundle. Resolve them before
            // locating the installer beside its bundled bin directory.
            let installer = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
                .appendingPathComponent("../extensions/install.sh").standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: installer.path) else {
                throw CLIError("Extension installer is missing beside the command line tool")
            }
            let result = try runner.run("/bin/sh", arguments: [installer.path], quiet: false)
            print(result.output, terminator: "")
            try Self.check(result, command: "Extension installer")
        case .browserOpen(let target, let tab, let urls, let json):
            do {
                for url in urls {
                    switch try BrowserAgentInvocation.send(.open(url: url), target: target, tab: tab, using: runner) {
                    case .opened(let tab): if json { print(try BrowserAgentInvocation.json(tab)) }
                    case .failure(let message, let exitCode): throw CLIError(message, exitCode: exitCode)
                    default: throw CLIError("Muxify sent an unexpected reply to browser open")
                    }
                }
            } catch let failure as BrowserAgentChannel.Failure {
                // Without the app, nothing can name the new Tab or load into one; a plain open waits for Muxify's next read.
                guard !json, tab == nil, case .unreachable = failure else { throw failure.cliError }
                try Self.appendOpenRequest(target: target, urls: urls, using: runner)
            }
        case .browser(let invocation):
            do { try invocation.run(using: runner) }
            catch let failure as BrowserAgentChannel.Failure { throw failure.cliError }
        case .sessionOpen(let name):
            let result = try runner.run("tmux", arguments: ["has-session", "-t", "=\(name)"], quiet: true)
            guard result.status == 0 else { throw CLIError("no tmux session '\(name)'") }
            try Self.select(.session(name), using: runner)
        case .windowOpen(let target):
            let result = try runner.run("tmux", arguments: ["list-panes", "-t", target, "-F", "#{window_id}"], quiet: true)
            let window = result.output.components(separatedBy: "\n").first ?? ""
            guard result.status == 0, !window.isEmpty else { throw CLIError("no tmux Window or Pane '\(target)'") }
            try Self.select(.window(window), using: runner)
        case .askpass(let prompt, let environment):
            do { print(try GitAskpass.ask(prompt, environment: environment)) }
            catch BrowserAgentChannel.Failure.unreachable(let reason) { throw CLIError("muxify askpass: cannot reach Muxify: \(reason)") }
            catch BrowserAgentChannel.Failure.broken(let reason) { throw CLIError("muxify askpass: \(reason)") }
        case .request(let invocation): return try await invocation.run()
        case .sessionList(let invocation): try await invocation.run()
        case .topicSessionPaths(let invocation): try await invocation.run()
        case .sessionPaths(let invocation): try await invocation.run(executable: executableURL)
        case .agent(let invocation): try await invocation.run()
        case .agentConversation(let invocation): try invocation.run(using: runner)
        case .diagnosticsSummary(let invocation): try invocation.run()
        case .server(let silence, let paths):
            // The Host's Config, with its SessionPaths from the discovery cache as `session-paths` reads them, read for each
            // request. This executable is the askpass helper of the Git View's network commands.
            let context = HostServerContext(paths: paths, config: {
                try ConfigSessions.loadCached(paths.configFile, cache: SessionPathCache(file: paths.sessionPathCache(remote: nil))).config
            }, gitNetwork: GitNetworkRunner(helper: executableURL.path, scratch: paths.state))
            return await HostServer.run(build: BuildStamp.versionLine, silence: silence, context: context).exitCode
        }
        return 0
    }

    private static func appendOpenRequest(target: String, urls: [String], using runner: any CLICommandRunning) throws {
        // list-panes validates the target; display-message succeeds even for missing Windows.
        let result = try runner.run("tmux", arguments: ["list-panes", "-t", target, "-F", "#{window_id}"], quiet: true)
        let window = result.output.components(separatedBy: "\n").first ?? ""
        guard result.status == 0, !window.isEmpty else { throw CLIError("no tmux Window '\(target)'") }
        // Append so requests made before Muxify's next poll aren't overwritten.
        try check(runner.run("tmux", arguments: ["set-option", "-wa", "-t", window, Tmux.openOption, " " + urls.joined(separator: " ")], quiet: false), command: "tmux")
    }

    /// A view verb: the App Window shows `request` and comes to the front. On a Host, the Host Server that
    /// `@muxify_browser_socket` names passes it to its Mac (ADR 0091); on a Mac, macOS `open` hands the app a
    /// `muxify://select` URL.
    static func select(_ request: SelectRequest, using runner: any CLICommandRunning = CLIProcessRunner()) throws {
        if let socket = hostServerSocket(using: runner) {
            let reply: BrowserAgentReply
            do { reply = try BrowserAgentChannel.send(MacRequest.select(request), replyTimeout: 30, to: socket) }
            catch let failure as BrowserAgentChannel.Failure { throw failure.cliError }
            if case .failure(let message, let exitCode) = reply { throw CLIError(message, exitCode: exitCode) }
            return
        }
        #if os(macOS)
        try open(selectURL(request), using: runner)
        #else
        throw BrowserAgentChannel.Failure.unreachable("no Muxify shows this Host's tmux server").cliError
        #endif
    }

    static func selectURL(_ request: SelectRequest) -> String {
        switch request {
        case .session(let name): "muxify://select?session=\(percentEncoded(name))"
        case .window(let id): "muxify://select?window=\(percentEncoded(id))"
        case .topic(let id): "muxify://select?topic=\(percentEncoded(id))"
        }
    }

    /// The Host Server socket that `@muxify_browser_socket` names; nil when it names the Mac app's socket, or none.
    private static func hostServerSocket(using runner: any CLICommandRunning) -> String? {
        guard let result = try? runner.run("tmux", arguments: ["show-options", "-sqv", BrowserAgentChannel.option], quiet: true),
              result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .newlines)
        return BrowserAgentChannel.isHostServerSocket(path) ? path : nil
    }

    /// Hands a `muxify://` URL to the app. A view verb asks the app to show something; it changes no state.
    static func open(_ url: String, using runner: any CLICommandRunning = CLIProcessRunner()) throws {
        try Self.check(runner.run("open", arguments: [url], quiet: false), command: "open")
    }

    /// Encodes every UTF-8 byte, matching the original CLI's links.
    static func percentEncoded(_ value: String) -> String {
        value.utf8.map { String(format: "%%%02x", $0) }.joined()
    }

    private static func check(_ result: CLICommandResult, command: String) throws {
        guard result.status == 0 else { throw CLIError("\(command) exited with status \(result.status)", exitCode: result.status) }
    }
}

struct CLIError: LocalizedError {
    let message: String
    let exitCode: Int32
    /// The message is help text, which the command line prints without the `muxify: ` prefix.
    let isUsage: Bool

    init(_ message: String, exitCode: Int32 = 1) {
        self.init(message, exitCode: exitCode, isUsage: false)
    }

    private init(_ message: String, exitCode: Int32, isUsage: Bool) {
        self.message = message
        self.exitCode = exitCode
        self.isUsage = isUsage
    }

    /// A usage error that shows the help of the verbs whose words start with `scope`.
    static func usage(for scope: [String]) -> CLIError { CLIError(CLIVerbs.usage(for: scope), exitCode: 2, isUsage: true) }

    /// What the Topic service could not do, then how far it got.
    init(_ failure: TopicFailure) {
        self.init("\(failure.message) \(failure.phase.summary)")
    }

    var errorDescription: String? { message }
}
