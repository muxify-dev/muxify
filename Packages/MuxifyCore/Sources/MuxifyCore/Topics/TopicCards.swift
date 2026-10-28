import Foundation

/// The cards of the Topics list, as the Sidebar shows them now. Move Topic Up and Down step among these, so the CLI and
/// the Sidebar cannot disagree about a card's neighbor (ADR 0039).
public enum TopicCards {
    public enum Step: Equatable, Sendable { case up, down }

    public enum Outcome: Equatable, Sendable {
        case to(TopicPlacement)
        /// The card is first (`up`) or last (`down`) among the cards with its Pin.
        case atEnd
        /// The list has no such card.
        case hidden
    }

    /// The open Topics and the Locked Sessions, in list order: Pinned first.
    public static func order(records: [TopicRecord], windows: [TmuxWindow]) -> [TopicListEntry] {
        TopicOrder.sorted(TopicListEntry.all(records: records, windows: windows))
    }

    /// Where one step puts the card: before the card above it, or after the card below it, among the cards with its Pin.
    public static func step(_ id: TopicListID, _ step: Step, in cards: [TopicListEntry]) -> Outcome {
        guard let card = cards.first(where: { $0.id == id }) else { return .hidden }
        let zone = cards.filter { $0.isPinned == card.isPinned }
        guard let index = zone.firstIndex(where: { $0.id == id }) else { return .hidden }
        switch step {
        case .up: return index > 0 ? .to(.before(zone[index - 1].id)) : .atEnd
        case .down: return index + 1 < zone.count ? .to(.after(zone[index + 1].id)) : .atEnd
        }
    }
}
