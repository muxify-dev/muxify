import Foundation
import MuxifyCore

enum CLICommand: Equatable {
    /// The help for the verbs whose words start with `scope`. An empty scope asks for every verb.
    case help(scope: [String])
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

    /// A help option before `--` asks for help on the verbs that the words before it name. A usage error shows the
    /// help of the verb that the words name, else of the verbs that they start, so `muxify browser` shows only Browser.
    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment, now: Date = Date()) throws {
        let args = ArraySlice(arguments)
        let options = args.prefix { $0 != "--" }
        let scope = CLIVerbs.scope(of: args)
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
            let parsed = try ParsedArguments(rest, for: verb, environment: environment, now: now)
            if let form = verb.removed.first(where: { $0.matches(parsed) }) { throw CLIError(form.message(parsed), exitCode: 2) }
            self = try verb.build(parsed)
        } catch let error as CLIError where error.isUsage {
            throw CLIError.usage(for: verb.words)
        }
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
            try Self.open("muxify://select?session=\(Self.percentEncoded(name))", using: runner)
        case .windowOpen(let target):
            let result = try runner.run("tmux", arguments: ["list-panes", "-t", target, "-F", "#{window_id}"], quiet: true)
            let window = result.output.components(separatedBy: "\n").first ?? ""
            guard result.status == 0, !window.isEmpty else { throw CLIError("no tmux Window or Pane '\(target)'") }
            try Self.open("muxify://select?window=\(Self.percentEncoded(window))", using: runner)
        case .request(let invocation): try await invocation.run()
        case .sessionList(let invocation): try await invocation.run()
        case .agent(let invocation): try await invocation.run()
        case .agentConversation(let invocation): try invocation.run(using: runner)
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
