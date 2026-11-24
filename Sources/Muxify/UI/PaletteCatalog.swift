import Foundation
import MuxifyCore

/// What a Command Palette row acts on. Its row's kind picks the icon.
struct PaletteItem: Equatable {
    enum Ref: Equatable {
        /// Nil `window`: Dormant or Settled, so ↩ shows the Topic's Reopen choice.
        case topic(id: String, window: TmuxWindow?)
        /// A Dormant Board Session, by its id: ↩ creates its Session again.
        case boardSession(id: String)
        case session(SessionGroup)
        case sessionPath(OpenDirectory)
        case window(TmuxWindow)
        case agent(Agent)
        case choice(PaletteChoice)
        case command(PaletteCommand)
        /// A Tag row of a search: ↩ makes it the search's Tag filter.
        case tag(Tag)
    }

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
    var mark: CardMark?
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
/// the topics Source's Settled section after all of them.
struct PaletteCatalog {
    var windows: [TmuxWindow]
    var agents: [Agent]
    var sessionPaths: [SessionPath] = []
    /// Resolves the Sessions' paths on the Environment's machine.
    var folders: FolderResolver = .local
    var selectedWindowID: String?
    var homeDirectory = NSHomeDirectory()
    var board: BoardModel? = nil
    /// Every Topic record, for the Settled rows.
    var records: [TopicRecord] = []
    var lastWindowByGroup: [TopicGroupID: String] = [:]
    var visits = VisitLog()
    var now = Date()
    var commands: [PaletteCommand] = []
    var commandShortcuts: [PaletteCommand: String] = [:]
    var commandSummaries: [PaletteCommand: String] = [:]
    /// The Agent mark of each Agent, by Pane ID.
    var agentMarks: [String: AgentMark] = [:]

    /// Whether the topics Source has rows: Topics are on, in a Local App Window.
    var offersTopics: Bool { board?.topicsEnabled == true }

    /// With `tagFilter`, only the Topics that have the Tag: open and Settled.
    func list(_ sources: [PaletteSource], query: String, tagFilter: Tag? = nil, rules: PickRules,
              order: PaletteOrder = .grouped) -> PickList<PaletteItem> {
        goTo.list(sources, query: query, tagFilter: tagFilter, rules: rules, order: order, payload: goToItem) { otherSections($0, among: sources) }
    }

    func sections(_ sources: [PaletteSource], ranksSetAside: Bool = false) -> [PickSectionInput<PaletteItem>] {
        goTo.sections(sources, ranksSetAside: ranksSetAside, payload: goToItem) { otherSections($0, among: sources) }
    }

    private var goTo: GoToInput {
        GoToInput(board: offersTopics ? board?.board : nil, records: records, windows: windows, sessionPaths: sessionPaths,
                  sessionMarks: board?.sessionMarks ?? [:], tags: board?.tags, visits: visits.times,
                  current: selectedWindowID.map(GoToLocation.window) ?? board?.activeTopic.map(GoToLocation.page),
                  home: homeDirectory, now: now)
    }

    private func otherSections(_ source: PaletteSource, among sources: [PaletteSource]) -> [PickSectionInput<PaletteItem>] {
        switch source {
        case .commands:
            return [PickSectionInput(id: "commands", title: "Commands", rule: .ranked(showsWhenEmpty: true),
                                     candidates: commands.map {
                PickCandidate(id: "command-" + $0.rawValue, kind: .command, title: $0.rawValue, note: commandSummaries[$0], trailing: commandShortcuts[$0] ?? "",
                              pick: .available(PaletteItem(ref: .command($0))))
            }, shorterTitleFirst: false)]
        case .windows:
            let hidden = sources.contains(.agents) ? Set(agents.map(\.windowID)) : []
            return [PickSectionInput(id: "windows", title: "Windows", rule: .ranked(showsWhenEmpty: sources == [.windows]),
                                     candidates: windows.filter { !hidden.contains($0.id) }.map(windowCandidate))]
        case .agents:
            return [PickSectionInput(id: "agents", title: "Agents", rule: .ranked(showsWhenEmpty: true), candidates: agentCandidates)]
        case .topics, .sessions:
            return []
        }
    }

