import Foundation
import MuxifyCore

enum TopicGroupID: Hashable {
    case topic(String)
    /// A Locked Session, by Session ID: a No Topic Session with its own card among the Topics (ADR 0018).
    case locked(String)
    case noTopic

    var accessibilityID: String {
        switch self {
        case .topic(let id): return "topic-\(id)"
        case .locked(let sessionID): return "locked-\(sessionID)"
        case .noTopic: return "no-topic"
        }
    }

    /// The card's place in the Topic order; No Topic has none.
    var listID: TopicListID? {
        switch self {
        case .topic(let id): return .topic(id)
        case .locked(let sessionID): return .lock(sessionID: sessionID)
        case .noTopic: return nil
        }
    }
}

/// The two group rows after the open Topics and the No Topic card in Topics mode.
enum TopicGroup: String, CaseIterable {
    case snoozed, settled

    var title: String { rawValue.capitalized }
    var accessibilityID: String { rawValue + "-topics" }
}

/// Which group is open and how many pages the Settled group shows. At most one group is open, and only for a while:
/// it follows the Active Topic, so it is view state that no restart keeps.
struct TopicGroupsState: Equatable {
    static let pageSize = 15

    var open: TopicGroup? {
        didSet { if oldValue == .settled, open != .settled { settledPages = 1 } }
    }
    private(set) var settledPages = 1
    private var followed: Place?

    private struct Place: Equatable {
        let topic: TopicGroupID?
        let group: TopicGroup?
    }

    /// A header click opens its group and closes the other one, or closes its own.
    mutating func toggle(_ group: TopicGroup) { open = open == group ? nil : group }

    mutating func showMoreSettled() { settledPages += 1 }

    /// Opens the group that lists the Active Topic, with the Settled pages that reach its row, and closes the open group
    /// when the Active Topic is in the Topics list, a Locked Session or No Topic. Only a change of the Active Topic or of
    /// the group that lists it does this, so a header click stays while the user works in the same Topic.
    mutating func follow(_ model: TopicsModel) {
        let place = Place(topic: model.activeTopic, group: model.activeTopicGroup)
        guard place != followed else { return }
        followed = place
        open = place.group
        if place.group == .settled, case .topic(let id)? = place.topic, let index = model.settledTopicIDs.firstIndex(of: id) {
            settledPages = max(settledPages, index / Self.pageSize + 1)
        }
    }
}

/// The Topic and Locked cards right above and below a card, among those with its Pin.
struct CardNeighbors: Equatable {
    let above: TopicListID?
    let below: TopicListID?

    /// Where Move Up (`previous`) or Move Down (`next`) puts the card; nil at that end of its cards.
    func placement(_ direction: StepDirection) -> TopicPlacement? {
        switch direction {
        case .previous: return above.map(TopicPlacement.before)
        case .next: return below.map(TopicPlacement.after)
        }
    }
}

/// Which Agents the Agents section lists: every Agent, or those of what the
/// user looks at, the Active Topic (No Topic included) or the selected Window's Session.
enum AgentsScopeTarget: Equatable {
    case everyAgent
    case topic(TopicGroupID, title: String)
    case session(id: String, name: String)
    case window(id: String, title: String)

    /// The name the Agents section header shows, nil for every Agent.
    var name: String? {
        switch self {
        case .everyAgent: return nil
        case .topic(_, let title): return title
        case .session(_, let name): return name
        case .window(_, let title): return title
        }
    }
}

struct TopicSessionID: Hashable {
    let topic: TopicGroupID
    let session: String
}

struct TopicSelection: Equatable {
    var windowID: String?
    /// A Topic with no live Session that the user looks at in place of `windowID`'s Window: an empty, Dormant or
    /// Settled Topic.
    var emptyTopicID: String?
    var showsEmptyNoTopic = false
    private(set) var activeTopic: TopicGroupID?
    /// The open Topic cards and Settled rows. A new Active Topic opens alone; the user opens or closes any of them.
    private(set) var openTopics: Set<TopicGroupID> = []
    /// The Window last looked at in each Topic and in No Topic, for going back there.
    private(set) var lastWindowByGroup: [TopicGroupID: String] = [:]

