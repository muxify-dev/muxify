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

    /// Runs a tmux command on the App Window's Environment. False when it cannot run one now.
    @ObservationIgnored var tmux: ([String], @escaping (Result<String, Error>) -> Void) -> Bool = { _, _ in false }
    /// The Window whose active Pane the search starts in.
    @ObservationIgnored var windowID: () -> String? = { nil }
    /// `ui.find_colors` as tmux styles.
    @ObservationIgnored var styles: () -> PaneSearch.Styles = { PaneSearch.Styles(match: "", current: "") }
    /// The Pane that the first step searched. The search stays in it until the bar closes.
    @ObservationIgnored private var pane: String?
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
        let submitted = tmux(["display-message", "-p", "-t", pane, "#{pane_active}"]) { [weak self] result in
            guard let self, self.generation == current, self.pane == pane,
                  case .success(let output) = result, output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { return }
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
        if let pane { _ = tmux(PaneSearch.cancel(pane: pane)) { _ in } }
        pane = nil
    }

    private func search(_ step: PaneSearch.Step) {
        guard isShown, let target = pane ?? windowID() else { return }
        generation += 1
        let current = generation
        let query = findQuery
        let submitted = tmux(PaneSearch.commands(step, query: query, target: target, styles: styles())) { [weak self] result in
            guard let self, self.generation == current else { return }
            guard case .success(let output) = result, let status = PaneSearch.Status(output) else {
                // The Pane is gone: the next step starts in the Window's active Pane.
                self.pane = nil
                self.findStatus = .idle
                return
            }
            self.pane = status.pane
            self.total = step == .query ? status.total : status.total ?? self.total
            guard !query.isEmpty else {
                self.findStatus = .idle
                return
            }
            guard status.found, let total = self.total, total > 0 else {
                self.findStatus = status.found ? .idle : .notFound
                return
            }
            self.count(query, status: status, total: total, generation: current)
        }
        if !submitted { findStatus = .idle }
    }

    private func count(_ query: String, status: PaneSearch.Status, total: Int, generation current: Int) {
        let submitted = tmux(PaneSearch.capture(status)) { [weak self] result in
            guard let self, self.generation == current else { return }
            let index = (try? result.get()).map { PaneSearch.index(of: query, in: $0, column: status.column, total: total) } ?? 0
            self.findStatus = .match(index: index, total: total)
        }
        if !submitted { findStatus = .match(index: 0, total: total) }
    }
}
