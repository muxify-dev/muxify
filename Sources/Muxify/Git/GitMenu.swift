import Foundation
import MuxifyCore

/// A Git View menu: a list of choices that a key opens inside the Git View,
/// as lazygit's menus are, each choice with its own key. j and k (and ↓ and
/// ↑) move the highlight, ↩ runs the highlighted choice, and ⎋ or q close
/// it and change nothing. A confirmation is a menu with one choice. While
/// one is open, no other Git View key acts.
struct GitMenu {
    /// What the menu is about, under its title.
    enum Subject: Equatable {
        case file(String)
        /// A folder, and how many files of it the menu is on, if it says.
        case folder(String, files: Int?)
        case text(String)
    }

    struct Choice: Identifiable {
        /// Its key, by its Config spelling, such as "x" or "shift+d".
        let key: String
        let title: String
        /// The line under the title.
        var note: String?
        var isEnabled = true
        /// Its title shows in red, as lazygit's are for what can't be undone.
        var isDestructive = false
        let run: () -> Void

        var id: String { key }
    }

    /// Names the menu for accessibility and for tests, such as "discard".
    let id: String
    let title: String
    var subject: Subject?
    /// An SF Symbol beside the title.
    var symbol: String
    var isDestructive = false
    /// The line beside Cancel, such as "This can't be undone."
    var footnote: String?
    let choices: [Choice]
    /// The choice ↩ runs: the first that's enabled, until j or k moves it.
    private(set) var highlighted: Int?

    init(id: String, title: String, subject: Subject? = nil, symbol: String, isDestructive: Bool = false,
         footnote: String? = nil, choices: [Choice]) {
        self.id = id
        self.title = title
        self.subject = subject
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.footnote = footnote
        self.choices = choices
        highlighted = choices.firstIndex(where: \.isEnabled)
    }

    var highlightedChoice: Choice? { highlighted.map { choices[$0] } }

    /// j and k: to the next or previous choice that's enabled, stopping at
    /// the ends.
    mutating func move(by step: Int) {
        let enabled = choices.indices.filter { choices[$0].isEnabled }
        guard let current = highlighted.flatMap(enabled.firstIndex(of:)) ?? (enabled.isEmpty ? nil : 0) else { return }
        highlighted = enabled[min(max(current + step, 0), enabled.count - 1)]
    }

    /// The choice whose key this is, enabled or not.
    func choice(for trigger: KeyTrigger) -> Choice? {
        choices.first { (try? KeyTrigger($0.key)) == trigger }
    }
}