    mutating func select(windowID: String?, activeTopic: TopicGroupID?) {
        let changedTopic = self.activeTopic != activeTopic
        if changedTopic { openTopics = Self.opening(activeTopic) }
        self.activeTopic = activeTopic
        let changedWindow = self.windowID != windowID
        self.windowID = windowID
        guard changedWindow || changedTopic, let activeTopic, let windowID else { return }
        lastWindowByGroup[activeTopic] = windowID
    }

    /// Takes the state the user asks for, not a toggle: a press on a card that a new Active Topic opened a moment
    /// before then leaves it open, as the user saw it.
    mutating func setTopic(_ id: TopicGroupID, open: Bool) {
        if open { openTopics.insert(id) } else { openTopics.remove(id) }
    }

    /// The open Topics for `activeTopic`: those the user left open, or the new Active Topic alone
    /// until `select` catches up with it.
    func openTopics(for activeTopic: TopicGroupID?) -> Set<TopicGroupID> {
        self.activeTopic == activeTopic ? openTopics : Self.opening(activeTopic)
    }

    /// No Topic has no card to open: the Topic list shows only the opened No Topic Session.
    private static func opening(_ activeTopic: TopicGroupID?) -> Set<TopicGroupID> {
        guard let activeTopic, activeTopic != .noTopic else { return [] }
        return [activeTopic]
    }
}

struct TopicsModel {
    /// A Window a Settled Topic's record remembers. Reopen rebuilds it; the row only shows it.
    struct RememberedWindow: Identifiable {
        let id: String
        let name: String
        let directory: String
    }

    /// A Pane row under a Window with 2 or more Panes, shown while Show Panes is on.
    struct PaneRow: Identifiable {
        let pane: TmuxPane
        let window: TmuxWindow
        /// The Agent the Pane runs, for its Status dot.
        let agent: Agent?
        /// False when the Pane rows stand in for the Session's only Window row.
        let isUnderWindowRow: Bool
        var id: String { pane.id }
    }

    /// The rows of a live Session: its Windows and, with Show Panes on, their Panes.
    struct SessionChildren {
        enum Item: Identifiable {
            case window(TmuxWindow)
            case pane(PaneRow)

            var id: String {
                switch self {
                case .window(let window): return window.id
                case .pane(let row): return row.id
                }
            }

            /// The Window the row stands for, or the Window of the Pane.
            var window: TmuxWindow {
                switch self {
                case .window(let window): return window
                case .pane(let row): return row.window
                }
            }
        }

        let windows: [TmuxWindow]
        let items: [Item]
        /// The Session's only Window when its Pane rows take the Window row's place.
        /// A click on the Session row selects it.
        let replacedWindow: TmuxWindow?

        /// `panes` is nil when Show Panes is off.
        init(windows: [TmuxWindow], panes: [String: [TmuxPane]]?, agents: [String: Agent]) {
            self.windows = windows
            func paneRows(_ window: TmuxWindow, underWindowRow: Bool) -> [PaneRow] {
                let shown = panes?[window.id] ?? []
                guard shown.count > 1 else { return [] }
                return shown.sorted { $0.index < $1.index }.map {
                    PaneRow(pane: $0, window: window, agent: agents[$0.id], isUnderWindowRow: underWindowRow)
                }
            }
            let soleWindowPanes = windows.count == 1 ? paneRows(windows[0], underWindowRow: false) : []
            if !soleWindowPanes.isEmpty {
                replacedWindow = windows[0]
                items = soleWindowPanes.map(Item.pane)
            } else {
                replacedWindow = nil
                items = windows.flatMap { [Item.window($0)] + paneRows($0, underWindowRow: true).map(Item.pane) }
            }
        }
    }

    struct Session: Identifiable {
        enum Contents {
            case live(SessionChildren)
            case remembered([RememberedWindow])
        }

        let id: TopicSessionID
        let baseName: String
        let contents: Contents
        var windows: [TmuxWindow] {
            if case .live(let children) = contents { return children.windows }
            return []
        }
    }

