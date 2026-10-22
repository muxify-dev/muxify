import Foundation
import MuxifyCore

/// What a Command Palette row is, for its icon and its actions.
struct PaletteItem: Equatable {
    enum Kind: Equatable {
        case topic, snoozedTopic, settledTopic, session, sessionPath, worktree, window, agent, command, tag
    }

    enum Ref: Equatable {
        /// Nil `window`: Dormant or Settled, so ↩ shows the Topic's Reopen choice.
        case topic(id: String, window: TmuxWindow?)
        case session(SessionGroup)
        case sessionPath(OpenDirectory)
        case window(TmuxWindow)
        case agent(Agent)
        case choice(PaletteChoice)
        case command(PaletteCommand)
        /// A Tag row of a search: ↩ makes it the search's Tag filter.
        case tag(Tag)
    }

    let kind: Kind
    let ref: Ref
    /// What Copy Path copies; empty for a Topic.
    var path = ""
    /// What Copy tmux Target copies: a Session name, `session:index`, or a Pane ID.
    var target: String?
    /// A `Resources/Logos` name, for Windows and Agents.
    var logo: String?
    /// A Tag row's Tag colour in the Config.
    var color: MarkColor?
    /// An Agent's Status, which its row shows as text.
    var status: AgentStatus?
    var mark: RowMark?
}

enum MoveDestination: Hashable {
    case topic(id: String)
    case noTopic
    case session(id: String)
    case newSession(topic: String?)
    /// An empty title makes an Untitled Topic.
    case newTopic(title: String)
    case newWindow(title: String)
}

/// What the Command Palettes of an App Window search, as sections for the ranker: one for each Source, with
/// the topics Source's Snoozed and Settled sections after all of them.
struct PaletteCatalog {
    var windows: [TmuxWindow]
    var agents: [Agent]
    var sessionPaths: [SessionPath] = []
    /// Resolves the Sessions' paths on the Environment's machine.
    var folders: FolderResolver = .local
    var selectedWindowID: String?
    var homeDirectory = NSHomeDirectory()
    var topics: TopicsModel? = nil
    /// Every Topic record, for the Settled rows.
    var records: [TopicRecord] = []
    var lastWindowByGroup: [TopicGroupID: String] = [:]
    var visits = VisitLog()
    var now = Date()
    var commands: [PaletteCommand] = []
    var commandShortcuts: [PaletteCommand: String] = [:]
    /// The Agent mark of each Agent, by Pane ID.
    var agentMarks: [String: AgentMark] = [:]

    /// Whether the topics Source has rows: Topics are on, in a Local App Window.
    var offersTopics: Bool { topics?.topicsEnabled == true }

    /// With `tagFilter`, only the Topics that have the Tag: open, Snoozed and Settled.
    func list(_ sources: [PaletteSource], query: String, tagFilter: Tag? = nil) -> PickList<PaletteItem> {
        guard let tagFilter else { return FuzzyRanker.list(sections(sources), query: FuzzyQuery(query)) }
        return FuzzyRanker.list((openTopicSection(only: tagFilter).map { [$0] } ?? []) + snoozedAndSettledSections(only: tagFilter),
                                query: FuzzyQuery(query))
    }

