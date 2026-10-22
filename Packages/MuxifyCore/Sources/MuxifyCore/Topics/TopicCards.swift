import Foundation

/// The cards of the Topics list, as the Sidebar shows them now. Move Topic Up and Down step among these, so the CLI and
/// the Sidebar cannot disagree about a card's neighbor (ADR 0039).
public enum TopicCards {
    public enum Step: Equatable, Sendable { case up, down }

    public enum Outcome: Equatable, Sendable {
        case to(TopicPlacement)
        /// The card is first (`up`) or last (`down`) among the cards with its Pin.
        case atEnd
        /// The list shows no card for it: a Snoozed Topic, or a Locked Session while Zen is on.
        case hidden
    }

    /// The open Topics that are not Snoozed at `now`, and the Locked Sessions unless Zen is on, in list order: Pinned
    /// first. A Snooze that is due but not woken yet counts as ended, as the Sidebar shows it.
    public static func order(records: [TopicRecord], windows: [TmuxWindow], zen: ZenRecord?, now: Date) -> [TopicListEntry] {
        let locks = zen == nil ? SessionLock.locks(in: windows, records: records) : []
        return TopicOrder.sorted(records.map(TopicListEntry.topic) + locks.map(TopicListEntry.lock)).filter { entry in
            if case .topic(let record) = entry { return !record.isSnoozed(at: now) }
            return true
        }
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
