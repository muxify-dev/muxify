import Foundation

/// The Window that going to a Worktree lands on (ADR 0041): when a branch is checked out in another Worktree, the
/// Git View offers to go to a Window that has a Pane there.
public enum WorktreeWindow {
    /// The Window of `windows` with a Pane whose folder is `worktree` or inside it, or nil when none has. Folders are
    /// compared by real path (ADR 0022); `resolver` turns a Pane's folder into a Folder on the machine that owns it.
    /// Of several, the one `recency` says was visited last wins; Windows it has no date for come after those it has,
    /// and then the Window that is active in its Session, the Session with the latest activity, and the lowest index.
    public static func mostRecent(in worktree: Folder, windows: [TmuxWindow], panes: [TmuxPane], resolver: FolderResolver = .local,
                                  recency: (TmuxWindow) -> Date?) -> TmuxWindow? {
        let inside = Set(panes.filter { !$0.path.isEmpty && worktree.contains(resolver.folder($0.path)) }.map(\.windowID))
        func better(_ a: TmuxWindow, than b: TmuxWindow) -> Bool {
            let (visitA, visitB) = (recency(a) ?? .distantPast, recency(b) ?? .distantPast)
            if visitA != visitB { return visitA > visitB }
            if a.isActive != b.isActive { return a.isActive }
            if a.sessionActivity != b.sessionActivity { return a.sessionActivity > b.sessionActivity }
            return a.index < b.index
        }
        return windows.filter { inside.contains($0.id) }.reduce(nil) { best, window in
            guard let best else { return window }
            return better(window, than: best) ? window : best
        }
    }
}