    /// The rows before any query, in the order of `sources`, then the Snoozed and Settled Topics, which rank
    /// below every other Source's rows for any query. Windows show on an empty query only when theirs is the
    /// only Source, and a Window with an Agent is left out beside the agents Source. The Tags follow the Topics, for
    /// a query only: a Tag is not a place, but a filter that leads to places.
    func sections(_ sources: [PaletteSource]) -> [PickSectionInput<PaletteItem>] {
        let laterTopics = sources.contains(.topics) ? snoozedAndSettledSections(only: nil) : []
        return sources.flatMap { source -> [PickSectionInput<PaletteItem>] in
            switch source {
            case .commands:
                return [PickSectionInput(id: "commands", title: "Commands", rule: .ranked(showsWhenEmpty: true),
                                         candidates: commands.map {
                    PickCandidate(id: "command-" + $0.rawValue, title: $0.rawValue, trailing: commandShortcuts[$0] ?? "",
                                  pick: .available(PaletteItem(kind: .command, ref: .command($0))))
                })]
            case .topics:
                return (openTopicSection(only: nil).map { [$0] } ?? []) + (tagSection.map { [$0] } ?? [])
            case .sessions:
                return [PickSectionInput(id: "sessions", title: "Sessions", rule: .ranked(showsWhenEmpty: true),
                                         candidates: sessionCandidates, currentLast: true)]
            case .windows:
                let hidden = sources.contains(.agents) ? Set(agents.map(\.windowID)) : []
                return [PickSectionInput(id: "windows", title: "Windows", rule: .ranked(showsWhenEmpty: sources == [.windows]),
                                         candidates: windows.filter { !hidden.contains($0.id) }.map(windowCandidate))]
            case .agents:
                return [PickSectionInput(id: "agents", title: "Agents", rule: .ranked(showsWhenEmpty: true), candidates: agentCandidates)]
            }
        } + laterTopics
    }

    // MARK: Topics

    private func openTopicSection(only tag: Tag?) -> PickSectionInput<PaletteItem>? {
        guard offersTopics, let topics else { return nil }
        return PickSectionInput(id: "topics", title: "Topics", rule: .ranked(showsWhenEmpty: true),
                                candidates: topics.rows.filter { $0.has(tag) }.compactMap(topicCandidate), currentLast: true)
    }

    /// Each Tag of `topics.tags` that a Topic record has, in Config order. A plain word matches its name too.
    private var tagSection: PickSectionInput<PaletteItem>? {
        guard offersTopics, let definitions = topics?.tags?.definitions else { return nil }
        return PickSectionInput(id: "tags", title: "Tags", rule: .ranked(showsWhenEmpty: false), candidates: definitions.compactMap { definition in
            let count = records.filter { $0.tags.contains(definition.tag) }.count
            guard count > 0 else { return nil }
            return PickCandidate(id: "tag-" + definition.tag.name, title: definition.tag.description, fields: [.hidden(definition.tag.name)],
                                 trailing: count == 1 ? "1 Topic" : "\(count) Topics",
                                 pick: .available(PaletteItem(kind: .tag, ref: .tag(definition.tag), color: definition.color)), titlePlace: .tag)
        })
    }

    private func snoozedAndSettledSections(only tag: Tag?) -> [PickSectionInput<PaletteItem>] {
        guard offersTopics, let topics else { return [] }
        let snoozed = (topics.groups.first { $0.kind == .snoozed }?.topics ?? [])
            .filter { $0.has(tag) }.compactMap(snoozedCandidate)
        let settled = records.filter { $0.settledAt != nil && (tag.map($0.tags.contains) ?? true) }
            .sorted { ($0.settledAt ?? "", $0.id) > ($1.settledAt ?? "", $1.id) }
            .map(settledCandidate)
        return [
            PickSectionInput(id: "snoozed", title: "Snoozed", rule: .ranked(showsWhenEmpty: true), candidates: snoozed),
            PickSectionInput(id: "settled", title: "Settled", rule: .ranked(showsWhenEmpty: true), candidates: settled),
        ]
    }

    private func age(_ key: VisitKey) -> String? {
        visits.last(key).map { VisitAge.short(since: $0, now: now) }
    }

    private func topicFields(_ row: TopicsModel.Row, type: String) -> [SearchField] {
        [.typeWord(type)] + row.sessions.map { .label($0.baseName) } + SearchField.tags(row.tags)
    }

    private func topicCandidate(_ row: TopicsModel.Row) -> PickCandidate<PaletteItem>? {
        guard case .topic(let id) = row.id else { return nil }
        let isCurrent = topics?.activeTopic == row.id
        let window = EntryWindow.of(row, lastWindowByGroup: lastWindowByGroup, visits: visits)
        let age = age(.topic(row.id))
        let trailing = window == nil ? [row.isDormant ? "Reopen" : "Empty", age].compactMap { $0 }.joined(separator: " · ") : isCurrent ? "Active" : age ?? ""
        return PickCandidate(
            id: row.id.accessibilityID, symbol: row.hasNoLiveSession ? "◇" : "◆", title: row.title,
            fields: topicFields(row, type: row.idleLabel?.lowercased() ?? "topic"),
            trailing: trailing, mark: row.mark,
            lastVisit: visits.last(.topic(row.id)), isCurrent: isCurrent, unopened: row.hasNoLiveSession,
            activity: row.sessions.flatMap(\.windows).map(\.sessionActivity).max() ?? 0,
            pick: .available(PaletteItem(kind: .topic, ref: .topic(id: id, window: window))), snooze: id)
    }

