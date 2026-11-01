import Foundation
import MuxifyCore

enum CLICommand: Equatable {
    case environmentWatch(socket: String?, config: String?)
    case help
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
    case agent(AgentInvocation)
    case agentConversation(AgentConversationInvocation)

    static var usage: String { CLIVerbs.usage }

    /// A help option before `--` asks for help, on any verb of a noun that the command line knows.
    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) throws {
        let args = ArraySlice(arguments)
        let options = args.prefix { $0 != "--" }
        guard let noun = args.first, !["-h", "--help", "help"].contains(noun) else {
            guard args.isEmpty else { self = .help; return }
            throw CLIError.usage
        }
        if options.contains(where: { $0 == "-h" || $0 == "--help" }), CLIVerbs.all.contains(where: { $0.words[0] == noun }) {
            self = .help
            return
        }
        guard let (verb, rest) = CLIVerbs.verb(for: args) else { throw CLIError.usage }
        let parsed = try ParsedArguments(rest, for: verb, environment: environment, now: now)
        if let form = verb.removed.first(where: { $0.matches(parsed) }) { throw CLIError(form.message(parsed), exitCode: 2) }
        self = try verb.build(parsed)
    }

    @discardableResult
    @MainActor func execute(using runner: any CLICommandRunning = CLIProcessRunner(),
                 executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) async throws -> Int32 {
        switch self {
        case .environmentWatch(let socket, let config):
            let server = TmuxServer(socketPath: socket ?? TmuxServer.local.socketPath,
                                    configPath: config, commandTimeout: 10)
            try await EnvironmentWatchCommand.run(server: server)
        case .browserAvailable(let pane):
            let result = try await EnvironmentModule.withCommand(server: CLITmuxTransport(runner: runner), topicsAvailable: false) { module in
                try await module.queries().browserAvailability(pane: pane).mapError { CLIError("cannot read tmux: \($0.message)", exitCode: 2) }.get()
            }
            print(result.rawValue)
            return result.exitCode
        case .help: print(Self.usage)
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
            let tmux = CLITmuxTransport(runner: runner)
            try await EnvironmentModule.withCommand(server: tmux, topicsAvailable: false) { module in
                do {
                    for url in urls {
                        switch try await BrowserAgentInvocation.send(.open(url: url), target: target, tab: tab, module: module) {
                        case .opened(let tab): if json { print(try BrowserAgentInvocation.json(tab)) }
                        case .failure(let message, let exitCode): throw CLIError(message, exitCode: exitCode)
                        default: throw CLIError("Muxify sent an unexpected reply to browser open")
                        }
                    }
                } catch let failure as BrowserAgentChannel.Failure {
                    // Without the app, nothing can name the new Tab or load into one; a plain open waits for Muxify's next read.
                    guard !json, tab == nil, case .unreachable = failure else { throw failure.cliError }
                    let receipt = await module.perform(EnvironmentRequest(.runtime(.openBrowser(target: target, urls: urls))))
                    if case .failed(let failure) = receipt.value { throw CLIError(failure.message, exitCode: tmux.failedStatus ?? 1) }
                }
            }
        case .browser(let invocation):
            do { try await invocation.run(using: runner) }
            catch let failure as BrowserAgentChannel.Failure { throw failure.cliError }
        case .sessionOpen(let name):
            try await EnvironmentModule.withCommand(server: CLITmuxTransport(runner: runner), topicsAvailable: false) { module in
                guard try await module.queries().sessionExists(name).mapError({ CLIError($0.message) }).get() else { throw CLIError("no tmux session '\(name)'") }
                try Self.open("muxify://select?session=\(Self.percentEncoded(name))", using: runner)
            }
        case .windowOpen(let target):
            try await EnvironmentModule.withCommand(server: CLITmuxTransport(runner: runner), topicsAvailable: false) { module in
                guard let window = try await module.queries().resolveWindow(target).mapError({ CLIError($0.message) }).get() else { throw CLIError("no tmux Window or Pane '\(target)'") }
                try Self.open("muxify://select?window=\(Self.percentEncoded(window))", using: runner)
            }
        case .request(let invocation): try await invocation.run()
        case .sessionList(let invocation): try await invocation.run()
        case .agent(let invocation): try await invocation.run()
        case .agentConversation(let invocation): try await invocation.run(using: runner)
        }
        return 0
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

    init(_ message: String, exitCode: Int32 = 1) {
        self.message = message
        self.exitCode = exitCode
    }

    /// What the Topic service could not do, then how far it got.
    init(_ failure: TopicFailure) {
        self.init("\(failure.message) \(failure.phase.summary)")
    }

    var errorDescription: String? { message }
}
