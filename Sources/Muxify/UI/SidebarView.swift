import AppKit
import SwiftUI
import MuxifyCore

/// Two sections stacked vertically: Topics or Sessions on top, Agents below. Each can be
/// hidden from the View menu; with both shown, a divider between them sets
/// their split. With neither, the sidebar stays open but empty.
struct SidebarView: View {
    let store: WorkspaceStore
    /// `ui.sidebar.font_family`. The size of Sidebar text comes from the Interface font size.
    var fontFamily = "system"
    @Environment(\.interfaceFontSize) private var fontSize

    /// The share of the sidebar's height the Agents section gets.
    @AppStorage("sidebarAgentsFraction") private var agentsFraction: Double = 0.35
    @State private var swipeArea = SidebarSwipeArea()

    var body: some View {
        // A swipe anywhere in the Sidebar switches Topics and Sessions, also over Agents.
        content.sidebarSwipeArea(swipeArea)
            .environment(\.sidebarTypography, SidebarTypography(fontSize: fontSize, fontFamily: fontFamily))
            .environment(\.wrapsCardTitles, store.config.sidebar.wrapsTitles)
    }

    @ViewBuilder
    private var content: some View {
        GeometryReader { proxy in
            let total = proxy.size.height
            let leastHeight = SectionResizeHandle.minHeight(fontSize)
            // Keep WorkSection's identity when the two modes have different Show Agents choices, so a swipe
            // can finish and both lists keep their scroll positions as the Agents section appears or disappears.
            VStack(spacing: 0) {
                if store.sessionsVisible {
                    WorkSection(store: store)
                        .frame(maxHeight: .infinity)
                }
                if store.sessionsVisible && store.agentsVisible {
                    SectionResizeHandle(fraction: $agentsFraction, total: total)
                }
                if store.agentsVisible {
                    AgentsSection(store: store)
                        .frame(height: store.sessionsVisible
                               ? SectionResizeHandle.agentsHeight(agentsFraction, total: total, minHeight: leastHeight) : total)
                }
                if !store.sessionsVisible && !store.agentsVisible {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: store.selectedWindowID, initial: true) { _, _ in store.updateTopicSelection() }
        .onChange(of: store.topics.activeTopic) { _, _ in store.updateTopicSelection() }
        .onChange(of: store.topics.activeTopicGroup) { _, _ in store.updateTopicSelection() }
        // Moving to another Session (click, tmux navigation, new Window) opens its card; `session_cards: one`
        // closes the others. The first call, as the Sidebar appears, is no move: it only opens the Location's card.
        .onChange(of: store.selectedWindow?.sessionName, initial: true) { previous, name in
            let moved = previous != name
            let cards = SessionCardSelection.open(store.openSessionCards, from: moved ? previous : nil, to: name,
                                                  rule: moved ? store.config.sidebar.sessionCards : .any)
            guard cards != store.openSessionCards else { return }
            withAnimation(SwitchPace.animates ? .easeOut(duration: 0.15) : nil) { store.openSessionCards = cards }
        }
    }
}

private struct WorkSection: View {
    let store: WorkspaceStore

    var body: some View {
        let model = store.topics
        if model.showsToggle {
            SidebarPager(mode: Binding(get: { model.mode }, set: { store.sidebarMode = $0 }),
                         animateSwitching: store.config.sidebar.animateSwitching,
                         acceptsGestures: !store.palette.isOpen && store.currentGitView?.isOpen != true) {
                TopicsSection(store: store, model: model).animatesSessionCards(store)
            } sessions: {
                SessionsSection(store: store).animatesSessionCards(store)
            }
        } else if model.mode == .topics {
            TopicsSection(store: store, model: model)
        } else if model.sessionsEnabled {
            SessionsSection(store: store)
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Each pager page is its own SwiftUI graph, so the `withAnimation` around a change of the open Session cards in
/// `SidebarView` does not reach it. The page animates that change itself, at the same pace, unless the change came
/// with its own animation.
private struct SessionCardsAnimation: ViewModifier {
    let store: WorkspaceStore

    func body(content: Content) -> some View {
        content.transaction(value: store.openSessionCards) { transaction in
            if transaction.animation == nil, SwitchPace.animates { transaction.animation = .easeOut(duration: 0.15) }
        }
    }
}

extension View {
    fileprivate func animatesSessionCards(_ store: WorkspaceStore) -> some View {
        modifier(SessionCardsAnimation(store: store))
    }
}

private struct TopicsSection: View {
    @Environment(\.sidebarTypography) private var typography
    @Environment(\.interfaceFontSize) private var fontSize
    let store: WorkspaceStore
    let model: TopicsModel
    @State private var drag = ListDrag<TopicListID>(spacing: 6, tradesAcross: [TopicsModel.ListItem.guestsLineID,
                                                                                TopicsModel.ListItem.benchLineID])
    /// The cards whose "N more…" the user pressed.
    @State private var showingAllRows: Set<TopicGroupID> = []
    /// The No Topic Session cards whose "N more…" the user pressed, by Session ID.
    @State private var showingAllSessionRows: Set<String> = []
    @State private var scroll = TopicsListScroll()
    /// The height of the block that sticks at the top while the Bench scrolls: the bottom of its last item.
    @State private var topHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var lastBenchHeight: CGFloat = 0
    /// The top of the Topics list's viewport in the window, where a lifted card's pointer is.
    @State private var viewportTop: CGFloat = 0
    @State private var driver = ScrollDriver()

    /// The coordinate space of the Topics list's content, from the top of its first item.
    static let contentSpace = "topics-content"
    static let contentSpacing: CGFloat = 6
    static let contentInset: CGFloat = 4

    private var geometry: BenchGeometry {
        BenchGeometry(topHeight: topHeight, viewportHeight: viewportHeight, spacing: Self.contentSpacing, inset: Self.contentInset,
                      fontSize: fontSize)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                topicsList
                if !model.groups.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(model.groups) { group in
                            TopicGroupBlock(store: store, model: model, group: group, showingAllRows: $showingAllRows,
                                            cardsLimit: proxy.size.height / 3)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
            }
        }
    }

    private var topicsList: some View {
        #if DEBUG
        BodyCount.tick("TopicsList")
        #endif
        let parts = model.listParts
        let hasBench = parts.bench != nil
        let geometry = geometry
        return ScrollView {
            // Not lazy: a lazy stack is one more accessibility element over all the cards, and a click tool
            // such as Homerow clicks its centre, on whichever card is there.
            VStack(alignment: .leading, spacing: Self.contentSpacing) {
                // One ForEach for both parts, so a card that trades across the line keeps its view.
                ForEach(model.list) { item in
                    listItem(item)
                        .modifier(TopicsListPart(part: part(of: item, in: parts), scroll: scroll, geometry: geometry,
                                                 isRaised: isRaised(item),
                                                 dragShift: drag.shift(of: item.dragSlot, in: model.dragSlots(around: item.id)),
                                                 theme: store.theme,
                                                 blockBottom: $topHeight, lastBenchHeight: $lastBenchHeight))
                }
                if let bench = parts.bench, !bench.isEmpty {
                    Color.clear.frame(height: geometry.tail(afterCardOfHeight: lastBenchHeight)).accessibilityHidden(true)
                }
            }
            .coordinateSpace(.named(Self.contentSpace))
            .background { ScrollDriverView(driver: driver) }
            .onOverhangingBottomEdge(of: TopicCard.viewport, upTo: EdgePill.height(fontSize)) { scroll.listEnd = $0 }
            // An In Play card that crosses a line opens the hidden Bench, so the user sees what it can trade with. When
            // it goes back above the line, the Bench hides again. A drop ends the drag in the phase handler below.
            .onChange(of: drag.isAcross) { _, across in
                if !across {
                    if case .lifted = drag.phase, store.benchPeek == .all { store.benchPeek = nil }
                    return
                }
                guard !store.benchShown, store.benchPeek != .all, let dragged = drag.dragged,
                      model.split?.inPlay.contains(where: { $0.id.listID == dragged }) == true
                else { return }
                store.benchPeek = .all
            }
            // What a drag showed of the hidden Bench folds into the line as soon as the cards no longer need it: at
            // the drop, while a card glides back, or once two traded cards are in their new places.
            .onChange(of: drag.phase) { _, phase in
                switch phase {
                case .lifted, .trading: return
                default: if store.benchPeek != nil { store.benchPeek = nil }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, Self.contentInset)
            // The drag hears the scroll from the action, not from this view's body: a lifted card reads where the
            // area scrolled to when it lands, and nothing reads it while no card is lifted.
            .onGeometryChange(for: CGFloat.self) { hasBench ? -$0.frame(in: .named(TopicCard.viewport)).minY : 0 } action: { offset in
                scroll.offset = offset
                drag.scrollArea(by: geometry.stick(at: offset))
            }
        }
        .coordinateSpace(.named(TopicCard.viewport))
        .scrollIndicators(.never)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { viewportTop = $0 }
        .background {
            EdgeAutoScroller(drag: drag, driver: driver, viewportTop: viewportTop,
                             geometry: parts.bench == nil ? nil : geometry, viewportHeight: viewportHeight)
        }
        .accessibilityIdentifier("topics-list")
        .onChange(of: model.activeTopic) { _, card in
            guard let card, model.isBenched(card), scroll.places[card]?.isOutOfView == true else { return }
            // On the next turn of the main queue, after the layout of the change that is in progress: the card
            // the user leaves can close then, and the block that sticks gets shorter with it.
            DispatchQueue.main.async { reveal(card) }
        }
        .overlay {
            if model.rows.isEmpty && model.openedNoTopicSession == nil && model.groups.isEmpty {
                Text("No Topics").font(typography.font(for: .title)).foregroundStyle(.secondary)
            }
        }
        // An overlay, not a row under the list: a row would change the list's height each time it shows or goes,
        // and at the end of the list that moves every card by the row's height.
        .overlay(alignment: .bottom) {
            MoreBelowPill(model: model, scroll: scroll, hasBench: hasBench, theme: store.theme, reveal: reveal)
        }
        .overlay(alignment: .top) {
            if hasBench {
                MoreAbovePill(model: model, scroll: scroll, geometry: geometry, theme: store.theme, reveal: reveal)
            }
        }
    }

    @ViewBuilder
    private func listItem(_ item: TopicsModel.ListItem) -> some View {
        switch item {
        case .card(let topic):
            listCard(topic, order: model.dragSlots(around: item.id)).tracksEdges(topic.id, in: scroll)
                .modifier(KeepsPlaceWhenBenchShows(isBenchedLocation: topic.id == model.benchedLocation,
                                                   isBenchShown: model.isBenchShown == true, hasCardsAbove: hasCardsAbove(topic.id),
                                                   indicatorHeight: geometry.indicatorHeight, driver: driver))
        case .openPlace(let id, let place):
            OpenPlaceCard(place: place) { store.presentFillOpenPlace(place) }
                .listDragItem(TopicListID.openPlace(id), drag: drag, shown: model.dragSlots(around: item.id), cornerRadius: 9)
        case .guestsLine:
            GuestsLine().listDragFixed(item.id, drag: drag, shown: model.dragSlots(around: item.id))
        case .benchLine(let isBenchShown):
            BenchLine(isBenchShown: isBenchShown) { store.toggleBench() }
                .listDragFixed(item.id, drag: drag, shown: model.dragSlots(around: item.id))
        case .noTopicSession(let opened):
            noTopicCard(opened).listDragFixed(item.id, drag: drag, shown: model.dragSlots(around: item.id))
        }
    }

    private func part(of item: TopicsModel.ListItem, in parts: (top: ArraySlice<TopicsModel.ListItem>,
                                                             bench: ArraySlice<TopicsModel.ListItem>?)) -> TopicsListPart.Part {
        guard let bench = parts.bench else { return .plain }
        if let index = parts.top.firstIndex(where: { $0.id == item.id }) {
            return .top(isFirst: index == parts.top.startIndex, isLast: index == parts.top.index(before: parts.top.endIndex))
        }
        return .bench(isLast: item.id == bench.last?.id)
    }

    /// A card the drag lifts or moves draws above every other card, also above the block that sticks.
    private func isRaised(_ item: TopicsModel.ListItem) -> Bool {
        guard let id = item.cardID?.listID else { return false }
        return drag.dragged == id || drag.tradePath(of: id) != nil
    }

    @ViewBuilder
    private func listCard(_ topic: TopicsModel.Row, order: [StackSlot<TopicListID>]) -> some View {
        let state = store.topicCardState(topic, titles: model.titles, holdsSelection: topic.id == model.activeTopic,
                                         showsAllRows: showingAllRows.contains(topic.id), showsTags: true)
        if case .locked(let sessionID) = topic.id {
            LockedCard(store: store, state: state, sessionID: sessionID,
                       onShowAllRows: { showingAllRows.insert(topic.id) },
                       drag: drag, order: order, steps: model.steps(of: topic.id))
                .equatable()
        } else {
            TopicCard(store: store, state: state,
                      onShowAllRows: { showingAllRows.insert(topic.id) },
                      place: .list(TopicListPlace(drag: drag, order: order, steps: model.steps(of: topic.id),
                                                  rename: renameTopic)))
                .equatable()
        }
    }

    /// Benched cards come before the card in the list: a shown Bench scrolled to the card has them above the area.
    private func hasCardsAbove(_ card: TopicGroupID) -> Bool { model.benchCardIDs.first != card }

    /// Glides the list to the card: a Benched card stands directly under the line, or under the "more above" pill when
    /// the cards before it are then above the area, and any other card at the top of the list.
    private func reveal(_ card: TopicGroupID) {
        guard let top = scroll.tops[card] else { return }
        driver.scroll(to: model.isBenched(card) ? geometry.revealOffset(cardTop: top, hasCardsAbove: hasCardsAbove(card))
                                                : top + Self.contentInset)
    }

    /// The No Topic Session the user opened, as the card Sessions mode shows. No Topic has no group row.
    @ViewBuilder
    private func noTopicCard(_ opened: TopicsModel.Session) -> some View {
        if let session = store.sessions.first(where: { $0.id == opened.id.session }) {
            SessionCard(store: store, state: store.sessionCardState(session, showsAllRows: showingAllSessionRows.contains(session.id)),
                        identifier: "\(TopicGroupID.noTopic.accessibilityID)-session-\(session.id)", viewport: TopicCard.viewport,
                        onShowAllRows: { showingAllSessionRows.insert(session.id) }) { [titles = model.titles] item, state in
                TopicItemRow(store: store, item: item, state: state, titles: titles, isDimmed: false)
            }
            .equatable()
            .tracksEdges(.noTopic, in: scroll)
        }
    }

    private func renameTopic(_ id: String) {
        guard let topic = store.topicWatcher.records.first(where: { $0.id == id }) else { return }
        store.palette.begin(.text(.renameTopic(topic)), text: topic.title ?? "")
    }
}

/// Hands a lifted card's pointer to `driver`, so the Topics list scrolls while the pointer rests at an edge: the edges
/// of the Bench area under the block that sticks, or of the whole list without a Bench line. A view of its own, so only
/// it draws again as the pointer moves.
private struct EdgeAutoScroller: View {
    let drag: ListDrag<TopicListID>
    let driver: ScrollDriver
    let viewportTop: CGFloat
    let geometry: BenchGeometry?
    let viewportHeight: CGFloat

    var body: some View {
        Color.clear.onChange(of: drag.pointer.map { $0 - viewportTop }, initial: true) { _, pointer in
            let geometry = geometry, height = viewportHeight
            driver.autoScroll(pointer: pointer) { offset in geometry?.autoScrollRange(at: offset) ?? 0...height }
        }
    }
}

/// The "N more below" pill: it shows while a card ends below the bottom edge, and then also counts a card whose bottom
/// is in its band, which it covers. It does not show for a card in its band alone, so it cannot show and go in turns.
/// A click on it reveals the first card under it. A view of its own: it reads where the cards stand, which changes as
/// the list scrolls, and the list around it does not.
private struct MoreBelowPill: View {
    let model: TopicsModel
    let scroll: TopicsListScroll
    let hasBench: Bool
    let theme: TerminalTheme?
    let reveal: (TopicGroupID) -> Void

    /// The cards under the pill, in list order.
    private var hidden: [TopicGroupID] {
        let cards = model.list.compactMap(\.cardID)
        guard cards.contains(where: { scroll.places[$0]?.isBelow == true }) else { return [] }
        return cards.filter { scroll.places[$0]?.isOverBottomIndicator == true }
    }

    var body: some View {
        if let first = hidden.first {
            EdgePill(edge: .bottom, count: hidden.count, slide: hasBench ? scroll.benchEnd : scroll.listEnd, theme: theme) {
                reveal(first)
            }
        }
    }
}

/// The "N more above" pill over the top of the Bench area: it shows while a Benched card is above the top edge of the
/// area, and then also counts a card whose top is in its band, which it covers. It does not show for a card in its
/// band alone, so it cannot show and go in turns. A click on it reveals the last card under it. A view of its own, as
/// `MoreBelowPill` is.
private struct MoreAbovePill: View {
    let model: TopicsModel
    let scroll: TopicsListScroll
    let geometry: BenchGeometry
    let theme: TerminalTheme?
    let reveal: (TopicGroupID) -> Void

    /// The Benched cards under the pill, in list order.
    private var hidden: [TopicGroupID] {
        let bench = model.benchCardIDs
        guard bench.contains(where: { scroll.places[$0]?.isAbove == true }) else { return [] }
        return bench.filter { scroll.places[$0]?.isUnderIndicator == true }
    }

    var body: some View {
        if let last = hidden.last {
            EdgePill(edge: .top, count: hidden.count, slide: geometry.stick(at: scroll.offset), theme: theme) {
                reveal(last)
            }
            .padding(.top, geometry.areaTop)
        }
    }
}

/// Where an item of the Topics list stands while the list has a Bench line. An item of the block at the top moves down
/// as far as the list scrolled, so it stays, and it stands on the Sidebar's chrome above the Benched cards, which pass
/// under it. A Benched card's open header sticks under the block. Without a Bench line the item is as it was.
private struct TopicsListPart: ViewModifier {
    enum Part: Equatable {
        case plain
        case top(isFirst: Bool, isLast: Bool)
        case bench(isLast: Bool)

        var isTop: Bool { if case .top = self { true } else { false } }
        var isFirst: Bool { if case .top(true, _) = self { true } else { false } }
        var isLastOfTop: Bool { if case .top(_, true) = self { true } else { false } }
        var isLastBenched: Bool { self == .bench(isLast: true) }
    }

    let part: Part
    let scroll: TopicsListScroll
    let geometry: BenchGeometry
    let isRaised: Bool
    /// How far a drag moves the item from its place, as `ListDrag.shift` gives: for the lifted item, the placeholder.
    let dragShift: CGFloat
    let theme: TerminalTheme?
    @Binding var blockBottom: CGFloat
    @Binding var lastBenchHeight: CGFloat

    func body(content: Content) -> some View {
        #if DEBUG
        BodyCount.tick("TopicsListPart")
        #endif
        let isTop = part.isTop, isFirst = part.isFirst, isLastOfTop = part.isLastOfTop, isLastBenched = part.isLastBenched
        // Only an item of the block reads the scroll, so a scroll of the Bench draws the block again, not the Bench.
        let stick = isTop ? geometry.stick(at: scroll.offset) : 0
        return content
            .environment(\.scrollTopInset, part == .plain || isTop ? 0 : geometry.areaTop)
            .onGeometryChange(for: CGFloat?.self) { isLastBenched ? $0.size.height : nil } action: {
                if let height = $0 { lastBenchHeight = height }
            }
            .onGeometryChange(for: CGFloat?.self) { proxy in
                guard isLastBenched, let visible = proxy.bounds(of: .named(TopicCard.viewport)) else { return nil }
                return min(max(0, proxy.size.height - visible.maxY), EdgePill.height(geometry.fontSize))
            } action: { if let end = $0 { scroll.benchEnd = end } }
            .background {
                if isTop {
                    Color.clear.chrome(theme: theme, material: .sidebar)
                        .padding(.top, isFirst ? -TopicsSection.contentInset : 0).padding(.bottom, -TopicsSection.contentSpacing)
                        .padding(.horizontal, -6)
                        .contentShape(Rectangle())
                        // With its card as the cards slide aside, so it does not cover a card that slides into its place.
                        .offset(y: dragShift)
                }
            }
            .offset(y: isTop ? stick : 0)
            // Outside the offset, so the block's height does not grow as it sticks.
            .onGeometryChange(for: CGFloat?.self) { isLastOfTop ? $0.frame(in: .named(TopicsSection.contentSpace)).maxY : nil } action: {
                if let bottom = $0 { blockBottom = bottom }
            }
            // The stack sees this zIndex, not the drag's inside the item, so it keeps the drag's raise.
            .zIndex(isRaised ? 30 : isTop ? 1 : 0)
    }
}

private extension View {
    /// Keeps the card's place against the edges of the Topics list in `scroll.places`, from the top of the visible part
    /// that `scrollTopInset` gives: under the block for a Benched card.
    func tracksEdges(_ id: TopicGroupID, in scroll: TopicsListScroll) -> some View {
        modifier(EdgeTracker(id: id, scroll: scroll))
    }
}

private struct EdgeTracker: ViewModifier {
    @Environment(\.scrollTopInset) private var scrollTopInset
    @Environment(\.interfaceFontSize) private var fontSize
    let id: TopicGroupID
    let scroll: TopicsListScroll

    func body(content: Content) -> some View {
        content
            .onEdgePlace(of: TopicCard.viewport, visibleTop: scrollTopInset, indicatorHeight: EdgePill.height(fontSize)) {
                if scroll.places[id] != $0 { scroll.places[id] = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TopicsSection.contentSpace)).minY } action: {
                scroll.tops[id] = $0
            }
            .onDisappear {
                scroll.places[id] = nil
                scroll.tops[id] = nil
            }
    }
}

/// Keeps the Location's Benched card where it is on the screen when the Bench shows: the list scrolls by as far as the
/// cards shown before it pushed it down, less the band of the "more above" pill that those cards bring, so the pill
/// does not cover the card. Without a Benched Location nothing scrolls, and the Bench opens at its top.
///
/// The scroll comes from the card's geometry change in the layout that shows the Bench, before that layout is drawn.
/// `scrollTo` from `onChange` cannot do it: the scroll view has the hidden Bench's height until that layout, so it has
/// nowhere to scroll to.
private struct KeepsPlaceWhenBenchShows: ViewModifier {
    let isBenchedLocation: Bool
    let isBenchShown: Bool
    let hasCardsAbove: Bool
    let indicatorHeight: CGFloat
    let driver: ScrollDriver
    @State private var last = Last()

    /// A class, so that the action can keep the last place without drawing the card again.
    final class Last {
        var place: BenchedLocationPlace?
    }

    func body(content: Content) -> some View {
        let isBenchedLocation = isBenchedLocation, isBenchShown = isBenchShown, hasCardsAbove = hasCardsAbove
        return content.onGeometryChange(for: BenchedLocationPlace?.self) { proxy in
            guard isBenchedLocation else { return nil }
            return BenchedLocationPlace(top: proxy.frame(in: .named(TopicCard.viewport)).minY, isBenchShown: isBenchShown,
                                        hasCardsAbove: hasCardsAbove)
        } action: { place in
            defer { last.place = place }
            if let scroll = place?.openingScroll(after: last.place, indicatorHeight: indicatorHeight) { driver.scroll(by: scroll) }
        }
    }
}

private extension View {
    /// The look of a Topic's own action (Settle, Reopen): a link, so the row stays quiet.
    func topicLink() -> some View { modifier(TopicLink()) }
}

private struct TopicLink: ViewModifier {
    @Environment(\.interfaceFontSize) private var fontSize

    func body(content: Content) -> some View {
        content.buttonStyle(.link).font(fontSize.font(11))
    }
}

/// The Sessions a Settled Topic's opened card lists: remembered ones, whose rows are dimmed and do nothing on click.
private struct RememberedSessions: View {
    let store: WorkspaceStore
    let topic: TopicsModel.Row
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        ForEach(topic.sessions) { session in
            if case .remembered(let windows) = session.contents {
                SessionHeading(store: store, topic: topic, session: session)
                ForEach(windows) { window in
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(fontSize.font(11)).frame(width: fontSize(14))
                        Text(window.name).font(fontSize.font(12)).hoverLabelTitle()
                        Spacer(minLength: 4)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24).padding(.trailing, 6).padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .hoverLabel(detail: Paths.tildify(window.directory),
                                onlyWhenCutOff: store.config.sidebar.windowTooltips == .truncated,
                                enabled: store.config.sidebar.windowTooltips != .off)
                    .accessibilityIdentifier("remembered-window-\(window.id)")
                }
            }
        }
        Color.clear.frame(height: fontSize(16))
    }
}

/// What a Session line of an open Topic card needs to move the Session within its Topic.
private struct SessionOrdering {
    /// The drag of the card's Session blocks; the line starts it, and the whole block moves.
    let drag: ListDrag<String>
    /// The Sessions right above and below this one, where Move Up and Move Down put it.
    let above: String?
    let below: String?
    /// The Topic keeps an order the user gave, which Sort Sessions by Creation ends.
    let isManual: Bool
}

/// The heading of one Session inside a Topic: its SessionPath. Pressing it goes to the Session's
/// active Window. In an open Topic card a drag moves the Session, with its rows, within its Topic.
private struct SessionHeading: View {
    let store: WorkspaceStore
    let topic: TopicsModel.Row
    let session: TopicsModel.Session
    var ordering: SessionOrdering? = nil
    @Environment(\.interfaceFontSize) private var fontSize

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
            Text(session.baseName).font(fontSize.font(11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 8).padding(.trailing, 6).padding(.top, 4).padding(.bottom, 1)
        .contentShape(Rectangle())
        if let ordering {
            let id = session.id.session
            label.listDrag(id, drag: ordering.drag, isEnabled: !store.changingTopic, onTap: go) { drop in
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
            Button("Move Up") { store.moveSession(id, to: .up) }
                .disabled(ordering.above == nil || store.changingTopic)
            Button("Move Down") { store.moveSession(id, to: .down) }
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
    /// What the row shows, read by its list: see SidebarCardState.swift.
    let state: SidebarRowState
    let titles: [String: String]
    let isDimmed: Bool

    var body: some View {
        switch item {
        case .window(let window):
            let shown = state.window
            Button { store.select(window) } label: {
                WindowRow(window: window, content: shown?.content, isSelected: shown?.isSelected ?? false,
                          tooltips: shown?.tooltips ?? .always,
                          tabCount: shown?.tabCount ?? 0, isGitViewOpen: shown?.isGitViewOpen ?? false, topicsView: true,
                          usesMainWorkingCopy: shown?.usesMainWorkingCopy ?? false)
            }
            .buttonStyle(.plain)
            .opacity(isDimmed ? 0.5 : 1)
            .id("\(window.sessionID):\(window.id):\(window.topicID ?? "")")
            .accessibilityIdentifier("topic-window-\(window.id)")
            .accessibilityValue(shown?.isSelected == true ? "selected" : "")
            .contextMenu { TopicMembershipMenu(store: store, source: .window(window)) }
            .topicMembershipActions(store: store, source: .window(window))
        case .pane(let row):
            PaneRow(store: store, row: row, state: state.pane)
                .opacity(isDimmed ? 0.5 : 1)
        }
    }
}

/// Where a Topic card sits. In the Topics list the card has a Hint, moves by a drag and by Move Up and Move Down, and
/// offers Settle. In the Settled group it has none of these, and tells how long ago, seen from `now`, it was Settled.
enum TopicCardPlace: Equatable {
    case list(TopicListPlace)
    case group(now: Date)
}

/// What a card in the Topics list needs to move among the cards with its Pin.
struct TopicListPlace: Equatable {
    let drag: ListDrag<TopicListID>
    /// The Topic and Locked cards among which it moves, in list order, and the views between them that slide.
    let order: [StackSlot<TopicListID>]
    let steps: CardSteps
    let rename: (String) -> Void

    /// The same drag and the same neighbours; `rename` only calls the list.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.drag === rhs.drag && lhs.order == rhs.order && lhs.steps == rhs.steps
    }
}

struct TopicCard: View, Equatable {
    let store: WorkspaceStore
    /// What the card shows, which its list reads from the store: see SidebarCardState.swift.
    let state: TopicCardState
    let onShowAllRows: () -> Void
    let place: TopicCardPlace

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.state == rhs.state && lhs.place == rhs.place
    }

    private var topic: TopicsModel.Row { state.topic }
    private var titles: [String: String] { state.titles }
    private var holdsSelection: Bool { state.holdsSelection }
    private var showsAllRows: Bool { state.showsAllRows }
    @State private var sessionDrag = ListDrag<String>(spacing: CardSpacing.block)
    @Environment(\.interfaceFontSize) private var fontSize

    /// The Topic list's scroll view, in which an open card's header sticks to the top.
    static let viewport = "topics-viewport"
    /// The scroll view of the Settled group.
    static let groupsViewport = "topic-groups-viewport"

    private var list: TopicListPlace? {
        if case .list(let list) = place { return list }
        return nil
    }

    /// A closed card in a group is dimmed, as the group is what the user put aside.
    private var restingOpacity: Double {
        if list == nil, !topic.isExpanded { return 0.5 }
        return topic.state == .dormant || topic.state == .empty ? 0.55 : 1
    }

    var body: some View {
        #if DEBUG
        BodyCount.tick("TopicCard")
        #endif
        return SidebarCard(isOpen: topic.isExpanded, holdsSelection: holdsSelection, mark: topic.usesRowMarks ? nil : topic.mark,
                           viewport: list == nil ? Self.groupsViewport : Self.viewport, restingOpacity: restingOpacity,
                           identifier: topic.id.accessibilityID) {
            header
        } content: {
            if case .settled = topic.kind {
                RememberedSessions(store: store, topic: topic)
            } else {
                sessionList
            }
        } menu: {
            if let list { listMenu(list) } else { groupActions }
        }
        .cardCorner { corner.opacity(restingOpacity) }
        .modifier(CardItem(list: list, listID: listID))
    }

    private var sessionList: some View {
        return CardList(blocks: topic.sessions.compactMap { session in
                         guard case .live(let children) = session.contents else { return nil }
                         return CardBlock(id: session.id.session, items: children.items)
                     },
                     identifier: topic.id.accessibilityID, selectedWindowID: state.selectedWindowID,
                     showsAll: showsAllRows, onShowAll: onShowAllRows, reservesCorner: true,
                     agentSpines: topic.agentSpines,
                     blockDrag: topic.kind == .open ? sessionDrag : nil, windows: store.windowRowDrag) { block in
                if let session = topic.sessions.first(where: { $0.id.session == block.id }) {
                    SessionHeading(store: store, topic: topic, session: session, ordering: ordering(of: session.id.session))
                }
            } row: { item in
                TopicItemRow(store: store, item: item, state: state.rows[item.id] ?? store.sidebarRowState(item), titles: titles,
                             isDimmed: topic.kind != .open)
            }
    }

    /// The Topic's own action: Settle in the Topics list, Reopen in a group, which reopens the Topic at once.
    @ViewBuilder
    private var corner: some View {
        if case .topic(let id) = topic.id {
            switch (list, topic.kind) {
            case (.some, _):
                Button("Settle") { store.presentSettleTopic(id) }
                    .topicLink()
                    .disabled(store.changingTopic)
                    .accessibilityIdentifier("settle-topic-" + id)
            case (nil, .settled):
                Button("Reopen") { store.reopenTopic(id, .reopen) }
                    .topicLink()
                    .disabled(store.changingTopic)
                    .accessibilityIdentifier("reopen-topic-" + id)
            case (nil, .open):
                EmptyView()
            }
        }
    }

    /// How a Session line moves within this Topic. A Settled Topic's lines do not move.
    private func ordering(of sessionID: String) -> SessionOrdering? {
        guard topic.kind == .open, case .topic(let id) = topic.id else { return nil }
        let order = topic.sessions.map(\.id.session)
        guard let index = order.firstIndex(of: sessionID) else { return nil }
        return SessionOrdering(drag: sessionDrag,
                               above: index > 0 ? order[index - 1] : nil, below: index + 1 < order.count ? order[index + 1] : nil,
                               isManual: store.topicWatcher.records.first { $0.id == id }?.hasManualSessionOrder ?? false)
    }

    private var formatted: SidebarFormats.Text { state.formatted }

    /// The outcome of a Settled Topic.
    private var groupDetail: String? {
        switch topic.kind {
        case .open: return nil
        case .settled(let outcome, _): return outcome.isEmpty ? nil : outcome
        }
    }

    /// How long ago a card in the Settled group was Settled, such as "Yesterday".
    private var settledAge: CardCornerLabel? {
        guard case .group(let now) = place, case .settled(_, let settledDate?) = topic.kind, case .topic(let id) = topic.id else { return nil }
        return CardCornerLabel(text: SettledAge.label(settled: settledDate, now: now, calendar: .autoupdatingCurrent),
                               accessibilityID: "settled-age-" + id)
    }

    private var header: some View {
        CardHeader(title: formatted.title, isOpen: topic.isExpanded, mark: topic.mark, isPinned: topic.isPinned, isGuest: topic.isGuest,
                   hintTarget: list == nil ? nil : namedTopicID.map { .topic($0) },
                   notes: (topic.isPinned ? ["Pinned"] : []) + (topic.isGuest ? ["Guest"] : []) + (topic.usesRowMarks && topic.isUnread && topic.mark != .unread ? ["unread"] : []) + (groupDetail.map { [$0] } ?? []) + (topic.idleLabel.map { [$0] } ?? []),
                   summary: list == nil ? "" : formatted.summary, cornerWidth: list == nil ? CardCorner.groupWidth(fontSize) : CardCorner.width(fontSize),
                   tags: tags, note: topic.note, cornerLabel: settledAge) {
            if list != nil || topic.isExpanded {
                if list == nil, let detail = groupDetail {
                    Text(detail)
                        .font(fontSize.font(10)).foregroundStyle(.secondary)
                }
                if let label = topic.idleLabel { Text(label).font(fontSize.font(10)).foregroundStyle(.secondary) }
            }
        }
        .overlay(alignment: .leading) {
            if topic.usesRowMarks, topic.isUnread {
                RowMarkSpine(mark: .unread)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .modifier(CardHandle(list: list, listID: listID, isEnabled: !store.changingTopic, onTap: press, onDrop: { drop in
            if let listID { store.moveTopic(listID, to: drop.topicPlacement) }
        }, onTrade: { other in
            if let listID { store.tradeCard(listID, with: other) }
        }))
        .accessibilityAction(.default, press)
        .accessibilityIdentifier(topic.id.accessibilityID)
        .accessibilityActions {
            if let list { listActions(list) } else { groupActions }
        }
        .cardTagsOverlay(tags, onPress: press)
        .cardCornerLabel(settledAge)
    }

    /// A closed card in a group shows no Tags.
    private var tags: CardTags? { state.tags }

    /// The actions of a card in a group: those of the Settled Topic.
    @ViewBuilder
    private var groupActions: some View {
        if case .topic(let id) = topic.id {
            Button("Forget Topic…") { store.presentForgetTopic(id) }.disabled(store.changingTopic)
        }
    }

    @ViewBuilder
    private func listActions(_ list: TopicListPlace) -> some View {
        Button("Go to Topic") { store.goToTopic(topic.id) }
        if case .topic(let id) = topic.id {
            Button("Forget Topic…") { store.presentForgetTopic(id) }.disabled(store.changingTopic)
            pinButton(id)
            guestButton(id)
            CardMoveButtons(store: store, id: .topic(id), steps: list.steps)
            Button("Rename Topic…") {
                DispatchQueue.main.async { list.rename(id) }
            }
            .disabled(store.changingTopic)
            noteButtons(id)
            Button("Add a Session…") { store.presentAddSession(toTopic: id) }
                .disabled(store.changingTopic)
        }
    }

    @ViewBuilder
    private func listMenu(_ list: TopicListPlace) -> some View {
        Button("Go to Topic") { store.goToTopic(topic.id) }
            .accessibilityIdentifier("go-to-topic")
        if case .topic(let id) = topic.id {
            Divider()
            if topic.state == .dormant {
                Button("Reopen") { store.reopenTopic(id, .reopen) }
                    .accessibilityIdentifier("reopen-topic-" + id)
                    .disabled(store.changingTopic)
                Button("Start Fresh") { store.reopenTopic(id, .startFresh) }
                    .accessibilityIdentifier("start-fresh-topic-" + id)
                    .disabled(store.changingTopic)
            }
            Button("Forget Topic…") { store.presentForgetTopic(id) }
                .accessibilityIdentifier("forget-topic").disabled(store.changingTopic)
            Button("Settle Topic…") { store.presentSettleTopic(id) }
                .accessibilityIdentifier("settle-topic")
                .disabled(store.changingTopic)
            Divider()
            Button("Rename Topic…") { list.rename(id) }
                .accessibilityIdentifier("rename-topic")
                .disabled(store.changingTopic)
            noteButtons(id)
            Button("Add a Session…") { store.presentAddSession(toTopic: id) }
                .accessibilityIdentifier("add-topic-sessionPath")
                .disabled(store.changingTopic)
            Divider()
            pinButton(id)
            guestButton(id)
            CardMoveButtons(store: store, id: .topic(id), steps: list.steps)
        }
    }

    @ViewBuilder
    private func noteButtons(_ id: String) -> some View {
        Button("Set Topic Note…") { DispatchQueue.main.async { store.presentSetTopicNote(of: id) } }
            .accessibilityIdentifier("set-topic-note")
            .disabled(store.changingTopic)
        if topic.note != nil {
            Button("Clear Topic Note") { store.setTopicNote(of: id, nil) }
                .accessibilityIdentifier("clear-topic-note")
                .disabled(store.changingTopic)
        }
    }

    private func pinButton(_ id: String) -> some View {
        Button(topic.isPinned ? "Unpin Topic" : "Pin Topic") { store.pinTopic(id, !topic.isPinned) }
            .accessibilityIdentifier("pin-topic")
            .disabled(store.changingTopic)
    }

    /// Make a Guest on a Benched Topic, Bench on an In Play Topic, while the Config sets `topics.in_play`.
    @ViewBuilder
    private func guestButton(_ id: String) -> some View {
        if state.guestState == false {
            Button("Make a Guest") { store.makeGuest(.topic(id)) }
                .accessibilityIdentifier("make-guest")
                .disabled(store.changingTopic)
        }
        if state.canBench {
            Button("Bench") { store.bench(.topic(id)) }
                .accessibilityIdentifier("bench")
                .disabled(store.changingTopic)
        }
    }

    /// A press on the Active Topic's header opens or closes the card; on another Topic's header it goes to that Topic,
    /// whose card then opens as the Active Topic's. A Settled one shows its Reopen choice.
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

/// The press on a Topic card's header: in the Topics list a click, or a drag that moves the card; in a group a click.
private struct CardHandle: ViewModifier {
    let list: TopicListPlace?
    let listID: TopicListID?
    let isEnabled: Bool
    let onTap: () -> Void
    let onDrop: (DropPlacement<TopicListID>) -> Void
    let onTrade: (TopicListID) -> Void

    func body(content: Content) -> some View {
        if let list, let listID {
            content.listDrag(listID, drag: list.drag, isEnabled: isEnabled, onTap: onTap, onDrop: onDrop, onTrade: onTrade)
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
            content.listDragItem(listID, drag: list.drag, shown: list.order, cornerRadius: 9)
        } else {
            content
        }
    }
}

/// Move Up and Move Down of a Topic or Locked card: the Sidebar's own order change, which the palette does not show.
private struct CardMoveButtons: View {
    let store: WorkspaceStore
    let id: TopicListID
    let steps: CardSteps

    var body: some View {
        Button("Move Up") { store.moveCard(id, .up) }
            .disabled(!steps.canMove(.up) || store.changingTopic)
        Button("Move Down") { store.moveCard(id, .down) }
            .disabled(!steps.canMove(.down) || store.changingTopic)
    }
}

/// A Locked Session among the Topic cards (ADR 0018). It has a Topic card's shape and its place in the order, but it
/// is a No Topic Session: its title and Summary come from the Session card Formats, its rows are its Windows with no
/// SessionPath heading, and it offers only what a Session can do.
private struct LockedCard: View, Equatable {
    let store: WorkspaceStore
    /// What the card shows, which its list reads from the store: see SidebarCardState.swift.
    let state: TopicCardState
    let sessionID: String
    let onShowAllRows: () -> Void
    let drag: ListDrag<TopicListID>
    let order: [StackSlot<TopicListID>]
    let steps: CardSteps

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.state == rhs.state && lhs.sessionID == rhs.sessionID && lhs.drag === rhs.drag
            && lhs.order == rhs.order && lhs.steps == rhs.steps
    }

    private var row: TopicsModel.Row { state.topic }
    private var titles: [String: String] { state.titles }
    private var holdsSelection: Bool { state.holdsSelection }
    private var showsAllRows: Bool { state.showsAllRows }

    private var id: TopicListID { .lock(sessionID: sessionID) }
    private var window: TmuxWindow? { row.sessions.first?.windows.first }

    private var formatted: SidebarFormats.Text { state.formatted }

    var body: some View {
        SidebarCard(isOpen: row.isExpanded, holdsSelection: holdsSelection, mark: row.mark, viewport: TopicCard.viewport,
                    identifier: row.id.accessibilityID) {
            header
        } content: {
            CardList(blocks: row.sessions.compactMap { session in
                         guard case .live(let children) = session.contents else { return nil }
                         return CardBlock(id: session.id.session, items: children.items)
                     },
                     identifier: row.id.accessibilityID, selectedWindowID: state.selectedWindowID,
                     showsAll: showsAllRows, onShowAll: onShowAllRows, windows: store.windowRowDrag) { _ in
                EmptyView()
            } row: { item in
                TopicItemRow(store: store, item: item, state: state.rows[item.id] ?? store.sidebarRowState(item), titles: titles,
                             isDimmed: false)
            }
        } menu: {
            Button("Go to Session") { store.goToTopic(row.id) }
            Divider()
            actions
        }
        .listDragItem(id, drag: drag, shown: order, cornerRadius: 9)
    }

    private var header: some View {
        CardHeader(title: formatted.title, isOpen: row.isExpanded, mark: row.mark, isLocked: true, isGuest: row.isGuest,
                   hintTarget: .locked(sessionID), notes: [row.isGuest ? "Guest" : "Locked"], summary: formatted.summary) {
            if !row.isExpanded, row.sessions.flatMap(\.windows).contains(where: \.hasBell) {
                BellMark()
            }
        }
        .listDrag(id, drag: drag, isEnabled: !store.changingTopic, onTap: press) { drop in
            store.moveTopic(id, to: drop.topicPlacement)
        } onTrade: { other in
            store.tradeCard(id, with: other)
        }
        .accessibilityAction(.default, press)
        .accessibilityIdentifier(row.id.accessibilityID)
        .accessibilityActions {
            Button("Go to Session") { store.goToTopic(row.id) }
            actions
        }
    }

    /// The Actions of a Locked Session. It is not a Topic, so it has no Settle, Pin or Forget. With `topics.in_play`
    /// it is a Guest, and its Unlock is Bench.
    @ViewBuilder
    private var actions: some View {
        Button(row.isGuest ? "Bench" : "Unlock Session") {
            if row.isGuest { store.bench(.session(sessionID)) } else { store.setLock(ofSession: sessionID, false) }
        }
            .disabled(store.changingTopic)
        if let window {
            Button("Rename Session…") { store.palette.begin(.text(.renameSession(window)), text: window.sessionName) }
            Button("Move to Topic…") { store.palette.openMove(window, scope: .session) }
                .disabled(store.changingTopic)
            Button("New Topic from this Session") { store.palette.openMove(window, scope: .session) }
                .disabled(store.changingTopic)
            Button("Kill Session…", role: .destructive) { store.palette.begin(.confirm(PaletteConfirmation(.killSession(window)))) }
        }
        CardMoveButtons(store: store, id: id, steps: steps)
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
    @Environment(\.interfaceFontSize) private var fontSize

    /// The least height of each section at 12. It holds rows of text, so it grows with the Interface font size.
    static let designMinHeight: CGFloat = 90

    /// Neither section gets smaller than this.
    static func minHeight(_ size: InterfaceFontSize) -> CGFloat { size(designMinHeight) }

    @State private var startHeight: CGFloat?

    /// The Agents section's height for `fraction`, keeping both sections usable.
    static func agentsHeight(_ fraction: Double, total: CGFloat, minHeight: CGFloat) -> CGFloat {
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
                                let least = Self.minHeight(fontSize)
                                let start = startHeight ?? Self.agentsHeight(fraction, total: total, minHeight: least)
                                if startHeight == nil { startHeight = start }
                                // Dragging up grows Agents.
                                let height = Self.agentsHeight(Double((start - value.translation.height) / total), total: total,
                                                               minHeight: least)
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
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy, for the same reason as the Topics list.
                    VStack(alignment: .leading, spacing: 6) {
                        // Read here, not in each card: see SidebarCardState.swift.
                        let cards = store.sessions.map { store.sessionCardState($0, showsAllRows: showingAllRows.contains($0.id)) }
                        ForEach(cards, id: \.session.id) { card in
                            SessionCard(store: store, state: card, identifier: "session-\(card.session.id)",
                                        viewport: Self.viewport,
                                        onShowAllRows: { showingAllRows.insert(card.session.id) }) { item, state in
                                row(item, state)
                            }
                            .equatable()
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
                    withAnimation(SwitchPace.animates ? .easeOut(duration: 0.15) : nil) { proxy.scrollTo(id) }
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
    private func row(_ item: TopicsModel.SessionChildren.Item, _ state: SidebarRowState) -> some View {
        switch item {
        case .window(let window):
            let shown = state.window
            WindowRow(
                window: window,
                content: shown?.content,
                isSelected: shown?.isSelected ?? false,
                tooltips: shown?.tooltips ?? .always,
                tabCount: shown?.tabCount ?? 0,
                isGitViewOpen: shown?.isGitViewOpen ?? false,
                usesMainWorkingCopy: shown?.usesMainWorkingCopy ?? false
            )
                .accessibilityIdentifier("session-window-\(window.id)")
                .accessibilityValue(shown?.isSelected == true ? "selected" : "")
                .contextMenu { menu(for: window) }
        case .pane(let row):
            PaneRow(store: store, row: row, state: state.pane)
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
/// It shows only `state`, which its list reads from the store, and touches the store only in its actions, so a card whose
/// values stay the same does not update on a switch elsewhere.
private struct SessionCard<Row: View>: View, Equatable {
    let store: WorkspaceStore
    let state: SessionCardState
    let identifier: String
    /// The coordinate space of the list's scroll view.
    let viewport: String
    let onShowAllRows: () -> Void
    @ViewBuilder var row: (TopicsModel.SessionChildren.Item, SidebarRowState) -> Row

    /// The closures only call the store, so the values decide what the card shows.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.state == rhs.state && lhs.identifier == rhs.identifier && lhs.viewport == rhs.viewport
    }

    private var session: SessionGroup { state.session }

    var body: some View {
        let isOpen = state.isOpen
        SidebarCard(isOpen: isOpen, holdsSelection: state.holdsSelection, mark: state.mark,
                    viewport: viewport, identifier: identifier) {
            CardHeader(title: state.formatted.title, isOpen: isOpen, mark: state.mark, isLocked: state.isLocked,
                       isGuest: state.isGuest, hintTarget: .session(session.id),
                       notes: state.isGuest ? ["Guest"] : state.isLocked ? ["Locked"] : [],
                       summary: state.formatted.summary) {
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
        } content: {
            CardList(blocks: [CardBlock(id: session.id, items: state.items)],
                     identifier: identifier, selectedWindowID: state.selectedWindowID,
                     showsAll: state.showsAllRows, onShowAll: onShowAllRows, windows: store.windowRowDrag) { _ in
                EmptyView()
            } row: { item in
                row(item, state.rows[item.id] ?? store.sidebarRowState(item))
            }
        } menu: {
            Button("Go to Session") { store.goToSession(session.id) }
            if let window = session.windows.first {
                Divider()
                TopicMembershipMenu(store: store, source: .session(window))
            }
            lockButton
        }
    }

    /// Only a No Topic Session of a Local App Window can be Locked. With `topics.in_play`, a Lock is a Guest.
    @ViewBuilder
    private var lockButton: some View {
        if let guest = state.guestState {
            Button(guest ? "Bench" : "Make a Guest") {
                if guest { store.bench(.session(session.id)) } else { store.makeGuest(.session(session.id)) }
            }
                .accessibilityIdentifier(guest ? "bench" : "make-guest")
                .disabled(state.changingTopic)
        } else if let locked = state.lockState {
            Button(locked ? "Unlock Session" : "Lock Session") { store.setLock(ofSession: session.id, !locked) }
                .disabled(state.changingTopic)
        }
    }

    /// As on a Topic card: a press on the card of the selected Window's Session opens or closes it; on another card
    /// it goes to that Session, whose card then opens.
    private func press() {
        guard !state.holdsSelection else { return toggle() }
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
    var tooltips = Config.Sidebar.WindowTooltips.always
    let tabCount: Int
    var isGitViewOpen = false
    var topicsView = false
    var usesMainWorkingCopy = false
    @Environment(\.sidebarTypography) private var typography
    @Environment(\.interfaceFontSize) private var fontSize

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if hints.windowSlotReserved { Color.clear.frame(width: fontSize(10)) }
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
                GitViewIcon(size: fontSize(11))
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
                            .font(fontSize.font(10, weight: .medium))
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
                            .font(fontSize.font(10, weight: .medium))
                        Text("\(window.paneCount)")
                            .font(typography.font(for: .badge))
                    }
                    // A Zoomed Pane hides the others, so the badge glows like the Maximized side's toggle.
                    .foregroundStyle(window.isZoomed ? Color.accentColor : secondaryStyle)
                    .padding(.horizontal, 4)
                    .background(
                        Capsule().fill(Color.accentColor.opacity(window.isZoomed ? 0.2 : 0))
                    )
                    .help(window.isZoomed ? "One Pane is Zoomed. The others are hidden." : "")
                    // The row's own identifier and value replace the badge's, so the row label is where a client reads Zoom.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(window.isZoomed ? "\(window.paneCount), Zoomed" : "\(window.paneCount)")
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
        .hoverLabel(detail: "\(window.sessionName):\(window.index) — \(window.abbreviatedPath)",
                    onlyWhenCutOff: tooltips == .truncated, enabled: tooltips != .off)
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
                        .font(fontSize.font(10, weight: .medium))
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
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Image(systemName: "bell.fill")
            .font(fontSize.font(9))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Bell")
    }
}

/// The row of one Pane of a split Window.
private struct PaneRow: View {
    let store: WorkspaceStore
    let row: TopicsModel.PaneRow
    /// What the row shows, read by its list; nil reads it from the store.
    var state: SidebarRowState.Pane? = nil
    @Environment(\.interfaceFontSize) private var fontSize

    @State private var hovering = false

    private var shown: SidebarRowState.Pane { state ?? store.sidebarRowState(.pane(row)).pane! }
    private var isSelected: Bool { shown.isSelected }
    private var formatted: SidebarFormats.Text { shown.formatted }
    private var mark: AgentMark? { shown.mark }

    var body: some View {
        Button { store.select(row) } label: {
            HStack(spacing: 6) {
                ZStack {
                    Color.clear.frame(width: fontSize(10), height: fontSize(10))
                    if let mark { AgentMarkView(mark: mark) }
                }
                .frame(width: fontSize(10), height: fontSize(10))
                Image(systemName: row.pane.isActive ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .font(fontSize.font(10)).frame(width: fontSize(14))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(formatted.title).font(fontSize.font(12)).hoverLabelTitle()
                    if !formatted.summary.isEmpty {
                        Text(formatted.summary).font(fontSize.font(11)).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
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
                                    Button("New Topic from this Pane") { store.presentMovePane(PaneID(rawValue: agent.paneID).map(EnvironmentTarget.pane)) }
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
