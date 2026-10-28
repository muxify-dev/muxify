import MuxifyCore

extension TopicsModel {
    /// The cards that are not Pinned, in list order, split after the first `inPlay`: the In Play cards and the Bench.
    /// It does not follow the Sidebar mode, so the In Play Actions work in Sessions mode too.
    func split(inPlay: Int) -> (inPlay: [Row], bench: [Row]) {
        let cards = rows.filter { !$0.isPinned }
        return (Array(cards.prefix(inPlay)), Array(cards.dropFirst(inPlay)))
    }
}

/// Choose In Play after its check step: one choose-a-row step for each checked card, from the first place. The places
/// after the `places` In Play places are the top of the Bench.
struct OrderDraft: Equatable {
    /// The checked cards, in list order.
    let cards: [TopicGroupID]
    /// The In Play places.
    let places: Int
    /// The card chosen for each place so far.
    var placed: [TopicGroupID] = []

    /// The rows of the next place: the cards not placed yet, in list order, so ↩ on each place keeps the order.
    var remaining: [TopicGroupID] { cards.filter { !placed.contains($0) } }

    var place: Int { placed.count + 1 }

    var placeIsOnBench: Bool { place > places }

    /// The order to write once no choice is left: one card remains, and it fills the last place.
    var chosen: [TopicGroupID]? { remaining.count <= 1 ? placed + remaining : nil }

    func placing(_ card: TopicGroupID) -> OrderDraft {
        var next = self
        next.placed.append(card)
        return next
    }
}

extension CommandPalette {
    /// Opens the step of the next place, or writes the order when no choice is left. Each place keeps the one before it
    /// in the history, so ⌫ in the empty field goes back one place, and from the first place to the checks.
    func order(_ draft: OrderDraft) {
        guard let store else { return }
        if let chosen = draft.chosen { store.chooseInPlay(chosen) } else { begin(.order(draft), keepingHistory: true) }
    }

    /// Whether the place is on the Bench, and the cards placed so far, by place.
    func orderNote(_ draft: OrderDraft) -> String {
        let placed = draft.placed.enumerated().map { "\($0.offset + 1) \(cardTitle($0.element))" }
        var parts = draft.placeIsOnBench ? ["Place \(draft.place) is on the Bench."] : []
        parts += placed.isEmpty ? ["↩ on each place keeps the list order."] : ["Placed: " + placed.joined(separator: ", "), "⌫ goes back one place"]
        return parts.joined(separator: " · ")
    }

    func orderRows(_ draft: OrderDraft) -> PickList<PaletteItem> {
        guard let store else { return .empty }
        let candidates = draft.remaining.compactMap { id in store.topics.rows.first { $0.id == id } }.map { cardCandidate($0, choice: .card($0.id), prefix: "place-") }
        return FuzzyRanker.list([PickSectionInput(id: "place", title: "Place \(draft.place)", rule: .ranked(showsWhenEmpty: true),
                                                  candidates: candidates)], query: FuzzyQuery(query), rules: PickRules())
    }

    /// A row for a card of the Topics list: a Topic, or a Locked Session. A query such as `#work` narrows by Tag. A step
    /// that follows another one with the same cards gives its rows a `prefix`: SwiftUI keeps the accessibility action of
    /// a row with the same id, so a press there would still check the card.
    func cardCandidate(_ row: TopicsModel.Row, choice: PaletteChoice, prefix: String = "") -> PickCandidate<PaletteItem> {
        let kind: RowKind = if case .locked = row.id { .session } else { .topic }
        return PickCandidate(id: prefix + row.id.accessibilityID, kind: kind, title: row.title,
                             fields: (row.idleLabel.map { [.detail($0)] } ?? []) + row.sessions.map { .label($0.baseName) }
                                + SearchField.tags(row.tags),
                             trailing: store?.topics.activeTopic == row.id ? "Active" : "", mark: row.mark,
                             pick: .available(PaletteItem(ref: .choice(choice))))
    }

    /// The title of a card of the Topics list.
    func cardTitle(_ id: TopicGroupID) -> String {
        store?.topics.rows.first { $0.id == id }?.title ?? "Untitled Topic"
    }

    /// Replace from Bench: one row for each Benched card.
    func benchRows() -> PickList<PaletteItem> {
        guard let store, let inPlay = store.topicConfig.inPlay else { return .empty }
        let candidates = store.topics.split(inPlay: inPlay).bench.map { cardCandidate($0, choice: .card($0.id)) }
        return FuzzyRanker.list([PickSectionInput(id: "bench", title: "Bench", rule: .ranked(showsWhenEmpty: true), candidates: candidates)],
                                query: FuzzyQuery(query), rules: PickRules())
    }
}
