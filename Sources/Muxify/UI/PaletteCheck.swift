import MuxifyCore

/// What a check step does with the cards that go on from it. Each Action that starts with a check step is a case, and
/// the compiler finds every place that must answer for it.
enum CheckAction: Equatable {
    /// Choose In Play: the cards that are not Pinned, with the In Play ones checked first. Going on orders every checked
    /// card: the first `places` fill the In Play places, and the others go to the top of the Bench.
    case chooseInPlay(places: Int)

    var title: String {
        switch self {
        case .chooseInPlay: "Choose In Play"
        }
    }

    /// The cards that the step lists, in list order.
    func listed(_ topics: TopicsModel) -> [TopicsModel.Row] {
        switch self {
        case .chooseInPlay: topics.rows.filter { !$0.isPinned }
        }
    }

    /// What going on with `count` cards does, for the note line.
    func outcome(_ count: Int) -> String {
        switch self {
        case .chooseInPlay(let places):
            return "\(count) checked for \(places) In Play \(places == 1 ? "place" : "places")."
                + (count > places ? " The last \(count - places) go to the top of the Bench." : "")
        }
    }

    /// Runs the Action on the cards that go on, in list order.
    @MainActor func goOn(with ids: [TopicGroupID], in palette: CommandPalette) {
        switch self {
        case .chooseInPlay(let places): palette.order(OrderDraft(cards: ids, places: places))
        }
    }
}

/// A check step (ADR 0035): the cards that the user checked. The step lists the order, so the set keeps none.
struct CheckDraft: Equatable {
    let action: CheckAction
    var checked: Set<TopicGroupID> = []

    /// Checks every card of `ids`, or unchecks them when all are already checked: ⌘A.
    mutating func flip(_ ids: Set<TopicGroupID>) {
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    /// What ↩ on the row of `id` goes on with: the checked cards on any row, else this row's card.
    func goingOn(from id: TopicGroupID) -> Set<TopicGroupID> { checked.isEmpty ? [id] : checked }
}

extension CommandPalette {
    /// `ids` in list order, without the cards that the step no longer lists.
    func listOrder(_ ids: Set<TopicGroupID>, _ action: CheckAction) -> [TopicGroupID] {
        guard let topics = store?.topics else { return [] }
        return action.listed(topics).map(\.id).filter(ids.contains)
    }

    func checkedIDs(_ draft: CheckDraft) -> [TopicGroupID] { listOrder(draft.checked, draft.action) }

    /// One row for each card that the step lists. A row stays in its place when it is checked.
    func checkRows(_ draft: CheckDraft) -> PickList<PaletteItem> {
        guard let topics = store?.topics else { return .empty }
        let candidates = draft.action.listed(topics).map { cardCandidate($0, choice: .check($0.id)) }
        return FuzzyRanker.list([PickSectionInput(id: "topics", title: "Topics", rule: .ranked(showsWhenEmpty: true),
                                                  candidates: candidates)], query: FuzzyQuery(query), rules: PickRules())
    }

    private func checkRow(of row: PickRow<PaletteItem>?) -> TopicGroupID? {
        guard case .choice(.check(let id))? = row?.pick.payload?.ref else { return nil }
        return id
    }

    /// Whether the row's box is checked; nil outside a check step.
    func rowCheck(_ row: PickRow<PaletteItem>) -> Bool? {
        guard case .check(let draft)? = flow, let id = checkRow(of: row) else { return nil }
        return checkedIDs(draft).contains(id)
    }

    /// How many cards are checked and what going on does with them, the checked cards that the filter hides, and what
    /// ↩ does now.
    func checkNote(_ draft: CheckDraft) -> String? {
        let ids = checkedIDs(draft)
        let list = results
        var parts = [draft.action.outcome(ids.count)]
        let shown = Set(list.rows.compactMap(checkRow(of:)))
        let hidden = ids.filter { !shown.contains($0) }.count
        if hidden > 0 { parts.append("\(hidden) checked \(hidden == 1 ? "is" : "are") not shown") }
        if let id = checkRow(of: selected(in: list)) {
            let ordered = listOrder(draft.goingOn(from: id), draft.action)
            parts.append("↩ goes on with " + (ordered.count == 1 ? cardTitle(ordered[0]) : "\(ordered.count) cards"))
        }
        return parts.joined(separator: " · ")
    }

    /// Changes the checks and keeps the highlighted row.
    private func updateCheck(_ draft: CheckDraft, highlighting id: String?) {
        replaceFlow(.check(draft))
        selectedID = id
    }

    /// Space, ⇥ or a click on a row checks or unchecks its card.
    func check(_ id: TopicGroupID, highlighting rowID: String?) {
        guard case .check(var draft) = flow else { return }
        draft.checked = Set(checkedIDs(draft))
        draft.flip([id])
        updateCheck(draft, highlighting: rowID)
    }

    func checkSelected() {
        let row = selected(in: results)
        guard let id = checkRow(of: row) else { return }
        check(id, highlighting: row?.id)
    }

    /// ⌘A: checks every row that the filter shows, or unchecks them when all are checked.
    func checkShown() {
        guard case .check(var draft) = flow else { return }
        draft.checked = Set(checkedIDs(draft))
        draft.flip(Set(results.rows.compactMap(checkRow(of:))))
        updateCheck(draft, highlighting: selectedID)
    }

    /// ↩ on a row of a check step.
    func returnOnCheck(_ id: TopicGroupID) {
        guard case .check(let draft) = flow else { return }
        draft.action.goOn(with: listOrder(draft.goingOn(from: id), draft.action), in: self)
    }
}
