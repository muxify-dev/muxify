import Foundation
import MuxifyCore

/// One `muxify topic` command line. It runs the Topic service in this process, on the records under `paths`,
/// so it works without Muxify running. The service chooses what the request acts on: `target`, else `caller`.
struct TopicInvocation: Equatable {
    enum Command: Equatable {
        /// A `sessionPath` is as typed; it resolves to a real directory when the command runs.
        case new(title: String?, sessionPath: String?)
        /// `directory` resolves to its row of the New Topic list. `newWorktree` asks for a new Worktree from that
        /// row's Worktree, at its HEAD or at the ref `base`.
        case addSession(directory: String, newWorktree: Bool, base: String?)
        /// `removeWorktrees` removes each Worktree that the Settle sheet offers to remove, as if each box were selected.
        case settle(removeWorktrees: Bool, killSessions: Bool = false)
        case forget(removeWorktrees: Bool, killSessions: Bool = false)
        case list
        /// `conversations` also lists the conversation of each Agent that the Topic has or remembers.
        case show(conversations: Bool)
        /// `sessionPath` is as typed and limits the run to the Session that uses it. `command` is the argument vector
        /// after `--`; it runs once per live Session, never in a Pane.
        case exec(sessionPath: String?, timeout: TimeInterval, command: [String])
        /// The git status of each live Session, or of the one that uses `sessionPath`.
        case status(sessionPath: String?)
        /// One changeset across the live Sessions since each one's base. `stat` prints a summary, not the patch.
        case diff(sessionPath: String?, stat: Bool)
        /// The time as the time step of Snooze Topic reads typed text. It becomes a time when the command runs.
        /// `topics` are the `--topic` options; empty is the target or the caller Pane's Topic.
        case snooze(SnoozeSchedule, topics: [TopicRef])
        case unsnooze(topics: [TopicRef])
        case tag(TopicTagChange)

        /// The target options this command takes. A titled Topic in a SessionPath starts its own Session, so it takes none.
        var targets: [TargetOption] {
            switch self {
            case .new(_?, _?): return []
            case .new: return [.window, .pane]
            case .addSession, .settle, .forget, .show, .exec, .status, .diff, .snooze, .unsnooze, .tag: return [.topic, .window, .pane]
            case .list: return []
            }
        }

        var needsTarget: Bool { !targets.isEmpty }

        /// exec, status and diff work in the Sessions that `topic show` gives.
        var showsTopic: Bool {
            switch self {
            case .show, .exec, .status, .diff: return true
            default: return false
            }
        }

        /// A Snooze or a Tag change needs no SessionPath, and a command that shows a Topic finds only the SessionPaths of its Sessions.
        var findsAllSessionPaths: Bool {
            switch self {
            case .snooze, .unsnooze, .tag: return false
            default: return !showsTopic
            }
        }

        /// The command as the user typed it, for an error message.
        var phrase: String {
            switch self {
            case .new(_?, _?): return "topic new with a title and --directory"
            case .new: return "topic new"
            case .addSession: return "topic add-session"
            case .settle: return "topic settle"
            case .forget: return "topic forget"
            case .list: return "topic list"
            case .show: return "topic show"
            case .exec: return "topic exec"
            case .status: return "topic status"
            case .diff: return "topic diff"
            case .snooze: return "topic snooze"
            case .unsnooze: return "topic unsnooze"
            case .tag: return "topic tag"
            }
        }
    }

    enum TargetOption: String, CaseIterable {
        case topic = "--topic"
        case window = "--window"
        case pane = "--pane"

        var usage: String {
            switch self {
            case .topic: return "--topic <id|label>"
            case .window: return "--window <id>"
            case .pane: return "--pane <id>"
            }
        }

        func target(_ value: String) throws -> TopicTarget {
            switch self {
            case .topic:
                return .topic(.named(try Self.topicName(value)))
            case .window:
                guard let id = WindowID(rawValue: value) else { throw CLIError("--window takes a tmux Window id, e.g. @12", exitCode: 2) }
                return .window(id)
            case .pane:
                guard let id = PaneID(rawValue: value) else { throw CLIError("--pane takes a tmux Pane id, e.g. %3", exitCode: 2) }
                return .pane(id)
            }
        }

