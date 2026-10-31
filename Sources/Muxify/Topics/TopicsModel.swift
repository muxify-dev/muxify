import Foundation
import MuxifyCore

extension TopicGroupID {
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

/// The group row after the open Topics and the No Topic card in Topics mode.
enum TopicGroup: String, CaseIterable {
    case settled

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
            /// `detail` is the outcome, or the settle date when there is none.
            case settled(detail: String)
        }

        let id: TopicGroupID
        let title: String
        let kind: Kind
        /// The Topic Unread mark or its strongest Agent mark.
        let mark: RowMark?
        /// Agent marks beside the rows of an expanded Active Topic, keyed by Window or replacing Pane ID.
        var agentSpines: [String: AgentMark] = [:]
        var usesRowMarks = false
        var isUnread = false
        /// A Guest, while the Config sets `topics.in_play`: a Topic with the Guest mark, or a Locked Session.
        var isGuest = false
        let isPinned: Bool
        let sessions: [Session]
        let isExpanded: Bool
        /// The record remembers Sessions that Reopen can make again.
        var remembersSessions = true
        /// In Config order, then the Tags the Config no longer defines. A Locked Session has none, and with Tags
        /// off no Topic has any.
        var tags: [ShownTag] = []
        /// The Topic Note from the record. A Locked Session has none.
        var note: String? = nil
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

    /// Benched cards that a drag across the Bench line shows for a moment while the Bench is hidden. The user's choice
    /// to show or hide the Bench stays as it is.
    enum BenchPeek: Equatable {
        /// An In Play card crossed the hidden line: the Bench shows until the drag ends.
        case all
        /// The card that a trade sent to the hidden Bench shows under the line, then folds into it.
        case card(TopicGroupID)
    }

    /// One item of the Topics list, in the order the Sidebar shows them.
    enum ListItem: Identifiable {
        case card(Row)
        /// The line between the In Play cards and the Bench.
        case benchLine(isBenchShown: Bool)
        case noTopicSession(Session)

        var id: String { cardID?.accessibilityID ?? "bench-line" }

        var dragSlot: StackSlot<TopicListID> {
            if case .card(let row) = self, let listID = row.id.listID { return .item(listID) }
            return .fixed(id)
        }

        /// The card's Topic, Locked Session or No Topic; nil for the Bench line.
        var cardID: TopicGroupID? {
            switch self {
            case .card(let row): return row.id
            case .noTopicSession: return .noTopic
            case .benchLine: return nil
            }
        }
    }

    /// The open Topics and the Locked Sessions, in one order; `groups` lists the others. No Topic has no row.
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

    /// The title of the Topic whose Session this is, among the open and shown Settled Topics. Nil for a
    /// Session in no Topic, and for a Locked Session, which is its own row.
    func topicTitle(ofSession sessionID: String) -> String? {
        let all = rows + groups.flatMap(\.topics)
        let row = all.first { row in
            if case .topic = row.id { return row.sessions.contains { $0.id.session == sessionID } }
            return false
        }
        return row?.title
    }

    /// The Pinned and In Play cards, then the Bench line, the opened No Topic Session and the Benched cards that
    /// show, in list order. Without a Bench: the cards of `rows`, then the opened No Topic Session.
    let list: [ListItem]
    /// The Topics list in two parts: the items that stay at the top of the Sidebar (the Pinned and In Play cards, the
    /// Bench line and the opened No Topic Session), and the Benched cards that show, which scroll alone under them.
    /// `bench` is nil without a Bench line, and then every item is in `top`.
    var listParts: (top: ArraySlice<ListItem>, bench: ArraySlice<ListItem>?) {
        guard let line = list.firstIndex(where: { $0.cardID == nil }) else { return (list[...], nil) }
        let start = list[(line + 1)...].firstIndex { if case .card = $0 { return true } else { return false } } ?? list.endIndex
        return (list[..<start], list[start...])
    }

    /// The Benched cards that show, in list order. Empty without a Bench line.
    var benchCardIDs: [TopicGroupID] { listParts.bench?.compactMap(\.cardID) ?? [] }

    func isBenched(_ id: TopicGroupID) -> Bool { benchCardIDs.contains(id) }

    /// The Location's card while it is on the Bench, shown or hidden. The Bench shows with this card where it was, and
    /// without one it shows at its top.
    var benchedLocation: TopicGroupID? {
        guard let activeTopic, isBenched(activeTopic) else { return nil }
        return activeTopic
    }

    /// Whether the Bench shows; nil while the Topics list has no Bench line.
    var isBenchShown: Bool? {
        list.lazy.compactMap { item -> Bool? in
            if case .benchLine(let shown) = item { return shown }
            return nil
        }.first
    }

    /// The cards of `rows`, as MuxifyCore orders them for the CLI too (`TopicCards`).
    private let cards: [TopicListEntry]

