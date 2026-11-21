import Foundation
import MuxifyCore

/// One command line that sends a request through `EnvironmentService` in this process, on the records under `paths`,
/// so it works without Muxify running. The service chooses what the request acts on: `target`, else `caller`.
struct RequestInvocation: Equatable {
    enum Command: Equatable {
        /// An Empty Topic.
        case new(title: String, tags: [Tag])
        /// `directory` resolves to its row of the New Topic list. `newWorktree` asks for a new Worktree from that
        /// row's Worktree, which starts as it says. `name` is the Session's exact name in the Topic, which the caller chose:
        /// a Session of the Topic that has it is found, not made again.
        case addSession(directory: String, newWorktree: WorktreeStart?, name: String? = nil)
        /// `removeWorktrees` removes each Worktree that the Settle sheet offers to remove, as if each box were selected.
        case settle(removeWorktrees: Bool, killSessions: Bool = false)
        case forget(removeWorktrees: Bool, killSessions: Bool = false)
        /// Nil takes the Config's `topics.forget_settled_older_than`.
        case forgetSettled(olderThan: Int?)
        case list
        /// Every live Session and the Topics list, as `EnvironmentSnapshot` orders them.
        case environmentShow
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
        case tag(TopicTagChange)
        case rename(title: String)
        /// A Dormant or Settled Topic has no Pane, so these take only `--topic`. Reopen also takes a Dormant Guest Session
        /// by its Lock id.
        case reopen
        case startFresh
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
        case zoomPane
        case kill(session: Bool)
        case pin(Bool)
        /// Make a Guest of the Benched Topic.
        case makeGuest
        /// Bench of a Topic: the In Play Topic goes to the top of the Bench.
        case benchTopic
        /// The Topic fills the Open Place at this In Play place, counted from 1.
        case fillPlace(Int)
        /// Nil clears the Topic Note.
        case note(String?)
        /// The Topic's card, one place up or down.
        case moveCard(CardMove)
        /// The Topic's card next to another card, as a drag inside one section does.
        case placeCard(next: CardName, after: Bool)
        /// The card that trades places with the Topic's card, as a drag across the Bench line does.
        case tradeCard(with: CardName)
        /// The cards In Play, in their order, and then the top of the Bench.
        case chooseInPlay([CardName])
        /// The Benched card that takes the place of the target's card In Play.
        case replaceFromBench(with: CardName)
        /// The Session one place up or down among its Topic's Sessions, or a Locked Session's card.
        case moveSession(TopicSessionPlacement)
        /// The whole Session into an open Topic or a new Topic, as Move Session does.
        case moveWholeSession(to: SessionDestination)
        case sortSessions
        /// Read or Unread for the `scope` of the target or of the caller's Pane.
        case markRead(ReadChange, scope: ReadScope)
        case markAllRead
        /// A Muxify Worktree from the checkout at `from`, the folder the command runs in. `open` switches the caller
        /// Pane's terminal to its Session.
        case createWorktree(name: String, from: String, start: WorktreeStart, open: Bool)
        case removeWorktree(String, kill: Bool, force: Bool)
        /// Nil `from` lists every Muxify Worktree.
        case listWorktrees(from: String?)
        /// A Session opened in `directory` at `at`, on a caller that Muxify does not see, such as the phone.
        case visitSessionPath(directory: String, at: Date)