        /// The id or label of an open Topic, as every `--topic` takes it.
        static func topicName(_ value: String) throws -> String {
            guard !value.isEmpty else { throw CLIError("--topic takes the id or label of an open Topic", exitCode: 2) }
            return value
        }
    }

    /// The target options of one command line, and the caller Pane that `TMUX_PANE` names. A command acts on its
    /// target, else on the caller Pane's Window or Topic.
    struct TargetOptions {
        let accepted: [TargetOption]
        /// Snooze and Unsnooze act on each Topic of a repeated `--topic` in one write.
        let repeatsTopic: Bool
        private(set) var chosen: (option: TargetOption, target: TopicTarget)?
        /// Each `--topic`, in order.
        private(set) var topics: [TopicRef] = []

        init(accepting accepted: [TargetOption], repeatsTopic: Bool = false) {
            self.accepted = accepted
            self.repeatsTopic = repeatsTopic
        }

        /// Takes `argument` and its value from `args` when it is an accepted target option. False for any other word.
        mutating func take(_ argument: String, from args: inout ArraySlice<String>) throws -> Bool {
            guard let option = TargetOption(rawValue: argument), accepted.contains(option) else { return false }
            if let first = chosen?.option, !(repeatsTopic && first == .topic && option == .topic) {
                let names = accepted.map(\.rawValue)
                if repeatsTopic {
                    throw CLIError("give --topic one or more times, or only one of " + names.dropFirst().joined(separator: " and "), exitCode: 2)
                }
                throw CLIError("give only one of " + names.dropLast().joined(separator: ", ") + " and " + names.last!, exitCode: 2)
            }
            guard let value = args.popFirst() else { throw CLIError(CLICommand.usage, exitCode: 2) }
            let target = try option.target(value)
            if case .topic(let ref) = target { topics.append(ref) }
            if chosen == nil { chosen = (option, target) }
            return true
        }

        /// The caller Pane, or nil outside tmux. When `needed` and no option chose a target, a missing caller Pane is
        /// a usage error that names the `offered` options.
        func caller(environment: [String: String], needed: Bool, offered: [TargetOption]) throws -> PaneID? {
            let pane = environment["TMUX_PANE"].flatMap { $0.isEmpty ? nil : $0 }
            let caller = pane.flatMap(PaneID.init(rawValue:))
            if needed, chosen == nil, caller == nil {
                let problem = pane.map { "TMUX_PANE \($0) is not a tmux Pane id" } ?? "not inside tmux"
                throw CLIError(problem + TopicInvocation.choice(of: offered), exitCode: 2)
            }
            return caller
        }
    }

    enum Output: Equatable {
        /// Each changed Topic's id, the tab-separated lines of `topic list`, or a short `topic show`.
        case text
        /// The whole `TopicResponse` as one JSON line.
        case json
    }

    var command: Command
    var target: TopicTarget?
    var caller: PaneID?
    var output: Output
    var paths: MuxifyPaths
}

