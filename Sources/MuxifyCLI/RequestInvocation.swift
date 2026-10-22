import Foundation
import MuxifyCore

/// One command line that sends a request through `EnvironmentService` in this process, on the records under `paths`,
/// so it works without Muxify running. The service chooses what the request acts on: `target`, else `caller`.
struct RequestInvocation: Equatable {
    enum Command: Equatable {
        /// An Empty Topic.
        case new(title: String, tags: [Tag])
        /// `directory` resolves to its row of the New Topic list. `newWorktree` asks for a new Worktree from that
        /// row's Worktree, which starts as it says.
        case addSession(directory: String, newWorktree: WorktreeStart?)
        /// `removeWorktrees` removes each Worktree that the Settle sheet offers to remove, as if each box were selected.
        case settle(removeWorktrees: Bool, killSessions: Bool = false)
        case forget(removeWorktrees: Bool, killSessions: Bool = false)
        case list
        /// `conversations` also lists the conversation of each Agent that the Topic has or remembers.
        case show(conversations: Bool)
        /// Shows the Topic in Muxify, as Jump To does. It finds the Topic as `topic show` does, then opens its URL.
        case open
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
        case rename(title: String)
        /// A Dormant or Settled Topic has no Pane, so these take only `--topic`.
        case reopen
        case startFresh
        case lock(Bool)
        /// `topic` is an open Topic's id or label. `session` chooses its destination Session; `newSession` makes one.
        case moveWindow(topic: String, session: String?, newSession: Bool)
        /// Before or after another Window of the same Session.
        case placeWindow(WindowPlacement)
        case moveToNewTopic(title: String)
        /// The caller's Pane, or the Pane that `--pane` names, into a new Window of its Session.
        case moveToNewWindow(title: String)
        /// `kill` stops the Session. `removeWorktree` also removes the clean Worktree that the Topic made for it.
        case removeSessionFromTopic(kill: Bool, removeWorktree: Bool)
        /// Into the No Topic Session that `session` names, or into a new one when nil.
        case removeWindowFromTopic(session: String?)
        /// `command` is the argument vector after `--`; nil starts the default shell.
        case newWindow(command: [String]?)
        /// `directory` is as typed; it resolves to a real directory when the command runs.
        case newSession(directory: String, name: String?)
        case renameSession(name: String)
        case renameWindow(name: String)
        case kill(session: Bool)
        case pin(Bool)
        /// The Topic's card, one place up or down.
        case moveCard(CardMove)
        /// The Session one place up or down among its Topic's Sessions, or a Locked Session's card.
        case moveSession(TopicSessionPlacement)
        case sortSessions
        /// Zen keeps the target's Topic until the time, which becomes a time when the command runs.
        case zen(SnoozeSchedule)
        case endZen
        /// Read or Unread for the `scope` of the target or of the caller's Pane.
        case markRead(ReadChange, scope: ReadScope)
        case markAllRead

        /// The target options this command takes. `topic new` makes an Empty Topic, so it takes none.
        var targets: [TargetOption] {
            switch self {
            case .new: return []
            case .addSession, .settle, .forget, .show, .open, .exec, .status, .diff, .snooze, .unsnooze, .tag, .rename, .pin, .moveCard, .sortSessions, .zen:
                return [.topic, .window, .pane]
            case .moveSession: return [.session, .pane]
            case .reopen, .startFresh: return [.topic]
            case .lock: return [.session]
            case .moveWindow, .moveToNewTopic, .removeWindowFromTopic: return [.window, .pane]
            case .moveToNewWindow: return [.pane]
            case .newWindow: return [.topic, .session, .window, .pane]
            case .newSession: return []
            case .renameSession: return [.session, .window, .pane]
            case .renameWindow, .placeWindow: return [.window, .pane]
            case .kill(let session): return session ? [.session, .window, .pane] : [.window, .pane]
            case .removeSessionFromTopic: return [.session, .pane]
            case .markRead(_, .topic): return [.topic, .window, .pane]
            case .markRead(_, .session): return [.session, .window, .pane]
            case .markRead(_, .window): return [.window, .pane]
            case .markRead(_, .pane): return [.pane]
            case .list, .endZen, .markAllRead: return []
            }
        }

        var needsTarget: Bool { !targets.isEmpty }

        /// exec, status and diff work in the Sessions that `topic show` gives.
        var showsTopic: Bool {
            switch self {
            case .show, .open, .exec, .status, .diff: return true
            default: return false
            }
        }

