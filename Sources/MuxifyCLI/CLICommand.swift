import Foundation
import MuxifyCore

enum CLICommand: Equatable {
    case help
    case browserAvailable(pane: String?)
    case browserOpen(window: String, urls: [String])
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
    func execute(using runner: any CLICommandRunning = CLIProcessRunner(),
                 executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])) async throws -> Int32 {
        switch self {
        case .browserAvailable(let pane):
            let result = BrowserAvailability.check(pane: pane, using: runner)
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
        case .browserOpen(let target, let urls):
            // list-panes validates the target; display-message succeeds even for missing Windows.
            let result = try runner.run("tmux", arguments: ["list-panes", "-t", target, "-F", "#{window_id}"], quiet: true)
            let window = result.output.components(separatedBy: "\n").first ?? ""
            guard result.status == 0, !window.isEmpty else { throw CLIError("no tmux Window '\(target)'") }
            // Append so requests made before Muxify's next poll aren't overwritten.
            try Self.check(runner.run("tmux", arguments: ["set-option", "-wa", "-t", window, "@muxify_open", " " + urls.joined(separator: " ")], quiet: false), command: "tmux")
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