extension TopicInvocation {
    /// Parses the words after `topic`. A command line that the commands cannot run is a usage error, status 2.
    init(arguments: ArraySlice<String>, environment: [String: String]) throws {
        let usageError = CLIError(CLICommand.usage, exitCode: 2)
        var args = arguments
        guard let name = args.popFirst() else { throw usageError }
        var words: [String] = []
        var sessionPath: String?
        var session: String?
        var newWorktree = false
        var base: String?
        var removeWorktrees = false
        var killSessions = false
        var timeout: TimeInterval?
        var execArguments: [String]?
        var stat = false
        var conversations = false
        var targets = TargetOptions(accepting: TargetOption.allCases, repeatsTopic: name == "snooze" || name == "unsnooze")
        var output = Output.text
        while let argument = args.popFirst() {
            if try targets.take(argument, from: &args) {
                continue
            } else if argument == "--directory" {
                guard sessionPath == nil, let value = args.popFirst(), !value.isEmpty, !value.hasPrefix("-") else { throw usageError }
                sessionPath = value
            } else if argument == "--session" {
                guard session == nil, let value = args.popFirst(), !value.isEmpty else { throw usageError }
                session = value
            } else if argument == "--worktree" {
                newWorktree = true
            } else if argument == "--base" {
                guard base == nil, let value = args.popFirst(), !value.isEmpty, !value.hasPrefix("-") else { throw usageError }
                base = value
            } else if argument == "--remove-worktrees" {
                removeWorktrees = true
            } else if argument == "--kill-sessions" {
                killSessions = true
            } else if argument == "--json" {
                output = .json
            } else if argument == "--timeout" {
                guard timeout == nil, let value = args.popFirst(), let seconds = TimeInterval(value), seconds > 0, seconds.isFinite else {
                    throw usageError
                }
                timeout = seconds
            } else if argument == "--stat" {
                stat = true
            } else if argument == "--conversations" {
                conversations = true
            } else if argument == "--" {
                execArguments = Array(args)
                args = []
            } else if argument.hasPrefix("-") {
                throw usageError
            } else {
                words.append(argument)
            }
        }
        if name != "add-session", newWorktree || base != nil { throw usageError }
        if name != "settle", name != "forget", removeWorktrees { throw usageError }
        if name != "settle", name != "forget", killSessions { throw usageError }
        if name != "exec", timeout != nil || execArguments != nil { throw usageError }
        if name != "diff", stat { throw usageError }
        if name != "show", conversations { throw usageError }
        if !["exec", "status", "diff"].contains(name), session != nil { throw usageError }
        if name != "new", sessionPath != nil { throw usageError }
        switch (name, words.count, sessionPath) {
        case ("new", 0...1, _):
            if let title = words.first, title.allSatisfy(\.isWhitespace) { throw usageError }
            command = .new(title: words.first, sessionPath: sessionPath)
        case ("add-session", 1, nil) where newWorktree || base == nil:
            command = .addSession(directory: words[0], newWorktree: newWorktree, base: base)
        case ("settle", 0, nil): command = .settle(removeWorktrees: removeWorktrees, killSessions: killSessions)
        case ("forget", 0, nil): command = .forget(removeWorktrees: removeWorktrees, killSessions: killSessions)
        case ("list", 0, nil): command = .list
        case ("show", 0, nil): command = .show(conversations: conversations)
        case ("exec", 0, _):
            guard let execArguments, !execArguments.isEmpty else { throw usageError }
            command = .exec(sessionPath: session, timeout: timeout ?? 60, command: execArguments)
        case ("status", 0, _): command = .status(sessionPath: session)
        case ("diff", 0, _): command = .diff(sessionPath: session, stat: stat)
        case ("snooze", 1..., nil):
            // Unquoted words join, so `topic snooze mon 9am` reads as the time step reads "mon 9am". The time step
            // says "never", but on a command line `snooze never` reads as no Snooze, so the CLI says "forever".
            let text = words.joined(separator: " ")
            if text.lowercased() == "forever" {
                command = .snooze(.never, topics: targets.topics)
            } else if let schedule = SnoozeSchedule(text, typed: true), schedule != .never {
                command = .snooze(schedule, topics: targets.topics)
            } else {
                throw CLIError("topic snooze takes a time, e.g. 2h, 17:30, tomorrow, mon 9am or forever", exitCode: 2)
            }
        case ("unsnooze", 0, nil): command = .unsnooze(topics: targets.topics)
        case ("tag", 1..., nil):
            let tags = try words.dropFirst().map { word in
                guard let tag = Tag(typed: word) else {
                    throw CLIError("\(word) is not a Tag: use lower case letters, digits and -, e.g. backend", exitCode: 2)
                }
                return tag
            }
            switch words[0] {
            case "set": command = .tag(.set(tags))
            case "add" where !tags.isEmpty: command = .tag(.add(tags))
            case "remove" where !tags.isEmpty: command = .tag(.remove(tags))
            default: throw usageError
            }
        default: throw usageError
        }
        let takes = command.targets
        if let chosen = targets.chosen, !takes.contains(chosen.option) {
            throw CLIError("\(command.phrase) does not take \(chosen.option.rawValue)" + Self.choice(of: takes), exitCode: 2)
        }
        caller = try targets.caller(environment: environment, needed: command.needsTarget, offered: takes)
        // Snooze and Unsnooze send their `--topic` options in the command, as a list.
        switch command {
        case .snooze(_, let topics), .unsnooze(let topics): target = topics.isEmpty ? targets.chosen?.target : nil
        default: target = targets.chosen?.target
        }
        self.output = output
        paths = MuxifyPaths(environment: environment, home: environment["HOME"] ?? NSHomeDirectory())
    }

