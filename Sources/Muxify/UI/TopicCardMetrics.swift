import CoreGraphics
import MuxifyCore

// What both versions of a Topic card and a Locked card read (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md):
// the words of a Topic card's header, the opacity a card rests at, and what a press on a card's header does. The sizes
// that every card shares are in CardMetrics.swift.

/// The words of a Topic card's header, for both versions of the card.
enum TopicCardWords {
    /// The words of the header's accessibility value after the open state: Pinned, Guest, unread while the card's rows
    /// show the Agent marks in its place, the outcome of a Settled Topic, and Dormant or Empty.
    static func notes(of topic: TopicsModel.Row) -> [String] {
        (topic.isPinned ? ["Pinned"] : []) + (topic.isGuest ? ["Guest"] : [])
            + (topic.usesRowMarks && topic.isUnread && topic.mark != .unread ? ["unread"] : [])
            + (outcome(of: topic).map { [$0] } ?? []) + (topic.idleLabel.map { [$0] } ?? [])
    }

    /// The words of the details line under the title: in the Topics list, Dormant or Empty; in a group, the outcome
    /// first. A closed card in a group shows none.
    static func details(of topic: TopicsModel.Row, inList: Bool) -> [String] {
        guard inList || topic.isExpanded else { return [] }
        return (inList ? [] : outcome(of: topic).map { [$0] } ?? []) + (topic.idleLabel.map { [$0] } ?? [])
    }

    /// The outcome of a Settled Topic. Nil for an open Topic and for none.
    static func outcome(of topic: TopicsModel.Row) -> String? {
        switch topic.kind {
        case .open: return nil
        case .settled(let outcome, _): return outcome.isEmpty ? nil : outcome
        }
    }
}

/// The Session line of an open Topic card, over the rows of its Session, for both versions of the card: the Session's
/// name on one line, in a small bold text of the secondary colour, cut with "…" when it does not fit. The text's size is
/// at 12 and grows with the Interface font size; the room around it does not.
enum SessionLineMetrics {
    static let fontSize: CGFloat = 11
    static let leading: CGFloat = 8
    static let trailing: CGFloat = 6
    static let top: CGFloat = 4
    static let bottom: CGFloat = 1
    /// The room between the name and the space after it.
    static let spacing: CGFloat = 6
    /// The least room of the space after the name.
    static let endGap: CGFloat = 4
}

/// The opacity of what an open Topic card lists while its Topic is not open, as a Settled Topic's: its Session lines
/// fade, and its rows dim. For both versions of the card.
enum TopicCardRowsOpacity {
    static let notOpen = 0.5
}

/// The opacity a Topic card rests at, for both versions of the card.
enum TopicCardOpacity {
    /// A closed card in a group is dimmed, as the group is what the user put aside. A Dormant or Empty Topic's card is
    /// dimmed a little less.
    static func resting(_ topic: TopicsModel.Row, inList: Bool) -> Double {
        if !inList, !topic.isExpanded { return 0.5 }
        return topic.state == .dormant || topic.state == .empty ? 0.55 : 1
    }
}

/// A press on the header of a card of the Topics list, a Topic card or a Locked card, for both versions of the list.
/// On the card that holds the Location it opens or closes the card; on another card it goes to that Topic or Locked
/// Session, whose card then opens. A Dormant Topic is Reopened at once.
@MainActor struct TopicCardPress {
    let store: WorkspaceStore
    let id: TopicGroupID
    /// The card holds the Location: it is the Active Topic's card.
    let holdsSelection: Bool
    let isOpen: Bool

    /// `opening` runs the change that opens or closes a card. The SwiftUI list animates it there; the AppKit list
    /// glides its cards itself.
    func callAsFunction(opening: (() -> Void) -> Void = { $0() }) {
        store.updateTopicSelection()
        guard !holdsSelection else {
            return opening { store.topicSelection.setTopic(id, open: !isOpen) }
        }
        opening { store.topicSelection.setTopic(id, open: true) }
        store.goToTopic(id)
    }
}