    private var goToItem: (GoToTarget) -> PaletteItem {
        let rows = Dictionary((board?.rows ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessions = Dictionary(grouping: windows, by: \.sessionID)
        let directories = Dictionary(SessionChoice.launches(in: sessionPaths).map { ($0.directory.path, $0.directory) }, uniquingKeysWith: { first, _ in first })
        return { target in
            switch target {
            case .topic(let id, _):
                let window = rows[.topic(id)].flatMap { EntryWindow.of($0, lastWindowByGroup: lastWindowByGroup, visits: visits) }
                return PaletteItem(ref: .topic(id: id, window: window))
            case .settled(let id):
                return PaletteItem(ref: .topic(id: id, window: nil))
            case .boardSession(let id):
                return PaletteItem(ref: .boardSession(id: id))
            case .session(let id, let name):
                let members = sessions[id] ?? []
                return PaletteItem(ref: .session(SessionGroup(id: id, name: name, windows: members)), path: EntryWindow.folder(ofSession: members),
                                   target: name)
            case .sessionPath(let directory, let name):
                return PaletteItem(ref: .sessionPath(OpenDirectory(directory: directories[directory] ?? folders.folder(directory), name: name)),
                                   path: directory)
            case .tag(let tag):
                return PaletteItem(ref: .tag(tag), color: board?.tags?.definition(of: tag)?.color)
            }
        }
    }

    private func age(_ key: VisitKey) -> String? {
        visits.last(key).map { VisitAge.short(since: $0, now: now) }
    }

    private func topicFields(_ row: BoardModel.Row, type: String) -> [SearchField] {
        [.typeWord(type)] + row.sessions.map { .label($0.baseName) } + SearchField.tags(row.tags)
    }

    // MARK: Sessions and SessionPaths

    /// The ids of the Topic records that are not Settled. A Session in one of them is a Topic Session.
    var openTopicIDs: Set<String> { Set(records.filter { $0.settledAt == nil }.map(\.id)) }

    private func sessionKind(_ window: TmuxWindow, open: Set<String>) -> RowKind {
        window.topicID.map(open.contains) == true ? .topicSession : .session
    }

    /// Running Sessions and launch folders share one rank in Add a Session.
    func addSessionList(topic: String, query: String, rows: [SessionPathRow], rules: PickRules) -> PickList<PaletteItem> {
        var seen: Set<String> = []
        let open = openTopicIDs
        let sessions = windows.filter { $0.topicID != topic && seen.insert($0.sessionID).inserted }.map { window in
            return PickCandidate(id: "running-" + window.sessionID, kind: sessionKind(window, open: open), symbol: "■", title: window.sessionName,
                fields: [.detail(window.sessionPath)],
                lastVisit: visits.last(.session(name: window.sessionName)), activity: window.sessionActivity,
                pick: .available(PaletteItem(ref: .choice(.session(window.sessionID)))))
        }
        let paths = rows.map { row in
            let note = SessionPathRow(choice: row.choice, alsoIn: row.alsoIn.filter { $0.id != topic }).note
            return PickCandidate(id: row.id, kind: row.choice.isWorktree ? .worktree : .sessionPath, symbol: "□", title: row.choice.displayName,
                fields: [.detail(row.choice.directory.path)] + row.choice.nameFields, note: note,
                lastVisit: visits.last(.directory(row.choice.directory.real)),
                pick: .available(PaletteItem(ref: .choice(.sessionPath(row.choice)))))
        }
        return FuzzyRanker.list([PickSectionInput(id: "add-session", rule: .ranked(showsWhenEmpty: true), candidates: sessions + paths)],
                                query: FuzzyQuery(query), rules: rules)
    }

    /// Start a Session…: each Session Path and Worktree, and the home folder. A row starts a No Topic Session in its
    /// folder, named after it, as Open as Session does. The home folder row ignores `show`: it leads on an empty query,
    /// so ↩ starts there, and follows the matches of a query.
    func startSessionList(query: String, rules: PickRules) -> PickList<PaletteItem> {
        let running = Dictionary(windows.map { ($0.sessionName, "session:\($0.sessionID)") }, uniquingKeysWith: { first, _ in first })
        var names: Set<String> = []
        let paths = sessionPaths.flatMap(SessionChoice.choices).filter { names.insert($0.name).inserted }
        let home = folders.folder(homeDirectory)
        let homeName = SessionPath.named(at: home, in: sessionPaths).name
        let homeRow = PickCandidate(
            id: "home-folder", kind: .sessionPath, symbol: "□", title: "Home Folder",
            fields: [.typeWord("folder"), .detail("~")], trailing: "↩ open", lastVisit: visits.last(.directory(home.real)), unopened: true,
            pick: .available(PaletteItem(ref: .sessionPath(OpenDirectory(directory: home, name: homeName)), path: home.path)),
            paste: home.path)
        let homeSection = PickSectionInput(id: "home", rule: .fixed, candidates: [homeRow])
        let pathSection = PickSectionInput(id: "session-paths", rule: .ranked(showsWhenEmpty: true),
                                           candidates: paths.map { pathCandidate($0, shadowedBy: running[$0.name]) })
        let query = FuzzyQuery(query)
        return FuzzyRanker.list(query.isEmpty ? [homeSection, pathSection] : [pathSection, homeSection], query: query, rules: rules)
    }

    func destinationList(_ source: TmuxWindow, topic: String?, query: String, rules: PickRules) -> PickList<PaletteItem> {
        var seen: Set<String> = []
        let open = openTopicIDs
        let rows = windows.filter {
            $0.topicID.flatMap { open.contains($0) ? $0 : nil } == topic && $0.sessionID != source.sessionID && seen.insert($0.sessionID).inserted
        }.map { window in
            PickCandidate(id: "destination-" + window.sessionID, kind: sessionKind(window, open: open), title: window.sessionName,
                fields: [.detail(window.sessionPath)], pick: .available(PaletteItem(ref: .choice(.move(.session(id: window.sessionID))))))
        }
        let new = PickCandidate(id: "new-session", kind: .session, title: "New Session",
                                pick: .available(PaletteItem(ref: .choice(.move(.newSession(topic: topic))))))
        return FuzzyRanker.list([PickSectionInput(id: "sessions", rule: .ranked(showsWhenEmpty: true), candidates: rows),
            PickSectionInput(id: "new", rule: .fixed, candidates: [new])], query: FuzzyQuery(query), rules: rules)
    }

    private func pathCandidate(_ choice: SessionChoice, shadowedBy: String?) -> PickCandidate<PaletteItem> {
        .sessionPath(choice, lastVisit: visits.last(.directory(choice.directory.real)), home: homeDirectory, shadowedBy: shadowedBy,
                     pick: .available(PaletteItem(ref: .sessionPath(OpenDirectory(directory: choice.directory, name: choice.name)),
                                                  path: choice.directory.path)))
    }

    // MARK: Windows and Agents

    private func windowCandidate(_ window: TmuxWindow) -> PickCandidate<PaletteItem> {
        let target = "\(window.sessionName):\(window.index)"
        let isCurrent = window.id == selectedWindowID
        return PickCandidate(
            id: "window:\(window.id)", kind: .window, title: window.displayTitle,
            fields: [.typeWord("window"), .detail(target), .detail(window.abbreviatedPath), .hidden(window.command)],
            trailing: isCurrent ? "Current" : "", isCurrent: isCurrent, activity: window.sessionActivity,
            pick: .available(PaletteItem(ref: .window(window), path: window.path, target: target, logo: window.logoName)),
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
                id: "agent:\(agent.paneID)", kind: .agent, title: agent.label,
                fields: [.detail(agent.kind.displayName), .detail(agent.location), .hidden(agent.status?.rawValue ?? ""),
                         .hidden(Paths.tildify(path, home: homeDirectory))],
                isCurrent: agent.windowID == selectedWindowID, activity: window?.sessionActivity ?? 0,
                pick: .available(PaletteItem(ref: .agent(agent), path: path, target: agent.paneID,
                                             logo: agent.kind.rawValue, status: agent.status,
                                             mark: agentMarks[agent.paneID].map(CardMark.agent))),
                paste: path.isEmpty ? nil : path)
        }
    }

    // MARK: Move

    /// The open Topics minus the source's own, ranked for `query`, then the New Topic row titled
    /// by it. A Topic with a Session in the source's folder is offered too: Topics group Sessions, not folders.
    func moveList(_ source: TmuxWindow, query: String, scope: MoveDraft.Scope = .session, rules: PickRules) -> PickList<PaletteItem> {
        guard let board else { return .empty }
        let candidates = board.rows.compactMap { row -> PickCandidate<PaletteItem>? in
            guard case .topic(let id) = row.id, scope != .session || id != source.topicID,
                  records.contains(where: { $0.id == id }) else { return nil }
            return PickCandidate(
                id: row.id.accessibilityID, kind: .topic, symbol: row.state == .live ? "◆" : "◇", title: row.title,
                fields: topicFields(row, type: row.idleLabel?.lowercased() ?? "topic"),
                trailing: age(.topic(row.id)) ?? "", mark: row.mark,
                lastVisit: visits.last(.topic(row.id)), isPinned: row.isPinned,
                pick: .available(PaletteItem(ref: .choice(.move(.topic(id: id))))))
        }
        let title = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTopic = PickCandidate(
            id: "new-topic", kind: .topic, symbol: "＋", title: "New Topic", note: title.isEmpty ? "Untitled" : "“" + title + "”",
            pick: .available(PaletteItem(ref: .choice(.move(.newTopic(title: title))))))
        var newRows = [newTopic]
        if query.isEmpty || "No Topic".localizedCaseInsensitiveContains(query) {
            newRows.append(PickCandidate(id: "no-topic", kind: .session, title: "No Topic",
                pick: .available(PaletteItem(ref: .choice(.move(.noTopic))))))
        }
        if scope == .pane {
            newRows.append(PickCandidate(id: "new-window", kind: .window, symbol: "＋", title: "New Window in " + source.sessionName,
                                        note: title.isEmpty ? nil : title,
                                        pick: .available(PaletteItem(ref: .choice(.move(.newWindow(title: title)))))))
        }
        let destinations = PickSectionInput(id: "move", rule: .ranked(showsWhenEmpty: true), candidates: candidates)
        let create = PickSectionInput(id: "new-topic", rule: .fixed, candidates: newRows)
        return FuzzyRanker.list(scope == .session ? [destinations, create] : [create, destinations], query: FuzzyQuery(query), rules: rules)
    }

    /// The path as one shell word: bare when the shell reads it as is, quoted otherwise.
    static func shellWord(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%,:=")
        return !path.isEmpty && path.unicodeScalars.allSatisfy(plain.contains) ? path : Tmux.shellQuote(path)
    }
}

extension EntryWindow {
    /// For a Topic or No Topic: the remembered one, else the active Window of the member Session visited
    /// last, else the first active member. Nil when Dormant.
    static func of(_ row: BoardModel.Row, lastWindowByGroup: [TopicGroupID: String], visits: VisitLog) -> TmuxWindow? {
        let members = row.sessions.flatMap(\.windows)
        if let remembered = members.first(where: { $0.id == lastWindowByGroup[row.id] }) { return remembered }
        let visited = row.sessions.filter { !$0.windows.isEmpty }
            .compactMap { session in visits.last(.session(name: session.windows[0].sessionName)).map { (session, $0) } }
            .max { $0.1 < $1.1 }?.0
        if let visited { return ofSession(visited.windows) }
        return ofSession(members)
    }
}
