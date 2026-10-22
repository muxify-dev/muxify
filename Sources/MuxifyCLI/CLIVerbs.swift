import Foundation
import MuxifyCore

/// Every verb of the command line, in the order that `muxify --help` lists them.
enum CLIVerbs {
    static let all: [CLIVerb] = browser + session + extensions + topic + window + zen + agent + read

    /// The verb that the words name, and the words after it. The longest match wins.
    static func verb(for arguments: ArraySlice<String>) -> (CLIVerb, ArraySlice<String>)? {
        all.filter { arguments.starts(with: $0.words) }.max { $0.words.count < $1.words.count }
            .map { ($0, arguments.dropFirst($0.words.count)) }
    }

    static let usage: String = {
        let synopses = all.enumerated().map { index, verb in
            let lead = (index == 0 ? "usage: " : "       ") + "muxify " + verb.path.rawValue
            let indent = String(repeating: " ", count: lead.count + 1)
            return verb.synopsis.isEmpty ? lead : lead + " " + verb.synopsis.replacingOccurrences(of: "\n", with: "\n" + indent)
        }
        let column = 15
        let paragraphs = all.map { verb in
            let lines = verb.help.split(separator: "\n", omittingEmptySubsequences: false)
            let indent = String(repeating: " ", count: column)
            let first = verb.path.rawValue.count < column ? verb.path.rawValue.padding(toLength: column, withPad: " ", startingAt: 0) + lines[0]
                                                  : verb.path.rawValue + "\n" + indent + lines[0]
            return ([first] + lines.dropFirst().map { indent + $0 }).joined(separator: "\n")
        }
        return (synopses + [""] + paragraphs + [""] + [footer]).joined(separator: "\n")
    }()

    private static let footer = """
    A Topic command acts on this Pane, or on the target that you name:
                     --topic <id|label>  an open Topic, e.g. --topic "Fix login"
                     --window <id>       a tmux Window, e.g. --window @12
                     --session <name|id> a tmux Session, where a command takes it, e.g. --session gs/fix
                     --pane <id>         a tmux Pane, e.g. --pane %3
    A command that changes something prints the id of each Topic that it changes, else the Window or Session it makes or renames.
                     --json              print the full result as one line of JSON

    Optional tmux binding: bind T run-shell 'muxify window move --new-topic --pane #{pane_id} >/dev/null'
    """

    private static let topicTarget = "[--topic <id|label> | --window <id> | --pane <id>]"

    // MARK: - browser

