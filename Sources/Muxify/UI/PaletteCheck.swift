import MuxifyCore

/// What a check step does with the Topics that go on from it.
enum CheckAction: Equatable {
    /// Goes on to the "until" step.
    case snooze
    /// Runs at once: one Unsnooze write for the set.
    case unsnooze

    var verb: String {
        switch self {
        case .snooze: "Snooze"
        case .unsnooze: "Unsnooze"
        }
    }

    /// The Topics that the step lists, in list order. Snooze: the Topics list, then the Snoozed Topics. Unsnooze: the
    /// Snoozed Topics. Settled Topics are in neither.
    func listed(_ topics: TopicsModel) -> [TopicsModel.Row] {
        switch self {
        case .snooze: topics.rows + topics.snoozedRows
        case .unsnooze: topics.snoozedRows
        }
    }

    /// The Topics that a Tag row reaches. Snooze: only the Topics list, so a Tag cannot change the time of an Already
    /// Snoozed Topic, and the user checks that Topic by its own row (ADR 0036). Unsnooze: the Snoozed Topics.
    func tagReach(_ topics: TopicsModel) -> [TopicsModel.Row] {
        switch self {
        case .snooze: topics.rows
        case .unsnooze: topics.snoozedRows
        }
    }
}

/// A check step (ADR 0035): the Topics that the user checked. The step lists the order, so the set keeps none.
struct CheckDraft: Equatable {
    let action: CheckAction
    var checked: Set<String> = []

    /// Checks every Topic of `ids`, or unchecks them when all are already checked: Space on a Tag row, and ⌘A.
    mutating func flip(_ ids: Set<String>) {
        if ids.isSubset(of: checked) { checked.subtract(ids) } else { checked.formUnion(ids) }
    }
}

/// A row of a check step. A Tag row is a shortcut to the Topics with the Tag that it reaches (`CheckAction.tagReach`), not a
/// member of the set.
enum CheckRow: Equatable {
    case tag(Tag, topics: Set<String>)
    case topic(String)

    var topics: Set<String> {
        switch self {
        case .tag(_, let topics): topics
        case .topic(let id): [id]
        }
    }

    func box(checked: Set<String>) -> CheckBox { CheckBox(topics, checked: checked) }

    /// What ↩ on this row does. With Topics checked, it goes on with them, on any row. With none, a Topic row goes on
    /// with its Topic, and a Tag row checks its Topics and stays: one ↩ by reflex never acts on all Topics of a Tag.
    func returnOutcome(checked: Set<String>) -> CheckOutcome {
        if !checked.isEmpty { return .goOn(checked) }
        switch self {
        case .topic(let id): return .goOn([id])
        case .tag(_, let topics): return .check(topics)
        }
    }
}

enum CheckOutcome: Equatable {
    case goOn(Set<String>)
    case check(Set<String>)
}

/// The box of a row: how many of its Topics are checked.
enum CheckBox: Equatable {
    case none, some, all

    init(_ topics: Set<String>, checked: Set<String>) {
        let count = topics.intersection(checked).count
        self = count == 0 ? .none : count == topics.count ? .all : .some
    }
}

/// The box that a row of a check step draws, in the colour of its Tag for a Tag row.
struct RowCheck {
    let box: CheckBox
    var color: MarkColor? = nil
}

extension CommandPalette {
    /// The Topics a check step lists (`CheckAction.listed`).
    func checkable(_ action: CheckAction) -> [(id: String, row: TopicsModel.Row)] {
        guard let topics = store?.topics else { return [] }
        return action.listed(topics).compactMap { row in
            guard case .topic(let id) = row.id else { return nil }
            return (id, row)
        }
    }

    /// `ids` in list order, without the Topics that the step no longer lists.
    func listOrder(_ ids: Set<String>, _ action: CheckAction) -> [String] {
        checkable(action).map(\.id).filter(ids.contains)
    }

    func checkedIDs(_ draft: CheckDraft) -> [String] { listOrder(draft.checked, draft.action) }

