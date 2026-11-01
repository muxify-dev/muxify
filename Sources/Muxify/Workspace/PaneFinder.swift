import Foundation
import Observation
import MuxifyCore

/// Find in Pane (ADR 0051): searches the history of the current Window's active Pane through tmux copy mode,
/// from a find bar over the Terminal. tmux highlights every match and scrolls the Pane to the current one.
@MainActor @Observable
final class PaneFinder: Finder {
    private(set) var isShown = false
    var findQuery = "" {
        didSet { if findQuery != oldValue { search(.query) } }
    }
    private(set) var findStatus = FindStatus.idle
    var findFieldFocusRequested = false
    /// The find field has Focus. What the user types there is the Terminal's, so Browser keybinds do not act.
    var findFieldHasFocus = false

    @ObservationIgnored var perform: (PaneSearch.Operation, @escaping (Result<PaneSearch.Response, Error>) -> Void) -> Bool = { _, _ in false }
    /// The Window whose active Pane the search starts in.
    @ObservationIgnored var windowID: () -> String? = { nil }
    /// `ui.find_colors` as tmux styles.
    @ObservationIgnored var styles: () -> PaneSearch.Styles = { PaneSearch.Styles(match: "", current: "") }
    /// The Pane that the first step searched. The search stays in it until the bar closes.
    @ObservationIgnored private var pane: PaneID?
    /// Drops the answers of steps that a later step or a close replaced.
    @ObservationIgnored private var generation = 0
    /// tmux's count of the query's matches, which a step that tmux gives no count for keeps.
    @ObservationIgnored private var total: Int?

    /// Shows the bar and selects the text of its field. A shown bar keeps its search.
    func show() {
        findFieldFocusRequested = true
        guard !isShown else { return }
        isShown = true
        if !findQuery.isEmpty { search(.query) }
    }

    func findNext() { step(.next) }
    func findPrevious() { step(.previous) }

    private func step(_ step: PaneSearch.Step) {
        if findQuery.isEmpty { show() } else { search(step) }
    }

    /// Closes the bar when the searched Pane is its Window's active Pane, which a key typed in the Terminal, such
    /// as Esc, went to. With another Pane active, the key was that Pane's, and the bar stays.
    func closeIfPaneIsActive() {
        guard isShown else { return }
        guard let pane else { return close() }
        let current = generation
        let submitted = perform(.isActive(pane)) { [weak self] result in
            guard let self, self.generation == current, self.pane == pane,
                  case .success(.active(true)) = result else { return }
            self.close()
        }
        if !submitted { close() }
    }

    /// Hides the bar and leaves copy mode, so the Pane shows its newest output again.
    func close() {
        guard isShown else { return }
        isShown = false
        findFieldHasFocus = false
        findStatus = .idle
        generation += 1
        if let pane { _ = perform(.cancel(pane)) { _ in } }
        pane = nil
    }

    private func search(_ step: PaneSearch.Step) {
        guard isShown else { return }
        generation += 1
        let current = generation
        guard let pane else {
            guard let window = windowID().flatMap(WindowID.init(rawValue:)) else { return }
            let submitted = perform(.resolve(window)) { [weak self] result in
                guard let self, self.generation == current, self.isShown,
                      case .success(.resolved(let pane)) = result else { return }
                self.pane = pane
                self.search(.query)
            }
            if !submitted { findStatus = .idle }
            return
        }
        let query = findQuery
        let submitted = perform(.search(step: step, query: query, pane: pane, styles: styles(), previousTotal: total)) { [weak self] result in
            guard let self, self.generation == current else { return }
            guard case .success(.searched(let found, let total, let index)) = result else {
                self.pane = nil
                self.findStatus = .idle
                return
            }
            self.total = total
            guard !query.isEmpty else {
                self.findStatus = .idle
                return
            }
            guard found, let total, total > 0 else {
                self.findStatus = found ? .idle : .notFound
                return
            }
            self.findStatus = .match(index: index, total: total)
        }
        if !submitted { findStatus = .idle }
    }
}
