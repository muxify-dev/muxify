import MuxifyCore

// A switch between Sessions or Topics rebuilds `topics` and the Sidebar Formats, and moves `selectedWindowID`. A card
// or row that reads one of them in its body updates on every switch, whether or not what it shows changed. With many
// Sessions that kept the main thread busy for a quick run of switches. So the list reads the store once and hands each
// card the values it shows; a card whose values are the same as before does not update.

/// What a Window or Pane row of a Sidebar card shows.
enum SidebarRowState: Equatable {
    case window(Window)
    case pane(Pane)

    struct Window: Equatable {
        let content: SidebarFormats.WindowRowContent
        let isSelected: Bool
        let tooltips: Config.Sidebar.WindowTooltips
        let tabCount: Int
        let isGitViewOpen: Bool
        let usesMainWorkingCopy: Bool
    }

    struct Pane: Equatable {
        let formatted: SidebarFormats.Text
        let mark: AgentMark?
        /// With no Window row above it, the active Pane row shows where the user is.
        let isSelected: Bool
    }

    var window: Window? {
        if case .window(let window) = self { return window }
        return nil
    }

    var pane: Pane? {
        if case .pane(let pane) = self { return pane }
        return nil
    }
}

/// What a Session card shows, in Sessions mode and as the opened No Topic Session in Topics mode.
struct SessionCardState: Equatable {
    let session: SessionGroup
    let isOpen: Bool
    let mark: CardMark?
    let isLocked: Bool
    /// A Lock is a Guest with `topics.in_play`.
    let isGuest: Bool
    let formatted: SidebarFormats.Text
    let items: [TopicsModel.SessionChildren.Item]
    let rows: [String: SidebarRowState]
    /// The selected Window when it is one of the card's, so a selection that moves between other cards leaves this
    /// card as it was.
    let selectedWindowID: String?
    let guestState: Bool?
    let lockState: Bool?
    let changingTopic: Bool
    let showsAllRows: Bool

    var holdsSelection: Bool { selectedWindowID != nil }
}

extension WorkspaceStore {
    func sidebarRowState(_ item: TopicsModel.SessionChildren.Item) -> SidebarRowState {
        switch item {
        case .window(let window):
            return .window(SidebarRowState.Window(
                content: sidebarWindowRow(window), isSelected: window.id == selectedWindowID,
                tooltips: config.sidebar.windowTooltips, tabCount: tabCount(for: window),
                isGitViewOpen: isGitViewOpen(in: window.id),
                usesMainWorkingCopy: TopicsModel.usesMainWorkingCopy(
                    window, record: topicWatcher.records.first { $0.id == window.topicID }, sessionPaths: sessionPaths)))
        case .pane(let row):
            return .pane(SidebarRowState.Pane(
                formatted: sidebarText(.pane, context: sidebarFormatContexts.panes[row.pane.id]),
                mark: topics.agentMarks[row.pane.id],
                isSelected: !row.isUnderWindowRow && row.pane.isActive && row.window.id == selectedWindowID))
        }
    }

    /// The values of each row in `items`, by row ID.
    func sidebarRowStates(_ items: [TopicsModel.SessionChildren.Item]) -> [String: SidebarRowState] {
        Dictionary(items.map { ($0.id, sidebarRowState($0)) }, uniquingKeysWith: { first, _ in first })
    }

    func sessionCardState(_ session: SessionGroup, showsAllRows: Bool) -> SessionCardState {
        let model = topics
        let isLocked = model.lockedSessionIDs.contains(session.id)
        let items = model.sessionChildren[session.id]?.items ?? []
        let selected = selectedWindowID.flatMap { id in session.windows.contains { $0.id == id } ? id : nil }
        return SessionCardState(
            session: session, isOpen: openSessionCards.contains(session.name),
            mark: model.sessionMarks[session.id].map(CardMark.agent), isLocked: isLocked,
            isGuest: isLocked && topicConfig.inPlay != nil,
            formatted: sidebarText(.session, context: sidebarFormatContexts.sessions[session.id]),
            items: items, rows: sidebarRowStates(items), selectedWindowID: selected,
            guestState: guestState(of: .session(session.id)), lockState: lockState(ofSession: session.id),
            changingTopic: changingTopic, showsAllRows: showsAllRows)
    }
}

/// What a Topic card or a Locked card shows.
struct TopicCardState: Equatable {
    let topic: TopicsModel.Row
    let titles: [String: String]
    let formatted: SidebarFormats.Text
    let tags: CardTags?
    let holdsSelection: Bool
    let showsAllRows: Bool
    /// The selected Window when it is one of the card's.
    let selectedWindowID: String?
    let rows: [String: SidebarRowState]
    /// `guestState(of:)` and `canBench(_:)` of a Topic, for its menu.
    let guestState: Bool?
    let canBench: Bool
    let changingTopic: Bool
}

extension WorkspaceStore {
    /// `showsTags` is false for a closed card in a group, which shows no Tags.
    func topicCardState(_ topic: TopicsModel.Row, titles: [String: String], holdsSelection: Bool, showsAllRows: Bool,
                        showsTags: Bool) -> TopicCardState {
        let items = topic.sessions.flatMap { session -> [TopicsModel.SessionChildren.Item] in
            if case .live(let children) = session.contents { return children.items }
            return []
        }
        let selected = selectedWindowID.flatMap { id in items.contains { $0.window.id == id } ? id : nil }
        let formatted: SidebarFormats.Text
        var guest: Bool?
        var canBench = false
        switch topic.id {
        case .locked(let sessionID):
            formatted = sidebarText(.session, context: sidebarFormatContexts.sessions[sessionID])
        default:
            formatted = sidebarText(.topic, context: sidebarFormatContexts.topics[topic.id])
            if case .topic(let id) = topic.id {
                guest = guestState(of: .topic(id))
                canBench = self.canBench(.topic(id))
            }
        }
        return TopicCardState(topic: topic, titles: titles, formatted: formatted, tags: showsTags ? cardTags(topic) : nil,
                              holdsSelection: holdsSelection, showsAllRows: showsAllRows, selectedWindowID: selected,
                              rows: sidebarRowStates(items), guestState: guest, canBench: canBench,
                              changingTopic: changingTopic)
    }
}
