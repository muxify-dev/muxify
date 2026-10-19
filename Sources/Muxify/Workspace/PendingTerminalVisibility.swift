import Foundation

/// Terminals just hidden or shown that snapshots may not reflect yet: one
/// already in flight still has the Window's old `@muxify_terminal`.
struct PendingTerminalVisibility {
    private var pending: [String: (hidden: Bool, deadline: Date)] = [:]

    mutating func set(_ hidden: Bool, windowID: String, until deadline: Date) {
        pending[windowID] = (hidden, deadline)
    }

    /// The snapshot's Windows with the pending changes kept. A change is
    /// dropped once tmux agrees, or when it expires.
    mutating func apply(to windows: [TmuxWindow], now: Date = Date()) -> [TmuxWindow] {
        guard !pending.isEmpty else { return windows }
        let listed = Set(windows.map(\.id))
        pending = pending.filter { listed.contains($0.key) && now <= $0.value.deadline }
        return windows.map { window in
            guard let change = pending[window.id] else { return window }
            if change.hidden == window.terminalHidden {
                pending[window.id] = nil
                return window
            }
            var window = window
            window.terminalHidden = change.hidden
            return window
        }
    }

    mutating func removeAll() {
        pending.removeAll()
    }
}