    private func snoozedCandidate(_ row: TopicsModel.Row) -> PickCandidate<PaletteItem>? {
        guard case .topic(let id) = row.id else { return nil }
        var wake: String?
        if case .snoozed(let label) = row.kind { wake = "until " + label }
        let window = EntryWindow.of(row, lastWindowByGroup: lastWindowByGroup, visits: visits)
        return PickCandidate(
            id: row.id.accessibilityID, symbol: "z", title: row.title, fields: topicFields(row, type: "snoozed"),
            note: wake, trailing: window == nil ? "Reopen" : "", lastVisit: visits.last(.topic(row.id)), isPinned: row.isPinned,
            pick: .available(PaletteItem(kind: .snoozedTopic, ref: .topic(id: id, window: window))), snooze: id)
    }

    private func settledCandidate(_ record: TopicRecord) -> PickCandidate<PaletteItem> {
        let row = TopicsModel.settledRow(record, sessionPaths: sessionPaths, tags: topics?.tags, expanded: [])
        let outcome = record.outcome?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var settledOn: String?
        if outcome.isEmpty, case .settled(let detail) = row.kind { settledOn = detail }
        return PickCandidate(
            id: row.id.accessibilityID, symbol: "✓", title: row.title,
            fields: [.typeWord("settled")] + (outcome.isEmpty ? [] : [.detail(outcome)]) + SearchField.tags(row.tags),
            note: settledOn, trailing: ["Reopen", age(.topic(row.id))].compactMap { $0 }.joined(separator: " · "), mark: row.mark,
            lastVisit: visits.last(.topic(row.id)),
            pick: .available(PaletteItem(kind: .settledTopic, ref: .topic(id: record.id, window: nil))))
    }

    // MARK: Sessions and SessionPaths

    /// All running Sessions, plus paths whose exact launch names are not running. Sidebar mode is irrelevant.
    private var sessionCandidates: [PickCandidate<PaletteItem>] {
        var names = Set(windows.map(\.sessionName))
        let paths = sessionPaths.flatMap(SessionChoice.choices).filter { names.insert($0.name).inserted }
        return looseSessionCandidates(windows) + paths.map(pathCandidate)
    }

    /// Running Sessions from any other Topic or No Topic can be moved into this Topic.
    func addSessionList(topic: String, query: String) -> PickList<PaletteItem> {
        var seen: Set<String> = []
        let rows = windows.filter { $0.topicID != topic && seen.insert($0.sessionID).inserted }.map { window in
            PickCandidate(id: "running-" + window.sessionID, title: window.sessionName,
                fields: [.detail(window.sessionPath)], pick: .available(PaletteItem(kind: .session, ref: .choice(.session(window.sessionID)))))
        }
        return FuzzyRanker.list([PickSectionInput(id: "running", title: "Running Sessions", rule: .ranked(showsWhenEmpty: true), candidates: rows)], query: FuzzyQuery(query))
    }

    func destinationList(_ source: TmuxWindow, topic: String?, query: String) -> PickList<PaletteItem> {
        var seen: Set<String> = []
        let open = Set(records.filter { $0.settledAt == nil }.map(\.id))
        let rows = windows.filter {
            $0.topicID.flatMap { open.contains($0) ? $0 : nil } == topic && $0.sessionID != source.sessionID && seen.insert($0.sessionID).inserted
        }.map { window in
            PickCandidate(id: "destination-" + window.sessionID, title: window.sessionName,
                fields: [.detail(window.sessionPath)], pick: .available(PaletteItem(kind: .session, ref: .choice(.move(.session(id: window.sessionID))))))
        }
        let new = PickCandidate(id: "new-session", title: "New Session", pick: .available(PaletteItem(kind: .session, ref: .choice(.move(.newSession(topic: topic))))))
        return FuzzyRanker.list([PickSectionInput(id: "sessions", rule: .ranked(showsWhenEmpty: true), candidates: rows),
            PickSectionInput(id: "new", rule: .fixed, candidates: [new])], query: FuzzyQuery(query))
    }

