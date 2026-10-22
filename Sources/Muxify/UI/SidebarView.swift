import AppKit
import SwiftUI
import MuxifyCore

/// Two sections stacked vertically: Topics or Sessions on top, Agents below. Each can be
/// hidden from the View menu; with both shown, a divider between them sets
/// their split. With neither, the sidebar stays open but empty.
struct SidebarView: View {
    let store: WorkspaceStore
    var typography = SidebarTypography()

    /// The share of the sidebar's height the Agents section gets.
    @AppStorage("sidebarAgentsFraction") private var agentsFraction: Double = 0.35

    var body: some View {
        content.environment(\.sidebarTypography, typography)
            .environment(\.wrapsCardTitles, store.config.sidebar.wrapsTitles)
    }

    @ViewBuilder
    private var content: some View {
        Group {
        if store.sessionsVisible && store.agentsVisible {
            GeometryReader { proxy in
                let total = proxy.size.height
                VStack(spacing: 0) {
                    WorkSection(store: store)
                        .frame(maxHeight: .infinity)
                    SectionResizeHandle(fraction: $agentsFraction, total: total)
                    AgentsSection(store: store)
                        .frame(height: SectionResizeHandle.agentsHeight(agentsFraction, total: total))
                }
            }
        } else if store.sessionsVisible {
            WorkSection(store: store)
        } else if store.agentsVisible {
            AgentsSection(store: store)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        }
        .onChange(of: store.selectedWindowID, initial: true) { _, _ in store.updateTopicSelection() }
        .onChange(of: store.topics.activeTopic) { _, _ in store.updateTopicSelection() }
        .onChange(of: store.topics.activeTopicGroup) { _, _ in store.updateTopicSelection() }
        // Moving to another Session (click, tmux navigation, new Window) opens its card.
        .onChange(of: store.selectedWindow?.sessionName, initial: true) { _, name in
            guard let name, !store.openSessionCards.contains(name) else { return }
            withAnimation(.easeOut(duration: 0.15)) { _ = store.openSessionCards.insert(name) }
        }
    }
}

private struct WorkSection: View {
    let store: WorkspaceStore

    var body: some View {
        let model = store.topics
        let showsTopics = model.mode == .topics
        VStack(spacing: 0) {
            if model.showsToggle {
                HStack(spacing: 4) {
                    viewButton(.topics, selected: showsTopics)
                    viewButton(.sessions, selected: !showsTopics)
                }
                .padding(6)
            }
            if showsTopics {
                TopicsSection(store: store, model: model)
            } else if model.sessionsEnabled {
                SessionsSection(store: store)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func viewButton(_ mode: SidebarMode, selected: Bool) -> some View {
        Button { store.sidebarMode = mode } label: {
            Text(mode.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-view-" + mode.rawValue.lowercased())
        .accessibilityValue(selected ? "selected" : "")
    }
}

private struct TopicsSection: View {
    @Environment(\.sidebarTypography) private var typography
    let store: WorkspaceStore
    let model: TopicsModel
    @State private var drag = LongPressDrag<TopicListID>(spacing: 6)
    @State private var groupsHeight: CGFloat = 0
    /// The cards whose "N more…" the user pressed.
    @State private var showingAllRows: Set<TopicGroupID> = []
    /// The No Topic Session cards whose "N more…" the user pressed, by Session ID.
    @State private var showingAllSessionRows: Set<String> = []

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let zen = store.topicWatcher.zen { zenLine(zen) }
                ScrollView {
                    // Not lazy: a lazy stack is one more accessibility element over all the cards, and a click tool
                    // such as Homerow clicks its centre, on whichever card is there.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.rows) { topic in
                            let order = model.cardOrder(pinned: topic.isPinned)
                            if case .locked(let sessionID) = topic.id {
                                LockedCard(store: store, row: topic, sessionID: sessionID, titles: model.titles,
                                           holdsSelection: topic.id == model.activeTopic,
                                           showsAllRows: showingAllRows.contains(topic.id),
                                           onShowAllRows: { showingAllRows.insert(topic.id) },
                                           drag: drag, order: order, neighbors: model.neighbors(of: topic.id))
                            } else {
                                TopicCard(store: store, topic: topic, titles: model.titles, holdsSelection: topic.id == model.activeTopic,
                                          showsAllRows: showingAllRows.contains(topic.id),
                                          onShowAllRows: { showingAllRows.insert(topic.id) },
                                          place: .list(TopicListPlace(drag: drag, order: order, neighbors: model.neighbors(of: topic.id),
                                                                      rename: renameTopic)))
                            }
                        }
                        if let opened = model.openedNoTopicSession { noTopicCard(opened) }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .coordinateSpace(.named(TopicCard.viewport))
                .scrollIndicators(.never)
                .accessibilityIdentifier("topics-list")
                .overlay {
                    if model.rows.isEmpty && model.openedNoTopicSession == nil && model.groups.isEmpty {
                        Text("No Topics").font(typography.font(for: .title)).foregroundStyle(.secondary)
                    }
                }
                if !model.groups.isEmpty {
                    // The groups stay at the bottom of the panel, so an opened group pushes its row up. They take
                    // their own height up to a third of the panel, and scroll when an open group is taller.
                    ScrollView {
                        groupRows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { groupsHeight = $0 }
                    }
                    .coordinateSpace(.named(TopicCard.groupsViewport))
                    .scrollIndicators(.never)
                    .frame(height: min(groupsHeight, proxy.size.height / 3))
                }
            }
        }
    }

    private func zenLine(_ zen: ZenRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.stars").font(.system(size: 11))
            Group {
                if let deadline = zen.deadline, deadline != .never { Text("Zen until " + deadline.wakeLabel) } else { Text("Zen") }
            }
            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            .accessibilityIdentifier("zen-status")
            Spacer(minLength: 4)
            Button("End Zen") { store.endZen() }
                .topicLink()
                .disabled(store.changingTopic)
                .accessibilityIdentifier("end-zen")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 26)
    }

    /// The No Topic Session the user opened, as the card Sessions mode shows. No Topic has no group row.
    @ViewBuilder
    private func noTopicCard(_ opened: TopicsModel.Session) -> some View {
        if let session = store.sessions.first(where: { $0.id == opened.id.session }) {
            SessionCard(store: store, model: model, session: session,
                        identifier: "\(TopicGroupID.noTopic.accessibilityID)-session-\(session.id)", viewport: TopicCard.viewport,
                        showsAllRows: showingAllSessionRows.contains(session.id),
                        onShowAllRows: { showingAllSessionRows.insert(session.id) }) { item in
                TopicItemRow(store: store, item: item, titles: model.titles, isDimmed: false)
            }
        }
    }

    private var groupRows: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(model.groups) { group in
                GroupHeader(icon: group.kind == .snoozed ? "moon" : "checkmark.circle", title: group.kind.title,
                            count: group.count, isExpanded: group.isExpanded) {
                    store.topicGroups.toggle(group.kind)
                }
                .padding(.top, 4)
                .accessibilityIdentifier(group.kind.accessibilityID)
                .accessibilityValue(group.isExpanded ? "expanded" : "collapsed")
                if group.isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.topics) { topic in
                            TopicCard(store: store, topic: topic, titles: model.titles, holdsSelection: topic.id == model.activeTopic,
                                      showsAllRows: showingAllRows.contains(topic.id),
                                      onShowAllRows: { showingAllRows.insert(topic.id) }, place: .group)
                        }
                    }
                    .padding(.vertical, 2)
                    if group.hiddenCount > 0 {
                        Button("Show \(min(group.hiddenCount, TopicGroupsState.pageSize)) more") { store.topicGroups.showMoreSettled() }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.leading, 24).frame(height: 24)
                            .accessibilityIdentifier("settled-show-more")
                    }
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    private func renameTopic(_ id: String, suggest: Bool = false) {
        guard let topic = store.topicWatcher.records.first(where: { $0.id == id }) else { return }
        store.palette.begin(.text(.renameTopic(topic)), text: topic.title ?? "")
        if suggest { store.palette.suggestTitle() }
    }
}

