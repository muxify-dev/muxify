import MuxifyCore
import SwiftUI

/// The Settled group at the bottom of the Topics panel, as a block of its own. Its row stays in view and
/// only its cards scroll, so the user can always close the open group.
struct TopicGroupBlock: View {
    let store: WorkspaceStore
    let model: TopicsModel
    let group: TopicsModel.Group
    @Binding var showingAllRows: Set<TopicGroupID>
    /// The most height the open group's cards take before they scroll.
    let cardsLimit: CGFloat
    @State private var cardsHeight: CGFloat = 0
    @Environment(\.interfaceFontSize) private var fontSize
    private static let forgetSettled = PaletteCommand.forgetSettledOlderThan.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(icon: TopicGroupMetrics.symbol(group.kind), title: TopicGroupMetrics.Header.title(group.kind, count: group.count),
                        isExpanded: group.isExpanded) {
                store.topicGroups.toggle(group.kind)
            }
            .accessibilityIdentifier(group.kind.accessibilityID)
            .accessibilityValue(group.isExpanded ? "expanded" : "collapsed")
            .contextMenu {
                Button(Self.forgetSettled) { store.presentForgetSettled() }.disabled(store.changingTopic || store.isRemote)
            }
            // The context menu's item, for an e2e check that must not open the menu.
            .accessibilityAction(named: Self.forgetSettled) { store.presentForgetSettled() }
            if group.isExpanded {
                Divider()
                ScrollView {
                    cards.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
                }
                .coordinateSpace(.named(TopicCard.groupsViewport))
                .scrollIndicators(.never)
                .frame(height: min(cardsHeight, cardsLimit))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TopicGroupMetrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: TopicGroupMetrics.cornerRadius)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: TopicGroupMetrics.borderWidth))
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: TopicGroupMetrics.cardSpacing) {
            TimelineView(EachMidnight()) { context in
                VStack(alignment: .leading, spacing: TopicGroupMetrics.cardSpacing) {
                    ForEach(group.topics) { topic in
                        TopicCard(store: store, topic: topic, titles: model.titles, holdsSelection: topic.id == model.activeTopic,
                                  showsAllRows: showingAllRows.contains(topic.id),
                                  onShowAllRows: { showingAllRows.insert(topic.id) }, place: .group(now: context.date))
                    }
                }
            }
            if group.hiddenCount > 0 {
                Button(TopicGroupMetrics.ShowMore.text(hiddenCount: group.hiddenCount)) { store.topicGroups.showMoreSettled() }
                    .buttonStyle(.plain).font(fontSize.font(TopicGroupMetrics.ShowMore.fontSize)).foregroundStyle(.secondary)
                    .padding(.leading, TopicGroupMetrics.ShowMore.leading).frame(height: fontSize(TopicGroupMetrics.ShowMore.designHeight))
                    .accessibilityIdentifier(TopicGroupMetrics.ShowMore.identifier)
            }
        }
        .padding(TopicGroupMetrics.cardsPadding)
    }
}

/// Now, then each midnight after it, as `SettledAge.nextMidnight` finds it, which the AppKit group waits for too. A
/// Settled card's age counts days, so the cards draw again only when the day changes; an entry's date is always on the
/// current day, which is all `SettledAge` reads from it.
private struct EachMidnight: TimelineSchedule {
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        let calendar = Calendar.autoupdatingCurrent
        return sequence(first: startDate) { SettledAge.nextMidnight(after: $0, calendar: calendar) }
    }
}

/// A group row: Settled.
private struct GroupHeader: View {
    let icon: String
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: TopicGroupMetrics.Header.spacing) {
                Image(systemName: TopicGroupMetrics.Header.chevron(isExpanded: isExpanded))
                    .font(fontSize.font(TopicGroupMetrics.Header.chevronFontSize, weight: .bold))
                    .frame(width: fontSize(TopicGroupMetrics.Header.designChevronWidth))
                Image(systemName: icon).font(fontSize.font(TopicGroupMetrics.Header.symbolFontSize))
                Text(title).font(fontSize.font(TopicGroupMetrics.Header.fontSize, weight: .semibold)).lineLimit(1)
                Spacer(minLength: TopicGroupMetrics.Header.endGap)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, TopicGroupMetrics.Header.horizontalPadding).frame(height: fontSize(TopicGroupMetrics.Header.designHeight))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