    private func pathCandidate(_ choice: SessionChoice) -> PickCandidate<PaletteItem> {
        let visit = visits.last(.directory(choice.directory.real))
        return PickCandidate(
            id: "session-path:\(choice.directory.path)", symbol: "□", title: choice.displayName,
            fields: [.typeWord(choice.isWorktree ? "worktree" : "session"), .detail(Paths.tildify(choice.directory.path, home: homeDirectory))] + choice.nameFields,
            trailing: "↩ open", lastVisit: visit, unopened: true,
            pick: .available(PaletteItem(kind: choice.isWorktree ? .worktree : .sessionPath,
                                         ref: .sessionPath(OpenDirectory(directory: choice.directory, name: choice.name)),
                                         path: choice.directory.path)),
            paste: choice.directory.path)
    }

    private func looseSessionCandidates(_ windows: [TmuxWindow]) -> [PickCandidate<PaletteItem>] {
        var groups: [SessionGroup] = []
        for window in windows {
            if let index = groups.firstIndex(where: { $0.id == window.sessionID }) { groups[index].windows.append(window) }
            else { groups.append(SessionGroup(id: window.sessionID, name: window.sessionName, windows: [window])) }
        }
        return groups.map { session in
            let active = EntryWindow.ofSession(session.windows) ?? session.windows[0]
            let folder = session.windows[0].sessionPath.isEmpty ? active.path : session.windows[0].sessionPath
            let count = session.windows.count
            let isCurrent = session.windows.contains { $0.id == selectedWindowID }
            return PickCandidate(
                id: "session:\(session.id)", symbol: "■", title: session.name,
                fields: [.typeWord("session"), .detail("\(count) window\(count == 1 ? "" : "s")"),
                         .detail(Paths.tildify(folder, home: homeDirectory))],
                trailing: isCurrent ? "Current" : age(.session(name: session.name)) ?? "",
                mark: topics?.sessionMarks[session.id].map(RowMark.agent),
                lastVisit: visits.last(.session(name: session.name)), isCurrent: isCurrent, activity: active.sessionActivity,
                pick: .available(PaletteItem(kind: .session, ref: .session(session), path: folder, target: session.name)),
                paste: folder)
        }
    }

    // MARK: Windows and Agents

    private func windowCandidate(_ window: TmuxWindow) -> PickCandidate<PaletteItem> {
        let target = "\(window.sessionName):\(window.index)"
        let isCurrent = window.id == selectedWindowID
        return PickCandidate(
            id: "window:\(window.id)", title: window.displayTitle,
            fields: [.typeWord("window"), .detail(target), .detail(window.abbreviatedPath), .hidden(window.command)],
            trailing: isCurrent ? "Current" : "", isCurrent: isCurrent, activity: window.sessionActivity,
            pick: .available(PaletteItem(kind: .window, ref: .window(window), path: window.path, target: target, logo: window.logoName)),
            paste: window.path)
    }

    /// Those with a Notification first, then working ones, then the rest, each in tmux order.
    private var agentCandidates: [PickCandidate<PaletteItem>] {
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func rank(_ agent: Agent) -> Int {
            switch agentMarks[agent.paneID] {
            case .working?: return 1
            case nil: return 2
            default: return 0
            }
        }
        let ordered = agents.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return ordered.map { agent in
            let window = windowsByID[agent.windowID]
            let path = agent.path.isEmpty ? window?.path ?? "" : agent.path
            return PickCandidate(
                id: "agent:\(agent.paneID)", title: agent.label,
                fields: [.detail(agent.kind.displayName), .detail(agent.location), .hidden(agent.status?.rawValue ?? ""),
                         .hidden(Paths.tildify(path, home: homeDirectory))],
                isCurrent: agent.windowID == selectedWindowID, activity: window?.sessionActivity ?? 0,
                pick: .available(PaletteItem(kind: .agent, ref: .agent(agent), path: path, target: agent.paneID,
                                             logo: agent.kind.rawValue, status: agent.status,
                                             mark: agentMarks[agent.paneID].map(RowMark.agent))),
                paste: path.isEmpty ? nil : path)
        }
    }