    static func choice(of options: [TargetOption]) -> String {
        let names = options.map(\.usage)
        guard let last = names.last else { return "" }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
        return "; name the target with " + list
    }

    func run() async throws {
        var response: TopicResponse
        if command == .list {
            response = TopicService(paths: paths).handle(TopicRequest(.list))
        } else {
            let config = try await ConfigSessions.load(paths.configFile, within: command.findsAllSessionPaths ? nil : [])
            func handle() throws -> TopicResponse {
                let service = TopicService(paths: paths, server: .local, sessionPaths: config.sessionPaths, topics: config.topics)
                // No client: no terminal switches to the result, because a command changes what the user sees only
                // when they ask for it.
                return service.handle(TopicRequest(try request(sessionPaths: config.sessionPaths, service: service), target: target,
                                                   caller: caller.map(TopicCaller.pane)))
            }
            response = try handle()
        }
        if case .topic(let topic) = response {
            switch command {
            case .exec(let sessionPath, let timeout, let arguments):
                let sessions = try TopicExec.sessions(of: topic, session: sessionPath)
                return try TopicExec(arguments: arguments, timeout: timeout).run(sessions, topic: topic, output: output)
            case .status(let sessionPath):
                return try TopicGit(report: .status).run(try TopicExec.sessions(of: topic, session: sessionPath),
                                                         topic: topic, output: output)
            case .diff(let sessionPath, let stat):
                return try TopicGit(report: .diff(stat: stat)).run(try TopicExec.sessions(of: topic, session: sessionPath),
                                                                   topic: topic, output: output)
            case .show(conversations: true):
                return try reportConversations(of: topic)
            default: break
            }
        }
        try Self.report(response, output: output)
    }