private extension View {
    /// The look of a Topic's own action (Settle, Unsnooze, Reopen): a link, so the row stays quiet.
    func topicLink() -> some View {
        buttonStyle(.link).font(.system(size: 11))
    }
}

/// The Sessions a Settled Topic's opened card lists: remembered ones, whose rows are dimmed and do nothing on click.
private struct RememberedSessions: View {
    let store: WorkspaceStore
    let topic: TopicsModel.Row

    var body: some View {
        ForEach(topic.sessions) { session in
            if case .remembered(let windows) = session.contents {
                SessionHeading(store: store, topic: topic, session: session)
                ForEach(windows) { window in
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).frame(width: 14)
                        Text(window.name).font(.system(size: 12)).hoverLabelTitle()
                        Spacer(minLength: 4)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24).padding(.trailing, 6).padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .hoverLabel(detail: Paths.tildify(window.directory))
                    .accessibilityIdentifier("remembered-window-\(window.id)")
                }
            }
        }
        Color.clear.frame(height: 16)
    }
}

/// What a Session line of an open Topic card needs to move the Session within its Topic.
private struct SessionOrdering {
    /// The drag of the card's Session blocks; the line starts it, and the whole block moves.
    let drag: LongPressDrag<String>
    /// The Sessions right above and below this one, where Move Up and Move Down put it.
    let above: String?
    let below: String?
    /// The Topic keeps an order the user gave, which Sort Sessions by Creation ends.
    let isManual: Bool
}

/// The heading of one Session inside a Topic: its SessionPath. Pressing it goes to the Session's
/// active Window. In an open Topic card a long press moves the Session, with its rows, within its Topic.
private struct SessionHeading: View {
    let store: WorkspaceStore
    let topic: TopicsModel.Row
    let session: TopicsModel.Session
    var ordering: SessionOrdering? = nil

    var body: some View {
        line
            .takesFirstClick()
            .opacity(topic.kind == .open ? 1 : 0.5)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, go)
            .accessibilityIdentifier("\(topic.id.accessibilityID)-session-\(session.id.session)")
            .accessibilityActions { orderButtons }
            .contextMenu {
                orderButtons
                if let window = session.windows.first {
                    if ordering != nil { Divider() }
                    TopicMembershipMenu(store: store, source: .session(window))
                }
            }
    }

    @ViewBuilder
    private var line: some View {
        let label = HStack(spacing: 6) {
            Text(session.baseName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8).padding(.trailing, 6).padding(.top, 4).padding(.bottom, 1)
        .contentShape(Rectangle())
        if let ordering {
            let id = session.id.session
            label.longPressDrag(id, drag: ordering.drag, isEnabled: !store.changingTopic, onTap: go) { drop in
                if let placement = drop.sessionPlacement { store.moveSession(id, to: placement) }
            }
        } else {
            label.onTapGesture(perform: go)
        }
    }

    @ViewBuilder
    private var orderButtons: some View {
        if let ordering, case .topic(let topicID) = topic.id {
            let id = session.id.session
            Button("Move Up") { if let above = ordering.above.flatMap(SessionID.init) { store.moveSession(id, to: .before(above)) } }
                .disabled(ordering.above == nil || store.changingTopic)
            Button("Move Down") { if let below = ordering.below.flatMap(SessionID.init) { store.moveSession(id, to: .after(below)) } }
                .disabled(ordering.below == nil || store.changingTopic)
            if ordering.isManual {
                Button("Sort Sessions by Creation") { store.sortSessionsByCreation(ofTopic: topicID) }
                    .disabled(store.changingTopic)
            }
        }
    }

    private func go() {
        if case .live = session.contents { store.goToSession(session.id.session) }
    }
}

