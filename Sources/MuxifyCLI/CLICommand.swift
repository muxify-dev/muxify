import Foundation
import MuxifyCore

enum CLICommand: Equatable {
    case help
    case browserAvailable(pane: String?)
    case browserOpen(window: String, urls: [String])
    case sessionOpen(name: String)
    case sessionLock(SessionInvocation)
    case extensionsInstall
    case topic(TopicInvocation)
    case sessionList(SessionListInvocation)
    case agent(AgentInvocation)
    case agentConversation(AgentConversationInvocation)
    case window(WindowInvocation)

    static let usage = """
    usage: muxify browser open [--window <id>] <url>...
           muxify browser available
           muxify session open <session name>
           muxify session lock [--session <name>] [--json]
           muxify session unlock [--session <name>] [--json]
           muxify extensions install
           muxify topic new ["title"] [--directory <dir>] [--window <id> | --pane <id>] [--json]
           muxify topic add-session <dir> [--worktree [--base <ref>]] [--topic <id|label> | --window <id> | --pane <id>] [--json]
           muxify topic forget [--kill-sessions] [--remove-worktrees] [--topic <id|label> | --window <id> | --pane <id>] [--json]
           muxify topic settle [--kill-sessions] [--remove-worktrees] [--topic <id|label> | --window <id> | --pane <id>] [--json]
           muxify topic snooze <time> [--topic <id|label>... | --window <id> | --pane <id>] [--json]
           muxify topic unsnooze [--topic <id|label>... | --window <id> | --pane <id>] [--json]
           muxify topic tag (add | remove | set) [<tag>...] [--topic <id|label> | --window <id> | --pane <id>] [--json]
           muxify topic list [--json]
           muxify topic show [--conversations] [--topic <id|label> | --window <id> | --pane <id>] [--json]
           muxify topic status [--session <name|id>] [--topic <id|label> | --window <id> | --pane <id>] [--json]
           muxify topic diff [--stat] [--session <name|id>] [--topic <id|label> | --window <id> | --pane <id>] [--json]
           muxify topic exec [--session <name|id>] [--timeout <seconds>] [--topic <id|label> | --window <id> | --pane <id>] [--json] -- <command> [<argument>...]
           muxify window move --topic <id|label> [--session <name|id> | --new-session] [--window <id> | --pane <id>] [--json]
           muxify session list [--json]
           muxify agent list [--topic <id|label>] [--status <status>] [--unread] [--json]
           muxify agent conversation (<pane> | --conversation <id> --kind <kind> | --transcript <path> [--kind <kind>])
                                     [--head <n> | --tail <n> | --range <a>..<b>] [--after <index>] [--since <time>]
                                     [--role <role>,... | --tools | --tool <name>,...] [--grep <regex> [--context <n>]]
                                     [--max-chars <n> | --full] [--info] [--json]

    browser available  Prints local, remote or no for this Pane's newest Client.
                       Exits 0 for local or remote, and 1 for no.
    browser open   Opens each URL as a Tab in this tmux Window's Browser.
                     --window <id>   open in another Window instead, e.g. --window @12
    session open   Shows the tmux Session in Muxify. The name may contain spaces,
                   quoted or not: muxify session open my session
    session lock   Locks this Pane's tmux Session, or the Session that --session names:
                   it keeps a card with a number in the Topics list, after the Topics
                   that are not Pinned. Only a Session in No Topic can be Locked. A
                   Locked Session stays where it is.
    session unlock Ends the Lock. The Session stays, in No Topic.
    extensions install
                   Installs or updates Extensions for Agents configured under HOME.
    topic new      Without a title, moves this Pane into an Untitled Topic.
                   With a title, creates a Topic Session and keeps this Pane here.
    topic add-session
                   Creates another Session at <dir> in this Pane's Topic, even if that folder is already used.
                     --worktree      start a new Worktree from it on the Topic's branch
                     --base <ref>    start the new Worktree at <ref>, not at HEAD
    topic forget   Removes this Topic for good. Sessions stay running, without the Topic.
    topic settle   Settles this Pane's Topic. Sessions and Worktrees are kept by default.
                     --kill-sessions    explicitly stop the Topic's Sessions (also for forget)
                     --remove-worktrees  also remove each Worktree that the Topic made
                                         and that is merged, as the Settle sheet offers.
                                         If one has uncommitted work, nothing changes.
    topic snooze   Snoozes this Pane's Topic until <time>, also when it was Snoozed until
                   later. <time> is as the time step of Snooze Topic reads it: 30m, 2h or 3d from now,
                   17:30 or 5pm, today, tomorrow or a weekday such as mon, each with an
                   optional time (default 9:00), or forever, until you Unsnooze it.
                   Give --topic more than once to Snooze each of those Topics. If one
                   is not an open Topic, nothing changes.
    topic unsnooze Unsnoozes this Pane's Topic, or each --topic. A Topic that is not
                   Snoozed does not change. It changes nothing in tmux.
    topic tag      Adds Tags to this Pane's Topic, removes them, or sets them, so that the
                   Topic has exactly these Tags: set with no Tag removes every Tag. Only a Tag
                   that the Config lists in topics.tags can be added, such as backend; upper case
                   becomes lower case. The # is optional, and the shell reads an unquoted # as a comment.
    topic list     Prints each open Topic's id, label and Tags without starting Muxify.
    topic show     Prints this Pane's Topic: its id, label and Tags, then a line for each live
                   Session: its name, base name, folder and branch. With --json, also its
                   Windows and Panes, and the Agent, Status, Unread and conversation of each Pane.
                     --conversations      also a line for the conversation of each Agent that
                                          the Topic has or remembers: its kind and id
    topic status   Prints the git status of each live Session of this Pane's Topic, as
                   git status --short --branch does, with each untracked file, under a
                   "==> <session> <==" line.
                   With --json, also each Session's upstream, ahead, behind and base.
                   A Session whose folder is in no repository has "git": null.
                     --session <name|id>   only this exact Session
    topic diff     Prints one patch of the Topic's work in all its live Sessions. Each
                   path starts with the Session's name. A Session's work is its commits,
                   changes and untracked files since its base: the commit its Worktree
                   started at, else the merge base with origin/HEAD, main or master.
                     --stat               print a summary, not the patch
                     --session <name|id>   only this exact Session
    topic exec     Runs <command> once in the folder of each live Session of this Pane's
                   Topic, all at the same time, and prints each Session's output under
                   a "==> <session> <==" line. It types nothing into a Pane. It exits
                   with 1 when a run does not exit with 0.
                     --session <name|id>   run only in this exact Session
                     --timeout <seconds>  stop a run after this time (default 60)
    window move    Moves this Pane's Window, or the Window that --window or --pane
                   names, into the open Topic that --topic names by id or exact label.
                     --session <name|id>   choose a destination when several Sessions exist
                     --new-session         create a destination instead of reusing one
    session list   Prints every running Session and each unused exact-named launch path,
                   with running or launchable, its directory, and Topic label when present.
    agent list     Prints a line for each Agent: its Pane, kind, Status, "unread" when it
                   is Unread, and the label of its Topic and the name of its Session.
                     --topic <id|label>  only the Agents in this open Topic
                     --status <status>   only the Agents with this Status: working,
                                         blocked, done or failed
                     --unread            only the Unread Agents
                   With --json, also the conversation id of each Agent.
    agent conversation
                   Prints the Entries of an Agent's conversation from the Transcript that
                   its CLI writes: each message, tool call and tool result, with an index
                   that does not change. It reads the Agent in <pane>, the conversation
                   that --conversation and --kind (claude, codex, pi or opencode) name,
                   or the Transcript file at --transcript. Without a selection, it prints
                   the last 20 user and assistant Entries, and on stderr what it left out.
                     --head <n>, --tail <n>  the first or last n Entries
                     --range <a>..<b>     the Entries from index a to b; negative counts from
                                          the end (-20..-1) and a side can be open (40..)
                     --after <index>      only the Entries after this index, to read new ones
                     --since <time>       only the Entries from this time: 2h, 30m, 17:30 or
                                          ISO 8601, as topic snooze reads a time, but back
                     --role <role>,...    user, assistant, tool_call, tool_result or all
                                          (default user,assistant)
                     --tools              all roles: also the tool calls and tool results
                     --tool <name>,...    only the tool Entries of these tools, e.g. Bash
                     --grep <regex>       only the Entries whose text or tool matches; it
                                          ignores case unless <regex> has a capital letter
                     --context <n>        with --grep, also n Entries before and after
                     --max-chars <n>      cut the text of each Entry at n characters (default 2000)
                     --full               do not cut the text
                     --info               print the size, times and roles, not the Entries
                     --json               print a line of JSON for the conversation, then
                                          one for each Entry

    A Topic command acts on this Pane, or on the target that you name:
                     --topic <id|label>  an open Topic, e.g. --topic "Fix login"
                     --window <id>       a tmux Window, e.g. --window @12
                     --pane <id>         a tmux Pane, e.g. --pane %3
    new, add-session, settle, snooze, unsnooze and window move print the id of each Topic that they change.
                     --json              print the full result as one line of JSON

    Optional tmux binding: bind T run-shell 'muxify topic new --pane #{pane_id} >/dev/null'
    """

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        var args = ArraySlice(arguments)
        switch args.popFirst() {
        case "-h", "--help", "help": self = .help
        case "extensions":
            switch args.popFirst() {
            case "-h", "--help": self = .help
            case "install":
                if args.first == "-h" || args.first == "--help" { self = .help; return }
                guard args.isEmpty else { throw CLIError("extensions install takes no arguments") }
                self = .extensionsInstall
            default: throw CLIError(Self.usage, exitCode: 2)
            }
        case "browser":
            switch args.popFirst() {
            case "-h", "--help": self = .help
            case "available":
                if args.first == "-h" || args.first == "--help" { self = .help; return }
                guard args.isEmpty else { throw CLIError("browser available takes no arguments", exitCode: 2) }
                self = .browserAvailable(pane: environment["TMUX_PANE"])
            case "open": self = try Self.browser(arguments: args, environment: environment)
            default: throw CLIError(Self.usage, exitCode: 2)
            }
        case "topic":
            if args.contains(where: { $0 == "-h" || $0 == "--help" }) { self = .help; return }
            self = .topic(try TopicInvocation(arguments: args, environment: environment))
        case "window":
            if args.contains(where: { $0 == "-h" || $0 == "--help" }) { self = .help; return }
            self = .window(try WindowInvocation(arguments: args, environment: environment))
        case "agent":
            if args.contains(where: { $0 == "-h" || $0 == "--help" }) { self = .help; return }
            if args.first == "conversation" {
                self = .agentConversation(try AgentConversationInvocation(arguments: args.dropFirst(), environment: environment))
            } else {
                self = .agent(try AgentInvocation(arguments: args, environment: environment))
            }
        case "session":
            switch args.popFirst() {
            case "list": self = .sessionList(try SessionListInvocation(arguments: ["list"] + args, environment: environment))
            case "-h", "--help": self = .help
            case "open":
                if args.first == "-h" || args.first == "--help" { self = .help; return }
                if args.first == "--" { args = args.dropFirst() }
                guard !args.isEmpty else { throw CLIError(Self.usage, exitCode: 2) }
                self = .sessionOpen(name: args.joined(separator: " "))
            case let verb? where verb == "lock" || verb == "unlock":
                if args.contains(where: { $0 == "-h" || $0 == "--help" }) { self = .help; return }
                self = .sessionLock(try SessionInvocation(locked: verb == "lock", arguments: args, environment: environment))
            default: throw CLIError(Self.usage, exitCode: 2)
            }
        default: throw CLIError(Self.usage, exitCode: 2)
        }
    }

    private static func browser(arguments: ArraySlice<String>, environment: [String: String]) throws -> Self {
        var args = arguments
        var target = ""
        options: while let argument = args.first {
            switch argument {
            case "-w", "--window":
                args = args.dropFirst()
                guard let value = args.popFirst() else { throw CLIError(usage, exitCode: 2) }
                target = value
            case let value where value.hasPrefix("--window="):
                target = String(value.dropFirst("--window=".count))
                args = args.dropFirst()
            case "-h", "--help": return .help
            case "--": args = args.dropFirst(); break options
            case let value where value.hasPrefix("-"): throw CLIError("unknown option \(value)")
            default: break options
            }
        }
        guard !args.isEmpty else { throw CLIError(usage, exitCode: 2) }
        if target.isEmpty {
            guard let pane = environment["TMUX_PANE"], !pane.isEmpty else {
                throw CLIError("not inside tmux; specify the Window with --window <id> (e.g. --window @12)")
            }
            target = pane
        }
        for url in args where url.contains(where: { $0.isWhitespace }) {
            throw CLIError("'\(url)' contains spaces; pass one URL per argument")
        }
        return .browserOpen(window: target, urls: Array(args))
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
            try check(result, command: "Extension installer")
        case .browserOpen(let target, let urls):
            // list-panes validates the target; display-message succeeds even for missing Windows.
            let result = try runner.run("tmux", arguments: ["list-panes", "-t", target, "-F", "#{window_id}"], quiet: true)
            let window = result.output.components(separatedBy: "\n").first ?? ""
            guard result.status == 0, !window.isEmpty else { throw CLIError("no tmux Window '\(target)'") }
            // Append so requests made before Muxify's next poll aren't overwritten.
            try check(runner.run("tmux", arguments: ["set-option", "-wa", "-t", window, "@muxify_open", " " + urls.joined(separator: " ")], quiet: false), command: "tmux")
        case .sessionOpen(let name):
            let result = try runner.run("tmux", arguments: ["has-session", "-t", "=\(name)"], quiet: true)
            guard result.status == 0 else { throw CLIError("no tmux session '\(name)'") }
            try open("muxify://select?session=\(Self.percentEncoded(name))", using: runner)
        case .topic(let invocation): try await invocation.run()
        case .sessionList(let invocation): try await invocation.run()
        case .agent(let invocation): try await invocation.run()
        case .agentConversation(let invocation): try invocation.run(using: runner)
        case .window(let invocation): try await invocation.run()
        case .sessionLock(let invocation): try invocation.run()
        }
        return 0
    }

    private func open(_ url: String, using runner: any CLICommandRunning) throws {
        try check(runner.run("open", arguments: [url], quiet: false), command: "open")
    }

    /// Encodes every UTF-8 byte, matching the original CLI's links.
    static func percentEncoded(_ value: String) -> String {
        value.utf8.map { String(format: "%%%02x", $0) }.joined()
    }

    private func check(_ result: CLICommandResult, command: String) throws {
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