    struct Row: Identifiable {
        enum Kind: Equatable {
            case open
            /// `wake` is the wake time the row shows: "Mon 9:00", or "never".
            case snoozed(wake: String)
            /// `detail` is the outcome, or the settle date when there is none.
            case settled(detail: String)
        }

        let id: TopicGroupID
        let title: String
        let kind: Kind
        /// The Topic Unread mark or its strongest Agent mark; nil while the Topic is quiet.
        let mark: RowMark?
        let isPinned: Bool
        let sessions: [Session]
        let isExpanded: Bool
        /// The record remembers Sessions that Reopen can make again.
        var remembersSessions = true
        /// In Config order, then the Tags the Config no longer defines. A Locked Session has none, and with Tags
        /// off no Topic has any.
        var tags: [ShownTag] = []
        /// An open Topic with no live Session. The card shows dimmed.
        var hasNoLiveSession: Bool {
            if case .settled = kind { return false }
            return sessions.isEmpty
        }
        /// True for no Tag, so a missing filter keeps every row.
        func has(_ tag: Tag?) -> Bool { tag.map { tag in tags.contains { $0.tag == tag } } ?? true }
        /// No live Session, and Reopen makes the remembered ones again.
        var isDormant: Bool { hasNoLiveSession && remembersSessions }
        /// "Dormant", or "Empty" for an open Topic that remembers no Session and offers Add a Session.
        var idleLabel: String? { hasNoLiveSession ? (remembersSessions ? "Dormant" : "Empty") : nil }
    }

    /// A group row and the Topic rows it shows. Absent from `groups` when it holds no Topic.
    struct Group: Identifiable {
        let kind: TopicGroup
        let topics: [Row]
        /// Settled Topics after the shown pages; "Show 15 more" adds them.
        let hiddenCount: Int
        let isExpanded: Bool
        var id: TopicGroup { kind }
        var count: Int { topics.count + hiddenCount }
    }

    struct Wake {
        let id: String
        let title: String
        let count: Int
        var message: String { "\(title) woke. \(count) Agent\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") you." }
    }

    /// The open Topics that are not Snoozed and the Locked Sessions, in one order; `groups` lists the others.
    /// No Topic has no row. While Zen is on, the Locked Sessions have no row either.
    let rows: [Row]
    /// The Next Topic after `id` leaves the list together with `others`: the nearest row below that stays, else above.
    func nextTopic(after id: String, skipping others: Set<String> = []) -> TopicGroupID {
        guard let index = rows.firstIndex(where: { $0.id == .topic(id) }) else { return .noTopic }
        func stays(_ row: Row) -> Bool {
            if case .topic(let other) = row.id { return other != id && !others.contains(other) }
            return true
        }
        return rows[(index + 1)...].first(where: stays)?.id ?? rows[..<index].last(where: stays)?.id ?? .noTopic
    }

    /// The cards of `rows`, as MuxifyCore orders them for the CLI too (`TopicCards`).
    private let cards: [TopicListEntry]

    /// The Pinned Topic cards, or the Topic and Locked cards that are not Pinned, in list order: a drag reorders a card
    /// among these only.
    func cardOrder(pinned: Bool) -> [TopicListID] {
        cards.filter { $0.isPinned == pinned }.map(\.id)
    }

    /// The cards right above and below a card in the Topics list, among those with its Pin. None for a Topic outside it.
    func neighbors(of id: TopicGroupID) -> CardNeighbors {
        guard let listID = id.listID else { return CardNeighbors(above: nil, below: nil) }
        var above: TopicListID?, below: TopicListID?
        if case .to(.before(let card)) = TopicCards.step(listID, .up, in: cards) { above = card }
        if case .to(.after(let card)) = TopicCards.step(listID, .down, in: cards) { below = card }
        return CardNeighbors(above: above, below: below)
    }

