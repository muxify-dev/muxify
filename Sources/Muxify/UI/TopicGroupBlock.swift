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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupHeader(icon: "checkmark.circle", title: group.kind.title,
                        count: group.count, isExpanded: group.isExpanded) {
                store.topicGroups.toggle(group.kind)
            }
            .accessibilityIdentifier(group.kind.accessibilityID)
            .accessibilityValue(group.isExpanded ? "expanded" : "collapsed")
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
            ForEach(group.topics) { topic in
                TopicCard(store: store, topic: topic, titles: model.titles, holdsSelection: topic.id == model.activeTopic,
                          showsAllRows: showingAllRows.contains(topic.id),
                          onShowAllRows: { showingAllRows.insert(topic.id) }, place: .group)
            }
            if group.hiddenCount > 0 {
                Button("Show \(min(group.hiddenCount, TopicGroupsState.pageSize)) more") { store.topicGroups.showMoreSettled() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.leading, 24).frame(height: 24)
                    .accessibilityIdentifier("settled-show-more")
            }
        }
        .padding(6)
    }
}

/// A group row: Settled.
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