/// A Window or Pane row of a Topic.
private struct TopicItemRow: View {
    let store: WorkspaceStore
    let item: TopicsModel.SessionChildren.Item
    let titles: [String: String]
    let isDimmed: Bool

    var body: some View {
        switch item {
        case .window(let window):
            Button { store.select(window) } label: {
                WindowRow(window: window, content: store.sidebarWindowRow(window), isSelected: window.id == store.selectedWindowID,
                          tabCount: store.tabCount(for: window), isGitViewOpen: store.isGitViewOpen(in: window.id), topicsView: true,
                          usesMainWorkingCopy: TopicsModel.usesMainWorkingCopy(
                              window, record: store.topicWatcher.records.first { $0.id == window.topicID }, sessionPaths: store.sessionPaths))
            }
            .buttonStyle(.plain)
            .opacity(isDimmed ? 0.5 : 1)
            .id("\(window.sessionID):\(window.id):\(window.topicID ?? "")")
            .accessibilityIdentifier("topic-window-\(window.id)")
            .accessibilityValue(window.id == store.selectedWindowID ? "selected" : "")
            .contextMenu { TopicMembershipMenu(store: store, source: .window(window)) }
            .topicMembershipActions(store: store, source: .window(window))
        case .pane(let row):
            PaneRow(store: store, row: row)
                .opacity(isDimmed ? 0.5 : 1)
        }
    }
}

/// A group row: Snoozed or Settled.
private struct GroupHeader: View {
    let icon: String
    let title: String
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold)).frame(width: 10)
                Image(systemName: icon).font(.system(size: 11))
                Text("\(title) (\(count))").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Where a Topic card sits. In the Topics list the card has a Hint, moves by a drag and by Move Up and Move Down, and
/// offers Settle. In the Snoozed or Settled group it has none of these, and closed it shows only its title and wake time.
private enum TopicCardPlace {
    case list(TopicListPlace)
    case group
}

/// What a card in the Topics list needs to move among the cards with its Pin.
private struct TopicListPlace {
    let drag: LongPressDrag<TopicListID>
    /// The Topic and Locked cards with this card's pin, in list order, among which it moves.
    let order: [TopicListID]
    let neighbors: CardNeighbors
    let rename: (String, Bool) -> Void
}

private struct TopicCard: View {
    let store: WorkspaceStore
    let topic: TopicsModel.Row
    let titles: [String: String]
    let holdsSelection: Bool
    let showsAllRows: Bool
    let onShowAllRows: () -> Void
    let place: TopicCardPlace
    @State private var sessionDrag = LongPressDrag<String>(spacing: CardSpacing.block)

    /// The Topic list's scroll view, in which an open card's header sticks to the top.
    static let viewport = "topics-viewport"
    /// The scroll view of the Snoozed and Settled groups.
    static let groupsViewport = "topic-groups-viewport"

    private var list: TopicListPlace? {
        if case .list(let list) = place { return list }
        return nil
    }

    /// A closed card in a group is dimmed, as the group is what the user put aside.
    private var restingOpacity: Double {
        if list == nil, !topic.isExpanded { return 0.5 }
        return topic.hasNoLiveSession ? 0.55 : 1
    }

    var body: some View {
        SidebarCard(isOpen: topic.isExpanded, holdsSelection: holdsSelection, mark: topic.mark,
                    viewport: list == nil ? Self.groupsViewport : Self.viewport, restingOpacity: restingOpacity) {
            header
        } content: {
            if case .settled = topic.kind {
                RememberedSessions(store: store, topic: topic)
            } else {
                sessionList
            }
        }
        .cardCorner { corner.opacity(restingOpacity) }
        .modifier(CardItem(list: list, listID: listID))
    }

    private var sessionList: some View {
        CardList(blocks: topic.sessions.compactMap { session in
                         guard case .live(let children) = session.contents else { return nil }
                         return CardBlock(id: session.id.session, items: children.items)
                     },
                     identifier: topic.id.accessibilityID, selectedWindowID: store.selectedWindowID,
                     showsAll: showsAllRows, onShowAll: onShowAllRows, reservesCorner: true,
                     blockDrag: topic.kind == .open ? sessionDrag : nil, windows: store.windowRowDrag) { block in
                if let session = topic.sessions.first(where: { $0.id.session == block.id }) {
                    SessionHeading(store: store, topic: topic, session: session, ordering: ordering(of: session.id.session))
                }
            } row: { item in
                TopicItemRow(store: store, item: item, titles: titles, isDimmed: topic.kind != .open)
            }
    }

    /// The Topic's own action: Settle in the Topics list, Unsnooze or Reopen… in a group.
    @ViewBuilder
    private var corner: some View {
        if case .topic(let id) = topic.id {
            switch (list, topic.kind) {
            case (.some, _):
                Button("Settle") { store.presentSettleTopic(id) }
                    .topicLink()
                    .disabled(store.changingTopic)
                    .accessibilityIdentifier("settle-topic-" + id)
            case (nil, .snoozed):
                Button("Unsnooze") { store.unsnoozeTopic(id) }
                    .topicLink()
                    .disabled(store.changingTopic)
                    .accessibilityIdentifier("unsnooze-topic-" + id)
            case (nil, .settled):
                Button("Reopen…") { store.showEmptyTopic(id) }
                    .topicLink()
                    .disabled(store.changingTopic)
                    .accessibilityIdentifier("reopen-topic-" + id)
            case (nil, .open):
                EmptyView()
            }
        }
    }