        /// The target options this command takes. `topic new` makes an Empty Topic, so it takes none.
        var targets: [TargetOption] {
            switch self {
            case .new: return []
            case .addSession, .settle, .forget, .show, .open, .exec, .status, .diff, .tag, .note, .rename, .pin, .fillPlace, .moveCard, .placeCard, .tradeCard,
                 .sortSessions:
                return [.topic, .window, .pane]
            case .moveSession: return [.session, .guestSession, .pane]
            case .moveWholeSession: return [.session, .pane]
            case .replaceFromBench, .makeGuest: return [.topic, .session, .window, .pane]
            case .benchTopic: return [.topic, .session, .guestSession, .window, .pane]
            case .reopen: return [.topic, .guestSession]
            case .startFresh: return [.topic]
            case .moveWindow, .moveToNewTopic, .removeWindowFromTopic: return [.window, .pane]
            case .moveToNewWindow: return [.pane]
            case .newWindow: return [.topic, .session, .window, .pane]
            case .newSession: return []
            case .renameSession: return [.session, .window, .pane]
            case .renameWindow, .placeWindow, .zoomPane: return [.window, .pane]
            case .kill(let session): return session ? [.session, .window, .pane] : [.window, .pane]
            case .removeSessionFromTopic: return [.session, .pane]
            case .markRead(_, .topic), .markRead(_, .topicMark): return [.topic, .window, .pane]
            case .markRead(_, .session): return [.session, .window, .pane]
            case .markRead(_, .window): return [.window, .pane]
            case .markRead(_, .pane): return [.pane]
            case .list, .environmentShow, .markAllRead, .chooseInPlay, .forgetSettled, .createWorktree, .removeWorktree, .listWorktrees,
                 .visitSessionPath: return []
            }
        }

        var needsTarget: Bool { !targets.isEmpty }

        /// What `--request` means for this command. A new command does not compile until it chooses.
        var requestPolicy: RequestPolicy {
            switch self {
            case .list, .environmentShow, .show, .open, .exec, .status, .diff, .listWorktrees:
                return .read
            // Each of these gives one end state however many times it runs: it sets a value, or it finds what its
            // first run made.
            case .new, .tag, .note, .rename, .pin, .markRead, .markAllRead, .chooseInPlay, .sortSessions, .visitSessionPath:
                return .rerun
            // Without a new Worktree, a second run finds the Session by its name. A new Worktree has setup that only
            // the first run can type into the Session.
            case .addSession(_, let newWorktree, let name):
                return name != nil && newWorktree == nil ? .rerun : .inDoubt
            // A second run could apply these twice: a move from the place where the first run left the card, a
            // Session or a Window that tmux makes again, a Topic that is no longer where the first run found it.
            case .settle, .forget, .forgetSettled, .reopen, .startFresh, .moveWindow, .placeWindow, .moveToNewTopic, .moveToNewWindow,
                 .removeSessionFromTopic, .removeWindowFromTopic, .newWindow, .newSession, .renameSession, .renameWindow, .zoomPane, .kill,
                 .makeGuest, .benchTopic, .fillPlace, .moveCard, .placeCard, .tradeCard, .replaceFromBench, .moveSession,
                 .moveWholeSession, .createWorktree, .removeWorktree:
                return .inDoubt
            }
        }

        /// exec, status and diff work in the Sessions that `topic show` gives.
        var showsTopic: Bool {
            switch self {
            case .show, .open, .exec, .status, .diff: return true
            default: return false
            }
        }

        /// A Tag change needs no SessionPath, and a command that shows a Topic finds only the SessionPaths of its Sessions.
        var findsAllSessionPaths: Bool {
            switch self {
            case .new, .environmentShow, .tag, .note, .pin, .makeGuest, .benchTopic, .fillPlace, .moveCard, .placeCard, .tradeCard, .chooseInPlay, .replaceFromBench, .moveSession, .sortSessions, .markRead, .markAllRead,
                 .forgetSettled, .placeWindow, .zoomPane, .createWorktree, .removeWorktree, .listWorktrees, .visitSessionPath: return false
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
            case .forgetSettled: return "topic forget-settled"
            case .list: return "topic list"
            case .environmentShow: return "environment show"
            case .show: return "topic show"
            case .open: return "topic open"
            case .exec: return "topic exec"
            case .status: return "topic status"
            case .diff: return "topic diff"
            case .tag: return "topic tag"
            case .note: return "topic note"
            case .rename: return "topic rename"
            case .reopen: return "topic reopen"
            case .startFresh: return "topic start-fresh"
            case .moveWindow: return "window move"
            case .moveToNewTopic: return "window move --new-topic"
            case .moveToNewWindow: return "window move --new-window"
            case .removeSessionFromTopic: return "session remove-from-topic"
            case .removeWindowFromTopic: return "window remove-from-topic"
            case .newWindow: return "window new"
            case .newSession: return "session new"
            case .renameSession: return "session rename"
            case .renameWindow: return "window rename"
            case .zoomPane: return "window zoom"
            case .placeWindow: return "window move"
            case .kill(let session): return session ? "session kill" : "window kill"
            case .pin(let pinned): return pinned ? "topic pin" : "topic unpin"
            case .makeGuest: return "topic make-guest"
            case .benchTopic: return "topic bench"
            case .fillPlace: return "topic fill-place"
            case .moveCard, .placeCard, .tradeCard: return "topic move"
            case .chooseInPlay: return "topic choose-in-play"
            case .replaceFromBench: return "topic replace-from-bench"
            case .moveSession, .moveWholeSession: return "session move"
            case .sortSessions: return "topic sort-sessions"
            case .markRead(let change, let scope): return CLIVerbPath.markRead(change, scope: scope).rawValue
            case .markAllRead: return "mark-all-read"
            case .createWorktree: return "worktree create"
            case .removeWorktree: return "worktree remove"
            case .listWorktrees: return "worktree list"
            case .visitSessionPath: return "session-paths visit"
            }
        }
    }