    /// Every live No Topic Session, Locked or not. The Command Palette reaches each of them.
    let noTopicSessions: [Session]
    /// The Locked Sessions, by Session ID, also while Zen hides their cards.
    let lockedSessionIDs: Set<String>
    /// The No Topic Session of the selected Window. The Topic list shows it as one card after the open Topics.
    /// Nil while the Active Topic is a Topic.
    let openedNoTopicSession: Session?
    /// Snoozed, then Settled, after the Topics rows in Topics mode. Empty in Sessions mode.
    let groups: [Group]
    /// The Snoozed Topics by wake time, soonest first, in both Sidebar modes. A Topic Snoozed until the user Unsnoozes
    /// it comes last; equal times keep the list order.
    let snoozedRows: [Row]
    /// Every Settled Topic, newest first.
    let settledTopicIDs: [String]
    /// The group that lists the Active Topic. Nil for a Topic in the Topics list, a Locked Session and No Topic.
    var activeTopicGroup: TopicGroup? {
        guard case .topic(let id)? = activeTopic else { return nil }
        if snoozedTopicIDs.contains(id) { return .snoozed }
        return settledTopicIDs.contains(id) ? .settled : nil
    }
    /// The title each row shows, by Topic id: open, Snoozed and the Settled Topics on the shown pages.
    let titles: [String: String]
    let snoozedTopicIDs: Set<String>
    let visibleAgents: [Agent]
    let agentsScope: AgentsScopeTarget
    /// The line under each listed Agent, by Pane ID: its Topic's title in Topics mode, its Session's name in
    /// Sessions mode. Empty when the section lists one Topic or Session, which the header already names.
    let agentGroups: [String: String]
    /// The Agent mark each Session card's spine shows in Sessions mode, by Session ID.
    let sessionMarks: [String: AgentMark]
    /// The Agent mark of each Agent's own row, by Pane ID: its Pane row, its Agents row and its Command Palette result.
    let agentMarks: [String: AgentMark]
    /// The rows under each Session row in Sessions mode, by Session ID.
    let sessionChildren: [String: SessionChildren]
    /// Each live Session as a Topic lists it, by Session ID, for its SessionPath name in the sidebar Formats.
    let topicSessions: [String: Session]
    let dueWakes: [Wake]
    /// The next Snooze deadline after `now`. From then on, a model built from the same inputs is different.
    let changesAt: Date?
    let activeTopic: TopicGroupID?
    /// The Active Topic when it has no live Session, which the terminal area shows in place of a Window: an empty
    /// Topic, or a Dormant or Settled one with its Reopen choice.
    let emptyTopic: Row?
    let topicsEnabled: Bool
    let sessionsEnabled: Bool
    let mode: SidebarMode
    /// `topics.tags`; nil while Tags are off.
    let tags: ConfigTags?
    var showsToggle: Bool { topicsEnabled && sessionsEnabled }