        /// A Snooze or a Tag change needs no SessionPath, and a command that shows a Topic finds only the SessionPaths of its Sessions.
        var findsAllSessionPaths: Bool {
            switch self {
            case .new, .snooze, .unsnooze, .tag, .lock, .pin, .moveCard, .moveSession, .sortSessions, .zen, .endZen, .markRead, .markAllRead,
                 .placeWindow: return false
            default: return !showsTopic
            }
        }

        /// The command as the user typed it, for an error message.
        var phrase: String {
            switch self {
            case .new: return "topic new"
            case .addSession: return "topic add-session"
            case .settle: return "topic settle"
            case .forget: return "topic forget"
            case .list: return "topic list"
            case .show: return "topic show"
            case .open: return "topic open"
            case .exec: return "topic exec"
            case .status: return "topic status"
            case .diff: return "topic diff"
            case .snooze: return "topic snooze"
            case .unsnooze: return "topic unsnooze"
            case .tag: return "topic tag"
            case .rename: return "topic rename"
            case .reopen: return "topic reopen"
            case .startFresh: return "topic start-fresh"
            case .lock(let locked): return locked ? "session lock" : "session unlock"
            case .moveWindow: return "window move"
            case .moveToNewTopic: return "window move --new-topic"
            case .moveToNewWindow: return "window move --new-window"
            case .removeSessionFromTopic: return "session remove-from-topic"
            case .removeWindowFromTopic: return "window remove-from-topic"
            case .newWindow: return "window new"
            case .newSession: return "session new"
            case .renameSession: return "session rename"
            case .renameWindow: return "window rename"
            case .placeWindow: return "window move"
            case .kill(let session): return session ? "session kill" : "window kill"
            case .pin(let pinned): return pinned ? "topic pin" : "topic unpin"
            case .moveCard: return "topic move"
            case .moveSession: return "session move"
            case .sortSessions: return "topic sort-sessions"
            case .zen: return "zen start"
            case .endZen: return "zen end"
            case .markRead(let change, let scope): return CLIVerbPath.markRead(change, scope: scope).rawValue
            case .markAllRead: return "mark-all-read"
            }
        }
    }

    enum TargetOption: String, CaseIterable {
        case topic = "--topic"
        case window = "--window"
        case pane = "--pane"
        case session = "--session"

        var usage: String {
            switch self {
            case .session: return "--session <name|id>"
            case .topic: return "--topic <id|label>"
            case .window: return "--window <id>"
            case .pane: return "--pane <id>"
            }
        }

        func target(_ value: String) throws -> EnvironmentTarget {
            switch self {
            case .topic:
                return .topic(.named(try Self.topicName(value)))
            case .window:
                guard let id = WindowID(rawValue: value) else { throw CLIError("--window takes a tmux Window id, e.g. @12", exitCode: 2) }
                return .window(id)
            case .pane:
                guard let id = PaneID(rawValue: value) else { throw CLIError("--pane takes a tmux Pane id, e.g. %3", exitCode: 2) }
                return .pane(id)
            case .session:
                guard !value.isEmpty else { throw CLIError("--session takes the name or id of a tmux Session", exitCode: 2) }
                return SessionID(rawValue: value).map(EnvironmentTarget.session) ?? .sessionName(value)
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
        private(set) var chosen: (option: TargetOption, target: EnvironmentTarget)?
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
            guard let value = args.popFirst() else { throw CLIError.usage }
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
                throw CLIError(problem + RequestInvocation.choice(of: offered), exitCode: 2)
            }
            return caller
        }
    }

    enum Output: Equatable {
        /// Each changed Topic's id, the tab-separated lines of `topic list`, or a short `topic show`.
        case text
        /// The whole `EnvironmentResponse` as one JSON line.
        case json
    }

    var command: Command
    var target: EnvironmentTarget?
    var caller: PaneID?
    var output: Output
    var paths: MuxifyPaths
}

extension RequestInvocation {
    /// The command that a verb built, with the target options and the caller of its command line. A target
    /// option that the command does not take is a usage error that names the options it takes.
    init(_ command: Command, parsed: ParsedArguments) throws {
        self.command = command
        let takes = command.targets
        if let chosen = parsed.targets.chosen, !takes.contains(chosen.option) {
            throw CLIError("\(command.phrase) does not take \(chosen.option.rawValue)" + Self.choice(of: takes), exitCode: 2)
        }
        caller = try parsed.targets.caller(environment: parsed.environment, needed: command.needsTarget, offered: takes)
        // Snooze and Unsnooze send their `--topic` options in the command, as a list.
        switch command {
        case .snooze(_, let topics), .unsnooze(let topics): target = topics.isEmpty ? parsed.targets.chosen?.target : nil
        default: target = parsed.targets.chosen?.target
        }
        output = parsed.output
        paths = parsed.paths
    }