    /// How a Session line moves within this Topic. A Snoozed or Settled Topic's lines do not move.
    private func ordering(of sessionID: String) -> SessionOrdering? {
        guard topic.kind == .open, case .topic(let id) = topic.id else { return nil }
        let order = topic.sessions.map(\.id.session)
        guard let index = order.firstIndex(of: sessionID) else { return nil }
        return SessionOrdering(drag: sessionDrag,
                               above: index > 0 ? order[index - 1] : nil, below: index + 1 < order.count ? order[index + 1] : nil,
                               isManual: store.topicWatcher.records.first { $0.id == id }?.hasManualSessionOrder ?? false)
    }

    private var formatted: SidebarFormats.Text {
        store.sidebarText(.topic, context: store.sidebarFormatContexts.topics[topic.id])
    }

    /// The wake time of a Snoozed Topic, or the outcome or settle date of a Settled one.
    private var groupDetail: String? {
        switch topic.kind {
        case .open: return nil
        case .snoozed(let wake): return wake
        case .settled(let detail): return detail.isEmpty ? nil : detail
        }
    }

    private var wake: String? {
        if case .snoozed(let wake) = topic.kind { return wake }
        return nil
    }

    private var header: some View {
        CardHeader(title: formatted.title, isOpen: topic.isExpanded, mark: topic.mark, isPinned: topic.isPinned,
                   hintTarget: list == nil ? nil : namedTopicID.map { .topic($0) },
                   notes: (topic.isPinned ? ["Pinned"] : []) + (groupDetail.map { [$0] } ?? []) + (topic.idleLabel.map { [$0] } ?? []),
                   summary: list == nil ? "" : formatted.summary, cornerWidth: list == nil ? CardCorner.groupWidth : CardCorner.width,
                   titleNote: list == nil && !topic.isExpanded ? wake : nil, tags: tags) {
            if list != nil || topic.isExpanded {
                if list == nil, let detail = groupDetail {
                    Text(wake.map { $0 == SnoozeDeadline.never.wakeLabel ? "until Unsnooze" : "wakes " + $0 } ?? detail)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let label = topic.idleLabel { Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .modifier(CardHandle(list: list, listID: listID, isEnabled: !store.changingTopic, onTap: press, onDrop: { drop in
            if let listID { store.moveTopic(listID, to: drop.topicPlacement) }
        }))
        .accessibilityAction(.default, press)
        .accessibilityIdentifier(topic.id.accessibilityID)
        .accessibilityActions {
            if let list { listActions(list) } else { groupActions }
        }
        .contextMenu {
            if let list { listMenu(list) } else { groupActions }
        }
        .cardTagsOverlay(tags, onPress: press)
    }

    /// A closed card in a group shows no Tags.
    private var tags: CardTags? { list != nil || topic.isExpanded ? store.cardTags(topic) : nil }

    /// The actions of a card in a group: those of the Snoozed or Settled Topic, and Pin.
    @ViewBuilder
    private var groupActions: some View {
        if case .topic(let id) = topic.id {
            Button("Forget Topic…") { store.presentForgetTopic(id) }.disabled(store.changingTopic)
            if case .snoozed = topic.kind {
                Button("Settle…") { store.presentSettleTopic(id) }.disabled(store.changingTopic)
                Button("Snooze again…") { store.presentSnooze(id) }.disabled(store.changingTopic)
            }
            pinButton(id)
        }
    }

    @ViewBuilder
    private func listActions(_ list: TopicListPlace) -> some View {
        Button("Go to Topic") { store.goToTopic(topic.id) }
        if case .topic(let id) = topic.id {
            Button("Forget Topic…") { store.presentForgetTopic(id) }.disabled(store.changingTopic)
            pinButton(id)
            CardMoveButtons(store: store, id: .topic(id), neighbors: list.neighbors)
            if !store.topicConfig.titleCommandFallbacks.isEmpty {
                Button("Suggest title from Agents") {
                    DispatchQueue.main.async { list.rename(id, true) }
                }
                .disabled(store.changingTopic)
            }
            Button("Rename Topic…") {
                DispatchQueue.main.async { list.rename(id, false) }
            }
            .disabled(store.changingTopic)
            Button("Add a Session…") { store.presentAddSession(toTopic: id) }
                .disabled(store.changingTopic)
            Button(store.topicWatcher.zen == nil ? "Zen…" : "End Zen") { store.toggleZen(keeping: id) }
                .disabled(store.changingTopic)
        }
    }

    @ViewBuilder
    private func listMenu(_ list: TopicListPlace) -> some View {
        Button("Go to Topic") { store.goToTopic(topic.id) }
            .accessibilityIdentifier("go-to-topic")
        if case .topic(let id) = topic.id {
            Divider()
            if topic.isDormant {
                Button("Reopen") { store.reopenTopic(id, .reopen) }
                    .accessibilityIdentifier("reopen-topic-" + id)
                    .disabled(store.changingTopic)
                Button("Start Fresh") { store.reopenTopic(id, .startFresh) }
                    .accessibilityIdentifier("start-fresh-topic-" + id)
                    .disabled(store.changingTopic)
            }
            Button("Snooze…") { store.presentSnooze(id) }
                .accessibilityIdentifier("snooze-topic").disabled(store.changingTopic)
            Button(store.topicWatcher.zen == nil ? "Zen…" : "End Zen") { store.toggleZen(keeping: id) }
                .accessibilityIdentifier("zen-topic").disabled(store.changingTopic)
            Button("Forget Topic…") { store.presentForgetTopic(id) }
                .accessibilityIdentifier("forget-topic").disabled(store.changingTopic)
            Button("Settle Topic…") { store.presentSettleTopic(id) }
                .accessibilityIdentifier("settle-topic")
                .disabled(store.changingTopic)
            Divider()
            if !store.topicConfig.titleCommandFallbacks.isEmpty {
                Button("Suggest title from Agents") { list.rename(id, true) }
                    .accessibilityIdentifier("suggest-topic-title")
                    .disabled(store.changingTopic)
            }
            Button("Rename Topic…") { list.rename(id, false) }
                .accessibilityIdentifier("rename-topic")
                .disabled(store.changingTopic)
            Button("Add a Session…") { store.presentAddSession(toTopic: id) }
                .accessibilityIdentifier("add-topic-sessionPath")
                .disabled(store.changingTopic)
            Divider()
            pinButton(id)
            CardMoveButtons(store: store, id: .topic(id), neighbors: list.neighbors)
        }
    }

    private func pinButton(_ id: String) -> some View {
        Button(topic.isPinned ? "Unpin Topic" : "Pin Topic") { store.pinTopic(id, !topic.isPinned) }
            .accessibilityIdentifier("pin-topic")
            .disabled(store.changingTopic)
    }

    /// A press on the Active Topic's header opens or closes the card; on another Topic's header it goes to that Topic,
    /// whose card then opens as the Active Topic's. A Snoozed Topic stays Snoozed, and a Settled one shows its Reopen choice.
    private func press() {
        guard !holdsSelection else { return toggle() }
        store.updateTopicSelection()
        withAnimation(.easeOut(duration: 0.15)) { store.topicSelection.setTopic(topic.id, open: true) }
        store.goToTopic(topic.id)
    }

    private func toggle() {
        store.updateTopicSelection()
        withAnimation(.easeOut(duration: 0.15)) { store.topicSelection.setTopic(topic.id, open: !topic.isExpanded) }
    }

    private var namedTopicID: String? {
        if case .topic(let id) = topic.id { return id }
        return nil
    }

    private var listID: TopicListID? { topic.id.listID }
}

/// The press on a Topic card's header: in the Topics list a click, or a long press that drags the card; in a group a click.
private struct CardHandle: ViewModifier {
    let list: TopicListPlace?
    let listID: TopicListID?
    let isEnabled: Bool
    let onTap: () -> Void
    let onDrop: (DropPlacement<TopicListID>) -> Void

    func body(content: Content) -> some View {
        if let list, let listID {
            content.longPressDrag(listID, drag: list.drag, isEnabled: isEnabled, onTap: onTap, onDrop: onDrop)
        } else {
            content.onTapGesture(perform: onTap).takesFirstClick()
        }
    }
}

/// A Topic card in the Topics list is an item of the list's drag; a card in a group does not move.
private struct CardItem: ViewModifier {
    let list: TopicListPlace?
    let listID: TopicListID?

    func body(content: Content) -> some View {
        if let list, let listID {
            content.longPressDragItem(listID, drag: list.drag, shown: list.order, cornerRadius: 9)
        } else {
            content
        }
    }
}

/// Move Up and Move Down of a Topic or Locked card: the Sidebar's own order change, which the palette does not show.
private struct CardMoveButtons: View {
    let store: WorkspaceStore
    let id: TopicListID
    let neighbors: CardNeighbors

    var body: some View {
        Button("Move Up") { if let placement = neighbors.placement(.previous) { store.moveTopic(id, to: placement) } }
            .disabled(neighbors.above == nil || store.changingTopic)
        Button("Move Down") { if let placement = neighbors.placement(.next) { store.moveTopic(id, to: placement) } }
            .disabled(neighbors.below == nil || store.changingTopic)
    }
}

/// A Locked Session among the Topic cards (ADR 0018). It has a Topic card's shape and its place in the order, but it
/// is a No Topic Session: its title and Summary come from the Session card Formats, its rows are its Windows with no
/// SessionPath heading, and it offers only what a Session can do.
private struct LockedCard: View {
    let store: WorkspaceStore
    let row: TopicsModel.Row
    let sessionID: String
    let titles: [String: String]
    let holdsSelection: Bool
    let showsAllRows: Bool
    let onShowAllRows: () -> Void
    let drag: LongPressDrag<TopicListID>
    let order: [TopicListID]
    let neighbors: CardNeighbors

    private var id: TopicListID { .lock(sessionID: sessionID) }
    private var window: TmuxWindow? { row.sessions.first?.windows.first }

    private var formatted: SidebarFormats.Text {
        store.sidebarText(.session, context: store.sidebarFormatContexts.sessions[sessionID])
    }

    var body: some View {
        SidebarCard(isOpen: row.isExpanded, holdsSelection: holdsSelection, mark: row.mark, viewport: TopicCard.viewport) {
            header
        } content: {
            CardList(blocks: row.sessions.compactMap { session in
                         guard case .live(let children) = session.contents else { return nil }
                         return CardBlock(id: session.id.session, items: children.items)
                     },
                     identifier: row.id.accessibilityID, selectedWindowID: store.selectedWindowID,
                     showsAll: showsAllRows, onShowAll: onShowAllRows, windows: store.windowRowDrag) { _ in
                EmptyView()
            } row: { item in
                TopicItemRow(store: store, item: item, titles: titles, isDimmed: false)
            }
        }
        .longPressDragItem(id, drag: drag, shown: order, cornerRadius: 9)
    }

    private var header: some View {
        CardHeader(title: formatted.title, isOpen: row.isExpanded, mark: row.mark, isLocked: true, hintTarget: .locked(sessionID),
                   notes: ["Locked"], summary: formatted.summary) {
            if !row.isExpanded, row.sessions.flatMap(\.windows).contains(where: \.hasBell) {
                BellMark()
            }
        }
        .longPressDrag(id, drag: drag, isEnabled: !store.changingTopic, onTap: press) { drop in
            store.moveTopic(id, to: drop.topicPlacement)
        }
        .accessibilityAction(.default, press)
        .accessibilityIdentifier(row.id.accessibilityID)
        .accessibilityActions {
            Button("Go to Session") { store.goToTopic(row.id) }
            actions
        }
        .contextMenu {
            Button("Go to Session") { store.goToTopic(row.id) }
            Divider()
            actions
        }
    }

    /// The Actions of a Locked Session. It is not a Topic, so it has no Settle, Snooze, Pin, Forget or Zen.
    @ViewBuilder
    private var actions: some View {
        Button("Unlock Session") { store.setLock(ofSession: sessionID, false) }
            .disabled(store.changingTopic)
        if let window {
            Button("Rename Session…") { store.palette.begin(.text(.renameSession(window)), text: window.sessionName) }
            Button("Move to Topic…") { store.palette.openMove(window, scope: .session) }
                .disabled(store.changingTopic)
            Button("New Topic from this Session") { store.palette.openMove(window, scope: .session) }
                .disabled(store.changingTopic)
            Button("Kill Session…", role: .destructive) { store.palette.begin(.confirm(PaletteConfirmation(.killSession(window)))) }
        }
        CardMoveButtons(store: store, id: id, neighbors: neighbors)
    }

    /// As on a Topic card: a press on the Active card opens or closes it; on another card it goes there.
    private func press() {
        guard !holdsSelection else {
            store.updateTopicSelection()
            withAnimation(.easeOut(duration: 0.15)) { store.topicSelection.setTopic(row.id, open: !row.isExpanded) }
            return
        }
        store.updateTopicSelection()
        withAnimation(.easeOut(duration: 0.15)) { store.topicSelection.setTopic(row.id, open: true) }
        store.goToTopic(row.id)
    }
}

/// The divider between Sessions and Agents; drag it to move the split.
private struct SectionResizeHandle: View {
    @Binding var fraction: Double
    /// The sidebar's height.
    let total: CGFloat

    /// Neither section gets smaller than this.
    static let minHeight: CGFloat = 90

    @State private var startHeight: CGFloat?

    /// The Agents section's height for `fraction`, keeping both sections usable.
    static func agentsHeight(_ fraction: Double, total: CGFloat) -> CGFloat {
        let high = max(minHeight, total - minHeight)
        return min(max((total * fraction).rounded(), minHeight), high)
    }

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = startHeight ?? Self.agentsHeight(fraction, total: total)
                                if startHeight == nil { startHeight = start }
                                // Dragging up grows Agents.
                                let height = Self.agentsHeight(Double((start - value.translation.height) / total), total: total)
                                fraction = Double(height / total)
                            }
                            .onEnded { _ in startHeight = nil }
                    )
            }
            .zIndex(1)
    }
}

