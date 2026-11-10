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
            GroupHeader(icon: "checkmark.circle", title: group.kind.title,
                        count: group.count, isExpanded: group.isExpanded) {
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 6) {
            TimelineView(EachMidnight()) { context in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.topics) { topic in
                        TopicCard(store: store,
                                  state: store.topicCardState(topic, titles: model.titles, holdsSelection: topic.id == model.activeTopic,
                                                              showsAllRows: showingAllRows.contains(topic.id),
                                                              showsTags: topic.isExpanded),
                                  onShowAllRows: { showingAllRows.insert(topic.id) }, place: .group(now: context.date))
                            .equatable()
                    }
                }
            }
            if group.hiddenCount > 0 {
                Button("Show \(min(group.hiddenCount, TopicGroupsState.pageSize)) more") { store.topicGroups.showMoreSettled() }
                    .buttonStyle(.plain).font(fontSize.font(12)).foregroundStyle(.secondary)
                    .padding(.leading, 24).frame(height: fontSize(24))
                    .accessibilityIdentifier("settled-show-more")
            }
        }
        .padding(6)
    }
}

/// Now, then each midnight after it. A Settled card's age counts days, so the cards draw again only when the day
/// changes; an entry's date is always on the current day, which is all `SettledAge` reads from it.
private struct EachMidnight: TimelineSchedule {
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        let calendar = Calendar.autoupdatingCurrent
        return sequence(first: startDate) {
            calendar.nextDate(after: $0, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
        }
    }
}

/// A group row: Settled.
private struct GroupHeader: View {
    let icon: String
    let title: String
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(fontSize.font(10, weight: .bold)).frame(width: fontSize(10))
                Image(systemName: icon).font(fontSize.font(11))
                Text("\(title) (\(count))").font(fontSize.font(13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: fontSize(26))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
