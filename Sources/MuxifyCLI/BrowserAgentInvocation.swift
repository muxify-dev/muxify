import Foundation
import MuxifyCore

/// One Browser command (ADR 0057): it finds the app that serves this tmux server's Browsers, sends one request
/// for the caller's Window, and prints the reply.
struct BrowserAgentInvocation: Equatable {
    /// A Window or a Pane id: `--window`, else `$TMUX_PANE`.
    let target: String
    let pane: String?
    let tab: UUID?
    let command: BrowserAgentCommand
    let json: Bool
    /// Where `screenshot` writes its PNG.
    var screenshotPath: String?

    init(_ command: BrowserAgentCommand, parsed: ParsedArguments, screenshotPath: String? = nil) throws {
        let pane = parsed.environment["TMUX_PANE"].flatMap { $0.isEmpty ? nil : $0 }
        guard let target = try parsed.value("--window") ?? pane else {
            throw CLIError("not inside tmux; specify the Window with --window <id> (e.g. --window @12)")
        }
        let tab = try parsed.value("--tab")
        if let tab, UUID(uuidString: tab) == nil {
            throw CLIError("'\(tab)' is not a Tab id; muxify browser tabs lists them", exitCode: 2)
        }
        self.target = target
        self.pane = pane
        self.tab = tab.flatMap(UUID.init(uuidString:))
        self.command = command
        json = parsed.flag("--json")
        self.screenshotPath = screenshotPath
    }

    func run(using runner: any CLICommandRunning) throws {
        let reply = try Self.send(command, target: target, pane: pane, tab: tab, using: runner)
        switch reply {
        case .tabs(let tabs):
            if json { print(try Self.json(tabs)) }
            else { tabs.forEach { print(Self.line($0)) } }
        case .opened(let tab): print(json ? try Self.json(tab) : tab.id.uuidString)
        case .value(let text), .snapshot(let text): print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        case .png(let data):
            guard let screenshotPath else { throw CLIError("Muxify sent a picture for a command that takes none") }
            do { try data.write(to: URL(fileURLWithPath: screenshotPath)) }
            catch { throw CLIError("cannot write \(screenshotPath): \(error.localizedDescription)") }
            print(screenshotPath)
        case .done: break
        case .failure(let message, let exitCode): throw CLIError(message, exitCode: exitCode)
        }
    }

    /// A Ref names an element of the last `snapshot`.
    static func ref(_ word: String) throws -> String {
        guard word.first == "e", let number = Int(word.dropFirst()), number > 0, word == "e\(number)" else {
            throw CLIError("'\(word)' is not a Ref; muxify browser snapshot gives each element one, such as e3", exitCode: 2)
        }
        return word
    }

    /// The app's reply for the caller's Window. A failure to reach the app is a `BrowserAgentChannel.Failure`, so
    /// `browser open` can fall back to `@muxify_open`; every other failure is a `CLIError`.
    static func send(_ command: BrowserAgentCommand, target: String, pane: String?, tab: UUID?,
                     using runner: any CLICommandRunning) throws -> BrowserAgentReply {
        let panes = try runner.run("tmux", arguments: ["list-panes", "-t", target, "-F", "#{window_id}"], quiet: true)
        guard panes.status == 0, let window = panes.output.split(separator: "\n").first.map(String.init) else {
            throw CLIError("no tmux Window or Pane '\(target)'")
        }
        let option = try runner.run("tmux", arguments: ["show-options", "-sqv", BrowserAgentChannel.option], quiet: false)
        guard option.status == 0 else {
            throw CLIError("cannot read tmux: tmux show-options exited with status \(option.status)", exitCode: 2)
        }
        let path = option.output.trimmingCharacters(in: .newlines)
        guard !path.isEmpty else {
            throw BrowserAgentChannel.Failure.unreachable("Muxify does not serve the Browser of this tmux server")
        }
        return try BrowserAgentChannel.send(BrowserAgentRequest(window: window, pane: pane, tab: tab, command: command), to: path)
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func line(_ tab: BrowserAgentTab) -> String {
        let marks = [tab.active ? "active" : nil, tab.agent ? "agent" : nil].compactMap { $0 }
        return ([tab.id.uuidString, tab.url.isEmpty ? "about:blank" : tab.url, tab.title] + marks).joined(separator: "\t")
    }
}

extension BrowserAgentChannel.Failure {
    /// What the CLI prints when it cannot reach the app.
    var cliError: CLIError {
        switch self {
        case .unreachable(let reason):
            CLIError("cannot reach Muxify: \(reason). Run muxify browser available to check that Muxify shows this tmux server.")
        case .broken(let reason): CLIError(reason)
        }
    }
}