    /// Where `session move` takes a whole Session.
    enum SessionDestination: Equatable {
        case topic(String)
        case newTopic(title: String)
    }

    /// A card of the Topics list as a command line names it: an open Topic by id or label, a Locked Session by name
    /// or id, or an Open Place by id.
    enum CardName: Equatable {
        case topic(String)
        case session(String)
        case openPlace(String)

        /// A Session name becomes its id here, because a card on the wire names a Locked Session by its id.
        var ref: TopicListRef {
            get throws {
                switch self {
                case .topic(let name): return .topic(.named(name))
                case .openPlace(let id): return .openPlace(id)
                case .session(let value):
                    guard let window = try TmuxServer.local.snapshot().windows.first(where: { $0.sessionID == value || $0.sessionName == value }),
                          let id = SessionID(rawValue: window.sessionID) else {
                        throw CLIError(TopicRequestError.sessionUnavailable(value).description)
                    }
                    return .lock(id)
                }
            }
        }
    }

    /// The exit status when the Request id has a row for another verb or other arguments.
    static let requestMismatchExitCode: Int32 = 3
    /// The exit status when the Request changed the records, did not finish, and cannot run again.
    static let requestInDoubtExitCode: Int32 = 4

    enum TargetOption: String, CaseIterable {
        case topic = "--topic"
        case window = "--window"
        case pane = "--pane"
        case session = "--session"
        /// A Guest Session, live or Dormant, by the id of its Lock, which `environment show` gives.
        case guestSession = "--guest-session"