    static func choice(of options: [TargetOption]) -> String {
        let names = options.map(\.usage)
        guard let last = names.last else { return "" }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
        return "; name the target with " + list
    }

    func run() async throws {
        var response: EnvironmentResponse
        switch command {
        case .list:
            response = EnvironmentService(paths: paths).handle(EnvironmentRequest(.list))
        case .lock(let locked):
            response = EnvironmentService(paths: paths).handle(EnvironmentRequest(locked ? .lock : .unlock, target: target,
                                                                                caller: caller.map(TopicCaller.pane)))
        default:
            let config = try await ConfigSessions.load(paths.configFile, within: command.findsAllSessionPaths ? nil : [])
            func handle() throws -> EnvironmentResponse {
                let service = EnvironmentService(paths: paths, server: TmuxServer.local, sessionPaths: config.sessionPaths, topics: config.topics)
                // No client: no terminal switches to the result, because a command changes what the user sees only
                // when they ask for it.
                return service.handle(EnvironmentRequest(try request(sessionPaths: config.sessionPaths, service: service), target: target,
                                                         caller: caller.map(TopicCaller.pane)))
            }
            do {
                response = try handle()
            } catch let answer as Answer {
                response = answer.response
            }
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
            case .open:
                return try CLICommand.open("muxify://select?topic=\(CLICommand.percentEncoded(topic.id))")
            default: break
            }
        }
        try Self.report(response, output: output)
    }

    /// Prints a response of the Topic service, and throws its failure so that the command exits with an error.
    static func report(_ response: EnvironmentResponse, output: Output) throws {
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
            // A Topic change prints the Topic's id, a change of a Window the Window's id, and a Session rename the full name.
            case .changed(let change): if let id = change.topicID ?? change.window?.rawValue ?? change.sessionName { print(id) }
            case .snoozeChanged(let change): for id in change.topicIDs { print(id) }
            case .readChanged(let change): for id in change.topicIDs + change.paneIDs.map(\.rawValue) { print(id) }
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

    private func request(sessionPaths: [SessionPath], service: EnvironmentService) throws -> EnvironmentCommand {
        switch command {
        case .new(let title, let tags): return .create(title: title, tags: tags.isEmpty ? nil : tags)
        case .addSession(let path, let newWorktree):
            let directory = try Self.directory(path)
            // A folder in no SessionPath goes to the service as typed, which fails with the Config's own words.
            guard let choice = SessionChoice.containing(directory, in: sessionPaths) else {
                return .addSession(sessionPath: directory.real, workingCopy: .directory)
            }
            if newWorktree != nil, choice.worktree == nil {
                throw CLIError("--worktree needs a git repository, and \(choice.directory.path) is not one", exitCode: 2)
            }
            // The same choice as the Add Session sheet makes for this row.
            return .addSession(sessionPath: choice.sessionPath.folder.path, workingCopy: choice.workingCopy(newWorktree: newWorktree != nil, start: newWorktree ?? .head), name: choice.name)
        case .forget(let remove, let kill):
            guard let target = target ?? caller.map(EnvironmentTarget.pane),
                  var choices = try? service.forgetChoices(for: target).get() else { return .forget(choices: [], worktrees: []) }
            if kill { for index in choices.sessions.indices { choices.sessions[index].disposition = .kill } }
            return .forget(choices: choices.sessions, worktrees: remove ? choices.worktrees.filter { $0.canRemove(sessions: choices.sessions) }.map(\.id) : [])
        case .settle(let remove, let kill):
            // Choices that fail to load leave the defaults, so the request itself reports why the Topic cannot settle.
            guard let settled = target ?? caller.map(EnvironmentTarget.pane),
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
        case .zen(let schedule):
            guard let deadline = schedule.deadline(from: Date()) else { throw CLIError("that time has already passed", exitCode: 2) }
            return .startZen(until: deadline)
        case .endZen: return .endZen
        case .markRead(let change, let scope): return .markRead(change, scope: scope)
        case .markAllRead: return .markAllRead
        case .tag(let change): return .tags(change)
        case .list: return .list
        case .show, .open, .exec, .status, .diff: return .show
        case .rename(let title): return .rename(title: title)
        case .reopen: return .reopen
        case .startFresh: return .startFresh
        case .lock(let locked): return locked ? .lock : .unlock
        case .moveWindow(let topic, let session, let newSession):
            guard let session else { return .move(to: newSession ? .newSession(topic: .named(topic)) : .topic(.named(topic))) }
            let response = service.handle(EnvironmentRequest(.show, target: .topic(.named(topic))))
            guard case .topic(let detail) = response else { throw Answer(response) }
            guard let chosen = detail.sessions.first(where: { $0.id == session || $0.name == session }),
                  let id = SessionID(rawValue: chosen.id) else { throw CLIError("no live Session of the Topic \(detail.label) matches \(session)") }
            return .move(to: .session(id))
        case .moveToNewTopic(let title): return .move(to: .newTopic(title: title))
        case .moveToNewWindow(let title): return .move(to: .newWindow(title: title))
        case .removeSessionFromTopic(kill: false, _): return .removeFromTopic
        case .removeSessionFromTopic(kill: true, let removeWorktree):
            guard removeWorktree, let session = target ?? caller.map(EnvironmentTarget.pane) else { return .removeAndKill(worktrees: []) }
            let worktree: TopicForgetChoices.Worktree?
            switch service.removeAndKillWorktree(of: session) {
            case .success(let made): worktree = made
            case .failure(let failure): throw Answer(.failed(failure))
            }
            guard let worktree else { throw CLIError("The Session works in no Worktree that Muxify made. No changes were made.") }
            guard worktree.isClean else {
                throw CLIError(TopicRequestError.worktreeHasChanges(worktree.spec.path).description + " No changes were made.")
            }
            guard worktree.sessionIDs.count <= 1 else {
                throw CLIError("Another live Session works in the Worktree \(worktree.spec.path). No changes were made.")
            }
            return .removeAndKill(worktrees: [worktree.id])
        case .newWindow(let command): return .newWindow(command: command)
        case .newSession(let path, let name): return .newSession(sessionPath: try Self.directory(path).real, name: name)
        case .renameSession(let name): return .renameSession(name: name)
        case .renameWindow(let name): return .renameWindow(name: name)
        case .placeWindow(let placement): return .moveWindow(to: placement)
        case .kill(let session): return session ? .killSession : .killWindow
        case .pin(let pinned): return pinned ? .pin : .unpin
        case .moveCard(let move): return .moveCard(move)
        case .moveSession(let placement): return .moveSession(to: placement)
        case .sortSessions: return .sortSessions
        case .removeWindowFromTopic(nil): return .move(to: .newSession(topic: nil))
        case .removeWindowFromTopic(let name?):
            let records = try TopicStore(paths: paths).read().records
            guard let window = TmuxServer.local.snapshot().windows.first(where: { $0.sessionID == name || $0.sessionName == name }),
                  let id = SessionID(rawValue: window.sessionID) else { throw CLIError(TopicRequestError.sessionUnavailable(name).description) }
            if let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) {
                throw CLIError("The Session \(window.sessionName) is in the Topic \(TopicSummary(record: topic).label). Name a No Topic Session, "
                               + "or use window move --topic. No changes were made.")
            }
            return .move(to: .session(id))
        }
    }

    /// A response that ends the command before its request, such as the failure of a read that the request needs.
    private struct Answer: Error {
        let response: EnvironmentResponse
        init(_ response: EnvironmentResponse) { self.response = response }
    }

    /// The directory `path` names. Its real path is where `cd -P` would reach it.
    static func directory(_ path: String) throws -> Folder {
        var isDirectory: ObjCBool = false
        let folder = Folder.local(path)
        guard FileManager.default.fileExists(atPath: folder.real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.usage
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

extension CLIVerbPath {
    /// The verb that marks this scope Read or Unread.
    static func markRead(_ change: ReadChange, scope: ReadScope) -> CLIVerbPath {
        switch (scope, change) {
        case (.topic, .read): .topicMarkRead
        case (.topic, .unread): .topicMarkUnread
        case (.session, .read): .sessionMarkRead
        case (.session, .unread): .sessionMarkUnread
        case (.window, .read): .windowMarkRead
        case (.window, .unread): .windowMarkUnread
        case (.pane, .read): .agentMarkRead
        case (.pane, .unread): .agentMarkUnread
        }
    }
}