/// The Sessions and their Windows.
private struct SessionsSection: View {
    let store: WorkspaceStore
    @Environment(\.sidebarTypography) private var typography

    /// The cards whose "N more…" the user pressed, by Session ID.
    @State private var showingAllRows: Set<String> = []

    static let viewport = "sessions-viewport"

    var body: some View {
        let model = store.topics
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy, for the same reason as the Topics list.
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.sessions) { session in
                            SessionCard(store: store, model: model, session: session, identifier: "session-\(session.id)",
                                        viewport: Self.viewport,
                                        showsAllRows: showingAllRows.contains(session.id),
                                        onShowAllRows: { showingAllRows.insert(session.id) }) { item in
                                row(item, model: model)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .coordinateSpace(.named(Self.viewport))
                .scrollIndicators(.never)
                .accessibilityIdentifier("sessions-list")
                // The list scrolls to the card that holds the Window.
                .onChange(of: store.selectedWindow?.sessionID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
        .overlay {
            if store.windows.isEmpty {
                Text(store.serverRunning ? "No windows" : "No tmux server")
                    .font(typography.font(for: .title))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: TopicsModel.SessionChildren.Item, model: TopicsModel) -> some View {
        let dimmed = item.window.topicID.map { model.snoozedTopicIDs.contains($0) } == true
        switch item {
        case .window(let window):
            WindowRow(
                window: window,
                content: store.sidebarWindowRow(window),
                isSelected: window.id == store.selectedWindowID,
                tabCount: store.tabCount(for: window),
                isGitViewOpen: store.isGitViewOpen(in: window.id),
                usesMainWorkingCopy: TopicsModel.usesMainWorkingCopy(
                    window, record: store.topicWatcher.records.first { $0.id == window.topicID },
                    sessionPaths: store.sessionPaths)
            )
                .opacity(dimmed ? 0.45 : 1)
                .accessibilityIdentifier("session-window-\(window.id)")
                .accessibilityValue(window.id == store.selectedWindowID ? "selected" : "")
                .contextMenu { menu(for: window) }
        case .pane(let row):
            PaneRow(store: store, row: row)
                .opacity(dimmed ? 0.45 : 1)
        }
    }

    @ViewBuilder
    private func menu(for window: TmuxWindow) -> some View {
        TopicMembershipMenu(store: store, source: .window(window))
        Divider()
        Button("Rename Window…") { rename(window) }
        Button("New Window in \(window.sessionName)") { store.newWindow(beside: window) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(window.path, forType: .string)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: window.path)
        }
        .disabled(store.isRemote)
        Divider()
        Button("Kill Window…", role: .destructive) { confirmKill(window) }
    }

    private func rename(_ window: TmuxWindow) {
        store.palette.begin(.text(.renameWindow(window)), text: window.name)
    }

    private func confirmKill(_ window: TmuxWindow) {
        store.palette.begin(.confirm(PaletteConfirmation(.killWindow(window))))
    }
}

/// A Session card, in Sessions mode and as the opened No Topic Session in Topics mode. Each place gives its own Window and Pane rows.
private struct SessionCard<Row: View>: View {
    let store: WorkspaceStore
    let model: TopicsModel
    let session: SessionGroup
    let identifier: String
    /// The coordinate space of the list's scroll view.
    let viewport: String
    let showsAllRows: Bool
    let onShowAllRows: () -> Void
    @ViewBuilder var row: (TopicsModel.SessionChildren.Item) -> Row

    var body: some View {
        let isOpen = store.openSessionCards.contains(session.name)
        let isSnoozed = session.windows.first?.topicID.map { model.snoozedTopicIDs.contains($0) } ?? false
        let mark = model.sessionMarks[session.id].map(RowMark.agent)
        let isLocked = model.lockedSessionIDs.contains(session.id)
        SidebarCard(isOpen: isOpen, holdsSelection: holdsSelection, mark: mark,
                    viewport: viewport, restingOpacity: isSnoozed ? 0.45 : 1) {
            CardHeader(title: formatted.title, isOpen: isOpen, mark: mark, isLocked: isLocked, hintTarget: .session(session.id),
                       notes: (isSnoozed ? ["snoozed"] : []) + (isLocked ? ["Locked"] : []),
                       summary: formatted.summary) {
                if isSnoozed { Text("snoozed").font(.system(size: 10)).foregroundStyle(.secondary) }
                if !isOpen, session.windows.contains(where: \.hasBell) {
                    BellMark()
                }
            }
            .onTapGesture(perform: press)
            .takesFirstClick()
            .accessibilityAction(.default, press)
            .accessibilityIdentifier(identifier)
            .accessibilityActions {
                Button("Go to Session") { store.goToSession(session.id) }
                lockButton
            }
            .contextMenu {
                Button("Go to Session") { store.goToSession(session.id) }
                if let window = session.windows.first {
                    Divider()
                    TopicMembershipMenu(store: store, source: .session(window))
                }
                lockButton
            }
        } content: {
            CardList(blocks: [CardBlock(id: session.id, items: model.sessionChildren[session.id]?.items ?? [])],
                     identifier: identifier, selectedWindowID: store.selectedWindowID,
                     showsAll: showsAllRows, onShowAll: onShowAllRows, windows: store.windowRowDrag) { _ in
                EmptyView()
            } row: { item in
                row(item)
            }
        }
    }

    private var formatted: SidebarFormats.Text {
        store.sidebarText(.session, context: store.sidebarFormatContexts.sessions[session.id])
    }

    /// Only a No Topic Session of a Local App Window can be Locked.
    @ViewBuilder
    private var lockButton: some View {
        if let locked = store.lockState(ofSession: session.id) {
            Button(locked ? "Unlock Session" : "Lock Session") { store.setLock(ofSession: session.id, !locked) }
                .disabled(store.changingTopic)
        }
    }

    private var holdsSelection: Bool { session.windows.contains { $0.id == store.selectedWindowID } }

    /// As on a Topic card: a press on the card of the selected Window's Session opens or closes it; on another card
    /// it goes to that Session, whose card then opens.
    private func press() {
        guard !holdsSelection else { return toggle() }
        withAnimation(.easeOut(duration: 0.15)) { _ = store.openSessionCards.insert(session.name) }
        store.goToSession(session.id)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) {
            if store.openSessionCards.remove(session.name) == nil { store.openSessionCards.insert(session.name) }
        }
    }
}

struct WindowRow: View {
    @Environment(\.quickSwitchHints) private var hints
    let window: TmuxWindow
    var content: SidebarFormats.WindowRowContent? = nil
    let isSelected: Bool
    let tabCount: Int
    var isGitViewOpen = false
    var topicsView = false
    var usesMainWorkingCopy = false
    @Environment(\.sidebarTypography) private var typography

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if hints.windowSlotReserved { Color.clear.frame(width: 10) }
            if let left = content?.left {
                if !left.isEmpty { customPart(left, side: "left") }
            } else {
                Logo(name: window.logoName)
                    .accessibilityIdentifier("window-left-app-icon-\(window.id)")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content?.text.title ?? window.displayTitle)
                    .font(typography.font(for: .title))
                    .hoverLabelTitle()
                if let summary = content?.text.summary, !summary.isEmpty {
                    Text(summary)
                        .font(typography.font(for: .location))
                        .foregroundStyle(secondaryStyle)
                        .lineLimit(1)
                }
                if usesMainWorkingCopy {
                    Text("Main working copy")
                        .font(typography.font(for: .location))
                        .foregroundStyle(secondaryStyle)
                        .accessibilityIdentifier("main-working-copy-\(window.id)")
                }
            }
            Spacer(minLength: 4)
            if window.hasBell && !topicsView {
                BellMark()
                    .accessibilityIdentifier("window-bell-\(window.id)")
            }
            if isGitViewOpen {
                GitViewIcon(size: 11)
                    .foregroundStyle(secondaryStyle)
                    .help("Git View open")
                    .accessibilityIdentifier("window-git-view-\(window.id)")
            }
            if let right = content?.right {
                if !right.isEmpty { customPart(right, side: "right") }
            } else {
                if tabCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "globe")
                            .font(.system(size: 10, weight: .medium))
                        Text("\(tabCount)")
                            .font(typography.font(for: .badge))
                    }
                    .foregroundStyle(secondaryStyle)
                    .help("\(tabCount) browser tab(s)")
                    .accessibilityIdentifier("window-right-tabs-\(window.id)")
                }
                if topicsView || window.paneCount > 1 {
                    HStack(spacing: 2) {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 10, weight: .medium))
                        Text("\(window.paneCount)")
                            .font(typography.font(for: .badge))
                    }
                    .foregroundStyle(secondaryStyle)
                    .accessibilityIdentifier("window-right-panes-\(window.id)")
                }
            }
        }
        .foregroundStyle(Color.primary)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(background)
                .animation(.easeOut(duration: SelectedRow.fade), value: isSelected)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .hintAnchor(.window(window.id))
        .hoverLabel(detail: "\(window.sessionName):\(window.index) — \(window.abbreviatedPath)")
    }

    private func customPart(_ parts: [SidebarPart], side: String) -> some View {
        HStack(spacing: 0) {
            ForEach(parts.indices, id: \.self) { index in
                switch parts[index] {
                case .text(let text):
                    Text(text)
                        .font(typography.font(for: side == "left" ? .title : .badge))
                        .lineLimit(1)
                        .accessibilityIdentifier("window-\(side)-text-\(window.id)-\(index)")
                case .currentAppIcon:
                    Logo(name: window.logoName)
                        .accessibilityIdentifier("window-\(side)-app-icon-\(window.id)-\(index)")
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 10, weight: .medium))
                        .accessibilityIdentifier("window-\(side)-symbol-\(window.id)-\(index)")
                        .accessibilityLabel(name)
                }
            }
        }
        .foregroundStyle(side == "left" ? Color.primary : secondaryStyle)
    }

    private var secondaryStyle: Color { .secondary }

    private var background: Color {
        if isSelected { return SelectedRow.fill }
        return hovering ? Color.primary.opacity(0.07) : .clear
    }
}