        var usage: String {
            switch self {
            case .session: return "--session <name|id>"
            case .topic: return "--topic <id|label>"
            case .window: return "--window <id>"
            case .pane: return "--pane <id>"
            case .guestSession: return "--guest-session <id>"
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
            case .guestSession:
                guard !value.isEmpty else { throw CLIError("--guest-session takes the id of a Guest Session, as environment show gives it", exitCode: 2) }
                return .guestSession(value)
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
        private(set) var chosen: (option: TargetOption, target: EnvironmentTarget)?

        init(accepting accepted: [TargetOption]) {
            self.accepted = accepted
        }

        /// Takes `argument` and its value from `args` when it is an accepted target option. False for any other word.
        mutating func take(_ argument: String, from args: inout ArraySlice<String>) throws -> Bool {
            guard let option = TargetOption(rawValue: argument), accepted.contains(option) else { return false }
            if chosen != nil {
                let names = accepted.map(\.rawValue)
                throw CLIError("give only one of " + names.dropLast().joined(separator: ", ") + " and " + names.last!, exitCode: 2)
            }
            guard let value = args.popFirst() else { throw CLIError.usage }
            chosen = (option, try option.target(value))
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
    /// The Request that `--request` names. Nil runs the command as before, with no ledger.
    var request: PendingRequest? = nil
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
        target = parsed.targets.chosen?.target
        output = parsed.output
        paths = parsed.paths
        request = parsed.request
        if request != nil, command.requestPolicy == .read {
            throw CLIError("--request names a change that Muxify applies one time only. \(command.phrase) is not such a change, so it does not take --request.",
                           exitCode: 2)
        }
    }

    static func choice(of options: [TargetOption]) -> String {
        let names = options.map(\.usage)
        guard let last = names.last else { return "" }
        let list = names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " or " + last
        return "; name the target with " + list
    }

    /// Runs the command and prints its answer. With a Request, the ledger decides first: a Request that has its answer
    /// prints it again and changes nothing.
    func run() async throws -> Int32 {
        guard let request else { return try await answer().reply.emit() }
        let reply: RequestReply
        do {
            reply = try await RequestLedger(paths: paths).apply(request, policy: command.requestPolicy, phrase: command.phrase, unrecorded: { error in
                FileHandle.standardError.write(Data("muxify: the ledger could not record the Request \(request.id): \(error)\n".utf8))
            }) {
                let answer = try await answer()
                return (answer.reply, answer.isFinal)
            }
        } catch let refusal as RequestRefusal {
            switch refusal {
            case .clash: throw CLIError(refusal.description, exitCode: Self.requestMismatchExitCode)
            case .inDoubt: throw CLIError(refusal.description, exitCode: Self.requestInDoubtExitCode)
            case .ledgerUnreadable: throw CLIError(refusal.description)
            }
        }
        return try reply.emit()
    }

    /// What one run of the command gave. `isFinal` is true for an answer that a second send must get again: a
    /// success or a refusal. A failure that can change on a second run, such as tmux that does not run, is not final.
    private struct Outcome {
        var reply: RequestReply
        var isFinal: Bool
    }

    /// A command that shows a Topic prints as it runs and gives an empty Reply.
    private func answer() async throws -> Outcome {
        var response: EnvironmentResponse
        var sidebar = EnvironmentShown.Sidebar()
        switch command {
        case .list:
            response = EnvironmentService(paths: paths).handle(EnvironmentRequest(.list))
        case .visitSessionPath(let path, let now):
            return Outcome(reply: try await visit(path, at: now), isFinal: true)
        default:
            let config = try await ConfigSessions.load(paths.configFile, within: command.findsAllSessionPaths ? nil : [])
            sidebar = EnvironmentShown.Sidebar(config.sidebar)
            func handle() throws -> EnvironmentResponse {
                let service = EnvironmentService(paths: paths, server: TmuxServer.local, sessionPaths: config.sessionPaths, topics: config.topics,
                                                 notifications: config.notifications, worktreesRoot: config.worktreesRoot, request: request)
                // No client: no terminal switches to the result, because a command changes what the user sees only
                // when they ask for it. A new Worktree's Session is shown unless --no-open says not to, and a Remove
                // that kills the caller's Session moves its terminal first.
                return service.handle(EnvironmentRequest(try self.request(sessionPaths: config.sessionPaths, service: service),
                                                         target: try requestTarget(), caller: caller.map(TopicCaller.pane)), client: callerClient)
            }
            do {
                response = try handle()
            } catch let answer as Answer {
                response = answer.response
            }
            if case .forgetSettled(let days) = command, case .topics([]) = response, output == .text {
                return Outcome(reply: RequestReply(stdout: "No Settled Topic was Settled more than \(days ?? config.topics.forgetSettledOlderThan) days ago.\n"),
                               isFinal: true)
            }
        }
        if case .topic(let topic) = response {
            let shown = Outcome(reply: RequestReply(stdout: ""), isFinal: true)
            switch command {
            case .exec(let sessionPath, let timeout, let arguments):
                let sessions = try TopicExec.sessions(of: topic, session: sessionPath)
                try TopicExec(arguments: arguments, timeout: timeout).run(sessions, topic: topic, output: output)
                return shown
            case .status(let sessionPath):
                try TopicGit(report: .status).run(try TopicExec.sessions(of: topic, session: sessionPath), topic: topic, output: output)
                return shown
            case .diff(let sessionPath, let stat):
                try TopicGit(report: .diff(stat: stat)).run(try TopicExec.sessions(of: topic, session: sessionPath), topic: topic, output: output)
                return shown
            case .show(conversations: true):
                try reportConversations(of: topic)
                return shown
            case .open:
                try CLICommand.select(.topic(topic.id))
                return shown
            default: break
            }
        }
        let isFinal: Bool
        if case .failed(let failure) = response { isFinal = failure.isRefusal } else { isFinal = true }
        return Outcome(reply: try Self.reply(to: response, output: output, sidebar: sidebar), isFinal: isFinal)
    }

    /// Prints a response of the Topic service, and throws its failure so that the command exits with an error.
    static func report(_ response: EnvironmentResponse, output: Output) throws {
        _ = try reply(to: response, output: output).emit()
    }

    /// What the command line prints for a response of the Topic service. A failure is the error line and exit status 1.
    static func reply(to response: EnvironmentResponse, output: Output, sidebar: EnvironmentShown.Sidebar = .init()) throws -> RequestReply {
        var stdout = ""
        func line(_ text: String) { stdout += text + "\n" }
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            // The snapshot is the whole answer of `environment show`, so it prints with no key around it.
            if case .snapshot(let snapshot) = response { line(String(decoding: try encoder.encode(EnvironmentShown(snapshot: snapshot, sidebar: sidebar, capabilities: EnvironmentShown.cliCapabilities)), as: UTF8.self)) }
            else { line(String(decoding: try encoder.encode(response), as: UTF8.self)) }
        case .text:
            switch response {
            case .topics(let topics):
                // One line per Topic, so a label keeps no tab or line break.
                for topic in topics {
                    line(Self.line(id: topic.id, label: topic.label, tags: topic.tags))
                }
            case .topic(let topic):
                // One line for the Topic, then one for each live Session, with tab-separated fields as in topic list.
                line(Self.line(id: topic.id, label: topic.label, tags: topic.tags))
                for session in topic.sessions {
                    line([session.name, session.baseName, session.directory,
                          session.worktree?.branch ?? ""].map(\.oneLineField).joined(separator: "\t"))
                }
            case .snapshot(let snapshot): stdout += snapshot.text
            // A Worktree change prints what its sync or hooks printed, then the Session it made. A Topic change prints the
            // Topic's id, a change of a Window the Window's id, and a Session rename the full name.
            case .changed(let change) where change.worktreeID != nil:
                if let output = change.output { line(output.trimmingCharacters(in: .newlines)) }
                if let name = change.sessionName { line(name) }
            case .changed(let change): if let id = change.topicID ?? change.window?.rawValue ?? change.sessionName { line(id) }
            case .worktrees(let worktrees):
                // One line each: name, branch, state, path, the Sessions that use it, and its Topic.
                for worktree in worktrees {
                    line([worktree.name, worktree.branch, worktree.state.rawValue, worktree.path, worktree.sessions.joined(separator: ","),
                          worktree.topic ?? ""].map(\.oneLineField).joined(separator: "\t"))
                }
            case .readChanged(let change): for id in change.topicIDs + change.paneIDs.map(\.rawValue) { line(id) }
            case .failed: break
            }
        }
        guard case .failed(let failure) = response else { return RequestReply(stdout: stdout) }
        let error = CLIError(failure)
        return RequestReply(stdout: stdout, stderr: error.message, exitCode: error.exitCode)
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
        let conversations = try record?.agentConversations(in: TmuxServer.local.snapshot()) ?? []
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

    /// The service moves a whole Session only for a Session id target. So a whole-Session move turns its Session name,
    /// `--pane` or caller Pane into the id of that Pane's Session.
    private func requestTarget() throws -> EnvironmentTarget? {
        guard case .moveWholeSession = command else { return target }
        let named = target ?? caller.map(EnvironmentTarget.pane)
        let snapshot = try TmuxServer.local.snapshot()
        let window: TmuxWindow?
        let missing: String
        switch named {
        case .session(let id)?: return .session(id)
        case .sessionName(let name)?:
            window = snapshot.windows.first { $0.sessionName == name }
            missing = TopicRequestError.sessionUnavailable(name).description
        case .pane(let pane)?:
            window = snapshot.panes.first { $0.id == pane.rawValue }.flatMap { found in snapshot.windows.first { $0.id == found.windowID } }
            missing = "No tmux Pane has the id \(pane.rawValue)."
        default: return target
        }
        guard let window, let id = SessionID(rawValue: window.sessionID) else { throw CLIError(missing) }
        return .session(id)
    }

    private func request(sessionPaths: [SessionPath], service: EnvironmentService) throws -> EnvironmentCommand {
        switch command {
        case .new(let title, let tags): return .create(title: title, tags: tags.isEmpty ? nil : tags)
        case .addSession(let path, let newWorktree, let name):
            let directory = try Self.directory(path)
            // A folder in no SessionPath goes to the service as typed, which fails with the Config's own words.
            guard let choice = SessionChoice.containing(directory, in: sessionPaths) else {
                return .addSession(sessionPath: directory.real, workingCopy: .directory, chosenName: name)
            }
            if newWorktree != nil, choice.worktree == nil {
                throw CLIError("--worktree needs a git repository, and \(choice.directory.path) is not one", exitCode: 2)
            }
            // The same choice as the Add Session sheet makes for this row.
            return .addSession(sessionPath: choice.sessionPath.folder.path, workingCopy: choice.workingCopy(newWorktree: newWorktree != nil, start: newWorktree ?? .head), name: choice.name,
                               chosenName: name)
        case .forget(let remove, let kill):
            guard let target = target ?? caller.map(EnvironmentTarget.pane),
                  var choices = try? service.forgetChoices(for: target).get() else { return .forget(choices: [], worktrees: []) }
            for index in choices.sessions.indices { choices.sessions[index].disposition = kill ? .kill : .keep }
            return .forget(choices: choices.sessions, worktrees: remove ? choices.worktrees.filter { $0.canRemove(sessions: choices.sessions) }.map(\.id) : [])
        case .forgetSettled(let days): return .forgetSettled(olderThan: days ?? service.topics.forgetSettledOlderThan, asOf: nil)
        case .settle(let remove, let kill):
            // The palette defaults to Kill behind ⌘↩; the CLI stops a Session only with an explicit flag (ADR 0039).
            // Choices that fail to load leave the defaults, so the request itself reports why the Topic cannot settle.
            guard let settled = target ?? caller.map(EnvironmentTarget.pane),
                  var choices = try? service.settleChoices(for: settled).get() else { return .settle(choices: []) }
            for index in choices.indices {
                choices[index].disposition = kill ? .kill : .keep
                choices[index].removeWorktree = remove && choices[index].worktree != nil
            }
            return .settle(choices: choices)
        case .markRead(let change, let scope): return .markRead(change, scope: scope)
        case .markAllRead: return .markAllRead
        case .createWorktree(let name, let from, let start, let open): return .createWorktree(name: name, from: from, start: start, open: open)
        case .removeWorktree(let worktree, let kill, let force): return .removeWorktree(worktree, kill: kill, force: force)
        case .listWorktrees(let from): return .listWorktrees(all: from == nil, from: from)
        case .tag(let change): return .tags(change)
        case .note(let note): return .note(note)
        case .list: return .list
        // A visit changes no Topic and nothing in tmux, so `answer` records it without a request to the Environment.
        case .visitSessionPath: throw CLIError("session-paths visit sends no request to the Environment")
        case .environmentShow: return .environmentShow
        case .show, .open, .exec, .status, .diff: return .show
        case .rename(let title): return .rename(title: title)
        case .reopen: return .reopen
        case .startFresh: return .startFresh
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
        case .zoomPane: return .zoomPane
        case .placeWindow(let placement): return .moveWindow(to: placement)
        case .kill(let session): return session ? .killSession : .killWindow
        case .pin(let pinned): return pinned ? .pin : .unpin
        case .makeGuest: return .makeGuest
        case .benchTopic: return .benchTopic
        case .fillPlace(let place): return .fillOpenPlace(place: place)
        case .moveCard(let move): return .moveCard(move)
        case .placeCard(let other, let after): return .moveCard(after ? .after(try other.ref) : .before(try other.ref))
        case .tradeCard(let other): return .moveCard(.trade(try other.ref))
        case .chooseInPlay(let cards): return .chooseInPlay(try cards.map { try $0.ref })
        case .replaceFromBench(let benched): return .replaceFromBench(with: try benched.ref)
        case .moveSession(let placement): return .moveSession(to: placement)
        case .moveWholeSession(.topic(let topic)): return .move(to: .topic(.named(topic)))
        case .moveWholeSession(.newTopic(let title)): return .move(to: .newTopic(title: title))
        case .sortSessions: return .sortSessions
        case .removeWindowFromTopic(nil): return .move(to: .newSession(topic: nil))
        case .removeWindowFromTopic(let name?):
            let records = try TopicStore(paths: paths).read().records
            guard let window = try TmuxServer.local.snapshot().windows.first(where: { $0.sessionID == name || $0.sessionName == name }),
                  let id = SessionID(rawValue: window.sessionID) else { throw CLIError(TopicRequestError.sessionUnavailable(name).description) }
            if let topic = records.first(where: { $0.id == window.topicID && $0.settledAt == nil }) {
                throw CLIError("The Session \(window.sessionName) is in the Topic \(TopicLabels(records).label(of: topic)). Name a No Topic Session, "
                               + "or use window move --topic. No changes were made.")
            }
            return .move(to: .session(id))
        }
    }

    /// Records the visit and prints the folder it is to, which is the row of `session-paths` that now ranks first.
    private func visit(_ path: String, at now: Date) async throws -> RequestReply {
        let directory = try Self.directory(path)
        let config = try await ConfigSessions.load(paths.configFile, cache: SessionPathCache(file: paths.sessionPathCache(remote: nil)))
        let visited: Folder
        switch EnvironmentService(paths: paths, sessionPaths: config.sessionPaths).recordVisit(opening: directory, at: now) {
        case .success(let folder): visited = folder
        case .failure(let failure): throw CLIError(failure)
        }
        switch output {
        case .text: return RequestReply(stdout: visited.path.oneLineField + "\n")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let answer = ["visited": ["directory": visited.path, "last_visit": SessionPathAnswer.timestamp(now)]]
            return RequestReply(stdout: String(decoding: try encoder.encode(answer), as: UTF8.self) + "\n")
        }
    }

    /// The terminal of the caller's Pane, for the two commands that may switch it: a Worktree's Session shown, or a
    /// Remove that kills the Session it shows. Nil for every other command, and outside tmux.
    private var callerClient: String? {
        switch command {
        case .createWorktree(_, _, _, true), .removeWorktree(_, kill: true, _): break
        default: return nil
        }
        guard let caller, let tty = try? TmuxServer.local.run(["display-message", "-p", "-t", caller.rawValue, "#{client_tty}"])
            .trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty else { return nil }
        return tty
    }

    /// A response that ends the command before its request, such as the failure of a read that the request needs.
    private struct Answer: Error {
        let response: EnvironmentResponse
        init(_ response: EnvironmentResponse) { self.response = response }
    }

    /// The directory `path` names. Its real path is where `cd -P` would reach it.
    static func directory(_ path: String) throws -> Folder {
        guard let folder = Folder.existingDirectory(path) else { throw CLIError("no directory '\(path)'", exitCode: 2) }
        return folder
    }
}

extension RequestReply {
    /// Prints the Reply as the command's own answer: its output, then its error as the command's failure.
    func emit() throws -> Int32 {
        print(stdout, terminator: "")
        if let stderr { throw CLIError(stderr, exitCode: exitCode) }
        return exitCode
    }
}

extension EnvironmentShown {
    /// The `capabilities` of `environment show --json`: the options that this command line takes and an older one
    /// does not. A caller sends `--request` only when the list has `request`, and reads `session-paths` with no Topic
    /// only when the list has `session-paths`, and names a Guest Session with `--guest-session` only when the list has
    /// `guest-sessions`. All are of this command line, so a `snapshot` item has none.
    static let cliCapabilities = ["request", "session-paths", "guest-sessions"]
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
        case (.topic, .read), (.topicMark, .read): .topicMarkRead
        case (.topic, .unread), (.topicMark, .unread): .topicMarkUnread
        case (.session, .read): .sessionMarkRead
        case (.session, .unread): .sessionMarkUnread
        case (.window, .read): .windowMarkRead
        case (.window, .unread): .windowMarkUnread
        case (.pane, .read): .agentMarkRead
        case (.pane, .unread): .agentMarkUnread
        }
    }
}
