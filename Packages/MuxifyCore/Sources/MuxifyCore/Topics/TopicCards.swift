import Foundation

/// The cards of the Board, as the Sidebar shows them now. Move Topic Up and Down step among these, so the CLI and
/// the Sidebar cannot disagree about a card's neighbor (ADR 0039).
public enum TopicCards {
    public enum Step: Equatable, Sendable { case up, down }

    /// What one step does, one case for each effect.
    public enum Outcome: Equatable, Sendable {
        /// The card goes before or after a neighbor in its own section, or among the cards with its Pin.
        case reorder(TopicPlacement)
        /// Down from the last place: the card becomes the top Guest and leaves an Open Place.
        case toGuests
        /// Up from the top Guest: the card fills the lowest Open Place.
        case fill(openPlace: String)
        /// Up from the top Guest, with every place full: the card trades with the card in the last place.
        case trade(BoardCardID)
        /// Up from the top Guest, with room in the places and no Open Place: the card takes the next place.
        case takePlace
        /// Down from the last Guest: a Topic goes to the top of the Bench, and a Board Session leaves the Board.
        case bench
        /// Up from a Benched card that has no card above it to reorder with: it becomes the last Guest. Up from the
        /// No Topic Session that has no card makes it a Board Session at the end of the Guests, which is the same.
        case makeGuest
        /// The card is first (`up`) or last (`down`) in its section, or among the cards with its Pin.
        case atEnd
        /// The list has no such card.
        case hidden
    }

    /// The open Topics, the Board Sessions, live or Dormant, and the Open Places, in list order: Pinned first.
    public static func order(records: [TopicRecord], boardSessions: [BoardSession] = [], openPlaces: [OpenPlace] = []) -> [BoardCard] {
        TopicOrder.sorted(BoardCard.all(records: records, boardSessions: boardSessions, openPlaces: openPlaces))
    }

    /// What one step does to the card. A card that is not Pinned moves inside its section of the cut
    /// (`InPlayCut`), and a step past the end of a section goes into the next one. A hidden Bench has no card to reorder
    /// with below its top, so Up from any Benched card makes a Guest.
    public static func step(_ id: BoardCardID, _ step: Step, in cards: [BoardCard], inPlay: Int,
                            benchShown: Bool = true) -> Outcome {
        guard let card = cards.first(where: { $0.id == id }) else { return .hidden }
        guard !card.isPinned else { return neighbor(of: id, step, in: cards.filter { $0.isPinned == card.isPinned }) }
        if case .openPlace = card { return .hidden }
        let cut = TopicOrder.cut(cards, inPlay: inPlay)
        if cut.places.contains(where: { $0.id == id }) {
            let outcome = neighbor(of: id, step, in: cut.places)
            return outcome == .atEnd && step == .down ? .toGuests : outcome
        }
        if cut.guests.contains(where: { $0.id == id }) {
            let outcome = neighbor(of: id, step, in: cut.guests)
            guard outcome == .atEnd else { return outcome }
            return step == .down ? .bench : upFromTopGuest(cut: cut, inPlay: inPlay)
        }
        if cut.bench.contains(where: { $0.id == id }) {
            let outcome = benchShown ? neighbor(of: id, step, in: cut.bench) : .atEnd
            return outcome == .atEnd && step == .up ? .makeGuest : outcome
        }
        return .hidden
    }

    /// What one step does to the No Topic Session that has no card. Only Up does anything: Make a Guest, which makes it a
    /// Board Session.
    public static func stepSessionWithoutCard(_ step: Step) -> Outcome {
        step == .up ? .makeGuest : .hidden
    }

    private static func upFromTopGuest(cut: InPlayCut<BoardCard>, inPlay: Int) -> Outcome {
        if let open = cut.places.last(where: { $0.slot == .openPlace }), case .openPlace(let place) = open { return .fill(openPlace: place.id) }
        if cut.places.count >= inPlay, let last = cut.places.last { return .trade(last.id) }
        return .takePlace
    }

    private static func neighbor(of id: BoardCardID, _ step: Step, in zone: [BoardCard]) -> Outcome {
        guard let index = zone.firstIndex(where: { $0.id == id }) else { return .hidden }
        switch step {
        case .up: return index > 0 ? .reorder(.before(zone[index - 1].id)) : .atEnd
        case .down: return index + 1 < zone.count ? .reorder(.after(zone[index + 1].id)) : .atEnd
        }
    }
}