    private static let browser: [CLIVerb] = [
        CLIVerb(path: .browserOpen, synopsis: "[--window <id>] <url>...",
                options: [.value("--window", aliases: ["-w"])], afterDashes: .operands,
                help: """
                Opens each URL as a Tab in this tmux Window's Browser.
                  --window <id>   open in another Window instead, e.g. --window @12
                """) { parsed in
            guard !parsed.operands.isEmpty else { throw CLIError.usage }
            var target = try parsed.value("--window") ?? ""
            if target.isEmpty {
                guard let pane = parsed.environment["TMUX_PANE"], !pane.isEmpty else {
                    throw CLIError("not inside tmux; specify the Window with --window <id> (e.g. --window @12)")
                }
                target = pane
            }
            for url in parsed.operands where url.contains(where: { $0.isWhitespace }) {
                throw CLIError("'\(url)' contains spaces; pass one URL per argument")
            }
            return .browserOpen(window: target, urls: parsed.operands)
        },
        CLIVerb(path: .browserAvailable, synopsis: "", options: [],
                help: """
                Prints local, remote or no for this Pane's newest Client.
                Exits 0 for local or remote, and 1 for no.
                """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError("browser available takes no arguments", exitCode: 2) }
            return .browserAvailable(pane: parsed.environment["TMUX_PANE"])
        },
    ]

    // MARK: - session

    private static let session: [CLIVerb] = [
        CLIVerb(path: .sessionOpen, synopsis: "<session name>", options: [], afterDashes: .operands,
                help: """
                Shows the tmux Session in Muxify. The name may contain spaces,
                quoted or not: muxify session open my session
                """) { parsed in
            guard !parsed.operands.isEmpty else { throw CLIError.usage }
            return .sessionOpen(name: parsed.operands.joined(separator: " "))
        },
        lock(true, help: """
        Locks this Pane's tmux Session, or the Session that --session names:
        it keeps a card with a number in the Topics list, after the Topics
        that are not Pinned. Only a Session in No Topic can be Locked. A
        Locked Session stays where it is.
        """),
        lock(false, help: "Ends the Lock. The Session stays, in No Topic."),
        CLIVerb(path: .sessionRemoveFromTopic, synopsis: "[--kill [--remove-worktree]] [--session <name|id> | --pane <id>] [--json]",
                options: [.flag("--kill"), .flag("--remove-worktree"), .flag("--json")], targets: [.session, .pane],
                help: """
                Takes this Pane's Session, or the Session that --session names, out of its
                Topic. The Topic forgets it, so Reopen does not make it again. The Session
                stays in No Topic.
                  --kill             also stop the Session, as Remove and Kill does
                  --remove-worktree  with --kill, also remove the Worktree that the Topic made
                                     for the Session. It fails when the Worktree has
                                     uncommitted changes or another live Session uses it.
                """) { parsed in
            let kill = parsed.flag("--kill"), removeWorktree = parsed.flag("--remove-worktree")
            guard parsed.operands.isEmpty, kill || !removeWorktree else { throw CLIError.usage }
            return .request(try RequestInvocation(.removeSessionFromTopic(kill: kill, removeWorktree: removeWorktree), parsed: parsed))
        },
        CLIVerb(path: .sessionNew, synopsis: "<dir> [--name <name>] [--json]", options: [.value("--name"), .flag("--json")],
                help: """
                Makes a No Topic Session in <dir>, as New tmux Session does. Its name is the
                Session Path's name, or <name>; a name that a Session has gets +2, +3.
                Prints the id of its Window.
                  --name <name>   name the Session
                """) { parsed in
            let name = try parsed.value("--name")
            guard parsed.operands.count == 1, name?.isEmpty != true else { throw CLIError.usage }
            return .request(try RequestInvocation(.newSession(directory: parsed.operands[0], name: name), parsed: parsed))
        },
        CLIVerb(path: .sessionRename, synopsis: "\"name\" [--session <name|id> | --window <id> | --pane <id>] [--json]",
                options: [.flag("--json")], targets: [.session, .window, .pane],
                help: """
                Renames this Pane's Session, as Rename does. A Session in a Topic keeps the
                Topic's slug after the name. Prints the full name.
                """) { parsed in
            guard parsed.operands.count == 1, !parsed.operands[0].allSatisfy(\.isWhitespace) else { throw CLIError.usage }
            return .request(try RequestInvocation(.renameSession(name: parsed.operands[0]), parsed: parsed))
        },
        CLIVerb(path: .sessionKill, synopsis: "[--session <name|id> | --window <id> | --pane <id>] [--json]",
                options: [.flag("--json")], targets: [.session, .window, .pane],
                help: """
                Kills this Pane's Session and every process in it, as Kill Session does.
                Its Topic remembers what is left; with no Session left, the Topic is Empty.
                """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .request(try RequestInvocation(.kill(session: true), parsed: parsed))
        },
        CLIVerb(path: .sessionMove, synopsis: "(up | down) [--session <name|id> | --pane <id>] [--json]",
                options: [.flag("--json")], targets: [.session, .pane],
                help: """
                Moves this Pane's Session one place up or down among the Sessions of its Topic, as
                Move Up and Move Down do on its row. For a Locked Session, which is in no Topic, it
                moves its card among the cards that the Topics list shows. At the end it fails.
                """) { parsed in
            .request(try RequestInvocation(.moveSession(try upOrDown(parsed) ? .up : .down), parsed: parsed))
        },
        CLIVerb(path: .sessionList, synopsis: "[--json]", options: [.flag("--json")],
                help: """
                Prints every running Session and each unused exact-named launch path,
                with running or launchable, its directory, and Topic label when present.
                """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .sessionList(SessionListInvocation(output: parsed.output, paths: parsed.paths))
        },
    ]

    private static func lock(_ locked: Bool, help: String) -> CLIVerb {
        CLIVerb(path: locked ? .sessionLock : .sessionUnlock, synopsis: "[--session <name|id>] [--json]",
                options: [.flag("--json")], targets: [.session], help: help) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .request(try RequestInvocation(.lock(locked), parsed: parsed))
        }
    }

    // MARK: - extensions

    private static let extensions: [CLIVerb] = [
        CLIVerb(path: .extensionsInstall, synopsis: "", options: [],
                help: "Installs or updates Extensions for Agents configured under HOME.") { parsed in
            guard parsed.operands.isEmpty else { throw CLIError("extensions install takes no arguments") }
            return .extensionsInstall
        },
    ]

    // MARK: - topic

    private static func topicVerb(_ path: CLIVerbPath, synopsis: String, options: [CLIOption] = [], repeatsTopic: Bool = false,
                                  afterDashes: CLIVerb.AfterDashes = .refused, removed: [RemovedForm] = [], help: String,
                                  build: @escaping (ParsedArguments) throws -> RequestInvocation.Command) -> CLIVerb {
        CLIVerb(path: path, synopsis: synopsis, options: options + [.flag("--json")],
                targets: [.topic, .window, .pane], repeatsTopic: repeatsTopic, afterDashes: afterDashes, removed: removed,
                help: help) { parsed in
            .request(try RequestInvocation(try build(parsed), parsed: parsed))
        }
    }

    /// A value option that must not look like an option, as a folder or a ref.
    private static func plainValue(_ name: String, in parsed: ParsedArguments) throws -> String? {
        guard let value = try parsed.value(name) else { return nil }
        guard !value.isEmpty, !value.hasPrefix("-") else { throw CLIError.usage }
        return value
    }

    private static func tags(_ words: [String]) throws -> [Tag] {
        try words.map { word in
            guard let tag = Tag(typed: word) else {
                throw CLIError("\(word) is not a Tag: use lower case letters, digits and -, e.g. backend", exitCode: 2)
            }
            return tag
        }
    }

    /// The forms of `topic new` before ADR 0039, when it also started a Session or moved the caller's Pane.
    private static let removedTopicNew: [RemovedForm] = [
        RemovedForm(options: [.value("--directory")], matches: { $0.flag("--directory") }) { parsed in
            """
            topic new makes an Empty Topic and no longer takes --directory. Use two commands:
              id=$(muxify \(CLIVerbPath.topicNew.rawValue) "\(parsed.operands.first ?? "title")" --json | jq -r .changed.topic_id)
              muxify \(CLIVerbPath.topicAddSession.rawValue) \(parsed.values("--directory").first ?? "<dir>") --topic "$id"
            """
        },
        RemovedForm(matches: { [.window, .pane].contains($0.targets.chosen?.option) }) { parsed in
            // A titled old form started a Session in the Pane's folder; an untitled one moved the Pane.
            let move = "To move a Pane or Window into a new Topic, use: muxify \(CLIVerbPath.windowMove.rawValue) --new-topic [\"title\"] [--window <id> | --pane <id>]"
            guard let title = parsed.operands.first else { return "topic new makes an Empty Topic and takes no Pane or Window. " + move }
            return """
            topic new makes an Empty Topic and takes no Pane or Window. To start a Session in the folder of a Pane, use two commands:
              id=$(muxify \(CLIVerbPath.topicNew.rawValue) "\(title)" --json | jq -r .changed.topic_id)
              muxify \(CLIVerbPath.topicAddSession.rawValue) <dir> --topic "$id"
            \(move)
            """
        },
        RemovedForm(matches: { $0.operands.isEmpty }) { _ in
            "topic new needs a title. To move this Pane into a new Topic, use: muxify \(CLIVerbPath.windowMove.rawValue) --new-topic [\"title\"]"
        },
    ]

    /// The time of `topic snooze` and `zen start`. Unquoted words join, so `topic snooze mon 9am` reads as the time
    /// step reads "mon 9am". The time step says "never", but on a command line `snooze never` reads as no Snooze, so
    /// the CLI says "forever".
    private static func time(_ parsed: ParsedArguments, of phrase: String) throws -> SnoozeSchedule {
        guard !parsed.operands.isEmpty else { throw CLIError.usage }
        let text = parsed.operands.joined(separator: " ")
        if text.lowercased() == "forever" { return .never }
        guard let schedule = SnoozeSchedule(text, typed: true), schedule != .never else {
            throw CLIError("\(phrase) takes a time, e.g. 2h, 17:30, tomorrow, mon 9am or forever", exitCode: 2)
        }
        return schedule
    }

    private static func upOrDown(_ parsed: ParsedArguments) throws -> Bool {
        guard parsed.operands.count == 1, ["up", "down"].contains(parsed.operands[0]) else { throw CLIError.usage }
        return parsed.operands[0] == "up"
    }

    /// `--session <name|id>` of exec, status and diff.
    private static func sessionFilter(_ parsed: ParsedArguments) throws -> String? {
        let session = try parsed.value("--session")
        if session?.isEmpty == true { throw CLIError.usage }
        return session
    }

    private static let topic: [CLIVerb] = [
        CLIVerb(path: .topicOpen, synopsis: topicTarget, options: [], targets: [.topic, .window, .pane],
                help: """
                Shows this Pane's Topic in Muxify, or the Topic that --topic names, as Jump To
                does. A Dormant Topic that remembers Sessions is Reopened.
                """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .request(try RequestInvocation(.open, parsed: parsed))
        },
        topicVerb(.topicNew, synopsis: "\"title\" [--tag <tag>]... [--json]", options: [.value("--tag")], removed: removedTopicNew,
                  help: """
                  Makes an Empty Topic with this title, as New Topic does. It starts no Session,
                  so it also works outside tmux. Add a Session with topic add-session.
                    --tag <tag>     give the Topic this Tag; give --tag again for more Tags
                  """) { parsed in
            guard parsed.operands.count == 1, !parsed.operands[0].allSatisfy(\.isWhitespace) else { throw CLIError.usage }
            return .new(title: parsed.operands[0], tags: try tags(parsed.values("--tag")))
        },
        topicVerb(.topicAddSession, synopsis: "<dir> [--worktree [--base <ref> | --branch <name>]] \(topicTarget) [--json]",
                  options: [.flag("--worktree"), .value("--base"), .value("--branch")],
                  help: """
                  Creates another Session at <dir> in this Pane's Topic, even if that folder is already used.
                    --worktree       start a new Worktree from it, on a new branch named from the Topic
                    --base <ref>     start the new branch at <ref>, not at HEAD
                    --branch <name>  check out the local branch <name> in the new Worktree. No other
                                     Worktree can have it checked out. Settle removes the Worktree
                                     and keeps the branch.
                  """) { parsed in
            let base = try plainValue("--base", in: parsed), branch = try plainValue("--branch", in: parsed)
            guard parsed.operands.count == 1, base == nil || branch == nil else { throw CLIError.usage }
            guard parsed.flag("--worktree") else {
                guard base == nil, branch == nil else { throw CLIError.usage }
                return .addSession(directory: parsed.operands[0], newWorktree: nil)
            }
            let start: WorktreeStart = branch.map(WorktreeStart.branch) ?? base.map(WorktreeStart.ref) ?? .head
            return .addSession(directory: parsed.operands[0], newWorktree: start)
        },
        topicVerb(.topicForget, synopsis: "[--kill-sessions] [--remove-worktrees] \(topicTarget) [--json]",
                  options: [.flag("--kill-sessions"), .flag("--remove-worktrees")],
                  help: "Removes this Topic for good. Sessions stay running, without the Topic.") { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .forget(removeWorktrees: parsed.flag("--remove-worktrees"), killSessions: parsed.flag("--kill-sessions"))
        },
        topicVerb(.topicSettle, synopsis: "[--kill-sessions] [--remove-worktrees] \(topicTarget) [--json]",
                  options: [.flag("--kill-sessions"), .flag("--remove-worktrees")],
                  help: """
                  Settles this Pane's Topic. Sessions and Worktrees are kept by default.
                    --kill-sessions    explicitly stop the Topic's Sessions (also for forget)
                    --remove-worktrees  also remove each Worktree that the Topic made
                                        and that is merged, as the Settle sheet offers.
                                        If one has uncommitted work, nothing changes.
                  """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .settle(removeWorktrees: parsed.flag("--remove-worktrees"), killSessions: parsed.flag("--kill-sessions"))
        },
        topicVerb(.topicSnooze, synopsis: "<time> [--topic <id|label>... | --window <id> | --pane <id>] [--json]", repeatsTopic: true,
                  help: """
                  Snoozes this Pane's Topic until <time>, also when it was Snoozed until
                  later. <time> is as the time step of Snooze Topic reads it: 30m, 2h or 3d from now,
                  17:30 or 5pm, today, tomorrow or a weekday such as mon, each with an
                  optional time (default 9:00), or forever, until you Unsnooze it.
                  Give --topic more than once to Snooze each of those Topics. If one
                  is not an open Topic, nothing changes.
                  """) { parsed in
            .snooze(try time(parsed, of: "topic snooze"), topics: parsed.targets.topics)
        },
        topicVerb(.topicUnsnooze, synopsis: "[--topic <id|label>... | --window <id> | --pane <id>] [--json]", repeatsTopic: true,
                  help: """
                  Unsnoozes this Pane's Topic, or each --topic. A Topic that is not
                  Snoozed does not change. It changes nothing in tmux.
                  """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .unsnooze(topics: parsed.targets.topics)
        },
        topicVerb(.topicTag, synopsis: "(add | remove | set) [<tag>...] \(topicTarget) [--json]",
                  help: """
                  Adds Tags to this Pane's Topic, removes them, or sets them, so that the
                  Topic has exactly these Tags: set with no Tag removes every Tag. Only a Tag
                  that the Config lists in topics.tags can be added, such as backend; upper case
                  becomes lower case. The # is optional, and the shell reads an unquoted # as a comment.
                  """) { parsed in
            guard let change = parsed.operands.first else { throw CLIError.usage }
            let tags = try tags(Array(parsed.operands.dropFirst()))
            switch change {
            case "set": return .tag(.set(tags))
            case "add" where !tags.isEmpty: return .tag(.add(tags))
            case "remove" where !tags.isEmpty: return .tag(.remove(tags))
            default: throw CLIError.usage
            }
        },
        topicVerb(.topicRename, synopsis: "\"title\" \(topicTarget) [--json]",
                  help: "Gives this Pane's Topic a new title, as Rename Topic does.") { parsed in
            guard parsed.operands.count == 1, !parsed.operands[0].allSatisfy(\.isWhitespace) else { throw CLIError.usage }
            return .rename(title: parsed.operands[0])
        },
        topicVerb(.topicReopen, synopsis: "--topic <id|label> [--json]",
                  help: """
                  Makes the remembered Sessions, Windows, Tabs and Agents of a Dormant or
                  Settled Topic again, as Reopen Topic does.
                  """) { parsed in
            try reopening(.reopen, parsed)
        },
        topicVerb(.topicStartFresh, synopsis: "--topic <id|label> [--json]",
                  help: """
                  Makes one Session with one shell Window in each Session Path that a
                  Dormant or Settled Topic remembers, as Start Topic Fresh does.
                  """) { parsed in
            try reopening(.startFresh, parsed)
        },
        topicVerb(.topicPin, synopsis: "\(topicTarget) [--json]",
                  help: "Pins this Pane's Topic, as Pin Topic does: its card goes last among the Pinned Topics.") { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .pin(true)
        },
        topicVerb(.topicUnpin, synopsis: "\(topicTarget) [--json]",
                  help: "Ends the Pin of this Pane's Topic, as Unpin Topic does: its card goes first among the others.") { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .pin(false)
        },
        topicVerb(.topicMove, synopsis: "(up | down) \(topicTarget) [--json]",
                  help: """
                  Moves the card of this Pane's Topic one place up or down among the cards that the
                  Topics list shows now, with the same Pin, as Move Topic Up and Down do. A Snoozed
                  Topic has no card, so a move steps over it. At the end of the cards it fails.
                  """) { parsed in
            .moveCard(try upOrDown(parsed) ? .up : .down)
        },
        topicVerb(.topicSortSessions, synopsis: "\(topicTarget) [--json]",
                  help: """
                  Lists the Sessions of this Pane's Topic by creation again, as Sort Sessions by
                  Creation does. It ends the order that session move or a drag gave.
                  """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .sortSessions
        },
        topicVerb(.topicList, synopsis: "[--json]",
                  help: """
                  Prints each open Topic's id, label and Tags without starting Muxify, in the order of
                  the Topics list: Pinned Topics first. With --json, also whether each is Pinned.
                  """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .list
        },
        topicVerb(.topicShow, synopsis: "[--conversations] \(topicTarget) [--json]", options: [.flag("--conversations")],
                  help: """
                  Prints this Pane's Topic: its id, label and Tags, then a line for each live
                  Session: its name, base name, folder and branch. With --json, also its
                  Windows and Panes, and the Agent, Status, Unread and conversation of each Pane.
                    --conversations      also a line for the conversation of each Agent that
                                         the Topic has or remembers: its kind and id
                  """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .show(conversations: parsed.flag("--conversations"))
        },
        topicVerb(.topicStatus, synopsis: "[--session <name|id>] \(topicTarget) [--json]", options: [.value("--session")],
                  help: """
                  Prints the git status of each live Session of this Pane's Topic, as
                  git status --short --branch does, with each untracked file, under a
                  "==> <session> <==" line.
                  With --json, also each Session's upstream, ahead, behind and base.
                  A Session whose folder is in no repository has "git": null.
                    --session <name|id>   only this exact Session
                  """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .status(sessionPath: try sessionFilter(parsed))
        },
        topicVerb(.topicDiff, synopsis: "[--stat] [--session <name|id>] \(topicTarget) [--json]",
                  options: [.flag("--stat"), .value("--session")],
                  help: """
                  Prints one patch of the Topic's work in all its live Sessions. Each
                  path starts with the Session's name. A Session's work is its commits,
                  changes and untracked files since its base: the commit its Worktree
                  started at, else the merge base with origin/HEAD, main or master.
                    --stat               print a summary, not the patch
                    --session <name|id>   only this exact Session
                  """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .diff(sessionPath: try sessionFilter(parsed), stat: parsed.flag("--stat"))
        },
        topicVerb(.topicExec, synopsis: "[--session <name|id>] [--timeout <seconds>] \(topicTarget) [--json] -- <command> [<argument>...]",
                  options: [.value("--session"), .value("--timeout")], afterDashes: .command,
                  help: """
                  Runs <command> once in the folder of each live Session of this Pane's
                  Topic, all at the same time, and prints each Session's output under
                  a "==> <session> <==" line. It types nothing into a Pane. It exits
                  with 1 when a run does not exit with 0.
                    --session <name|id>   run only in this exact Session
                    --timeout <seconds>  stop a run after this time (default 60)
                  """) { parsed in
            var timeout: TimeInterval = 60
            if let value = try parsed.value("--timeout") {
                guard let seconds = TimeInterval(value), seconds > 0, seconds.isFinite else { throw CLIError.usage }
                timeout = seconds
            }
            guard parsed.operands.isEmpty, let command = parsed.command, !command.isEmpty else { throw CLIError.usage }
            return .exec(sessionPath: try sessionFilter(parsed), timeout: timeout, command: command)
        },
    ]

    /// A Dormant or Settled Topic has no Pane, so Reopen and Start Fresh name it.
    private static func reopening(_ command: RequestInvocation.Command, _ parsed: ParsedArguments) throws -> RequestInvocation.Command {
        guard parsed.operands.isEmpty else { throw CLIError.usage }
        guard parsed.targets.chosen != nil else {
            throw CLIError("\(command.phrase) takes the Topic: --topic <id|label>. A Dormant or Settled Topic has no Pane.", exitCode: 2)
        }
        return command
    }

    // MARK: - window

    private static let window: [CLIVerb] = [
        CLIVerb(path: .windowOpen, synopsis: "[--window <id> | --pane <id>]", options: [], targets: [.window, .pane],
                help: "Shows this Pane's tmux Window in Muxify, or the Window of --window or --pane.") { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            switch parsed.targets.chosen?.target {
            case .window(let id)?: return .windowOpen(target: id.rawValue)
            case .pane(let id)?: return .windowOpen(target: id.rawValue)
            default:
                let caller = try parsed.targets.caller(environment: parsed.environment, needed: true, offered: [.window, .pane])
                guard let caller else { throw CLIError.usage }
                return .windowOpen(target: caller.rawValue)
            }
        },
        CLIVerb(path: .windowMove,
                synopsis: """
                (--topic <id|label> [--session <name|id> | --new-session] | --new-topic ["title"] | --new-window ["title"]
                 | --before <window> | --after <window>) [--window <id> | --pane <id>] [--json]
                """,
                options: [.value("--topic"), .value("--session"), .flag("--new-session"), .flag("--new-topic"), .flag("--new-window"),
                          .value("--before"), .value("--after"), .flag("--json")],
                targets: [.window, .pane],
                help: """
                Moves this Pane's Window, or the Window that --window or --pane
                names, as Move does.
                  --topic <id|label>    into the open Topic that has this id or exact label
                  --session <name|id>   choose a destination when several Sessions exist
                  --new-session         create a destination instead of reusing one
                  --new-topic ["title"]  into a new Topic, Untitled without a title
                  --new-window ["title"] this Pane into a new Window of its Session
                  --before <window>     before this Window of its Session, e.g. @3
                  --after <window>      after this Window of its Session
                """) { parsed in
            let topic = try parsed.value("--topic")
            let newTopic = parsed.flag("--new-topic"), newWindow = parsed.flag("--new-window")
            let before = try parsed.value("--before"), after = try parsed.value("--after")
            guard [topic != nil, newTopic, newWindow, before != nil, after != nil].filter({ $0 }).count == 1 else {
                throw CLIError("window move takes one destination: --topic <id|label>, --new-topic [\"title\"], --new-window [\"title\"], "
                               + "--before <window> or --after <window>", exitCode: 2)
            }
            let session = try parsed.value("--session")
            let newSession = parsed.flag("--new-session")
            guard session?.isEmpty != true, session == nil || !newSession else { throw CLIError.usage }
            if let anchor = before ?? after {
                guard parsed.operands.isEmpty, session == nil, !newSession else { throw CLIError.usage }
                guard let id = WindowID(rawValue: anchor) else {
                    throw CLIError("--\(before == nil ? "after" : "before") takes a tmux Window id, e.g. @3", exitCode: 2)
                }
                return .request(try RequestInvocation(.placeWindow(before == nil ? .after(id) : .before(id)), parsed: parsed))
            }
            guard let topic else {
                guard parsed.operands.count <= 1, session == nil, !newSession else { throw CLIError.usage }
                let title = parsed.operands.first ?? ""
                return .request(try RequestInvocation(newTopic ? .moveToNewTopic(title: title) : .moveToNewWindow(title: title), parsed: parsed))
            }
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .request(try RequestInvocation(.moveWindow(topic: try RequestInvocation.TargetOption.topicName(topic), session: session,
                                                              newSession: newSession), parsed: parsed))
        },
        CLIVerb(path: .windowRemoveFromTopic, synopsis: "(--session <name|id> | --new-session) [--window <id> | --pane <id>] [--json]",
                options: [.value("--session"), .flag("--new-session"), .flag("--json")], targets: [.window, .pane],
                help: """
                Moves this Pane's Window, or the Window that --window or --pane names,
                out of its Topic, into a No Topic Session.
                  --session <name|id>   the No Topic Session to move it into
                  --new-session         a new No Topic Session
                """) { parsed in
            let session = try parsed.value("--session")
            guard parsed.operands.isEmpty, session?.isEmpty != true else { throw CLIError.usage }
            guard (session != nil) != parsed.flag("--new-session") else {
                throw CLIError("window remove-from-topic takes the destination: --session <name|id> of a No Topic Session, or --new-session",
                               exitCode: 2)
            }
            return .request(try RequestInvocation(.removeWindowFromTopic(session: session), parsed: parsed))
        },
        CLIVerb(path: .windowNew,
                synopsis: "[--topic <id|label> | --session <name|id> | --window <id> | --pane <id>] [--json] [-- <command> [<argument>...]]",
                options: [.flag("--json")], targets: [.topic, .session, .window, .pane], afterDashes: .command,
                help: """
                Makes a tmux Window in this Pane's Session, or in the Session that the
                target names, as New tmux Window does. The Window starts in the folder of
                the target's Window. --topic names the Topic's only live Session: it fails
                when the Topic has none or more than one, and it never makes a Session.
                Prints the id of the new Window.
                  -- <command>    run this command in the Window, not the default shell,
                                  e.g. -- claude "Read /tmp/handoff.md"
                """) { parsed in
            guard parsed.operands.isEmpty, parsed.command?.isEmpty != true else { throw CLIError.usage }
            return .request(try RequestInvocation(.newWindow(command: parsed.command), parsed: parsed))
        },
        CLIVerb(path: .windowRename, synopsis: "\"name\" [--window <id> | --pane <id>] [--json]",
                options: [.flag("--json")], targets: [.window, .pane],
                help: "Renames this Pane's Window, as Rename does. Prints the id of the Window.") { parsed in
            guard parsed.operands.count == 1, !parsed.operands[0].allSatisfy(\.isWhitespace) else { throw CLIError.usage }
            return .request(try RequestInvocation(.renameWindow(name: parsed.operands[0]), parsed: parsed))
        },
        CLIVerb(path: .windowKill, synopsis: "[--window <id> | --pane <id>] [--json]",
                options: [.flag("--json")], targets: [.window, .pane],
                help: """
                Kills this Pane's Window and every process in it, as Kill Window does.
                With --json, "stopped" lists the Agent Panes that stopped.
                """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .request(try RequestInvocation(.kill(session: false), parsed: parsed))
        },
    ]

    // MARK: - read

    private static let read: [CLIVerb] = readVerbs(.topic, synopsis: topicTarget, what: """
        this Pane's Topic and each Agent in its Sessions
        """)
        + readVerbs(.session, synopsis: "[--session <name|id> | --window <id> | --pane <id>]", what: "each Agent in this Pane's Session")
        + readVerbs(.window, synopsis: "[--window <id> | --pane <id>]", what: "each Agent in this Pane's Window")
        + readVerbs(.pane, synopsis: "[--pane <id>]", what: "the Agent in this Pane")
        + [CLIVerb(path: .markAllRead, synopsis: "[--json]", options: [.flag("--json")],
                   help: "Marks every Topic and every Agent Read, as Mark All as Read does.") { parsed in
               guard parsed.operands.isEmpty else { throw CLIError.usage }
               return .request(try RequestInvocation(.markAllRead, parsed: parsed))
           }]

    /// Mark Read and Mark Unread of one scope. Each prints the id of each Topic and each Agent Pane that changed.
    private static func readVerbs(_ scope: ReadScope, synopsis: String, what: String) -> [CLIVerb] {
        [ReadChange.read, .unread].map { change in
            let command = RequestInvocation.Command.markRead(change, scope: scope)
            return CLIVerb(path: .markRead(change, scope: scope), synopsis: synopsis + " [--json]",
                           options: [.flag("--json")], targets: command.targets,
                           help: change == .read ? "Marks \(what) Read, as Mark Read does."
                                                 : "Marks \(what) Unread, as Mark Unread does.\nAn Agent that is working does not change.") { parsed in
                guard parsed.operands.isEmpty else { throw CLIError.usage }
                return .request(try RequestInvocation(command, parsed: parsed))
            }
        }
    }

    // MARK: - zen

    private static let zen: [CLIVerb] = [
        CLIVerb(path: .zenStart, synopsis: "<time> \(topicTarget) [--json]", options: [.flag("--json")],
                targets: [.topic, .window, .pane],
                help: """
                Starts Zen until <time>, as Zen does: every open Topic but this Pane's Topic is
                Snoozed until then, and the Topics list shows no Locked Session. A Topic Snoozed
                until later keeps its Snooze. <time> is as topic snooze reads it. One Zen at a
                time: while Zen is on, it fails. It prints the id of each Topic that Zen Snoozed.
                """) { parsed in
            .request(try RequestInvocation(.zen(try time(parsed, of: "zen start")), parsed: parsed))
        },
        CLIVerb(path: .zenEnd, synopsis: "[--json]", options: [.flag("--json")],
                help: """
                Ends Zen: each Topic that Zen Snoozed gets its earlier Snooze back. With no Zen
                it changes nothing. It prints the id of each Topic whose Snooze changed.
                """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            return .request(try RequestInvocation(.endZen, parsed: parsed))
        },
    ]

    private static let agent: [CLIVerb] = [
        CLIVerb(path: .agentList, synopsis: "[--topic <id|label>] [--status <status>] [--unread] [--json]",
                options: [.value("--topic"), .value("--status"), .flag("--unread"), .flag("--json")],
                help: """
                Prints a line for each Agent: its Pane, kind, Status, "unread" when it
                is Unread, and the label of its Topic and the name of its Session.
                  --topic <id|label>  only the Agents in this open Topic
                  --status <status>   only the Agents with this Status: working,
                                      blocked, done or failed
                  --unread            only the Unread Agents
                With --json, also the conversation id of each Agent.
                """) { parsed in
            guard parsed.operands.isEmpty else { throw CLIError.usage }
            let status = try parsed.value("--status").map { value in
                guard let status = AgentStatus(rawValue: value) else { throw CLIError("--status takes working, blocked, done or failed", exitCode: 2) }
                return status
            }
            return .agent(AgentInvocation(topic: try parsed.value("--topic").map(RequestInvocation.TargetOption.topicName), status: status,
                                          unreadOnly: parsed.flag("--unread"), output: parsed.output, paths: parsed.paths))
        },
        CLIVerb(path: .agentConversation,
                synopsis: """
                (<pane> | --conversation <id> --kind <kind> | --transcript <path> [--kind <kind>])
                [--head <n> | --tail <n> | --range <a>..<b>] [--after <index>] [--since <time>]
                [--role <role>,... | --tools | --tool <name>,...] [--grep <regex> [--context <n>]]
                [--max-chars <n> | --full] [--info] [--json]
                """,
                options: ["--conversation", "--kind", "--transcript", "--head", "--tail", "--range", "--after", "--since", "--role",
                          "--tool", "--grep", "--context", "--max-chars"].map { CLIOption.value($0) }
                    + ["--tools", "--full", "--info", "--json"].map(CLIOption.flag),
                help: """
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
                """) { parsed in
            .agentConversation(try AgentConversationInvocation(parsed))
        },
    ]
}
