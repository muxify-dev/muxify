import Foundation
import MuxifyCore

/// One `muxify agent` command line. `agent list` prints every Agent on the tmux server with its Status, Unread and
/// Topic. It reads the Topic records and one tmux snapshot, and changes nothing.
struct AgentInvocation: Equatable {
    /// An open Topic's id or label, as `--topic` takes it elsewhere.
    var topic: String?
    var status: AgentStatus?
    var unreadOnly: Bool
    var output: RequestInvocation.Output
    var paths: MuxifyPaths
}

extension AgentInvocation {
    func run() async throws {
        let records: [TopicRecord]
        do {
            records = try TopicStore(paths: paths).read().records
        } catch {
            throw CLIError("Muxify could not read the Topic records in \(paths.state.path). \(error.localizedDescription)")
        }
        let topicID: String?
        do {
            topicID = try topic.map { try TopicRef.named($0).resolve(in: records).id }
        } catch let error as TopicRequestError {
            throw CLIError(error.description)
        }
        // No tmux server gives no Panes, so no Agents.
        let rows = AgentRow.list(snapshot: TmuxServer.local.snapshot(), records: records).filter { row in
            (topicID == nil || row.topic?.id == topicID)
                && (status == nil || row.agent.status == status)
                && (!unreadOnly || row.agent.unread)
        }
        switch output {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(AgentList(agents: rows)), as: UTF8.self))
        case .text:
            for row in rows {
                print([row.paneID, row.agent.kind.rawValue, row.agent.status?.rawValue ?? "", row.agent.unread ? "unread" : "",
                       row.topic?.label ?? "", row.sessionName].map(\.oneLineField).joined(separator: "\t"))
            }
        }
    }
}

/// One Agent as `agent list` prints it: its Pane, where the Pane is, and the open Topic of its Session.
struct AgentRow: Encodable, Equatable {
    let paneID: String
    let windowID: String
    let sessionID: String
    let sessionName: String
    let agent: PaneSummary.AgentState
    /// Nil when the Session is in no open Topic.
    let topic: TopicSummary?