    /// Prints a response of the Topic service, and throws its failure so that the command exits with an error.
    static func report(_ response: TopicResponse, output: Output) throws {
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(response), as: UTF8.self))
        case .text:
            switch response {
            case .topics(let topics):
                // One line per Topic, so a label keeps no tab or line break.
                for topic in topics {
                    print(Self.line(id: topic.id, label: topic.label, tags: topic.tags))
                }
            case .topic(let topic):
                // One line for the Topic, then one for each live Session, with tab-separated fields as in topic list.
                print(Self.line(id: topic.id, label: topic.label, tags: topic.tags))
                for session in topic.sessions {
                    print([session.name, session.baseName, session.directory,
                           session.worktree?.branch ?? ""].map(\.oneLineField).joined(separator: "\t"))
                }
            case .changed(let change): if let id = change.topicID { print(id) }
            case .snoozeChanged(let change): for id in change.topicIDs { print(id) }
            case .failed: break
            }
        }
        if case .failed(let failure) = response { throw CLIError(failure) }
    }

    /// A Topic's line in `topic list` and `topic show`: id, label, and its Tags with `#`, which an empty field
    /// gives when it has none.
    private static func line(id: String, label: String, tags: [Tag]) -> String {
        [id, label.oneLineField, tags.map(\.description).joined(separator: " ")].joined(separator: "\t")
    }

    /// `topic show --conversations`: the Topic as `topic show` prints it, then the conversation of each Agent in its live
    /// Panes and in its remembered Sessions, which `agent conversation --conversation <id> --kind <kind>` reads.
    private func reportConversations(of topic: TopicDetail) throws {
        let record: TopicRecord?
        do {
            record = try TopicStore(paths: paths).read().records.first { $0.id == topic.id }
        } catch {
            throw CLIError("Muxify could not read the Topic records in \(paths.state.path). \(error.localizedDescription)")
        }
        let conversations = record?.agentConversations(in: TmuxServer.local.snapshot()) ?? []
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(TopicConversations(topic: topic, conversations: conversations)), as: UTF8.self))
        case .text:
            try Self.report(.topic(topic), output: .text)
            for conversation in conversations {
                print(["conversation", conversation.kind.rawValue, conversation.id].map(\.oneLineField).joined(separator: "\t"))
            }
        }
    }

    private func request(sessionPaths: [SessionPath], service: TopicService) throws -> TopicCommand {
        switch command {
        case .new(nil, let sessionPath): return .extract(sessionPath: try sessionPath.map(Self.directory)?.real)
        case .new(let title?, let sessionPath): return .create(title: title, sessionPath: try sessionPath.map(Self.directory)?.real)
        case .addSession(let path, let newWorktree, let base):
            let directory = try Self.directory(path)
            // A folder in no SessionPath goes to the service as typed, which fails with the Config's own words.
            guard let choice = SessionChoice.containing(directory, in: sessionPaths) else {
                return .addSession(sessionPath: directory.real, workingCopy: .directory)
            }
            if newWorktree, choice.worktree == nil {
                throw CLIError("--worktree needs a git repository, and \(choice.directory.path) is not one", exitCode: 2)
            }
            // The same choice as the Add Session sheet makes for this row.
            return .addSession(sessionPath: choice.sessionPath.folder.path, workingCopy: choice.workingCopy(newWorktree: newWorktree, base: base), name: choice.name)
        case .forget(let remove, let kill):
            guard let target = target ?? caller.map(TopicTarget.pane),
                  var choices = try? service.forgetChoices(for: target).get() else { return .forget(choices: [], worktrees: []) }
            if kill { for index in choices.sessions.indices { choices.sessions[index].disposition = .kill } }
            return .forget(choices: choices.sessions, worktrees: remove ? choices.worktrees.filter { $0.canRemove(sessions: choices.sessions) }.map(\.id) : [])
        case .settle(let remove, let kill):
            // Choices that fail to load leave the defaults, so the request itself reports why the Topic cannot settle.
            guard let settled = target ?? caller.map(TopicTarget.pane),
                  var choices = try? service.settleChoices(for: settled).get() else { return .settle(choices: [], outcome: "") }
            for index in choices.indices {
                if kill { choices[index].disposition = .kill }
                choices[index].removeWorktree = remove && choices[index].worktree != nil
            }
            return .settle(choices: choices, outcome: "")
        case .snooze(let schedule, let topics):
            // Only a time later today can be past, e.g. today 8:00 at 9:00.
            guard let deadline = schedule.deadline(from: Date()) else { throw CLIError("that time has already passed", exitCode: 2) }
            return .snooze(until: deadline, topics: topics)
        case .unsnooze(let topics): return .unsnooze(topics: topics)
        case .tag(let change): return .tags(change)
        case .list: return .list
        case .show, .exec, .status, .diff: return .show
        }
    }

    /// The directory `path` names. Its real path is where `cd -P` would reach it.
    static func directory(_ path: String) throws -> Folder {
        var isDirectory: ObjCBool = false
        let folder = Folder.local(path)
        guard FileManager.default.fileExists(atPath: folder.real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError(CLICommand.usage, exitCode: 2)
        }
        return folder
    }
}

/// The `--json` form of `topic show --conversations`.
private struct TopicConversations: Encodable {
    struct Conversation: Encodable {
        let kind: AgentKind
        let conversation: String
    }

    let topic: TopicDetail
    let conversations: [Conversation]

    init(topic: TopicDetail, conversations: [AgentConversation]) {
        self.topic = topic
        self.conversations = conversations.map { Conversation(kind: $0.kind, conversation: $0.id) }
    }
}