    /// The Topics of `rows` that have each Tag.
    private func tagged(_ rows: [TopicsModel.Row]) -> [Tag: Set<String>] {
        var tagged: [Tag: Set<String>] = [:]
        for row in rows {
            guard case .topic(let id) = row.id else { continue }
            for tag in row.tags.compactMap(\.definition).map(\.tag) { tagged[tag, default: []].insert(id) }
        }
        return tagged
    }

    /// The Topics with `tag` that its Tag row reaches.
    func topics(with tag: Tag, _ action: CheckAction) -> Set<String> {
        guard let topics = store?.topics else { return [] }
        return tagged(action.tagReach(topics))[tag] ?? []
    }

    /// Tags in Config order, then Topics, then Already Snoozed for Snooze, or Snoozed for Unsnooze. A Tag that reaches no
    /// Topic has no row. A row stays in its place when it is checked.
    func checkRows(_ draft: CheckDraft) -> PickList<PaletteItem> {
        guard let topics = store?.topics else { return .empty }
        let checked = Set(checkedIDs(draft))
        func plural(_ count: Int) -> String { count == 1 ? "1 Topic" : "\(count) Topics" }
        func candidate(_ row: TopicsModel.Row) -> PickCandidate<PaletteItem>? {
            guard case .topic(let id) = row.id else { return nil }
            var trailing = topics.activeTopic == row.id ? "Active" : ""
            var kind = PaletteItem.Kind.topic
            if case .snoozed(let wake) = row.kind { trailing = "until " + wake; kind = .snoozedTopic }
            return PickCandidate(id: row.id.accessibilityID, title: row.title,
                                 fields: (row.idleLabel.map { [.detail($0)] } ?? []) + row.sessions.map { .label($0.baseName) }
                                    + SearchField.tags(row.tags),
                                 trailing: trailing, mark: row.mark,
                                 pick: .available(PaletteItem(kind: kind, ref: .choice(.check(.topic(id))))))
        }
        let reached = tagged(draft.action.tagReach(topics))
        let listed = tagged(draft.action.listed(topics))
        let tags = (topics.tags?.definitions ?? []).compactMap { definition -> PickCandidate<PaletteItem>? in
            guard let ids = reached[definition.tag] else { return nil }
            let row = CheckRow.tag(definition.tag, topics: ids)
            let snoozed = (listed[definition.tag]?.count ?? 0) - ids.count
            let count = row.box(checked: checked) == .some ? "\(ids.intersection(checked).count)/\(ids.count)" : plural(ids.count)
            return PickCandidate(id: "tag-" + definition.tag.name, title: definition.tag.description, fields: [.hidden(definition.tag.name)],
                                 trailing: count + (snoozed > 0 ? " · \(snoozed) Snoozed" : ""),
                                 pick: .available(PaletteItem(kind: .tag, ref: .choice(.check(row)), color: definition.color)), titlePlace: .tag)
        }
        var sections = [PickSectionInput(id: "tags", title: "Tags", rule: .ranked(showsWhenEmpty: true), candidates: tags)]
        switch draft.action {
        case .snooze:
            sections += [
                PickSectionInput(id: "topics", title: "Topics", rule: .ranked(showsWhenEmpty: true),
                                 candidates: topics.rows.compactMap(candidate)),
                PickSectionInput(id: "snoozed", title: "Already Snoozed", rule: .ranked(showsWhenEmpty: true),
                                 candidates: topics.snoozedRows.compactMap(candidate)),
            ]
        case .unsnooze:
            sections.append(PickSectionInput(id: "snoozed", title: "Snoozed", rule: .ranked(showsWhenEmpty: true),
                                             candidates: topics.snoozedRows.compactMap(candidate)))
        }
        return FuzzyRanker.list(sections, query: FuzzyQuery(query))
    }

    private func checkRow(of row: PickRow<PaletteItem>?) -> CheckRow? {
        guard case .choice(.check(let checkRow))? = row?.pick.payload?.ref else { return nil }
        return checkRow
    }

    /// The box a row draws; nil outside a check step.
    func rowCheck(_ row: PickRow<PaletteItem>) -> RowCheck? {
        guard case .check(let draft)? = flow, let checkRow = checkRow(of: row) else { return nil }
        let box = checkRow.box(checked: Set(checkedIDs(draft)))
        return RowCheck(box: box, color: row.pick.payload?.color)
    }

