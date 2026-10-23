import Foundation

/// A Git View prompt: a one-line field inside the Git View for one value, as
/// lazygit's prompts are. ↩ submits and ⎋ cancels with no change. It can
/// start with text filled in, and it can hide what the user types, as a
/// password's prompt does. While one is open, the field takes the keys.
struct GitPrompt {
    /// Names the prompt for accessibility and for tests, such as "stash".
    let id: String
    let title: String
    var subject: GitMenu.Subject?
    /// An SF Symbol beside the title.
    var symbol: String
    /// Shown in the empty field.
    var placeholder = ""
    /// What the field starts with.
    var initialText = ""
    /// What the user types shows as dots.
    var isSecret = false
    /// ↩ submits an empty value, as for a stash with no message.
    var allowsEmpty = true
    /// Names to offer as the user types, such as the branches `c` checks out; ↓/↑ choose one and ↩ takes it.
    var suggestions: [String] = []
    /// The button beside Cancel, such as "Stash".
    var submitTitle = "OK"
    /// Takes what was typed, as it was: the prompt's owner trims it.
    let submit: (String) -> Void

    /// How many suggestions show at once.
    static let suggestionLimit = 8

    /// The suggestions that match what was typed, those it starts first, as many as show.
    func suggestions(matching text: String) -> [String] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty else { return Array(suggestions.prefix(Self.suggestionLimit)) }
        let matches = suggestions.filter { $0.lowercased().contains(typed) }
        let starting = matches.filter { $0.lowercased().hasPrefix(typed) }
        return Array((starting + matches.filter { !starting.contains($0) }).prefix(Self.suggestionLimit))
    }

    func accepts(_ text: String) -> Bool {
        allowsEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// lazygit's stash options, for `S`: what `git stash push` takes, and the
/// key each has in the menu.
enum GitStashKind: String, CaseIterable {
    case all, untracked, staged, unstaged, keepIndex = "keepindex"

    var title: String {
        switch self {
        case .all: "Stash all changes"
        case .untracked: "Stash all changes including untracked files"
        case .staged: "Stash staged changes"
        case .unstaged: "Stash unstaged changes"
        case .keepIndex: "Stash all changes and keep index"
        }
    }

    /// lazygit's key for it in the stash options menu.
    var key: String {
        switch self {
        case .all: "a"
        case .untracked: "shift+u"
        case .staged: "s"
        case .unstaged: "u"
        case .keepIndex: "i"
        }
    }

    var note: String {
        switch self {
        case .all: "Staged and unstaged changes. Untracked files stay."
        case .untracked: "As above, and new files that git doesn't track."
        case .staged: "Only what's staged. Needs git 2.35."
        case .unstaged: "Only what isn't staged. What's staged stays."
        case .keepIndex: "As the first, but what's staged stays in the working tree too."
        }
    }
}