    init(records: [TopicRecord], windows: [TmuxWindow], config: Config, selection: TopicSelection,
         mode: SidebarMode = .topics, groups groupsState: TopicGroupsState = TopicGroupsState(),
         agents: [Agent] = [], panes: [TmuxPane]? = nil, zen: ZenRecord? = nil,
         now: Date = Date()) {
        topicsEnabled = config.sidebar.topics
        sessionsEnabled = config.sidebar.sessions
        tags = config.topics.tags
        self.mode = config.sidebar.shownMode(chosen: mode)
        let locks = SessionLock.locks(in: windows, records: records)
        lockedSessionIDs = Set(locks.map(\.sessionID))
        // Zen keeps only Topics: it hides the Locked Sessions, and then each is one more No Topic Session.
        let shownLocks = zen == nil ? lockedSessionIDs : []
        let entries = TopicOrder.sorted(records.map(TopicListEntry.topic) + (zen == nil ? locks : []).map(TopicListEntry.lock))
        let open = entries.records
        let cards = TopicCards.order(records: records, windows: windows, zen: zen, now: now)
        self.cards = cards
        let ids = Set(open.map(\.id))
        let snoozedIDs = Set(open.filter { $0.isSnoozed(at: now) }.map(\.id))
        snoozedTopicIDs = snoozedIDs
        func groupID(_ window: TmuxWindow) -> TopicGroupID {
            if let id = window.topicID, ids.contains(id) { return .topic(id) }
            if shownLocks.contains(window.sessionID) { return .locked(window.sessionID) }
            return .noTopic
        }
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agentsByGroup = Dictionary(grouping: agents, by: { windowsByID[$0.windowID].map(groupID) ?? .noTopic })
        /// A group that shows no Notification: a Snoozed Topic, and No Topic while Zen is on. Its card has no mark at
        /// all; an Agent's own row keeps the Working mark. Unread does not change, so the Notifications come back when
        /// the Snooze or Zen ends.
        func isQuiet(_ group: TopicGroupID) -> Bool {
            switch group {
            case .topic(let id): return snoozedIDs.contains(id)
            case .locked: return false
            case .noTopic: return zen != nil
            }
        }
        func isQuiet(_ agent: Agent) -> Bool { isQuiet(windowsByID[agent.windowID].map(groupID) ?? .noTopic) }
        let agentMarks = Dictionary(agents.compactMap { agent in
            AgentMark(agent, notifications: config.notifications, quiet: isQuiet(agent)).map { (agent.paneID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        self.agentMarks = agentMarks
        func mark(_ agents: [Agent]) -> AgentMark? { agents.compactMap { agentMarks[$0.paneID] }.max() }
        let shown = agents.filter { !isQuiet($0) }
        sessionMarks = Dictionary(grouping: shown, by: \.sessionID).compactMapValues(mark)
        let panesByWindow = panes.map { Dictionary(grouping: $0, by: \.windowID) }
        let agentsByPane = Dictionary(agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        func children(_ windows: [TmuxWindow]) -> SessionChildren {
            SessionChildren(windows: windows, panes: panesByWindow, agents: agentsByPane)
        }
        sessionChildren = Dictionary(grouping: windows, by: \.sessionID).mapValues(children)

        let selectedWindow = windows.first { $0.id == selection.windowID }
        let emptyTopicID = selection.emptyTopicID.flatMap { id in
            records.contains { $0.id == id } && !windows.contains { $0.topicID == id } ? id : nil
        }
        activeTopic = selection.showsEmptyNoTopic ? .noTopic : (emptyTopicID.map(TopicGroupID.topic) ?? selectedWindow.map(groupID))
        let active = activeTopic
        let openTopics = selection.openTopics(for: active)
        let grouped = Dictionary(grouping: windows, by: groupID)
        /// A Topic's Sessions in the Topic's order; the Sessions of No Topic or of a Locked Session in tmux order.
        func sessions(of id: TopicGroupID, members: [TmuxWindow], record: TopicRecord?) -> [Session] {
            var seen: Set<String> = []
            let firsts = members.filter { seen.insert($0.sessionID).inserted }
            let ordered = record == nil ? firsts : TopicSessionOrder.ordered(firsts, record: record, order: config.topics.sessionOrder) {
                TopicSessionKey(of: $0)
            }
            return ordered.map(\.sessionID).map { sessionID -> Session in
                let windows = members.filter { $0.sessionID == sessionID }
                let identity = TopicSessionID(topic: id, session: sessionID)
                return Session(id: identity, baseName: SessionNaming.base(of: windows[0].sessionName, topic: record),
                               contents: .live(children(windows)))
            }
        }
        func row(_ record: TopicRecord, title: String) -> Row {
            let id = TopicGroupID.topic(record.id)
            let kind: Row.Kind = (record.isSnoozed(at: now) ? record.snoozeDeadline : nil).map { .snoozed(wake: $0.wakeLabel) } ?? .open
            let agents = isQuiet(id) ? [] : agentsByGroup[id] ?? []
            return Row(id: id, title: title, kind: kind, mark: isQuiet(id) ? nil : RowMark(unread: record.isUnread, agent: mark(agents)), isPinned: record.isPinned,
                       sessions: sessions(of: id, members: grouped[id] ?? [], record: record), isExpanded: openTopics.contains(id),
                       remembersSessions: !record.sessions.isEmpty, tags: config.topics.tags?.shown(record.tags) ?? [])
        }
        /// A Locked Session's row: one Session, quiet only as No Topic is, and titled by the Session card Formats.
        func lockedRow(_ lock: SessionLock) -> Row {
            let id = TopicGroupID.locked(lock.sessionID)
            let agents = agentsByGroup[id] ?? []
            let members = grouped[id] ?? []
            return Row(id: id, title: members.first?.sessionName ?? lock.sessionID, kind: .open, mark: mark(agents).map(RowMark.agent), isPinned: false,
                       sessions: sessions(of: id, members: members, record: nil), isExpanded: openTopics.contains(id))
        }
        let untitledRecords = open.filter { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
        var numbers: [String: Int] = [:]
        var usedNumbers: Set<Int> = []
        for record in untitledRecords.sorted(by: { $0.id < $1.id }) {
            if let slug = record.slug, slug.hasPrefix("untitled-"), let number = Int(slug.dropFirst(9)), number > 0,
               usedNumbers.insert(number).inserted {
                numbers[record.id] = number
            }
        }
        for record in untitledRecords.sorted(by: { $0.id < $1.id }) where numbers[record.id] == nil {
            var number = 1
            while usedNumbers.contains(number) { number += 1 }
            numbers[record.id] = number
            usedNumbers.insert(number)
        }
        let rows = entries.map { entry -> Row in
            switch entry {
            case .lock(let lock): return lockedRow(lock)
            case .topic(let record):
                let title: String
                if let value = record.title, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = value }
                else {
                    title = "Untitled \(numbers[record.id] ?? 1)"
                }
                return row(record, title: title)
            }
        }
        noTopicSessions = sessions(of: .noTopic, members: windows.filter { window in
            switch groupID(window) {
            case .topic: return false
            case .locked, .noTopic: return true
            }
        }, record: nil)
        openedNoTopicSession = active == .noTopic ? noTopicSessions.first { $0.id.session == selectedWindow?.sessionID } : nil
        topicSessions = Dictionary((rows.flatMap(\.sessions) + noTopicSessions).map { ($0.id.session, $0) },
                                   uniquingKeysWith: { first, _ in first })
        let wakes = Dictionary(open.compactMap { record in record.snoozeDeadline.map { (record.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        func wake(_ row: Row) -> Date {
            guard case .topic(let id) = row.id, case .at(let date)? = wakes[id] else { return .distantFuture }
            return date
        }
        let snoozedRows = rows.filter { if case .topic(let id) = $0.id { return snoozedIDs.contains(id) }; return false }
            .enumerated().sorted { (wake($0.element), $0.offset) < (wake($1.element), $1.offset) }.map(\.element)
        let rowsByCard = Dictionary(rows.compactMap { row in row.id.listID.map { ($0, row) } }, uniquingKeysWith: { first, _ in first })
        let openRows = cards.compactMap { rowsByCard[$0.id] }
        self.rows = openRows
        self.snoozedRows = snoozedRows
        let settled = records.filter { $0.settledAt != nil }
            .sorted { ($0.settledAt ?? "", $0.id) > ($1.settledAt ?? "", $1.id) }
        settledTopicIDs = settled.map(\.id)
        if let id = emptyTopicID, let row = rows.first(where: { $0.id == .topic(id) }) {
            emptyTopic = row
        } else if let id = emptyTopicID, let record = settled.first(where: { $0.id == id }) {
            emptyTopic = Self.settledRow(record, sessionPaths: config.sessionPaths, tags: config.topics.tags, expanded: openTopics)
        } else {
            emptyTopic = nil
        }
        let settledRows = settled.prefix(groupsState.settledPages * TopicGroupsState.pageSize)
            .map { Self.settledRow($0, sessionPaths: config.sessionPaths, tags: config.topics.tags, expanded: openTopics) }
        groups = self.mode == .topics ? [
            Group(kind: .snoozed, topics: snoozedRows, hiddenCount: 0, isExpanded: groupsState.open == .snoozed),
            Group(kind: .settled, topics: settledRows,
                  hiddenCount: settled.count - settledRows.count, isExpanded: groupsState.open == .settled),
        ].filter { $0.count > 0 } : []
        titles = Dictionary((rows + settledRows).compactMap { row -> (String, String)? in
            if case .topic(let id) = row.id { return (id, row.title) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        changesAt = open.compactMap { record -> Date? in
            guard case .at(let date)? = record.snoozeDeadline, date > now else { return nil }
            return date
        }.min()
        dueWakes = open.filter { $0.snoozeDeadline?.isDue(at: now) == true }.map { record in
            Wake(id: record.id, title: rows.first { $0.id == .topic(record.id) }?.title ?? "Untitled Topic",
                 count: (agentsByGroup[.topic(record.id)] ?? []).filter {
                     AgentMark($0, notifications: config.notifications)?.isNotification == true
                 }.count)
        }

        let scope: AgentsScopeTarget
        switch (config.sidebar.agentsScope[self.mode], self.mode, selectedWindow) {
        case (.all, _, _), (.active, _, nil), (.window, _, nil):
            scope = .everyAgent
        case (.window, _, let window?):
            scope = .window(id: window.id, title: window.displayTitle)
        case (.active, .topics, let window?):
            let id = groupID(window)
            scope = .topic(id, title: rows.first { $0.id == id }?.title ?? "No Topic")
        case (.active, .sessions, let window?):
            scope = .session(id: window.sessionID, name: window.sessionName)
        }
        agentsScope = scope
        let scoped = shown.filter { agent in
            switch scope {
            case .everyAgent: return true
            case .topic(let id, _): return windowsByID[agent.windowID].map(groupID) == id
            case .session(let id, _): return agent.sessionID == id
            case .window(let id, _): return agent.windowID == id
            }
        }
        let titlesByGroup = Dictionary(rows.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let groupsBySession = self.mode == .sessions
        agentGroups = scope != .everyAgent ? [:] : Dictionary(scoped.map { agent in
            let group = groupsBySession ? agent.sessionName
                : windowsByID[agent.windowID].map(groupID).flatMap { titlesByGroup[$0] } ?? "No Topic"
            return (agent.paneID, group)
        }, uniquingKeysWith: { first, _ in first })
        visibleAgents = scoped.filter { agentMarks[$0.paneID]?.isNotification == true }
            + scoped.filter { agentMarks[$0.paneID] == .working }
            + scoped.filter { agentMarks[$0.paneID] == nil }
    }

    /// A Settled Topic's row, with the Sessions and Windows its record remembers.
    static func settledRow(_ record: TopicRecord, sessionPaths: [SessionPath], tags: ConfigTags?, expanded: Set<TopicGroupID>) -> Row {
        let id = TopicGroupID.topic(record.id)
        let title = [record.title, record.slug].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Untitled Topic"
        let outcome = record.outcome?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let settledOn = record.settledAt.flatMap { SnoozeDeadline(stored: $0) }.flatMap { deadline -> String? in
            if case .at(let date) = deadline { return date.formatted(date: .abbreviated, time: .omitted) }
            return nil
        }
        let sessions = record.sessions.enumerated().compactMap { index, session -> Session? in
            guard let path = session["directory"]?.string, let savedID = session["id"]?.string else { return nil }
            let identity = TopicSessionID(topic: id, session: savedID)
            let windows = (session["windows"]?.array ?? []).enumerated().map { position, window in
                RememberedWindow(id: "\(record.id)-\(index)-\(position)", name: window["name"]?.string ?? "shell",
                                 directory: window["directory"]?.string ?? path)
            }
            return Session(id: identity, baseName: session["base_name"]?.string ?? session["name"]?.string ?? "Session",
                           contents: .remembered(windows))
        }
        return Row(id: id, title: title, kind: .settled(detail: outcome.isEmpty ? settledOn ?? record.settledAt ?? "" : outcome),
                   mark: RowMark(unread: record.isUnread, agent: nil), isPinned: record.isPinned, sessions: sessions, isExpanded: expanded.contains(id),
                   tags: tags?.shown(record.tags) ?? [])
    }

    /// A Window that left its Session's Worktree for the main working copy of the SessionPath.
    /// It compares against the Session's own Worktree, so in a bare layout, where every
    /// Worktree sits inside the SessionPath folder, a Window in its own Worktree is not flagged.
    static func usesMainWorkingCopy(_ window: TmuxWindow, record: TopicRecord?, sessionPaths: [SessionPath]) -> Bool {
        guard let saved = record?.session(of: window), let worktree = saved["worktree_path"]?.string.map(Folder.local),
              let repository = saved["repository_path"]?.string.map(Folder.local) else { return false }
        let folder = Folder.local(window.path)
        return repository.contains(folder) && !worktree.contains(folder)
    }
}