    /// The checked Topics by name, the checked Topics that the filter hides, and what ↩ does now.
    func checkNote(_ draft: CheckDraft) -> String? {
        let ids = checkedIDs(draft)
        let list = results
        var parts: [String] = []
        if !ids.isEmpty {
            let named = ids.prefix(4).map(topicTitle(id:)).joined(separator: ", ")
            parts.append("\(draft.action.verb)s: " + named + (ids.count > 4 ? " +\(ids.count - 4) more" : ""))
            let shown = Set(list.rows.compactMap { row -> String? in
                guard case .topic(let id)? = checkRow(of: row) else { return nil }
                return id
            })
            let hidden = ids.filter { !shown.contains($0) }.count
            if hidden > 0 { parts.append("\(hidden) checked \(hidden == 1 ? "is" : "are") not shown") }
            if draft.action == .snooze, let next = nextTopicNote(ids) { parts.append(next) }
        }
        if let row = checkRow(of: selected(in: list)) {
            switch row.returnOutcome(checked: Set(ids)) {
            case .goOn(let going):
                let ordered = listOrder(going, draft.action)
                let what = ordered.count == 1 ? topicTitle(id: ordered[0]) : "\(ordered.count) Topics"
                parts.append("↩ \(draft.action.verb)s \(what)" + (draft.action == .snooze ? "…" : ""))
            case .check:
                if case .tag(let tag, _) = row { parts.append("↩ checks " + tag.description) }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Changes the checks and keeps the highlighted row.
    private func updateCheck(_ draft: CheckDraft, highlighting id: String?) {
        replaceFlow(.check(draft))
        selectedID = id
    }

    /// Space, ⇥ or a click on a row: a Topic row checks or unchecks its Topic, and a Tag row checks all its Topics,
    /// or unchecks them when all are checked.
    func check(_ row: CheckRow, highlighting id: String?) {
        guard case .check(var draft) = flow else { return }
        draft.checked = Set(checkedIDs(draft))
        draft.flip(row.topics)
        updateCheck(draft, highlighting: id)
    }

    func checkSelected() {
        let row = selected(in: results)
        guard let checkRow = checkRow(of: row) else { return }
        check(checkRow, highlighting: row?.id)
    }

    /// ⌘A: checks every Topic row that the filter shows, or unchecks them when all are checked.
    func checkShown() {
        guard case .check(var draft) = flow else { return }
        let shown = Set(results.rows.compactMap { row -> String? in
            guard case .topic(let id)? = checkRow(of: row) else { return nil }
            return id
        })
        draft.checked = Set(checkedIDs(draft))
        draft.flip(shown)
        updateCheck(draft, highlighting: selectedID)
    }

    /// ↩ on a row of a check step.
    func returnOnCheck(_ row: CheckRow) {
        guard let store, case .check(var draft) = flow else { return }
        switch row.returnOutcome(checked: Set(checkedIDs(draft))) {
        case .check(let ids):
            draft.checked.formUnion(ids)
            updateCheck(draft, highlighting: selectedID)
        case .goOn(let ids):
            switch draft.action {
            case .snooze:
                query = ""
                replaceFlow(.snoozeUntil(ids))
            case .unsnooze:
                store.unsnoozeTopics(listOrder(ids, .unsnooze))
            }
        }
    }

    /// Unsnooze Topic while the Active Topic is not Snoozed: one row for each Snoozed Topic.
    func unsnoozeRows() -> PickList<PaletteItem> {
        let candidates = checkable(.unsnooze).map { id, row in
            var trailing = ""
            if case .snoozed(let wake) = row.kind { trailing = "until " + wake }
            return PickCandidate(id: row.id.accessibilityID, title: row.title,
                                 fields: row.sessions.map { .label($0.baseName) } + SearchField.tags(row.tags),
                                 trailing: trailing, mark: row.mark,
                                 pick: .available(PaletteItem(kind: .snoozedTopic, ref: .choice(.unsnooze(id)))))
        }
        return FuzzyRanker.list([PickSectionInput(id: "snoozed", title: "Snoozed", rule: .ranked(showsWhenEmpty: true),
                                                  candidates: candidates)], query: FuzzyQuery(query))
    }
}