    /// The slots of `list` that the item `id` can reach in a drag: the cards with its Pin and, among the cards that are
    /// not Pinned, the Bench line and the opened No Topic Session, which a card passes. A card that crosses the line
    /// trades with a card on the other side.
    func dragSlots(around id: ListItem.ID) -> [StackSlot<TopicListID>] {
        func isPinned(_ item: ListItem) -> Bool {
            if case .card(let row) = item { return row.isPinned }
            return false
        }
        guard let dragged = list.first(where: { $0.id == id }) else { return [] }
        return list.filter { isPinned($0) == isPinned(dragged) }.map(\.dragSlot)
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
    /// The Locked Sessions, by Session ID.
    let lockedSessionIDs: Set<String>
    /// The No Topic Session of the selected Window. The Topic list shows it as one card after the open Topics, or under
    /// the Bench line.
    /// Nil while the Active Topic is a Topic.
    let openedNoTopicSession: Session?
    /// Settled, after the Topics rows in Topics mode. Empty in Sessions mode.
    let groups: [Group]
    /// Every Settled Topic, newest first.
    let settledTopicIDs: [String]
    /// The group that lists the Active Topic. Nil for a Topic in the Topics list, a Locked Session and No Topic.
    var activeTopicGroup: TopicGroup? {
        guard case .topic(let id)? = activeTopic else { return nil }
        return settledTopicIDs.contains(id) ? .settled : nil
    }
    /// The title each row shows, by Topic id: open and the Settled Topics on the shown pages.
    let titles: [String: String]
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

    init(records: [TopicRecord], windows: [TmuxWindow], config: Config, selection: TopicSelection, location: Location? = nil,
         mode: SidebarMode = .topics, groups groupsState: TopicGroupsState = TopicGroupsState(), benchShown: Bool = false,
         benchPeek: BenchPeek? = nil,
         agents: [Agent] = [], panes: [TmuxPane]? = nil) {
        topicsEnabled = config.sidebar.topics
        sessionsEnabled = config.sidebar.sessions
        tags = config.topics.tags
        self.mode = config.sidebar.shownMode(chosen: mode)
        let lockedIDs = Set(SessionLock.locks(in: windows, records: records).map(\.sessionID))
        lockedSessionIDs = lockedIDs
        let cards = TopicCards.order(records: records, windows: windows)
        self.cards = cards
        let open = cards.records
        let ids = Set(open.map(\.id))
        func groupID(_ window: TmuxWindow) -> TopicGroupID {
            if let id = window.topicID, ids.contains(id) { return .topic(id) }
            if lockedIDs.contains(window.sessionID) { return .locked(window.sessionID) }
            return .noTopic
        }
        let windowsByID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let agentsByGroup = Dictionary(grouping: agents, by: { windowsByID[$0.windowID].map(groupID) ?? .noTopic })
        let agentMarks = Dictionary(agents.compactMap { agent in
            AgentMark(agent, notifications: config.notifications).map { (agent.paneID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        self.agentMarks = agentMarks
        func mark(_ agents: [Agent]) -> AgentMark? { agents.compactMap { agentMarks[$0.paneID] }.max() }
        sessionMarks = Dictionary(grouping: agents, by: \.sessionID).compactMapValues(mark)
        let windowMarks = Dictionary(grouping: agents, by: \.windowID).compactMapValues(mark)
        let panesByWindow = panes.map { Dictionary(grouping: $0, by: \.windowID) }
        let agentsByPane = Dictionary(agents.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
        func children(_ windows: [TmuxWindow]) -> SessionChildren {
            SessionChildren(windows: windows, panes: panesByWindow, agents: agentsByPane)
        }
        sessionChildren = Dictionary(grouping: windows, by: \.sessionID).mapValues(children)

        let selectedWindow = windows.first { $0.id == location?.windowID?.rawValue }
        let pageTopicID: String?
        switch location {
        case .window:
            activeTopic = selectedWindow.map(groupID)
            pageTopicID = nil
        case .emptyTopic(let group):
            activeTopic = group
            if case .topic(let id) = group { pageTopicID = id } else { pageTopicID = nil }
        case nil:
            activeTopic = nil
            pageTopicID = nil
        }
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
            let agents = agentsByGroup[id] ?? []
            let sessions = sessions(of: id, members: grouped[id] ?? [], record: record)
            var spines: [String: AgentMark] = [:]
            if id == active, openTopics.contains(id) {
                for session in sessions {
                    guard case .live(let children) = session.contents else { continue }
                    for item in children.items {
                        switch item {
                        case .window(let window): spines[item.id] = windowMarks[window.id]
                        case .pane(let row) where !row.isUnderWindowRow:
                            spines[item.id] = agentMarks[row.id]
                        case .pane: break
                        }
                    }
                }
            }
            return Row(id: id, title: title, kind: .open, mark: RowMark(unread: record.isUnread, agent: mark(agents)),
                       agentSpines: spines, usesRowMarks: id == active && openTopics.contains(id),
                       isUnread: record.isUnread, isGuest: config.topics.inPlay != nil && record.isGuest && !record.isPinned,
                       isPinned: record.isPinned, sessions: sessions, isExpanded: openTopics.contains(id),
                       remembersSessions: !record.sessions.isEmpty, tags: config.topics.tags?.shown(record.tags) ?? [], note: record.note)
        }
        /// A Locked Session's row: one Session, titled by the Session card Formats.
        func lockedRow(_ lock: SessionLock) -> Row {
            let id = TopicGroupID.locked(lock.sessionID)
            let agents = agentsByGroup[id] ?? []
            let members = grouped[id] ?? []
            return Row(id: id, title: members.first?.sessionName ?? lock.sessionID, kind: .open, mark: mark(agents).map(RowMark.agent),
                       isGuest: config.topics.inPlay != nil, isPinned: false,
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
        let rows = cards.map { entry -> Row in
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
        self.rows = rows
        list = Self.list(rows, inPlay: self.mode == .topics ? config.topics.inPlay : nil, benchShown: benchShown,
                         peek: benchPeek, location: active, noTopic: openedNoTopicSession)
        let settled = records.filter { $0.settledAt != nil }
            .sorted { ($0.settledAt ?? "", $0.id) > ($1.settledAt ?? "", $1.id) }
        settledTopicIDs = settled.map(\.id)
        if let id = pageTopicID, let row = rows.first(where: { $0.id == .topic(id) }) {
            emptyTopic = row
        } else if let id = pageTopicID, let record = settled.first(where: { $0.id == id }) {
            emptyTopic = Self.settledRow(record, sessionPaths: config.sessionPaths, tags: config.topics.tags, expanded: openTopics)
        } else {
            emptyTopic = nil
        }
        let settledRows = settled.prefix(groupsState.settledPages * TopicGroupsState.pageSize)
            .map { Self.settledRow($0, sessionPaths: config.sessionPaths, tags: config.topics.tags, expanded: openTopics) }
        groups = self.mode == .topics ? [
            Group(kind: .settled, topics: settledRows,
                  hiddenCount: settled.count - settledRows.count, isExpanded: groupsState.open == .settled),
        ].filter { $0.count > 0 } : []
        titles = Dictionary((rows + settledRows).compactMap { row -> (String, String)? in
            if case .topic(let id) = row.id { return (id, row.title) }
            return nil
        }, uniquingKeysWith: { first, _ in first })
        let scope: AgentsScopeTarget
        if config.sidebar.agentsScope[self.mode] == .active, self.mode == .topics, let activeTopic {
            let title = rows.first { $0.id == activeTopic }?.title ?? emptyTopic?.title ?? "No Topic"
            scope = .topic(activeTopic, title: title)
        } else {
            switch (config.sidebar.agentsScope[self.mode], selectedWindow) {
            case (.all, _), (_, nil): scope = .everyAgent
            case (.window, let window?): scope = .window(id: window.id, title: window.displayTitle)
            case (.active, let window?): scope = .session(id: window.sessionID, name: window.sessionName)
            }
        }
        agentsScope = scope
        let scoped = agents.filter { agent in
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

    /// The Guests and the first `inPlay` other cards that are not Pinned are In Play, and the other cards are on the
    /// Bench (`InPlayCut`). A shown Bench shows each Benched card at its place in the list. While the Bench is hidden,
    /// only the Location's card and the card that `peek` holds show from it. The opened No Topic Session shows right
    /// under the line and counts toward nothing.
    private static func list(_ rows: [Row], inPlay: Int?, benchShown: Bool, peek: BenchPeek?, location: TopicGroupID?,
                             noTopic: Session?) -> [ListItem] {
        let opened = noTopic.map { [ListItem.noTopicSession($0)] } ?? []
        let cut = InPlayCut(rows.filter { !$0.isPinned }, limit: inPlay ?? .max, isGuest: \.isGuest)
        let front = rows.filter(\.isPinned) + cut.inPlay, bench = cut.bench
        guard !bench.isEmpty else { return front.map(ListItem.card) + opened }
        let shown = benchShown || peek == .all
        let benchCards = shown ? bench : bench.filter { $0.id == location || peek == .card($0.id) }
        return front.map(ListItem.card) + [.benchLine(isBenchShown: shown)] + opened + benchCards.map(ListItem.card)
    }

    /// A Settled Topic's row, with the Sessions and Windows its record remembers.
    static func settledRow(_ record: TopicRecord, sessionPaths: [SessionPath], tags: ConfigTags?, expanded: Set<TopicGroupID>) -> Row {
        let id = TopicGroupID.topic(record.id)
        let title = [record.title, record.slug].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Untitled Topic"
        let outcome = record.outcome?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let settledOn = record.settledAt.flatMap { try? Date.ISO8601FormatStyle().parse($0) }?.formatted(date: .abbreviated, time: .omitted)
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
                   tags: tags?.shown(record.tags) ?? [], note: record.note)
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