/// How the Sidebar marks the selected Window or Pane row: a soft accent tint that fades in, so moving
/// between Windows does not flash a block of full colour from row to row.
private enum SelectedRow {
    static let fill = Color.accentColor.opacity(0.22)
    static let fade = 0.14
}

/// A terminal bell in a Window. It is not an Agent mark, so it is gray, and no Config changes it.
private struct BellMark: View {
    var body: some View {
        Image(systemName: "bell.fill")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Bell")
    }
}

/// The row of one Pane of a split Window.
private struct PaneRow: View {
    let store: WorkspaceStore
    let row: TopicsModel.PaneRow

    @State private var hovering = false

    /// With no Window row above it, the active Pane row shows where the user is.
    private var isSelected: Bool {
        !row.isUnderWindowRow && row.pane.isActive && row.window.id == store.selectedWindowID
    }

    private var formatted: SidebarFormats.Text {
        store.sidebarText(.pane, context: store.sidebarFormatContexts.panes[row.pane.id])
    }

    private var mark: AgentMark? { store.topics.agentMarks[row.pane.id] }

    var body: some View {
        Button { store.select(row) } label: {
            HStack(spacing: 6) {
                Image(systemName: row.pane.isActive ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .font(.system(size: 10)).frame(width: 14)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(formatted.title).font(.system(size: 12)).hoverLabelTitle()
                    if !formatted.summary.isEmpty {
                        Text(formatted.summary).font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if let mark { AgentMarkView(mark: mark) }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.leading, row.isUnderWindowRow ? 28 : 8).padding(.trailing, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? SelectedRow.fill : hovering ? Color.primary.opacity(0.07) : .clear)
                .animation(.easeOut(duration: SelectedRow.fade), value: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverLabel(detail: row.pane.path.isEmpty ? row.pane.label : Paths.tildify(row.pane.path))
        .accessibilityIdentifier("pane-" + row.pane.id)
        .accessibilityValue([row.pane.isActive ? "active" : nil, mark?.rawValue].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The Agents reporting their Status (ADR 0004), in tmux order.
private struct AgentsSection: View {
    let store: WorkspaceStore
    @Environment(\.sidebarTypography) private var typography

    private var scopeName: String? {
        let scope = store.topics.agentsScope
        if case .window(let id, _) = scope, let window = store.windows.first(where: { $0.id == id }) {
            return store.sidebarWindowRow(window).text.title
        }
        return scope.name
    }

    var body: some View {
        let model = store.topics
        VStack(alignment: .leading, spacing: 0) {
            Text(["Agents", scopeName].compactMap { $0 }.joined(separator: " · "))
                .font(typography.font(for: .section))
                .lineLimit(1)
                .accessibilityIdentifier("agents-header")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 2)
            if model.visibleAgents.isEmpty {
                Text("No agents")
                    .font(typography.font(for: .title))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.visibleAgents) { agent in
                            AgentRow(agent: agent,
                                     text: store.sidebarText(.agent, context: store.sidebarFormatContexts.panes[agent.paneID]),
                                     mark: model.agentMarks[agent.paneID])
                                .onTapGesture { store.select(agent) }
                                .accessibilityIdentifier("agent-" + agent.paneID)
                                .contextMenu {
                                    Button("New Topic from this Pane") { store.presentMovePane(PaneID(rawValue: agent.paneID).map(TopicTarget.pane)) }
                                        .disabled(store.changingTopic)
                                }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct AgentRow: View {
    let agent: Agent
    let text: SidebarFormats.Text
    let mark: AgentMark?

    private var detail: String {
        "\(agent.kind.displayName) — \(agent.status?.rawValue ?? "no status yet")\(agent.unread ? ", unread" : "")"
    }
    @Environment(\.sidebarTypography) private var typography

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Logo(name: agent.kind.rawValue)
            VStack(alignment: .leading, spacing: 1) {
                Text(text.title)
                    .font(typography.font(for: .title))
                    .hoverLabelTitle()
                if !text.summary.isEmpty {
                    Text(text.summary)
                        .font(typography.font(for: .location))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let mark { AgentMarkView(mark: mark) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
        .hoverLabel(detail: detail)
    }
}

/// A program's logo from `Resources/Logos` (`<name>.svg` or `<name>.png`),
/// or the terminal logo when there is none. On a dark theme `<name>.dark.svg`
/// wins when there is one; black-only logos without one are drawn in the text
/// color so they stay visible.
struct Logo: View {
    let name: String
    var size: CGFloat = 14

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = (colorScheme == .dark ? Self.image(name + ".dark") : nil) ?? Self.image(name) ?? Self.image("terminal") {
                Image(nsImage: image)
                    .renderingMode(Self.monochrome.contains(name) ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 11 / 14))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
    }

    private static let monochrome: Set<String> = ["pi"]
    /// Looked up once per name; nil when the bundle has no logo for it.
    private static var cache: [String: NSImage?] = [:]

    private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let url = name.isEmpty ? nil : ["svg", "png"].lazy
            .compactMap { Bundle.main.url(forResource: name, withExtension: $0) }.first
        let image = url.flatMap(NSImage.init(contentsOf:))
        cache[name] = image
        return image
    }
}