    /// The Agents in tmux order.
    static func list(snapshot: TmuxSnapshot, records: [TopicRecord]) -> [AgentRow] {
        let windows = Dictionary(snapshot.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let open = Dictionary(records.filter { $0.settledAt == nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.panes.compactMap { pane in
            guard let agent = PaneSummary(pane).agent, let window = windows[pane.windowID] else { return nil }
            return AgentRow(paneID: pane.id, windowID: window.id, sessionID: window.sessionID, sessionName: window.sessionName,
                            agent: agent, topic: window.topicID.flatMap { open[$0] }.map(TopicSummary.init(record:)))
        }
    }

    // Synthesized encoding leaves out a nil key. A reader gets every key, with null for No Topic.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(paneID, forKey: .paneID)
        try values.encode(windowID, forKey: .windowID)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(sessionName, forKey: .sessionName)
        try values.encode(agent, forKey: .agent)
        try values.encode(topic, forKey: .topic)
    }

    private enum CodingKeys: String, CodingKey {
        case agent, topic
        case paneID = "pane_id", windowID = "window_id", sessionID = "session_id", sessionName = "session_name"
    }
}

/// The `--json` form of `agent list`.
private struct AgentList: Encodable {
    let agents: [AgentRow]
}

/// One `muxify agent conversation` command line. It reads the Transcript of one Agent's conversation, as its CLI
/// writes it, and prints the Entries that the selection keeps. It changes nothing and needs no caller Pane.
struct AgentConversationInvocation: Equatable {
    enum Source: Equatable {
        /// The conversation of the Agent that runs in the Pane now.
        case pane(PaneID)
        case conversation(AgentConversation)
        /// Nil `kind` is the kind whose folder holds the file.
        case transcript(path: String, kind: AgentKind?)
    }

    var source: Source
    var selection: EntrySelection
    /// Print facts about the conversation, not its Entries.
    var info: Bool
    var output: RequestInvocation.Output
    var roots: TranscriptRoots
}

extension AgentConversationInvocation {
    /// The command line of `agent conversation`. A command line that the command cannot run is a usage error, status 2.
    init(_ parsed: ParsedArguments) throws {
        func count(_ option: String, from lowest: Int) throws -> Int? {
            guard let value = try parsed.value(option) else { return nil }
            guard let number = Int(value), number >= lowest else {
                throw CLIError("\(option) takes a whole number" + (lowest > 0 ? " above 0" : ""), exitCode: 2)
            }
            return number
        }
        let windows = ["--head", "--tail", "--range"], roleOptions = ["--role", "--tools", "--tool"]
        guard parsed.count(of: windows) <= 1 else { throw CLIError("give only one of --head, --tail and --range", exitCode: 2) }
        guard parsed.count(of: roleOptions) <= 1 else { throw CLIError("give only one of --role, --tools and --tool", exitCode: 2) }
        guard parsed.operands.count <= 1 else { throw CLIError.usage }
        let pane = try parsed.operands.first.map { word in
            guard let id = PaneID(rawValue: word) else { throw CLIError("agent conversation takes a tmux Pane id, e.g. %3", exitCode: 2) }
            return id
        }
        let conversation = try parsed.value("--conversation")
        let kind = try parsed.value("--kind").map { value in
            guard let kind = AgentKind(rawValue: value) else { throw CLIError("--kind takes claude, codex, pi or opencode", exitCode: 2) }
            return kind
        }
        let transcript = try parsed.value("--transcript")
        if transcript?.isEmpty == true { throw CLIError.usage }
        var selection = EntrySelection()
        var window: EntrySelection.Window?
        if let head = try count("--head", from: 1) { window = .head(head) }
        if let tail = try count("--tail", from: 1) { window = .tail(tail) }
        if let range = try parsed.value("--range") { window = try Self.range(range) }
        selection.after = try count("--after", from: -1)
        if let value = try parsed.value("--since") {
            guard let since = EntrySelection.since(value, now: parsed.now) else {
                throw CLIError("--since takes a time, e.g. 2h, 30m, 17:30, mon 9am or 2026-10-18T09:00:00Z", exitCode: 2)
            }
            selection.since = since
        }
        var roles: Set<Entry.Role>?
        if parsed.flag("--tools") { roles = Set(Entry.Role.allCases) }
        if let tools = try parsed.value("--tool") {
            guard !tools.isEmpty else { throw CLIError.usage }
            roles = [.toolCall, .toolResult]
            selection.tools = Set(tools.split(separator: ",").map(String.init))
        }
        if let value = try parsed.value("--role") {
            guard let parsed = Self.roles(value) else {
                throw CLIError("--role takes user, assistant, tool_call, tool_result or all, separated by commas", exitCode: 2)
            }
            roles = parsed
        }
        let pattern = try parsed.value("--grep")
        let context = try count("--context", from: 0)
        let maxChars = try count("--max-chars", from: 1)
        let full = parsed.flag("--full"), info = parsed.flag("--info")
        let selects = parsed.count(of: windows + roleOptions + ["--after", "--since", "--grep"]) > 0
        let source: Source
        switch (pane, conversation, transcript) {
        case (let pane?, nil, nil):
            guard kind == nil else { throw CLIError("--kind goes with --conversation or --transcript, not with a Pane", exitCode: 2) }
            source = .pane(pane)
        case (nil, let id?, nil):
            guard let kind else { throw CLIError("--conversation needs --kind claude, codex, pi or opencode", exitCode: 2) }
            let named = AgentConversation(kind: kind, id: id)
            guard named.hasSafeID else { throw CLIError("--conversation takes an id of letters, digits, _ and -", exitCode: 2) }
            source = .conversation(named)
        case (nil, nil, let path?):
            if kind == .opencode {
                throw CLIError("OpenCode keeps no Transcript file; read it with --conversation <id> --kind opencode", exitCode: 2)
            }
            source = .transcript(path: path, kind: kind)
        default:
            throw CLIError("name the conversation with a Pane, --conversation <id> --kind <kind> or --transcript <path>", exitCode: 2)
        }
        if context != nil, pattern == nil { throw CLIError("--context goes with --grep", exitCode: 2) }
        if full, maxChars != nil { throw CLIError("give only one of --max-chars and --full", exitCode: 2) }
        if info, selects || full || maxChars != nil {
            throw CLIError("--info prints no Entries, so it takes no selection; it takes --json", exitCode: 2)
        }
        if let pattern {
            do {
                selection.grep = try EntrySelection.Grep(pattern: pattern, context: context ?? 0)
            } catch {
                throw CLIError("--grep takes a regular expression; \(pattern) is not one", exitCode: 2)
            }
        }
        if let roles { selection.roles = roles }
        selection.window = window ?? (selects ? nil : .tail(20))
        selection.maxChars = full ? nil : maxChars ?? 2000
        self.init(source: source, selection: selection, info: info, output: parsed.output,
                  roots: TranscriptRoots(environment: parsed.environment,
                                         home: URL(fileURLWithPath: parsed.environment["HOME"] ?? NSHomeDirectory())))
    }

    /// A..B, -20..-1, 40.. or ..10.
    private static func range(_ value: String) throws -> EntrySelection.Window {
        let problem = CLIError("--range takes A..B, e.g. 40..60, -20..-1 or 40..", exitCode: 2)
        guard let dots = value.range(of: "..") else { throw problem }
        func end(_ text: Substring) throws -> Int? {
            if text.isEmpty { return nil }
            guard let number = Int(text) else { throw problem }
            return number
        }
        let first = try end(value[..<dots.lowerBound]), last = try end(value[dots.upperBound...])
        guard first != nil || last != nil else { throw problem }
        return .range(first, last)
    }

    private static func roles(_ value: String) -> Set<Entry.Role>? {
        var roles: Set<Entry.Role> = []
        for name in value.split(separator: ",", omittingEmptySubsequences: false) {
            if name == "all" {
                roles.formUnion(Entry.Role.allCases)
            } else if let role = Entry.Role(rawValue: String(name)) {
                roles.insert(role)
            } else {
                return nil
            }
        }
        return roles
    }

    func run(using runner: any CLICommandRunning) throws {
        let read = try readConversation(using: runner)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        func printJSON<Value: Encodable>(_ value: Value) throws { print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
        let name = ConversationName(kind: read.kind, conversation: read.conversation, transcript: read.transcript)
        if info {
            let facts = ConversationInfo(name: name, entries: read.entries)
            switch output {
            case .json: try printJSON(facts)
            case .text:
                print(facts.lines.map { $0.map(\.oneLineField).joined(separator: "\t") }.joined(separator: "\n"))
            }
            return
        }
        let result = selection.apply(to: read.entries)
        switch output {
        case .json:
            try printJSON(name)
            for selected in result.entries { try printJSON(JSONEntry(selected)) }
        case .text:
            print("==> \(read.kind.rawValue) \(read.conversation ?? "-") \(read.transcript) <==")
            for selected in result.entries { print(Self.text(of: selected, now: Date())) }
        }
        if let hint = hint(for: result) {
            fflush(stdout)
            FileHandle.standardError.write(Data("muxify: \(hint)\n".utf8))
        }
    }

    private struct Read {
        let kind: AgentKind
        let conversation: String?
        /// The file, or the command that printed the conversation.
        let transcript: String
        let entries: [Entry]
    }

    private func readConversation(using runner: any CLICommandRunning) throws -> Read {
        let conversation: AgentConversation
        switch source {
        case .pane(let pane):
            guard let tmuxPane = TmuxServer.local.snapshot().panes.first(where: { $0.id == pane.rawValue }) else {
                throw CLIError("No tmux Pane \(pane.rawValue).")
            }
            guard let found = AgentConversation(in: tmuxPane) else {
                guard Agent.runs(in: tmuxPane), !tmuxPane.agent.isEmpty else { throw CLIError("No Agent runs in Pane \(pane.rawValue).") }
                throw CLIError("The Agent in Pane \(pane.rawValue) has no conversation id yet.")
            }
            guard found.hasSafeID else { throw CLIError("The conversation id of Pane \(pane.rawValue) is not safe to read.") }
            conversation = found
        case .conversation(let named):
            conversation = named
        case .transcript(let path, let kind):
            let file = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: file.path) else { throw CLIError("No Transcript at \(file.path).") }
            guard let kind = kind ?? roots.kind(ofTranscriptAt: file) else {
                let folders = AgentKind.allCases.compactMap { roots.folder(for: $0)?.path }.joined(separator: ", ")
                throw CLIError("\(file.path) is in none of \(folders); give its --kind", exitCode: 2)
            }
            return try read(file, kind: kind, conversation: nil)
        }
        guard let folder = roots.folder(for: conversation.kind) else {
            let command = "opencode export \(conversation.id)"
            let result = try runner.run("opencode", arguments: ["export", conversation.id], quiet: true)
            guard result.status == 0 else { throw CLIError("\(command) exited with status \(result.status).") }
            let entries = TranscriptReader.entries(in: Data(result.output.utf8), kind: conversation.kind)
            if entries.isEmpty, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw CLIError("No Entries could be read as \(conversation.kind.rawValue) from \(command).")
            }
            return Read(kind: conversation.kind, conversation: conversation.id, transcript: command, entries: entries)
        }
        guard let file = roots.transcript(of: conversation) else {
            throw CLIError("No Transcript of \(conversation.kind.rawValue) conversation \(conversation.id) in \(folder.path).")
        }
        return try read(file, kind: conversation.kind, conversation: conversation.id)
    }

    private func read(_ file: URL, kind: AgentKind, conversation: String?) throws -> Read {
        let entries: [Entry]
        do {
            entries = try TranscriptReader.entries(inFile: file, kind: kind)
        } catch {
            throw CLIError("Muxify could not read \(file.path). \(error.localizedDescription)")
        }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if entries.isEmpty, size > 0 { throw CLIError("No Entries could be read as \(kind.rawValue) from \(file.path).") }
        return Read(kind: kind, conversation: conversation, transcript: file.path, entries: entries)
    }

    /// `[42] assistant 09:12`, or `[43] tool_call Bash 09:12`, then the text.
    static func text(of selected: EntrySelection.Selected, now: Date) -> String {
        let entry = selected.entry
        var header = "[\(entry.index)] \(entry.role.rawValue)"
        if let tool = entry.tool { header += " \(tool.oneLineField)" }
        if let at = entry.at {
            header += " " + (Calendar.current.isDate(at, inSameDayAs: now)
                ? at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                : at.formatted(.iso8601.year().month().day().dateSeparator(.dash)) + " "
                    + at.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
        }
        var lines = [header, selected.text]
        if selected.truncated { lines.append("[cut at \(selected.text.count) of \(selected.chars) characters]") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One line on what the selection left out, so that the caller knows how to read more. Nil when nothing is left out.
    func hint(for result: EntrySelection.Result) -> String? {
        let shown = result.entries.count
        guard shown < result.filtered || result.hiddenByRole > 0 || result.cut > 0 else { return nil }
        func list(_ names: [String]) -> String {
            names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
        var phrase = "showed \(shown) of \(result.filtered) " + list(Entry.Role.allCases.filter(selection.roles.contains).map(\.rawValue))
            + " Entries"
        if let first = result.entries.first, let last = result.entries.last { phrase += " (index \(first.entry.index)..\(last.entry.index))" }
        var parts = [phrase]
        if result.hiddenByRole > 0 {
            let hidden = Entry.Role.allCases.filter { !selection.roles.contains($0) }
            let what = !selection.tools.isEmpty ? "other" : hidden.allSatisfy(\.isTool) ? "tool" : list(hidden.map(\.rawValue))
            parts.append("\(result.hiddenByRole) \(what) Entries hidden")
        }
        if result.cut > 0, let limit = selection.maxChars { parts.append("\(result.cut) Entries cut at \(limit) characters") }
        return parts.joined(separator: "; ") + ". Use --tools, --range or --full to read more."
    }
}

/// Which conversation the output is from, so that a saved index can be checked against it later.
private struct ConversationName: Encodable {
    let kind: AgentKind
    /// Nil for a Transcript that `--transcript` names.
    let conversation: String?
    let transcript: String

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(conversation, forKey: .conversation)
        try values.encode(transcript, forKey: .transcript)
    }

    private enum CodingKeys: String, CodingKey { case kind, conversation, transcript }
}

/// The `--info` facts: enough to choose a range before reading Entries.
private struct ConversationInfo: Encodable {
    let name: ConversationName
    let entries: Int
    let firstAt: Date?
    let lastAt: Date?
    let roles: [String: Int]

    init(name: ConversationName, entries: [Entry]) {
        self.name = name
        self.entries = entries.count
        firstAt = entries.lazy.compactMap(\.at).first
        lastAt = entries.reversed().lazy.compactMap(\.at).first
        roles = Dictionary(uniqueKeysWithValues: Entry.Role.allCases.map { role in (role.rawValue, entries.filter { $0.role == role }.count) })
    }

    var lines: [[String]] {
        [["kind", name.kind.rawValue], ["conversation", name.conversation ?? ""], ["transcript", name.transcript],
         ["entries", String(entries)], ["first_at", firstAt?.ISO8601Format() ?? ""], ["last_at", lastAt?.ISO8601Format() ?? ""]]
            + Entry.Role.allCases.map { [$0.rawValue, String(roles[$0.rawValue] ?? 0)] }
    }

    func encode(to encoder: Encoder) throws {
        try name.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries, forKey: .entries)
        try values.encode(firstAt, forKey: .firstAt)
        try values.encode(lastAt, forKey: .lastAt)
        try values.encode(roles, forKey: .roles)
    }

    private enum CodingKeys: String, CodingKey {
        case entries, roles
        case firstAt = "first_at", lastAt = "last_at"
    }
}

/// One Entry as a line of `--json`.
private struct JSONEntry: Encodable {
    let selected: EntrySelection.Selected

    init(_ selected: EntrySelection.Selected) { self.selected = selected }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(selected.entry.index, forKey: .index)
        try values.encode(selected.entry.at, forKey: .at)
        try values.encode(selected.entry.role, forKey: .role)
        try values.encode(selected.entry.tool, forKey: .tool)
        try values.encode(selected.text, forKey: .text)
        try values.encode(selected.chars, forKey: .chars)
        try values.encode(selected.truncated, forKey: .truncated)
    }

    private enum CodingKeys: String, CodingKey { case index, at, role, tool, text, chars, truncated }
}