    // MARK: Move

    /// The open, not Snoozed Topics minus the source's own, ranked for `query`, then the New Topic row titled
    /// by it. A Topic with a live Session in the source's SessionPath is blocked, by the rule the move itself
    /// throws on, so the dimmed row and the refusal cannot disagree.
    func moveList(_ source: TmuxWindow, query: String, scope: MoveDraft.Scope = .session) -> PickList<PaletteItem> {
        guard let topics else { return .empty }
        let candidates = topics.rows.compactMap { row -> PickCandidate<PaletteItem>? in
            guard case .topic(let id) = row.id, scope != .session || id != source.topicID,
                  records.contains(where: { $0.id == id }) else { return nil }
            return PickCandidate(
                id: row.id.accessibilityID, symbol: row.hasNoLiveSession ? "◇" : "◆", title: row.title,
                fields: topicFields(row, type: row.idleLabel?.lowercased() ?? "topic"),
                trailing: age(.topic(row.id)) ?? "", mark: row.mark,
                lastVisit: visits.last(.topic(row.id)), isPinned: row.isPinned,
                pick: .available(PaletteItem(kind: .topic, ref: .choice(.move(.topic(id: id))))))
        }
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTopic = PickCandidate(
            id: "new-topic", symbol: "＋", title: "New Topic", note: title.isEmpty ? "Untitled" : "“" + title + "”",
            pick: .available(PaletteItem(kind: .topic, ref: .choice(.move(.newTopic(title: title))))))
        var newRows = [newTopic]
        if query.isEmpty || "No Topic".localizedCaseInsensitiveContains(query) {
            newRows.append(PickCandidate(id: "no-topic", title: "No Topic",
                pick: .available(PaletteItem(kind: .session, ref: .choice(.move(.noTopic))))))
        }
        if scope == .pane {
            newRows.append(PickCandidate(id: "new-window", symbol: "＋", title: "New Window in " + source.sessionName,
                                        note: title.isEmpty ? nil : title,
                                        pick: .available(PaletteItem(kind: .window, ref: .choice(.move(.newWindow(title: title)))))))
        }
        let destinations = PickSectionInput(id: "move", rule: .ranked(showsWhenEmpty: true), candidates: candidates)
        let create = PickSectionInput(id: "new-topic", rule: .fixed, candidates: newRows)
        return FuzzyRanker.list(scope == .session ? [destinations, create] : [create, destinations], query: FuzzyQuery(query))
    }

    /// The path as one shell word: bare when the shell reads it as is, quoted otherwise.
    static func shellWord(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%,:=")
        return !path.isEmpty && path.unicodeScalars.allSatisfy(plain.contains) ? path : Tmux.shellQuote(path)
    }
}

/// The Window that going to a Topic or a Session lands on.
enum EntryWindow {
    /// For a Topic or No Topic: the remembered one, else the active Window of the member Session visited
    /// last, else the first active member. Nil when Dormant.
    static func of(_ row: TopicsModel.Row, lastWindowByGroup: [TopicGroupID: String], visits: VisitLog) -> TmuxWindow? {
        let members = row.sessions.flatMap(\.windows)
        if let remembered = members.first(where: { $0.id == lastWindowByGroup[row.id] }) { return remembered }
        let visited = row.sessions.filter { !$0.windows.isEmpty }
            .compactMap { session in visits.last(.session(name: session.windows[0].sessionName)).map { (session, $0) } }
            .max { $0.1 < $1.1 }?.0
        if let visited { return ofSession(visited.windows) }
        return ofSession(members)
    }

    /// For a Session: its active Window, else its first.
    static func ofSession(_ windows: [TmuxWindow]) -> TmuxWindow? {
        windows.first(where: \.isActive) ?? windows.first
    }
}
