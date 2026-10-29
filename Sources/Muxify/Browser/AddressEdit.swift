import Foundation

/// The address field while it has Focus: what the user typed, what the field shows, and the list of Suggestions
/// under it (ADR 0060). The view feeds it each change of the text and each list key, and shows what it holds.
struct AddressEdit {
    /// What ↩ opens.
    enum Target: Equatable {
        case suggestion(Suggestion)
        case text(String)
    }

    /// The URL of the Tab when the field took Focus. The list shows only while the typed text is something else.
    let url: String
    /// What the user typed, without the Inline completion. The Suggestions are for it.
    private(set) var typed: String
    /// What the field shows: the typed text, with the Inline completion or the URL of the selected Suggestion.
    private(set) var text: String
    private(set) var suggestions: [Suggestion] = []
    private(set) var selection: Int?
    /// The added text of the Inline completion, in UTF-16 offsets of `text`, for the field's selection.
    private(set) var completion: NSRange?
    /// ⎋ closed the list. The next change of the text shows it again.
    private var dismissed = false

    init(url: String) {
        self.url = url
        typed = url
        text = url
    }

    var showsList: Bool { !dismissed && !suggestions.isEmpty && typed != url }

    /// The field's text changed: a typed letter, ⌫, a paste, or the field echoing what this edit gave it. Only one
    /// letter typed at the end completes, so ⌫ over a completion and a paste leave the text as it is.
    mutating func textChanged(to newText: String, suggest: (String) -> [Suggestion]) {
        guard newText != text else { return }
        let addsOneLetter = newText.count == typed.count + 1 && newText.hasPrefix(typed)
        typed = newText
        text = newText
        selection = nil
        completion = nil
        dismissed = false
        suggestions = suggest(newText)
        if addsOneLetter, let completed = suggestions.first?.completion(of: newText) {
            text = completed
            completion = NSRange(location: newText.utf16.count, length: completed.utf16.count - newText.utf16.count)
        }
    }

    /// ↓ and ⌃N move down by one, ↑ and ⌃P up by one. Past either end, the field shows the typed text again.
    /// False when the list does not show, so the key goes on to the field.
    mutating func move(_ step: Int) -> Bool {
        guard showsList else { return false }
        let next = selection.map { $0 + step } ?? (step > 0 ? 0 : suggestions.count - 1)
        selection = suggestions.indices.contains(next) ? next : nil
        completion = nil
        text = selection.map { Self.fieldText(of: suggestions[$0]) } ?? typed
        return true
    }

    /// ⎋: true when it closed the list, false when there was no list to close.
    mutating func escape() -> Bool {
        guard showsList else { return false }
        dismissed = true
        selection = nil
        return true
    }

    var target: Target {
        if showsList, let selection { return .suggestion(suggestions[selection]) }
        if completion != nil, let first = suggestions.first { return .suggestion(first) }
        return .text(text)
    }

    private static func fieldText(of suggestion: Suggestion) -> String {
        if case .search(let query) = suggestion { return query }
        return suggestion.url
    }
}
