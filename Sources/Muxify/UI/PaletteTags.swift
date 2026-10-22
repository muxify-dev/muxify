import MuxifyCore

/// A palette field that takes Tags: New Topic or Edit Tags. The complete Tags are chips that the flow keeps; the
/// text holds the words after them.
struct TagField {
    enum Mode {
        /// A word that starts with `#` is a Tag, and the other words are the title.
        case newTopic
        /// The field holds only the Tags of this Topic, so a word without `#` is a Tag too.
        case editTags(TopicRecord)
    }

    let mode: Mode
    /// `topics.tags` when the step began. Nil: Tags are off, so New Topic reads `#` as title text.
    let defined: ConfigTags?
    var chipField: ChipField<Tag>

    init(mode: Mode, defined: ConfigTags?, chips: [Tag] = []) {
        self.mode = mode
        self.defined = defined
        chipField = ChipField(chips: chips)
    }

    func text(_ query: String) -> TagText { TagText(field: self, text: query) }
}

/// The text of a `TagField`. A Tag word is the draft while no space follows it, so the rows show the Tags that
/// match it.
struct TagText {
    let field: TagField
    let text: String

    private var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// A lone `#` in New Topic is title text, except as the draft, where it lists every Tag.
    private func isTagWord(_ word: String) -> Bool {
        guard field.defined != nil else { return false }
        if case .editTags = field.mode { return true }
        return word.hasPrefix("#") && word.count > 1
    }

    private func tag(_ word: String) -> Tag? { field.defined?.tag(typed: word) }

    /// The word being typed, with its `#`; nil when the caret is not after a Tag word.
    var draft: String? {
        guard let last = words.last, text.last?.isWhitespace == false, isTagWord(last) || (last == "#" && field.defined != nil) else { return nil }
        return last.hasPrefix("#") ? last : "#" + last
    }

    /// The text without the draft, for when the draft becomes a chip.
    var withoutDraft: String {
        guard draft != nil, let range = text.range(of: words.last ?? "", options: .backwards) else { return text }
        return String(text[..<range.lowerBound])
    }

    /// The Tag words that no Tag of the Config matches. ↩ does nothing while one is in the field.
    var refusedWords: [String] { words.filter { isTagWord($0) && tag($0) == nil } }

    /// The chips, then each Tag word, once each.
    var tags: [Tag] {
        var tags = field.chipField.chips
        for tag in words.compactMap({ isTagWord($0) ? tag($0) : nil }) where !tags.contains(tag) { tags.append(tag) }
        return tags
    }

    /// New Topic: the words that are not Tags.
    var title: String { words.filter { !isTagWord($0) }.joined(separator: " ") }
}

extension PaletteFlow {
    /// Nil in a step that takes no Tags.
    var tagField: TagField? {
        if case .text(.tags(let field)) = self { return field }
        return nil
    }
}

extension CommandPalette {
    /// The Tags of `topics.tags` that match the draft, in Config order, without the chips. A Tag with no Topic is
    /// listed too. When none matches, one row says so. Empty while there is no draft.
    func tagRows(_ field: TagField) -> PickList<PaletteItem> {
        guard let store, let defined = field.defined, let draft = field.text(query).draft else { return .empty }
        let records = store.topicWatcher.records
        let candidates = defined.definitions.filter { !field.chipField.chips.contains($0.tag) }.map { definition in
            let count = records.filter { $0.tags.contains(definition.tag) }.count
            return PickCandidate(id: "tag-" + definition.tag.name, title: definition.tag.description,
                                 trailing: count == 1 ? "1 Topic" : "\(count) Topics",
                                 pick: .available(PaletteItem(kind: .tag, ref: .choice(.tag(definition.tag)), color: definition.color)),
                                 titlePlace: .tag)
        }
        let list = FuzzyRanker.list([PickSectionInput(id: "tags", title: "Tags", rule: .ranked(showsWhenEmpty: true), candidates: candidates)],
                                    query: FuzzyQuery(draft))
        guard list.rows.isEmpty else { return list }
        return FuzzyRanker.list([PickSectionInput(id: "no-tag", rule: .fixed, candidates: [
            PickCandidate(id: "no-tag", title: "No Tag “\(draft.dropFirst())” matches", note: "The Config defines the Tags in topics.tags",
                          pick: .blocked(reason: "")),
        ])], query: FuzzyQuery(""))
    }

    /// ⇥ or ↩ on a Tag row, or a space after a complete Tag word: the draft becomes a chip.
    func addTagChip(_ tag: Tag) {
        guard var field = flow?.tagField else { return }
        query = field.text(query).withoutDraft
        field.chipField.append(tag)
        replaceFlow(.text(.tags(field)))
    }

    /// A space after a draft that names a Tag of the Config makes it a chip at once, so ⌫ then removes it whole.
    /// False when the draft names no Tag, and the space goes into the field.
    func completeTagDraft() -> Bool {
        guard let field = flow?.tagField, let draft = field.text(query).draft, let tag = field.defined?.tag(typed: draft) else { return false }
        addTagChip(tag)
        return true
    }

    /// While a draft is typed: how it becomes a chip. Then for New Topic what ↩ makes, and for Edit Tags what it
    /// changes.
    func tagNote(_ field: TagField) -> String? {
        let text = field.text(query)
        if text.draft != nil { return "⇥ or ↩ makes a chip · ⌫ in an empty field removes a chip" }
        if let word = text.refusedWords.first { return "\(word) is not a Tag in topics.tags. Remove it, or add the Tag to the Config." }
        func list(_ tags: [Tag]) -> String { tags.map(\.description).joined(separator: " ") }
        let tags = text.tags
        switch field.mode {
        case .newTopic:
            guard !tags.isEmpty else { return nil }
            let title = text.title.isEmpty ? "Untitled" : text.title
            return "Title: \(title) · Tags: \(list(tags)) · ↩ makes the Topic. Its first Session comes next."
        case .editTags(let topic):
            let changes = [("Removes", topic.tags.sorted().filter { !tags.contains($0) }), ("Adds", tags.filter { !topic.tags.contains($0) })]
                .filter { !$0.1.isEmpty }.map { "\($0.0): \(list($0.1))" }
            let keys = field.chipField.selection == nil ? "← selects a Tag" : "← → move · ⌫ ⌦ remove the selected Tag"
            return (changes + [keys, "↩ saves"] + (changes.isEmpty ? ["esc changes nothing"] : []))
                .joined(separator: " · ")
        }
    }
}
