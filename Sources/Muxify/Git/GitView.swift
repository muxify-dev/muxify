import AppKit
import Observation
import MuxifyCore

/// A Git View tab (CONTEXT.md). The tabs are along the bottom of the list
/// pane, which shows one tab's list at a time.
enum GitTab: String, CaseIterable, Identifiable {
    case changes, history, branches, stashes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .history: "History"
        case .branches: "Branches"
        case .stashes: "Stashes"
        }
    }

    var symbol: String {
        switch self {
        case .changes: "plusminus"
        case .history: "clock"
        case .branches: "arrow.triangle.branch"
        case .stashes: "archivebox"
        }
    }

    /// 1 to 4, in order.
    var key: Int { Self.allCases.firstIndex(of: self)! + 1 }

    /// Its own list, before going into anything.
    var list: GitList {
        switch self {
        case .changes: .changes
        case .history: .history
        case .branches: .branches
        case .stashes: .stashes
        }
    }
}

/// A list the list pane shows: a tab's own, or one gone into from it. A
/// branch goes into its commits, and a commit or stash into its files.
enum GitList: String {
    case changes, history, branches, stashes
    /// A branch's commits.
    case branch
    /// The Diff files: a commit's or stash's files.
    case files
}

/// The Git View of one tmux Window in an App Window (CONTEXT.md): a look at
/// the repository in the Window's folder, as a navigator. Tabs of changed
/// files, history, branches and stashes, and the selection's diff beside
/// them. Changes, or lines of them, can be staged, discarded and committed,
/// as in lazygit. Selecting
/// another Window leaves it open as it is, for when you come back.
@MainActor @Observable
final class GitView {
    /// Something in a list.
    enum Item: Equatable, Identifiable {
        case change(GitChange)
        /// A folder of the Changes tree or of the Diff files.
        case folder(GitList, String)
        case commit(GitCommit)
        case stash(GitStash)
        case branch(GitBranch)
        /// A file of the Diff files, by path.
        case file(String)

        var id: String {
            switch self {
            case .change(let change): "change:\(change.path)"
            case .folder(let list, let path): "folder:\(list.rawValue):\(path)"
            case .commit(let commit): "commit:\(commit.sha)"
            case .stash(let stash): "stash:\(stash.sha)"
            case .branch(let branch): "branch:\(branch.name)"
            case .file(let path): "file:\(path)"
            }
        }

        var isFolder: Bool {
            if case .folder = self { return true }
            return false
        }

        /// What the filter looks in.
        fileprivate var text: String {
            switch self {
            case .change(let change): change.path
            case .folder(_, let path), .file(let path): path
            case .commit(let commit): "\(commit.sha) \(commit.subject) \(commit.author) \((commit.tags + commit.refs + commit.remotes).joined(separator: " "))"
            case .stash(let stash): "\(stash.ref) \(stash.message)"
            case .branch(let branch): branch.name
            }
        }

        /// The commit a commit, branch or stash is at, which W compares.
        var sha: String? {
            switch self {
            case .commit(let commit): commit.sha
            case .branch(let branch): branch.sha
            case .stash(let stash): stash.sha
            default: nil
            }
        }

        /// A branch's name, a commit's short hash or a stash's ref, as the
        /// toolbar and a comparison's card name them.
        var name: String {
            switch self {
            case .commit(let commit): String(commit.sha.prefix(7))
            case .branch(let branch): branch.name
            case .stash(let stash): stash.ref
            case .change(let change): change.path
            case .folder(_, let path), .file(let path): path
            }
        }
    }

    /// A row of a list as shown.
    struct Row: Identifiable {
        /// Nil for a note, like "Working tree clean".
        var item: Item?
        /// A folder's name, `Sources/Muxify` for one holding one folder, or
        /// the note.
        var text = ""
        var depth = 0
        /// Everything in it staged: lazygit's green, else red.
        var isStaged = false
        /// The History graph's row, unless filtering.
        var graph: GitGraphRow?

        var id: String { item?.id ?? "note:\(text)" }
    }

    /// A list as the list pane shows it: what it was gone into from, what's
    /// selected, and its filter.
    struct Level: Equatable {
        let list: GitList
        /// The branch whose commits, or the commit or stash whose files,
        /// it lists.
        var owner: Item?
        /// An item's id. None in Diff files shows all of them.
        var selection: String?
        var filter = ""
    }

    enum Focus { case list, diff }

    enum Layout: String { case unified, split }

    /// The side of a split diff whose lines are selected.
    enum Side { case old, new }

    /// A place in the diff's code: a row of `diffRows` and a character of
    /// its line as shown.
    struct TextPoint: Comparable {
        var row: Int
        var offset = 0

        static func < (lhs: TextPoint, rhs: TextPoint) -> Bool {
            (lhs.row, lhs.offset) < (rhs.row, rhs.offset)
        }
    }

    /// What a selection grows by: whole lines, as the keys and the line
    /// numbers select, or characters, as dragging over code does.
    enum Granularity { case line, character }

    /// The part of a line that is selected.
    enum LineSelection: Equatable {
        case whole
        case characters(Range<Int>)
    }

    /// Where the code is drawn, for finding the character under the mouse.
    struct TextMetrics: Equatable {
        let charWidth: CGFloat
        let lineHeight: CGFloat
        /// Characters a line of code shows before it wraps.
        let columns: Int
        /// The code's left edge: after the line numbers and the marker.
        let codeX: CGFloat
    }

    /// What of the content the diff pane shows: all of it, or a file or
    /// folder of the Diff files.
    enum Scope: Equatable {
        case all, file(String), folder(String)

        func contains(_ path: String) -> Bool {
            switch self {
            case .all: true
            case .file(let file): path == file
            case .folder(let folder): GitTree.path(path, isIn: folder)
            }
        }
    }

    /// What the diff pane shows for the selection.
    struct Content {
        enum Header {
            case change(GitChange)
            /// A folder of the Changes tree, with its changes.
            case folder(String, [GitChange])
            case commit(GitCommit, GitCommitDetail?)
            /// A branch, with its history once read; no diff.
            case branch(GitBranch, GitLog?)
            case stash(GitStash)
            /// The diff from the base to the commit, branch or stash
            /// selected; none while the base itself is.
            case comparison(base: Item, target: Item?)
        }

        let id: String
        let header: Header
        let output: String
        let patch: GitPatch
        let theme: TerminalTheme?
        var error: String?
    }

    /// The bar above one file's diff: a change, or a file of the Diff files.
    struct FileHeader {
        let path: String
        /// A change's staged and unstaged patches, or the one file.
        let files: [GitPatchFile]
        let change: GitChange?

        var additions: Int { files.reduce(0) { $0 + $1.additions } }
        var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
    }

    /// A row of the diff pane, numbered for scrolling to.
    struct DiffRow: Identifiable {
        enum Kind {
            /// The commit, branch, stash, comparison or folder card.
            case card
            /// A file's header bar, for the patches with several files.
            case file(Int)
            /// "Unstaged", above that part of a change that has staged
            /// lines too.
            case part(GitChange.Group)
            case hunk(file: Int, hunk: Int)
            case line(GitDiffLine)
            case pair(old: GitDiffLine?, new: GitDiffLine?)
            case binary
            /// Loads the file with all of its lines as context.
            case wholeFile
            case endOfFile
            case omitted(Int)
            case message(String)
        }

        let id: Int
        let kind: Kind
        let file: Int?
        let hunk: Int?
        /// The indexes of its hunk's lines it shows, for staging them.
        var lines: [Int] = []

        /// A line of code, which can be selected and copied.
        var isLine: Bool {
            switch kind {
            case .line(let line): line.kind != .note
            case .pair(let old, let new): (old ?? new).map { $0.kind != .note } ?? false
            default: false
            }
        }

        var isChange: Bool {
            switch kind {
            case .line(let line): line.kind == .added || line.kind == .removed
            case .pair(let old, let new): old?.kind == .removed || new?.kind == .added
            default: false
            }
        }

        var isHunk: Bool {
            if case .hunk = kind { return true }
            return false
        }
    }

    /// lazygit's keys where they fit. They aren't configurable; only
    /// `toggle_git_view` is.
    enum Command: Equatable {
        case tab(GitTab)
        case down, up, top, bottom
        case nextTab, previousTab, enter, focusDiff, focusList
        case scroll(lines: Int), halfPage(Int)
        case nextHunk, previousHunk, nextFile, previousFile
        case extend(Int), range, hunk, copy
        /// Space: stages or unstages in Changes, and the selected lines in
        /// a change's diff; folds a folder of the Diff files.
        case toggle, collapseAll, expandAll
        case commit, discard, filter, back, close, refresh
        /// W: marks the commit, branch or stash selected as the base, or
        /// ends the comparison on the base, as lazygit's diffing mode.
        case mark
        /// e: opens the file in the editor, at the line.
        case edit
    }

    private(set) var isOpen = false
    /// The Window's folder, which may be anywhere in the repository.
    private(set) var folder = ""
    private(set) var snapshot: GitSnapshot?
    private(set) var error: String?
    /// Reading on opening or after R, when the toolbar shows a spinner.
    private(set) var isReading = false
    /// Staging, unstaging or committing; the toolbar shows a spinner.
    private(set) var isWriting = false
    /// What a stage, unstage or commit that failed said.
    private(set) var writeError: String?
    /// The commit message box is open; c opens it, as in lazygit.
    private(set) var isCommitOpen = false
    /// The message being written, kept when the box closes uncommitted.
    var commitSummary = ""
    var commitDescription = ""
    private(set) var commitError: String?
    private(set) var isCommitting = false
    /// d in Changes: lazygit's Discard changes menu, on what it's for.
    private(set) var discard: Discard?
    /// The Git View tab the list pane shows.
    private(set) var tab = GitTab.changes
    /// Each tab's lists: its own, then each one gone into; the last one
    /// is shown, and the rest keep where they were, as in lazygit.
    private(set) var levels = GitView.rootLevels
    private(set) var focus = Focus.list
    /// Folded folders of the Changes tree and of the Diff files.
    private(set) var collapsedFolders: [GitList: Set<String>] = [:]
    /// W: the commit, branch or stash that the commit, branch or stash
    /// selected is compared with, in every Git View tab.
    private(set) var base: Item?
    /// The branches' histories read, with the commit each branch was at.
    private(set) var branchLogs: [String: (sha: String, log: GitLog)] = [:]
    /// The filter field has keyboard focus; the view keeps it current.
    var isFiltering = false
    /// Asks the view to put keyboard focus in the filter field.
    var wantsFilterFocus = false
    var layout = Layout(rawValue: UserDefaults.standard.string(forKey: "gitDiffLayout") ?? "") ?? .unified {
        didSet {
            UserDefaults.standard.set(layout.rawValue, forKey: "gitDiffLayout")
            clearLineSelection()
            rebuildDiffRows(keepingPosition: true)
        }
    }
    private(set) var content: Content?
    private(set) var diffRows: [DiffRow] = []
    private(set) var fileHeader: FileHeader?
    /// The selection in the diff: where the keys or the mouse are, and the
    /// other end of a range.
    private(set) var cursor: TextPoint?
    private(set) var anchor: TextPoint?
    private(set) var granularity = Granularity.line
    private(set) var side = Side.new
    /// The diff row at the top of the pane; the view scrolls to it.
    var scrollRow: Int?
    /// The diff's scroll view, for paging and for finding the lines on it.
    @ObservationIgnored var diffHeight: CGFloat = 600
    @ObservationIgnored var diffWidth: CGFloat = 800
    /// Where the diff lines on screen are, in the scroll view. Rows keep
    /// their ids when the diff changes, and report only a frame that moved.
    @ObservationIgnored var lineFrames: [Int: CGRect] = [:]
    /// How the diff draws its code now.
    @ObservationIgnored var textMetrics = TextMetrics(charWidth: 7.2, lineHeight: 19, columns: 120, codeX: 110)
    /// The mouse button went down here, and how many clicks it was.
    @ObservationIgnored private var press: (point: TextPoint, location: CGPoint, inGutter: Bool, clicks: Int)?

    @ObservationIgnored weak var store: WorkspaceStore?
    /// Holds keyboard focus while the Git View has it (see `GitKeyCatcher`).
    @ObservationIgnored weak var keyView: NSView?
    /// The tmux Window it's of.
    let windowID: String
    @ObservationIgnored private var previousResponder: NSResponder?
    @ObservationIgnored private var wantsFocus = false
    @ObservationIgnored private var snapshotGeneration = 0
    @ObservationIgnored private var contentWork: DispatchWorkItem?
    @ObservationIgnored private var loadingID: String?
    @ObservationIgnored private var logWork: DispatchWorkItem?
    /// Git commands that change the repository, run one at a time.
    @ObservationIgnored private var writes: [Write] = []
    /// The branch and commit whose history is being read.
    @ObservationIgnored private var readingLog: String?
    @ObservationIgnored private var shownScope = Scope.all
    /// v: moving the cursor extends the range, as in lazygit.
    @ObservationIgnored private var isRangeSelecting = false
    /// Lines were staged or discarded here: the diff's next read puts the
    /// cursor back, on what it shows, at this row with this one on top.
    @ObservationIgnored private var keptCursor: (item: String, row: Int, top: Int)?
    /// The repository the commit message was written in: the one read
    /// last.
    @ObservationIgnored private var messageRoot: String?
    /// Entering Diff files before they were read: select the first once
    /// they are.
    @ObservationIgnored private var wantsFirstFile = false
    /// Changes shown with all of their lines.
    @ObservationIgnored private var wholeFiles = Set<String>()
    /// Commits and stashes don't change, so their output is kept.
    @ObservationIgnored private var fixedOutputs: [String: String] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var activationObserver: Any?

    /// The terminal's size; code is in the system's monospaced font.
    var fontSize: CGFloat { max(11, (GhosttyRuntime.shared.fontSize ?? 13) - 1) }
    var colors: GitColors { GitColors(store?.theme) }

    init(windowID: String) {
        self.windowID = windowID
    }

    /// Its Window is the one selected, so it's on screen when open.
    var isCurrent: Bool { store?.selectedWindowID == windowID }

    // MARK: Opening and closing

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Opens on the Window's folder, on Changes every time. The other tabs
    /// are where they were left when that is the folder it last showed.
    func open() {
        guard !isOpen, isCurrent, let store, let window = store.selectedWindow else { return }
        previousResponder = store.terminalHost.window?.firstResponder
        if folder != window.path {
            folder = window.path
            snapshot = nil
            error = nil
            content = nil
            diffRows = []
            fileHeader = nil
            levels = Self.rootLevels
            branchLogs = [:]
            collapsedFolders = [:]
            wholeFiles = []
            clearLineSelection()
        }
        isOpen = true
        tab = .changes
        focus = .list
        if snapshot != nil { showSelection() }
        takeFocus()
        refresh(showingProgress: true)
        startRefreshing()
    }

    func close(restoringFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        base = nil
        closeFilesOfNothing()
        isFiltering = false
        isCommitOpen = false
        commitError = nil
        discard = nil
        writeError = nil
        wantsFocus = false
        contentWork?.cancel()
        loadingID = nil
        logWork?.cancel()
        readingLog = nil
        stopRefreshing()
        let responder = previousResponder
        previousResponder = nil
        guard restoringFocus, let store else { return }
        DispatchQueue.main.async { [weak store] in
            guard let store else { return }
            if let responder, responder !== self.keyView,
               let window = store.terminalHost.window, window.makeFirstResponder(responder) { return }
            store.moveFocusIntoWindow()
        }
    }

    /// Another Window was selected: it stays open as it is, but stops
    /// reading the repository until its Window is selected again.
    func suspend() {
        isFiltering = false
        // Asked again when it's wanted, never waiting to be confirmed.
        discard = nil
        wantsFocus = false
        // What had focus before is gone with the Window; closing later
        // gives it to the terminal.
        previousResponder = nil
        stopRefreshing()
    }

    /// Its Window is selected again: shown as it was left, with the keys,
    /// and read again.
    func resume() {
        guard isOpen else { return }
        takeFocus()
        refresh()
        startRefreshing()
    }

    private func startRefreshing() {
        stopRefreshing()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    // MARK: Focus

    /// Whether keys typed in `window` are for the Git View: it has focus,
    /// not the Browser, a palette or the filter field.
    func hasKeyFocus(in window: NSWindow?) -> Bool {
        guard isOpen, let keyView, let responder = window?.firstResponder else { return false }
        return responder === keyView
    }

    var hasKeyFocus: Bool { hasKeyFocus(in: keyView?.window) }

    func focusKeyView() {
        guard isOpen, isCurrent, let keyView, let window = keyView.window else { return }
        wantsFocus = false
        if !hasKeyFocus(in: window) { window.makeFirstResponder(keyView) }
    }

    /// Focus once the key view is on screen, as selecting its Window draws a
    /// new one. The commit message box focuses its own field.
    func takeFocus() {
        guard !isCommitOpen else { return }
        wantsFocus = true
        DispatchQueue.main.async { [weak self] in self?.focusKeyView() }
    }

    /// The key view is in a window only once SwiftUI has shown the Git View.
    func keyViewDidAppear() {
        if wantsFocus { focusKeyView() }
    }

    func setFocus(_ focus: Focus) {
        if focus == .diff, visibleCursor() == nil {
            place(firstLine())
            anchor = nil
            isRangeSelecting = false
        }
        self.focus = focus
        focusKeyView()
    }

    /// The filter field gave keyboard focus back.
    func filterDidEnd() {
        isFiltering = false
        focus = .list
        focusKeyView()
    }

    // MARK: Lists

    private static var rootLevels: [GitTab: [Level]] {
        Dictionary(uniqueKeysWithValues: GitTab.allCases.map { ($0, [Level(list: $0.list)]) })
    }

    /// The list shown: the tab's own, or the last one gone into.
    var level: Level { levels[tab]?.last ?? Level(list: tab.list) }
    var list: GitList { level.list }

    /// The list the shown one was gone into from, which ⎋ goes back to.
    var parentLevel: Level? {
        guard let stack = levels[tab], stack.count > 1 else { return nil }
        return stack[stack.count - 2]
    }

    /// The list above the Diff files: the shown one, or the commits or
    /// stashes the Diff files were gone into from.
    var listLevel: Level {
        list == .files ? parentLevel ?? level : level
    }

    /// The Diff files under the History, a branch's commits and the
    /// Stashes, and under the Branches while comparing: the selection's,
    /// or those gone into.
    var filesLevel: Level? {
        if list == .files { return level }
        guard list != .changes, let item = selectedItem, hasFiles(item) else { return nil }
        return Level(list: .files, owner: item)
    }

    /// Whether an item has Diff files: a commit or stash, and while
    /// comparing, a branch; the base, which shows a note, has none.
    func hasFiles(_ item: Item) -> Bool {
        if let base, base.id == item.id { return false }
        switch item {
        case .commit, .stash: return true
        case .branch: return base != nil
        default: return false
        }
    }

    /// What the diff pane compares with the base: the commit, branch or
    /// stash selected, or whose Diff files are shown; never the base.
    var compared: Item? {
        guard let base, let item = contentItem, item.sha != nil, item.id != base.id else { return nil }
        return item
    }

    /// The shown list's filter; each list has its own.
    var filter: String {
        get { level.filter }
        set {
            guard newValue != level.filter else { return }
            updateLevel { $0.filter = newValue }
            keepSelectionVisible()
        }
    }

    private func updateLevel(_ update: (inout Level) -> Void) {
        var stack = levels[tab] ?? [Level(list: tab.list)]
        update(&stack[stack.count - 1])
        levels[tab] = stack
    }

    /// Whether an item has every word of a filter.
    private static func matcher(_ filter: String) -> (Item) -> Bool {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        return { item in words.isEmpty || words.allSatisfy(item.text.lowercased().contains) }
    }

    var rows: [Row] { rows(for: level) }

    /// A list's rows: the Changes and Diff files as trees, and commits with
    /// their graph. A filter shows the matches with their folders open.
    func rows(for level: Level) -> [Row] {
        guard let snapshot else { return [] }
        let matches = Self.matcher(level.filter)
        let isFiltered = !level.filter.isEmpty
        func note(_ text: String) -> [Row] { [Row(text: text)] }
        switch level.list {
        case .changes:
            let changes = snapshot.changes.filter { matches(.change($0)) }
            guard !changes.isEmpty else { return note(snapshot.changes.isEmpty ? "Working tree clean" : "No matches") }
            // A folder is green when everything in it is staged.
            var unstaged = Set<String>()
            for change in changes where !change.isStaged {
                var folder = (change.path as NSString).deletingLastPathComponent
                while !folder.isEmpty, unstaged.insert(folder).inserted {
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
            return tree(changes.map(\.path), in: .changes, folding: !isFiltered) { index in
                Row(item: .change(changes[index]), isStaged: changes[index].isStaged)
            } folder: { path in
                !unstaged.contains(path)
            }
        case .history, .branch:
            guard let log = log(for: level) else { return note("Reading…") }
            if let error = log.error { return note(error) }
            let rows = log.commits.indices.compactMap { index -> Row? in
                let commit = log.commits[index]
                guard matches(.commit(commit)) else { return nil }
                return Row(item: .commit(commit), graph: !isFiltered && log.graph.indices.contains(index) ? log.graph[index] : nil)
            }
            return rows.isEmpty ? note(log.commits.isEmpty ? "No commits yet" : "No matches") : rows
        case .branches:
            let rows = snapshot.branches.map(Item.branch).filter(matches).map { Row(item: $0) }
            return rows.isEmpty ? note(snapshot.branches.isEmpty ? "No branches yet" : "No matches") : rows
        case .stashes:
            let rows = snapshot.stashes.map(Item.stash).filter(matches).map { Row(item: $0) }
            return rows.isEmpty ? note(snapshot.stashes.isEmpty ? "No stashes" : "No matches") : rows
        case .files:
            guard let owner = level.owner else { return [] }
            if let content, content.id == request(for: owner)?.id, content.error != nil { return note("Could not read the files") }
            guard let files = ownerFiles(for: level) else { return note("Reading…") }
            let shown = files.filter { matches(.file($0.path)) }
            guard !shown.isEmpty else { return note(files.isEmpty ? "No changes" : "No matches") }
            return tree(shown.map(\.path), in: .files, folding: !isFiltered) { index in
                Row(item: .file(shown[index].path))
            } folder: { _ in false }
        }
    }

    /// How many files, commits, branches or stashes a list has, folded or
    /// not; with a filter, how many match.
    func count(for level: Level) -> Int {
        guard let snapshot else { return 0 }
        let matches = Self.matcher(level.filter)
        switch level.list {
        case .changes: return snapshot.changes.filter { matches(.change($0)) }.count
        case .history, .branch: return log(for: level)?.commits.filter { matches(.commit($0)) }.count ?? 0
        case .branches: return snapshot.branches.filter { matches(.branch($0)) }.count
        case .stashes: return snapshot.stashes.filter { matches(.stash($0)) }.count
        case .files: return ownerFiles(for: level)?.filter { matches(.file($0.path)) }.count ?? 0
        }
    }

    private func tree(_ paths: [String], in list: GitList, folding: Bool, file: (Int) -> Row,
                      folder isStaged: (String) -> Bool) -> [Row] {
        GitTree.nodes(paths, collapsed: folding ? collapsedFolders[list] ?? [] : []).map { node in
            var row = node.file.map(file) ?? Row(item: .folder(list, node.path), text: node.name, isStaged: isStaged(node.path))
            row.depth = node.depth
            return row
        }
    }

    /// The commits a list shows: the current branch's, or the branch's it
    /// was gone into from, once read.
    func log(for level: Level) -> GitLog? {
        if case .branch(let branch)? = level.owner { return log(of: branch) }
        return snapshot?.log
    }

    /// The branch you're on has the History's.
    func log(of branch: GitBranch) -> GitLog? {
        branch.isHead ? snapshot?.log : branchLogs[branch.name]?.log
    }

    /// The items the selection moves through, in order.
    func items(for level: Level) -> [Item] {
        rows(for: level).compactMap(\.item)
    }

    var items: [Item] { items(for: level) }

    /// A list's selection, also when a folded folder or the filter hides it.
    func selectedItem(for level: Level) -> Item? {
        guard let id = level.selection, let snapshot else { return nil }
        switch level.list {
        case .changes:
            if let change = snapshot.changes.first(where: { Item.change($0).id == id }) { return .change(change) }
            let path = String(id.dropFirst("folder:changes:".count))
            return id.hasPrefix("folder:changes:") && snapshot.changes.contains { GitTree.path($0.path, isIn: path) }
                ? .folder(.changes, path) : nil
        case .history, .branch:
            return log(for: level)?.commits.first { Item.commit($0).id == id }.map(Item.commit)
        case .branches:
            return snapshot.branches.first { Item.branch($0).id == id }.map(Item.branch)
        case .stashes:
            return snapshot.stashes.first { Item.stash($0).id == id }.map(Item.stash)
        case .files:
            guard let files = ownerFiles(for: level) else { return nil }
            if let file = files.first(where: { Item.file($0.path).id == id }) { return .file(file.path) }
            let path = String(id.dropFirst("folder:files:".count))
            return id.hasPrefix("folder:files:") && files.contains { GitTree.path($0.path, isIn: path) } ? .folder(.files, path) : nil
        }
    }

    var selectedItem: Item? { selectedItem(for: level) }

    /// The Diff files, once their owner's diff has been read.
    var ownerFiles: [GitPatchFile]? { ownerFiles(for: level) }

    func ownerFiles(for level: Level) -> [GitPatchFile]? {
        guard level.list == .files, let owner = level.owner, let content, content.error == nil,
              content.id == request(for: owner)?.id else { return nil }
        return content.patch.files
    }

    /// What the diff pane shows: the selection, or in the Diff files, what
    /// they're the files of.
    var contentItem: Item? {
        list == .files ? level.owner : selectedItem
    }

    var scope: Scope {
        guard list == .files else { return .all }
        switch selectedItem {
        case .file(let path)?: return .file(path)
        case .folder(_, let path)?: return .folder(path)
        default: return .all
        }
    }

    /// A click on a row of a list: a branch's goes into its commits, and a
    /// file of the selected commit or stash into its files; a commit above
    /// the files gone into comes back out to it.
    func select(_ item: Item, in level: Level) {
        if case .branch = item { return enter(item) }
        if level.list == .files, list != .files, let owner = level.owner { return enter(owner, into: .files, selecting: item) }
        if level.list != .files, list == .files { goBack() }
        focus = .list
        choose(item)
        focusKeyView()
    }

    func select(_ item: Item) {
        select(item, in: level)
    }

    /// Shows a tab as it was left, the first time on its first item. The
    /// tab shown goes back to its own list.
    func selectTab(_ tab: GitTab) {
        focus = .list
        if tab == self.tab, let stack = levels[tab], stack.count > 1 {
            levels[tab] = [stack[0]]
            wantsFirstFile = false
        }
        self.tab = tab
        if level.selection == nil, list != .files {
            choose(items.first { !$0.isFolder } ?? items.first)
        } else {
            showSelection()
        }
        focusKeyView()
    }

    /// Goes into a branch's commits, or a commit's or stash's files, as ↩
    /// in lazygit: on the first one, or on `selecting`. A branch compared
    /// with the base goes `into` its Diff files.
    func enter(_ item: Item, into files: GitList? = nil, selecting: Item? = nil) {
        let list: GitList
        switch item {
        case .branch: list = files ?? .branch
        case .commit, .stash: list = .files
        default: return
        }
        guard list != .files || hasFiles(item) else { return }
        focus = .list
        updateLevel { $0.selection = item.id }
        levels[tab, default: [Level(list: tab.list)]].append(Level(list: list, owner: item))
        // A branch's commits not read yet: the first once they are.
        let first = selecting ?? items.first { !$0.isFolder }
        wantsFirstFile = list == .files && first == nil
        choose(first)
        focusKeyView()
    }

    /// Back to the list the shown one was gone into from, on what it went
    /// into; or out of `list` and what was gone into from it.
    func goBack(from list: GitList? = nil) {
        guard var stack = levels[tab], stack.count > 1 else { return }
        let index = list.flatMap { list in stack.lastIndex { $0.list == list } } ?? stack.count - 1
        guard index > 0 else { return }
        stack.removeSubrange(index...)
        levels[tab] = stack
        focus = .list
        wantsFirstFile = false
        showSelection()
        focusKeyView()
    }

    /// Tab: the next tab, round to the first.
    private func cycle(_ step: Int) {
        let tabs = GitTab.allCases
        selectTab(tabs[(tabs.firstIndex(of: tab)! + step + tabs.count) % tabs.count])
    }

    /// Selects without moving keyboard focus.
    private func choose(_ item: Item?) {
        keptCursor = nil
        updateLevel { $0.selection = item?.id }
        showSelection()
    }

    private func move(by delta: Int) {
        let items = items
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == level.selection } ?? (delta > 0 ? -1 : items.count)
        let next = min(max(current + delta, 0), items.count - 1)
        guard items[next].id != level.selection else { return }
        choose(items[next])
    }

    func toggleFolder(_ path: String, in list: GitList) {
        var folded = collapsedFolders[list] ?? []
        if folded.remove(path) == nil { folded.insert(path) }
        collapsedFolders[list] = folded
    }

    /// `-` folds every folder of the list, `=` opens them, as in lazygit.
    private func foldAll(_ folding: Bool) {
        guard list == .changes || list == .files else { return }
        guard folding else {
            collapsedFolders[list] = []
            return
        }
        let paths = list == .changes ? snapshot?.changes.map(\.path) ?? [] : ownerFiles?.map(\.path) ?? []
        collapsedFolders[list] = Set(GitTree.nodes(paths).filter { $0.file == nil }.map(\.path))
        // A file now folded away: select its top folder.
        let items = items
        if let id = level.selection, !items.contains(where: { $0.id == id }),
           let top = items.first(where: { item in
               guard case .folder(_, let path) = item else { return false }
               return id.hasSuffix(":" + path) || id.contains(":\(path)/")
           }) {
            choose(top)
        }
    }

    /// A filter can take the selection away; select the first match.
    private func keepSelectionVisible() {
        guard !filter.isEmpty else { return }
        let items = items
        guard !items.isEmpty, !items.contains(where: { $0.id == level.selection }) else { return }
        choose(items.first { !$0.isFolder } ?? items[0])
    }

    // MARK: Keys

    /// Sees each key in the App Window before Muxify's keybinds while the
    /// Git View or its filter field has focus. Keys it doesn't use, such as
    /// ⌘B, go on to them.
    func handle(_ trigger: KeyTrigger, in event: NSEvent) -> Bool {
        handle(trigger, in: event.window)
    }

    /// An accessibility action of the Git View performs the key named by its
    /// Config spelling, as `handle` does for the key in the Git View's window.
    @discardableResult
    func performKey(named name: String) -> Bool {
        guard let trigger = try? KeyTrigger(name) else { return false }
        return handle(trigger, in: keyView?.window)
    }

    private func handle(_ trigger: KeyTrigger, in window: NSWindow?) -> Bool {
        guard isOpen else { return false }
        // The commit message box's fields take the rest.
        if isCommitOpen, window === keyView?.window {
            switch trigger {
            case Self.escape: closeCommit()
            case Self.commandEnter: commit()
            default: return false
            }
            return true
        }
        // The Discard changes menu's keys, as lazygit's.
        if let discard, window === keyView?.window {
            switch trigger {
            case Self.escape, Self.q: closeDiscard()
            case Self.x: confirmDiscard(.all)
            case Self.u: confirmDiscard(.unstaged)
            case Self.enter: confirmDiscard(discard.option)
            case Self.down, Self.j, Self.ctrlJ: moveDiscardOption(by: 1)
            case Self.up, Self.k, Self.ctrlK: moveDiscardOption(by: -1)
            default: return false
            }
            return true
        }
        if isFiltering, window === keyView?.window {
            switch trigger {
            case Self.escape, Self.enter:
                filterDidEnd()
            case Self.down, Self.ctrlJ:
                move(by: 1)
            case Self.up, Self.ctrlK:
                move(by: -1)
            default:
                return false
            }
            return true
        }
        guard hasKeyFocus(in: window), let command = Self.commands[trigger] else { return false }
        perform(command)
        return true
    }

    private static let escape = try! KeyTrigger("escape")
    private static let enter = try! KeyTrigger("enter")
    private static let down = try! KeyTrigger("down")
    private static let up = try! KeyTrigger("up")
    private static let ctrlJ = try! KeyTrigger("ctrl+j")
    private static let ctrlK = try! KeyTrigger("ctrl+k")
    private static let commandEnter = try! KeyTrigger("cmd+enter")
    private static let j = try! KeyTrigger("j")
    private static let k = try! KeyTrigger("k")
    private static let q = try! KeyTrigger("q")
    private static let u = try! KeyTrigger("u")
    private static let x = try! KeyTrigger("x")

    /// The Git View's keys by their Config spelling; each is also an
    /// accessibility action of the Git View, named by its spelling.
    static let keyMap: KeyValuePairs<String, Command> = [
            "1": .tab(.changes), "2": .tab(.history), "3": .tab(.branches), "4": .tab(.stashes),
            "j": .down, "down": .down, "k": .up, "up": .up, "shift+comma": .top, "shift+period": .bottom,
            "tab": .nextTab, "shift+tab": .previousTab, "enter": .enter,
            "l": .focusDiff, "right": .focusDiff, "h": .focusList, "left": .focusList,
            "shift+j": .scroll(lines: 3), "shift+k": .scroll(lines: -3), "ctrl+d": .halfPage(1), "ctrl+u": .halfPage(-1),
            "alt+down": .nextHunk, "alt+up": .previousHunk, "right_bracket": .nextFile, "left_bracket": .previousFile,
            "shift+down": .extend(1), "shift+up": .extend(-1), "v": .range, "a": .hunk, "y": .copy, "cmd+c": .copy,
            "space": .toggle, "minus": .collapseAll, "equal": .expandAll,
            "c": .commit, "d": .discard, "slash": .filter, "escape": .back, "q": .close, "shift+r": .refresh,
            "shift+w": .mark, "e": .edit,
    ]

    static let commands: [KeyTrigger: Command] = Dictionary(uniqueKeysWithValues: keyMap.map { (try! KeyTrigger($0), $1) })

    func perform(_ command: Command) {
        switch command {
        case .tab(let tab):
            selectTab(tab)
        case .down, .up:
            let delta = command == .down ? 1 : -1
            if focus == .diff { moveCursor(by: delta) } else { move(by: delta) }
        case .top, .bottom:
            if focus == .diff {
                let lines = diffRows.indices.filter { diffRows[$0].isLine }
                place(command == .top ? lines.first : lines.last)
                anchor = isRangeSelecting ? anchor : nil
                scrollRow = command == .top ? diffRows.first?.id : diffRows.last?.id
            } else {
                move(by: command == .top ? -Int.max / 2 : Int.max / 2)
            }
        case .nextTab, .previousTab:
            cycle(command == .nextTab ? 1 : -1)
        case .enter:
            guard focus == .list, let item = selectedItem else { return }
            switch item {
            case .folder(let tree, let path): toggleFolder(path, in: tree)
            case .branch where hasFiles(item): enter(item, into: .files)
            case .branch, .commit, .stash: enter(item)
            case .change, .file: setFocus(.diff)
            }
        case .focusDiff:
            // A branch has no diff: → goes into its commits.
            if focus == .list, let item = selectedItem, case .branch = item { enter(item) } else { setFocus(.diff) }
        case .focusList:
            if focus == .diff { setFocus(.list) } else { goBack() }
        case .scroll(let lines):
            scrollDiff(by: lines)
        case .halfPage(let direction):
            scrollDiff(by: direction * max(3, Int(diffHeight / (fontSize * 1.6) / 2)))
        case .nextHunk, .previousHunk:
            jumpToHunk(forward: command == .nextHunk)
        case .nextFile, .previousFile:
            jumpToFile(forward: command == .nextFile)
        case .extend(let delta):
            if focus == .diff { moveCursor(by: delta, extending: true) }
        case .range:
            guard focus == .diff else { return }
            isRangeSelecting.toggle()
            place(cursor?.row)
            anchor = isRangeSelecting ? cursor : nil
        case .hunk:
            // In Changes, as in lazygit: everything.
            if focus == .diff { selectHunk() } else if list == .changes { toggleStagedAll() }
        case .copy:
            copySelection()
        case .toggle:
            if focus == .diff {
                if list == .changes { toggleStagedLines() }
                return
            }
            guard let item = selectedItem else { return }
            if list == .changes {
                toggleStaged(item)
            } else if case .folder(let tree, let path) = item {
                toggleFolder(path, in: tree)
            }
        case .commit:
            openCommit()
        case .discard:
            guard list == .changes else { return }
            if focus == .diff { askDiscardLines() } else if let item = selectedItem { askDiscard(item) }
        case .collapseAll, .expandAll:
            if focus == .list { foldAll(command == .collapseAll) }
        case .filter:
            wantsFilterFocus = true
        case .back:
            if focus == .diff {
                if anchor != nil { clearLineSelection(keepingCursor: true) } else { setFocus(.list) }
            } else if !filter.isEmpty {
                filter = ""
            } else if parentLevel != nil {
                goBack()
            } else if base != nil {
                mark(nil)
            } else {
                close()
            }
        case .close:
            close()
        case .refresh:
            refresh(showingProgress: true)
        case .mark:
            guard let item = contentItem, item.sha != nil else { return }
            mark(item.id == base?.id ? nil : item)
        case .edit:
            openInEditor()
        }
    }

    // MARK: Editing

    /// The file `e` opens and the line: in the diff, the selection's first
    /// line; in a list, a change's or a file's first changed line.
    var editorTarget: (path: String, line: Int)? {
        if focus == .diff {
            guard let row = selectionBounds?.start.row, diffRows.indices.contains(row), diffRows[row].isLine,
                  let fileID = diffRows[row].file, let hunkIndex = diffRows[row].hunk,
                  let file = content?.patch.files.first(where: { $0.id == fileID }), file.hunks.indices.contains(hunkIndex)
            else { return nil }
            let hunk = file.hunks[hunkIndex]
            switch diffRows[row].kind {
            case .line:
                return diffRows[row].lines.first.map { (file.path, hunk.newLine(at: $0)) }
            case .pair(_, let new):
                if let line = new?.new { return (file.path, line) }
                return diffRows[row].lines.first.map { (file.path, hunk.newLine(at: $0)) }
            default:
                return nil
            }
        }
        let path: String
        switch selectedItem {
        case .change(let change)?: path = change.path
        case .file(let file)?: path = file
        default: return nil
        }
        let file = content?.patch.files.first { $0.path == path }
        return (path, file?.firstChangedLine ?? 1)
    }

    /// Opens the file in the editor, unless it's gone from the working tree.
    func openInEditor() {
        guard let store, let root = snapshot?.root, let target = editorTarget else { return }
        writeError = nil
        let file = (root as NSString).appendingPathComponent(target.path)
        store.runGitScript("[ -e \"$1\" ] && echo present || echo missing", arguments: [file], timeout: 10) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output) where output.contains("missing"):
                self.writeError = "\(target.path) is no longer in the working tree."
            case .success:
                store.openInEditor(file: file, line: target.line, from: self.windowID, in: root)
            case .failure(let error):
                self.writeError = Self.message(for: error)
            }
        }
    }

    // MARK: Comparing

    /// Marks the base, or with nil ends the comparison.
    func mark(_ item: Item?) {
        base = item
        closeFilesOfNothing()
        showSelection()
    }

    /// Diff files gone into that have nothing to list now close: the
    /// base's, or a branch's once the comparison ends.
    private func closeFilesOfNothing() {
        for (tab, stack) in levels {
            guard let index = stack.firstIndex(where: { $0.list == .files && !($0.owner.map(hasFiles) ?? false) }) else { continue }
            levels[tab] = Array(stack[..<index])
            if tab == self.tab {
                focus = .list
                wantsFirstFile = false
            }
        }
    }

    // MARK: Staging and committing

    /// Space: stages a file or folder, all of it, unless it all is; then
    /// unstages it.
    func toggleStaged(_ item: Item) {
        guard let snapshot else { return }
        let staging: (stage: Bool, paths: [String])
        switch item {
        case .change(let change):
            staging = Self.staging([change], path: change.path)
        case .folder(_, let folder):
            staging = Self.staging(snapshot.changes.filter { GitTree.path($0.path, isIn: folder) }, path: folder)
        default:
            return
        }
        write(staging.stage ? GitRepository.stageScript : GitRepository.unstageScript, arguments: [snapshot.root] + staging.paths)
    }

    /// a: stages every change, or once they all are, unstages them.
    private func toggleStagedAll() {
        guard let snapshot, !snapshot.changes.isEmpty else { return }
        let staging = Self.staging(snapshot.changes, path: ".")
        write(staging.stage ? GitRepository.stageScript : GitRepository.unstageScript, arguments: [snapshot.root] + staging.paths)
    }

    /// Whether to stage or unstage a file or folder with these changes, and
    /// the paths to; a rename is unstaged from both of its paths.
    static func staging(_ changes: [GitChange], path: String) -> (stage: Bool, paths: [String]) {
        let stage = changes.contains { !$0.isStaged }
        return (stage, stage ? [path] : [path] + changes.compactMap(\.originalPath))
    }

    /// Lines picked in a change's diff, as git takes them: the files all
    /// of whose changed lines are picked, whole, and a patch of the rest.
    struct LineWrite: Equatable {
        enum Mode: String { case stage, unstage, discard }

        /// Files to stage, unstage or discard the unstaged changes of, and
        /// the paths renamed files came from.
        var paths: [String] = []
        var patch = ""
        /// New files the patch has some lines of, which git is told of
        /// before it stages them.
        var newFiles: [String] = []
        /// The changed lines picked.
        var lines = 0
        /// Lines of conflicted files were picked, which are only staged
        /// whole.
        var hasConflicts = false

        var isEmpty: Bool { paths.isEmpty && patch.isEmpty }
    }

    /// lazygit's Discard changes menu, for a file or folder of Changes, or
    /// for the lines picked in its diff.
    struct Discard: Equatable {
        enum Option: CaseIterable { case all, unstaged }

        /// The file's path, or the folder's.
        let path: String
        let isFolder: Bool
        /// The file's change, or each one in the folder.
        let changes: [GitChange]
        /// d in the diff: the lines to discard, instead of the changes.
        var lines: LineWrite?
        /// The option ↩ picks.
        var option = Option.all

        /// As in lazygit, only when some of it is staged and some isn't.
        var canDiscardUnstaged: Bool {
            lines == nil && changes.contains { $0.groups.contains(.staged) } && changes.contains { !$0.isStaged }
        }

        /// Discarding everything puts a renamed file back at its old path.
        func paths(_ option: Option) -> [String] {
            option == .all ? [path] + changes.compactMap(\.originalPath) : [path]
        }
    }

    /// d: asks what to discard of a file or folder, as lazygit does.
    func askDiscard(_ item: Item) {
        guard let snapshot else { return }
        switch item {
        case .change(let change):
            discard = Discard(path: change.path, isFolder: false, changes: [change])
        case .folder(_, let folder):
            discard = Discard(path: folder, isFolder: true, changes: snapshot.changes.filter { GitTree.path($0.path, isIn: folder) })
        default:
            return
        }
        writeError = nil
    }

    func closeDiscard() {
        discard = nil
    }

    /// x, u, or ↩ or a click on an option. It can't be undone.
    func confirmDiscard(_ option: Discard.Option) {
        guard let discard, let snapshot, option == .all || discard.canDiscardUnstaged else { return }
        self.discard = nil
        if let lines = discard.lines {
            keepCursor()
            return write(lines, .discard, root: snapshot.root)
        }
        write(option == .all ? GitRepository.discardScript : GitRepository.discardUnstagedScript,
              arguments: [snapshot.root] + discard.paths(option))
    }

    // MARK: Staging lines

    /// The lines selected in a change's diff, else the cursor's: by file
    /// of its patch, then by hunk, indexes of the hunk's lines.
    private var pickedLines: [Int: [Int: Set<Int>]] {
        guard let bounds = selectionBounds, diffRows.indices.contains(bounds.end.row) else { return [:] }
        var picked: [Int: [Int: Set<Int>]] = [:]
        for row in diffRows[bounds.start.row...bounds.end.row] where row.isLine {
            guard let file = row.file, let hunk = row.hunk else { continue }
            picked[file, default: [:]][hunk, default: []].formUnion(row.lines)
        }
        return picked
    }

    /// The picked lines of a patch's files in `groups`, as git takes them:
    /// reversed to unstage or discard them.
    static func lineWrite(picking picked: [Int: [Int: Set<Int>]], of patch: GitPatch, in groups: Set<GitChange.Group>,
                          reversed: Bool, changes: [GitChange]) -> LineWrite {
        var write = LineWrite()
        for file in patch.files {
            guard let group = file.group, groups.contains(group), let picks = picked[file.id] else { continue }
            let count = file.changedLines(picking: picks)
            guard count > 0 else { continue }
            let change = changes.first { $0.path == file.path }
            if change?.isConflict == true {
                write.hasConflicts = true
                continue
            }
            write.lines += count
            // All of it: the file, as space in Changes takes it; a rename
            // is unstaged from both of its paths.
            if count == file.additions + file.deletions, patch.omittedLines == 0 {
                write.paths.append(file.path)
                if group == .staged, let from = change?.originalPath { write.paths.append(from) }
            } else if let text = file.patch(picking: picks, reversed: reversed) {
                write.patch += text
                if group == .untracked { write.newFiles.append(file.path) }
            }
        }
        return write
    }

    /// Space in a change's diff: stages the picked lines, and unstages
    /// those in its Staged part, as lazygit does.
    private func toggleStagedLines() {
        guard let snapshot, let content, content.id == request()?.id else { return }
        let picked = pickedLines
        let stage = Self.lineWrite(picking: picked, of: content.patch, in: [.unstaged, .untracked], reversed: false,
                                   changes: snapshot.changes)
        let unstage = Self.lineWrite(picking: picked, of: content.patch, in: [.staged], reversed: true, changes: snapshot.changes)
        guard !stage.isEmpty || !unstage.isEmpty else {
            if stage.hasConflicts { writeError = "A conflicted file is staged whole: with space in Changes, once its conflict markers are gone." }
            return
        }
        keepCursor()
        write(stage, .stage, root: snapshot.root)
        write(unstage, .unstage, root: snapshot.root)
    }

    /// d in a change's diff: asks whether to discard the picked lines of
    /// its unstaged changes.
    private func askDiscardLines() {
        guard let snapshot, let content, content.id == request()?.id else { return }
        let picked = pickedLines
        let lines = Self.lineWrite(picking: picked, of: content.patch, in: [.unstaged, .untracked], reversed: true,
                                   changes: snapshot.changes)
        guard !lines.isEmpty else {
            if lines.hasConflicts {
                writeError = "A conflicted file's lines aren't discarded one by one: discard the file in Changes."
            } else if !Self.lineWrite(picking: picked, of: content.patch, in: [.staged], reversed: true, changes: snapshot.changes).isEmpty {
                writeError = "Only unstaged lines are discarded. Unstage these first, with space."
            }
            return
        }
        switch content.header {
        case .change(let change): discard = Discard(path: change.path, isFolder: false, changes: [change], lines: lines)
        case .folder(let path, let changes): discard = Discard(path: path, isFolder: true, changes: changes, lines: lines)
        default: return
        }
        writeError = nil
    }

    private func write(_ lines: LineWrite, _ mode: LineWrite.Mode, root: String) {
        if !lines.paths.isEmpty {
            let script = switch mode {
            case .stage: GitRepository.stageScript
            case .unstage: GitRepository.unstageScript
            case .discard: GitRepository.discardUnstagedScript
            }
            write(script, arguments: [root] + lines.paths)
        }
        if !lines.patch.isEmpty {
            write(GitRepository.applyPatchScript, arguments: [root, mode.rawValue, lines.patch] + (mode == .stage ? lines.newFiles : []))
        }
    }

    /// The diff read after lines are staged keeps the cursor where it was,
    /// on the next change, as lazygit's does.
    private func keepCursor() {
        guard let row = cursor?.row else { return }
        keptCursor = (contentItem?.id ?? "", row, topIndex)
    }

    private func moveDiscardOption(by step: Int) {
        guard var discard else { return }
        let options = discard.canDiscardUnstaged ? Discard.Option.allCases : [.all]
        let index = (options.firstIndex(of: discard.option) ?? 0) + step
        discard.option = options[min(max(index, 0), options.count - 1)]
        self.discard = discard
    }

    /// The changes staged, which a commit takes.
    var stagedCount: Int {
        snapshot?.changes.filter { $0.groups.contains(.staged) }.count ?? 0
    }

    /// c: the commit message box, once something is staged, or to conclude
    /// a merge once its conflicts are resolved. A rebase, cherry-pick or
    /// revert goes on in the terminal.
    func openCommit() {
        guard let snapshot else { return }
        if let block = snapshot.operation?.commitBlock {
            writeError = block
            return
        }
        if snapshot.isMerging, snapshot.changes.contains(where: \.isConflict) {
            writeError = "Resolve the conflicts first: stage each conflicted file once its conflict markers are gone."
            return
        }
        guard stagedCount > 0 || snapshot.isMerging else {
            writeError = snapshot.changes.isEmpty ? "Nothing to commit: the working tree is clean."
                : "Nothing is staged. Stage files with space, or everything with a, to commit them."
            return
        }
        writeError = nil
        commitError = nil
        // git's message for the merge, unless one is written already.
        if snapshot.isMerging, commitSummary.isEmpty, commitDescription.isEmpty, let message = snapshot.mergeMessage {
            let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            commitSummary = String(parts.first ?? "")
            commitDescription = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        isCommitOpen = true
    }

    func closeCommit() {
        guard isCommitOpen else { return }
        isCommitOpen = false
        commitError = nil
        focusKeyView()
    }

    /// ↩ in the summary or ⌘↩. Hooks and signing can take a while, or wait
    /// for you.
    func commit() {
        let summary = commitSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCommitOpen, !isCommitting, !summary.isEmpty, let snapshot, stagedCount > 0 || snapshot.isMerging else { return }
        if let block = snapshot.operation?.commitBlock {
            commitError = block
            return
        }
        let description = commitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        isCommitting = true
        commitError = nil
        write(GitRepository.makeCommitScript,
              arguments: [snapshot.root, description.isEmpty ? summary : summary + "\n\n" + description],
              timeout: 600) { [weak self] result in
            guard let self else { return }
            self.isCommitting = false
            switch result {
            case .success(let output):
                self.commitSummary = ""
                self.commitDescription = ""
                self.closeCommit()
                self.store?.palette.showCopied(title: "Committed", value: output.trimmingCharacters(in: .whitespacesAndNewlines))
            case .failure(let error):
                // Closed while committing: the banner says it instead.
                if self.isCommitOpen { self.commitError = Self.message(for: error) } else { self.writeError = Self.message(for: error) }
            }
        }
    }

    func dismissWriteError() {
        writeError = nil
    }

    /// A git command that changes the repository.
    private struct Write {
        let script: String
        let arguments: [String]
        let timeout: TimeInterval
        let completion: ((Result<String, Error>) -> Void)?
    }

    /// Runs commands that change the repository one at a time, so they
    /// don't race for its index, and reads it again after the last.
    private func write(_ script: String, arguments: [String], timeout: TimeInterval = 30,
                       completion: ((Result<String, Error>) -> Void)? = nil) {
        writeError = nil
        writes.append(Write(script: script, arguments: arguments, timeout: timeout, completion: completion))
        runNextWrite()
    }

    private func runNextWrite() {
        guard !isWriting, let store, !writes.isEmpty else { return }
        let write = writes.removeFirst()
        isWriting = true
        store.runGitScript(write.script, arguments: write.arguments, timeout: write.timeout) { [weak self] result in
            guard let self else { return }
            self.isWriting = false
            if let completion = write.completion {
                completion(result)
            } else if case .failure(let error) = result {
                self.writeError = Self.message(for: error)
            }
            if self.writes.isEmpty { self.refresh() } else { self.runNextWrite() }
        }
    }

    // MARK: Diff pane

    private var topIndex: Int {
        diffRows.firstIndex { $0.id == scrollRow } ?? 0
    }

    private func scrollDiff(by rows: Int) {
        guard !diffRows.isEmpty else { return }
        scrollRow = diffRows[min(max(topIndex + rows, 0), diffRows.count - 1)].id
    }

    /// Where the pane is: the file and hunk of the row at its top.
    var position: (file: Int, hunk: Int?)? {
        guard diffRows.indices.contains(topIndex) else { return nil }
        let row = diffRows[topIndex]
        return row.file.map { ($0, row.hunk) }
    }

    /// Which of the hunks shown the cursor, or the top of the pane, is in.
    var hunkPosition: (current: Int, count: Int) {
        let hunks = diffRows.indices.filter { diffRows[$0].isHunk }
        let reference = focus == .diff ? cursor?.row ?? topIndex : topIndex
        return ((hunks.lastIndex { $0 <= reference } ?? 0) + 1, hunks.count)
    }

    /// With the keys in the diff, the cursor goes to the hunk's first change.
    func jumpToHunk(forward: Bool) {
        let hunks = diffRows.indices.filter { diffRows[$0].isHunk }
        let reference = focus == .diff ? cursor?.row ?? topIndex : topIndex
        let current = hunks.last { $0 <= reference }
        let target = forward ? hunks.first { $0 > reference } : hunks.last { $0 < (focus == .diff ? current ?? reference : reference) }
        guard let target else { return }
        scrollRow = diffRows[target].id
        if focus == .diff {
            let lines = diffRows.indices.dropFirst(target + 1).prefix { !diffRows[$0].isHunk }.filter { diffRows[$0].isLine }
            place(lines.first { diffRows[$0].isChange } ?? lines.first ?? cursor?.row)
            anchor = nil
            isRangeSelecting = false
        }
    }

    /// For a single file, the next one in its list; in a commit, stash or
    /// folder, the next file's diff.
    func jumpToFile(forward: Bool) {
        if fileHeader != nil {
            if let item = neighbor(forward: forward) { select(item) }
            return
        }
        let top = topIndex
        let files = diffRows.indices.filter { if case .file = diffRows[$0].kind { true } else { false } }
        let target = forward ? files.first { $0 > top } : files.last { $0 < top }
        if let target { scrollRow = diffRows[target].id }
    }

    /// The file after or before the selected one in its list, for the
    /// end-of-file footer and `]`/`[`.
    func neighbor(forward: Bool) -> Item? {
        guard list == .changes || list == .files else { return nil }
        let files = items.filter { !$0.isFolder }
        guard let index = files.firstIndex(where: { $0.id == level.selection }) else { return nil }
        let next = index + (forward ? 1 : -1)
        return files.indices.contains(next) ? files[next] : nil
    }

    func showWholeFile() {
        guard list == .changes, case .change(let change)? = selectedItem else { return }
        wholeFiles.insert(change.path)
        loadContent(reload: true)
    }

    func copy(_ value: String, title: String, shown: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        store?.palette.showCopied(title: title, value: shown ?? value)
    }

    // MARK: Selecting

    /// The selection's two ends, the first one first.
    private var selectionBounds: (start: TextPoint, end: TextPoint)? {
        guard let cursor else { return nil }
        let anchor = anchor ?? cursor
        return anchor < cursor ? (anchor, cursor) : (cursor, anchor)
    }

    /// What of a row is selected: the whole line, as the keys select, or
    /// the characters dragged over.
    func selection(inRow row: Int) -> LineSelection? {
        guard focus == .diff, let bounds = selectionBounds, bounds.start.row <= row, row <= bounds.end.row,
              diffRows.indices.contains(row), diffRows[row].isLine else { return nil }
        guard granularity == .character else { return .whole }
        let length = line(at: row)?.shown.count ?? 0
        let lower = row == bounds.start.row ? min(bounds.start.offset, length) : 0
        // A line the selection goes past takes its line break too.
        let upper = row == bounds.end.row ? min(bounds.end.offset, length) : length + 1
        return .characters(lower..<max(lower, upper))
    }

    /// A row's line, on the selected side of a split diff.
    func line(at row: Int) -> GitDiffLine? {
        guard diffRows.indices.contains(row) else { return nil }
        switch diffRows[row].kind {
        case .line(let line): return line
        case .pair(let old, let new): return side == .old ? old : new
        default: return nil
        }
    }

    /// The mouse went down on a line. In the line numbers it selects lines;
    /// on code, a click puts the cursor there, a double click selects a
    /// word and a triple click the line. Shift extends the selection.
    func mouseDown(at location: CGPoint, row: Int, clicks: Int, extending: Bool) {
        guard let frame = lineFrames[row] else { return }
        focus = .diff
        focusKeyView()
        isRangeSelecting = false
        if extending, let cursor {
            if anchor == nil { anchor = cursor }
            self.cursor = textPoint(at: location, in: row, frame: frame) ?? TextPoint(row: row)
            press = nil
            return
        }
        side = layout == .split && location.x < frame.minX + (frame.width + 1) / 2 ? .old : .new
        let inGutter = location.x - codeLeft(in: frame) < 0
        let point = textPoint(at: location, in: row, frame: frame) ?? TextPoint(row: row)
        press = (point, location, inGutter, clicks)
        anchor = nil
        place(row)
        if clicks == 2, !inGutter, let word = word(at: textPoint(at: location, in: row, frame: frame, rounding: false) ?? point) {
            granularity = .character
            anchor = TextPoint(row: row, offset: word.lowerBound)
            cursor = TextPoint(row: row, offset: word.upperBound)
        }
    }

    /// Dragging selects code by characters from where it began, or lines
    /// from the line numbers.
    func mouseDragged(to location: CGPoint) {
        guard let press else { return }
        // A click that hasn't moved yet stays a click.
        if granularity == .line, hypot(location.x - press.location.x, location.y - press.location.y) < 3 { return }
        guard let row = lineFrames.first(where: { row, frame in
                  frame.minY <= location.y && location.y < frame.maxY && diffRows.indices.contains(row) && diffRows[row].isLine
              })?.key,
              let frame = lineFrames[row], let point = textPoint(at: location, in: row, frame: frame) else { return }
        if press.inGutter || press.clicks >= 3 {
            if anchor == nil { anchor = press.point }
            place(row)
        } else {
            if granularity == .line {
                granularity = .character
                anchor = press.point
            }
            cursor = point
        }
    }

    func mouseUp() {
        press = nil
    }

    /// Where a row's code starts, on the selected side.
    private func codeLeft(in frame: CGRect) -> CGFloat {
        (layout == .split && side == .new ? frame.minX + (frame.width + 1) / 2 : frame.minX) + textMetrics.codeX
    }

    /// The character boundary nearest `location`, or with `rounding` off,
    /// the character under it. Code is monospaced and wraps every
    /// `columns` characters.
    private func textPoint(at location: CGPoint, in row: Int, frame: CGRect, rounding: Bool = true) -> TextPoint? {
        guard let line = line(at: row) else { return nil }
        let metrics = textMetrics
        let length = line.shown.count
        let wraps = max(0, (length - 1) / metrics.columns)
        let wrap = min(max(0, Int((location.y - frame.minY) / metrics.lineHeight)), wraps)
        let x = (location.x - codeLeft(in: frame)) / metrics.charWidth
        let column = min(max(0, Int(rounding ? x.rounded() : x.rounded(.down))), metrics.columns)
        return TextPoint(row: row, offset: min(wrap * metrics.columns + column, length))
    }

    /// The word around a point: letters, digits and `_`; else the
    /// character.
    private func word(at point: TextPoint) -> Range<Int>? {
        guard let characters = line(at: point.row).map({ Array($0.shown) }), !characters.isEmpty else { return nil }
        let index = min(point.offset, characters.count - 1)
        func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }
        guard isWord(characters[index]) else { return index..<(index + 1) }
        var lower = index
        var upper = index + 1
        while lower > 0, isWord(characters[lower - 1]) { lower -= 1 }
        while upper < characters.count, isWord(characters[upper]) { upper += 1 }
        return lower..<upper
    }

    private func clearLineSelection(keepingCursor: Bool = false) {
        if keepingCursor { place(cursor?.row) } else { cursor = nil }
        anchor = nil
        granularity = .line
        isRangeSelecting = false
    }

    /// Puts the cursor on a line; the keys select whole lines.
    private func place(_ row: Int?) {
        cursor = row.map { TextPoint(row: $0) }
        granularity = .line
    }

    /// The cursor's row, unless scrolled out of sight; keys then start from
    /// the top of the pane.
    private func visibleCursor() -> Int? {
        guard let row = cursor?.row, diffRows.indices.contains(row), let frame = lineFrames[row],
              frame.maxY > 0, frame.minY < diffHeight else { return nil }
        return row
    }

    /// The first change on screen, as lazygit starts on the first change.
    private func firstLine() -> Int? {
        let lines = diffRows.indices.dropFirst(topIndex).filter { diffRows[$0].isLine }
        let onScreen = lines.prefix(max(8, Int(diffHeight / (fontSize * 1.6))))
        return onScreen.first { diffRows[$0].isChange } ?? lines.first ?? diffRows.indices.last { diffRows[$0].isLine }
    }

    private func moveCursor(by delta: Int, extending: Bool = false) {
        guard let start = visibleCursor() else {
            place(firstLine())
            anchor = nil
            isRangeSelecting = false
            return
        }
        if extending || isRangeSelecting {
            if anchor == nil || granularity == .character { anchor = TextPoint(row: start) }
        } else {
            anchor = nil
        }
        var index = start
        for _ in 0..<abs(delta) {
            guard let next = (delta > 0 ? diffRows.indices.dropFirst(index + 1).first { diffRows[$0].isLine }
                                        : diffRows.indices.prefix(index).last { diffRows[$0].isLine }) else { break }
            index = next
        }
        place(index)
    }

    /// a: the cursor's hunk, all of it.
    private func selectHunk() {
        guard let row = visibleCursor() ?? firstLine(), let hunk = diffRows[row].hunk, let file = diffRows[row].file else { return }
        let lines = diffRows.indices.filter { diffRows[$0].isLine && diffRows[$0].hunk == hunk && diffRows[$0].file == file }
        anchor = lines.first.map { TextPoint(row: $0) }
        place(lines.last)
        isRangeSelecting = false
    }

    /// y or ⌘C: the selected code, without the +/− markers; in the list,
    /// the selection's path, hash or name.
    private func copySelection() {
        guard focus == .diff else {
            switch selectedItem ?? level.owner {
            case .change(let change)?: copy(change.path, title: "Copied Path")
            case .folder(_, let path)?, .file(let path)?: copy(path, title: "Copied Path")
            case .commit(let commit)?: copy(commit.sha, title: "Copied Hash", shown: commit.shortSHA)
            case .stash(let stash)?: copy(stash.sha, title: "Copied Hash", shown: String(stash.sha.prefix(8)))
            case .branch(let branch)?: copy(branch.name, title: "Copied Branch")
            case nil: break
            }
            return
        }
        guard let text = selectedText else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        copy(text, title: granularity == .character ? "Copied Text" : lines == 1 ? "Copied Line" : "Copied \(lines) Lines",
             shown: text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text)
    }

    /// The code selected in the diff, with tabs as they are in the file.
    var selectedText: String? {
        guard let bounds = selectionBounds else { return nil }
        var lines: [String] = []
        for row in bounds.start.row...bounds.end.row {
            guard let line = line(at: row), line.kind != .note else { continue }
            switch selection(inRow: row) {
            case .whole?: lines.append(line.text)
            case .characters(let range)?: lines.append(line.text(in: range.lowerBound..<min(range.upperBound, line.shown.count)))
            case nil: continue
            }
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: Diff rows

    private func rebuildDiffRows(keepingPosition: Bool) {
        let kept = keepingPosition ? position : nil
        let scope = scope
        shownScope = scope
        guard let content else {
            diffRows = []
            fileHeader = nil
            clearLineSelection()
            return
        }
        let wholeFile: Bool
        switch content.header {
        case .change(let change):
            wholeFile = wholeFiles.contains(change.path)
            fileHeader = FileHeader(path: change.path, files: content.patch.files, change: change)
        default:
            wholeFile = false
            if case .file(let path) = scope {
                fileHeader = FileHeader(path: path, files: content.patch.files.filter { $0.path == path }, change: nil)
            } else {
                fileHeader = nil
            }
        }
        diffRows = Self.diffRows(for: content, layout: layout, wholeFile: wholeFile, scope: scope)
        if !keepingPosition || cursor.map({ !diffRows.indices.contains($0.row) || !diffRows[$0.row].isLine }) == true {
            clearLineSelection()
        }
        if let kept, let row = diffRows.first(where: { $0.file == kept.file && $0.hunk == kept.hunk }) {
            scrollRow = row.id
        } else {
            scrollRow = diffRows.first?.id
        }
        if let keptCursor, keptCursor.item == contentItem?.id, !diffRows.isEmpty {
            self.keptCursor = nil
            let lines = diffRows.indices.filter { diffRows[$0].isLine }
            clearLineSelection()
            place(lines.first { $0 >= keptCursor.row && diffRows[$0].isChange } ?? lines.last { $0 < keptCursor.row } ?? lines.first)
            scrollRow = diffRows[min(keptCursor.top, diffRows.count - 1)].id
        }
        if focus == .diff, cursor == nil { place(firstLine()) }
    }

    static func diffRows(for content: Content, layout: Layout, wholeFile: Bool = false, scope: Scope = .all) -> [DiffRow] {
        var rows: [DiffRow] = []
        func add(_ kind: DiffRow.Kind, file: Int? = nil, hunk: Int? = nil, lines: [Int] = []) {
            rows.append(DiffRow(id: rows.count, kind: kind, file: file, hunk: hunk, lines: lines))
        }
        let isChange = if case .change = content.header { true } else { false }
        let isSingleFile = isChange || { if case .file = scope { true } else { false } }()
        if !isSingleFile, scope == .all { add(.card) }
        if case .branch = content.header { return rows }
        if case .comparison(_, nil) = content.header { return rows }
        if let error = content.error {
            add(.message(error))
            return rows
        }
        let files = content.patch.files.filter { scope.contains($0.path) }
        if files.isEmpty { add(.message("No changes")) }
        let groups = Set(files.compactMap(\.group))
        for file in files {
            if !isSingleFile {
                add(.file(file.id), file: file.id)
            } else if groups.count > 1, let group = file.group {
                add(.part(group), file: file.id)
            }
            if file.isBinary, file.hunks.isEmpty { add(.binary, file: file.id) }
            for (index, hunk) in file.hunks.enumerated() {
                add(.hunk(file: file.id, hunk: index), file: file.id, hunk: index)
                switch layout {
                case .unified:
                    for (line, text) in hunk.lines.enumerated() { add(.line(text), file: file.id, hunk: index, lines: [line]) }
                case .split:
                    for pair in hunk.pairIndices {
                        add(.pair(old: pair.old.map { hunk.lines[$0] }, new: pair.new.map { hunk.lines[$0] }),
                            file: file.id, hunk: index, lines: [pair.old, pair.new].compactMap { $0 })
                    }
                }
            }
        }
        if isSingleFile, !files.isEmpty {
            let canExpand = files.contains { !$0.hunks.isEmpty && $0.change != .added && $0.change != .deleted }
            if isChange, !wholeFile, canExpand { add(.wholeFile) }
            add(.endOfFile)
        }
        if content.patch.omittedLines > 0 { add(.omitted(content.patch.omittedLines)) }
        return rows
    }

    // MARK: Loading

    /// Reads the repository again: on opening, with R, every 10 seconds
    /// and when Muxify comes to the front. Each list keeps its selection.
    func refresh(showingProgress: Bool = false) {
        guard isOpen, let store else { return }
        snapshotGeneration += 1
        let generation = snapshotGeneration
        if showingProgress { isReading = true }
        store.runGitScript(GitRepository.snapshotScript, arguments: [folder]) { [weak self] result in
            guard let self, self.isOpen, self.snapshotGeneration == generation else { return }
            self.isReading = false
            switch result.flatMap({ GitRepository.parseSnapshot($0).mapError { $0 as Error } }) {
            case .success(let snapshot):
                self.apply(snapshot)
            case .failure(let error):
                self.snapshot = nil
                self.content = nil
                self.diffRows = []
                self.fileHeader = nil
                self.error = Self.message(for: error)
            }
        }
    }

    /// Shows a read of the repository. Each list keeps its selection, else
    /// selects what's now where it was; a list whose branch or stash is
    /// gone closes.
    func apply(_ next: GitSnapshot) {
        let previous = levels.mapValues { $0.map { items(for: $0).map(\.id) } }
        error = nil
        // A message written for one repository is never committed to
        // another, as when the Window's folder is now in another one.
        if let messageRoot, messageRoot != next.root {
            commitSummary = ""
            commitDescription = ""
        }
        messageRoot = next.root
        if snapshot != next { snapshot = next }
        // A branch moved: the comparison follows it. One gone is compared
        // at the commit it was at.
        if let base { self.base = refreshed(base) ?? base }
        for (tab, stack) in levels {
            levels[tab] = refreshed(stack, previous: previous[tab] ?? [])
        }
        // Changes, where it opens, are on a file whenever there is one.
        if let changes = levels[.changes]?.first, changes.selection == nil,
           let change = items(for: changes).first(where: { !$0.isFolder }) {
            levels[.changes]?[0].selection = change.id
        }
        readBranchLog()
        loadContent(reload: true)
    }

    /// A tab's lists after a read: those gone into on what was just read,
    /// and each selection kept, else the item now where it was.
    private func refreshed(_ stack: [Level], previous: [[String]]) -> [Level] {
        var stack = stack
        for index in stack.indices.dropFirst() {
            guard let owner = stack[index].owner.flatMap(refreshed) else {
                stack.removeSubrange(index...)
                break
            }
            stack[index].owner = owner
        }
        // The Diff files are read with their owner's diff, not here.
        for index in stack.indices where stack[index].list != .files {
            guard let id = stack[index].selection, selectedItem(for: stack[index]) == nil else { continue }
            stack[index].selection = Self.neighbor(of: id, previous: previous.indices.contains(index) ? previous[index] : [],
                                                   items: items(for: stack[index]))
        }
        return stack
    }

    /// The item now where `id` was.
    private static func neighbor(of id: String, previous: [String], items: [Item]) -> String? {
        guard let old = previous.firstIndex(of: id), !items.isEmpty else { return nil }
        return items[min(old, items.count - 1)].id
    }

    /// Reads the history of the branch selected in Branches or gone into,
    /// unless it's read at the commit the branch is at.
    private func readBranchLog() {
        let item = list == .branch ? level.owner : list == .branches ? selectedItem : nil
        guard case .branch(let branch)? = item, !branch.isHead, branchLogs[branch.name]?.sha != branch.sha,
              readingLog != "\(branch.name) \(branch.sha)" else { return }
        logWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.runLog(of: branch) }
        }
        logWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func runLog(of branch: GitBranch) {
        guard let store, let root = snapshot?.root else { return }
        readingLog = "\(branch.name) \(branch.sha)"
        store.runGitScript(GitRepository.logScript, arguments: [root, branch.name]) { [weak self] result in
            guard let self, self.isOpen else { return }
            switch result {
            case .success(let output): self.didRead(GitRepository.parseLog(output), of: branch)
            case .failure(let error): self.didRead(GitLog(error: Self.message(for: error)), of: branch)
            }
        }
    }

    /// A branch's history was read: its card lists it, and its commits keep
    /// their selection, else select the commit now where it was, or the
    /// first.
    private func didRead(_ log: GitLog, of branch: GitBranch) {
        if readingLog == "\(branch.name) \(branch.sha)" { readingLog = nil }
        let previous = levels[.branches].flatMap { $0.count > 1 ? items(for: $0[1]).map(\.id) : nil } ?? []
        // Bounded, as the outputs are.
        if branchLogs.count >= 50 { branchLogs.removeAll() }
        branchLogs[branch.name] = (branch.sha, log)
        if var stack = levels[.branches], stack.count > 1, case .branch(let owner)? = stack[1].owner, owner.name == branch.name {
            let items = items(for: stack[1])
            if let id = stack[1].selection, selectedItem(for: stack[1]) == nil {
                stack[1].selection = Self.neighbor(of: id, previous: previous, items: items)
            }
            if stack[1].selection == nil { stack[1].selection = items.first?.id }
            levels[.branches] = stack
        }
        if tab == .branches { showSelection() }
    }

    /// The owner as just read, or nil when it's gone.
    private func refreshed(_ item: Item) -> Item? {
        guard let snapshot else { return nil }
        switch item {
        case .commit(let commit): return snapshot.commits.first { $0.sha == commit.sha }.map(Item.commit) ?? item
        case .stash(let stash): return snapshot.stashes.first { $0.sha == stash.sha }.map(Item.stash)
        case .branch(let branch): return snapshot.branches.first { $0.name == branch.name }.map(Item.branch)
        default: return nil
        }
    }

    /// Shows the selection: reads a new diff, or shows another part of the
    /// one read.
    private func showSelection() {
        readBranchLog()
        loadContent()
        if let content, content.id == request()?.id, shownScope != scope {
            clearLineSelection()
            rebuildDiffRows(keepingPosition: false)
        }
    }

    /// Reads the diff soon, so holding j doesn't start a git process per
    /// row.
    private func loadContent(reload: Bool = false) {
        contentWork?.cancel()
        guard let request = request() else {
            loadingID = nil
            content = nil
            diffRows = []
            fileHeader = nil
            clearLineSelection()
            return
        }
        if !reload, content?.id == request.id { return }
        if let output = fixedOutputs[request.id] ?? request.localOutput {
            show(output, for: request)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.run(request) }
        }
        contentWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (reload ? 0 : 0.06), execute: work)
    }

    private func run(_ request: Request) {
        guard let store else { return }
        loadingID = request.id
        store.runGitScript(request.script, arguments: request.arguments) { [weak self] result in
            guard let self, self.isOpen, self.loadingID == request.id else { return }
            self.loadingID = nil
            switch result {
            case .success(let output):
                if request.isFixed {
                    // Bounded: a few big diffs shouldn't stay for the App Window's life.
                    if self.fixedOutputs.count >= 100 { self.fixedOutputs.removeAll() }
                    self.fixedOutputs[request.id] = output
                }
                self.show(output, for: request)
            case .failure(let error):
                self.show(output: "", error: Self.message(for: error), for: request)
            }
        }
    }

    private func show(_ output: String, for request: Request) {
        show(output: output, error: nil, for: request)
    }

    /// Parses and highlights off the main thread; a big patch takes a
    /// moment. Reading the same output again keeps the pane where it is.
    private func show(output: String, error: String?, for request: Request) {
        let theme = store?.theme
        if let content, content.id == request.id, content.output == output, content.theme == theme, content.error == error { return }
        let highlighter = GitHighlighter(colors: colors, fontSize: fontSize)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var header = request.header
            var patch: GitPatch
            switch header {
            case .change, .folder:
                patch = GitPatch.joined(GitRepository.parseParts(output).map { ($0.group, GitPatch.parse($0.patch)) })
            case .commit(let commit, _):
                let parsed = GitRepository.parseCommitDetail(output)
                header = .commit(commit, parsed.detail)
                patch = GitPatch.parse(parsed.patch)
            default:
                patch = GitPatch.parse(output)
            }
            highlighter.highlight(&patch)
            let content = Content(id: request.id, header: header, output: output, patch: patch, theme: theme, error: error)
            DispatchQueue.main.async {
                guard let self, self.isOpen, self.request()?.id == request.id else { return }
                let isSame = self.content?.id == content.id
                self.content = content
                if self.wantsFirstFile, self.list == .files, self.level.selection == nil {
                    let first = self.items.first { !$0.isFolder }
                    self.updateLevel { $0.selection = first?.id }
                }
                self.wantsFirstFile = false
                self.rebuildDiffRows(keepingPosition: isSame)
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let error as GitViewError: return error.message
        case TmuxError.failed(_, let stderr): return stderr.isEmpty ? "git failed." : stderr
        case TmuxError.timedOut: return "git took too long to answer."
        default: return String(describing: error)
        }
    }

    /// A git command whose output the diff pane shows.
    struct Request {
        let id: String
        let header: Content.Header
        var script = ""
        var arguments: [String] = []
        /// Commits and stashes, which never change; the rest is read again
        /// on every refresh.
        var isFixed = false
        /// Shown without running git.
        var localOutput: String?
    }

    func request() -> Request? {
        contentItem.flatMap(request(for:))
    }

    func request(for item: Item) -> Request? {
        guard let snapshot else { return nil }
        let root = snapshot.root
        // W: a commit, branch or stash shows the diff from the base, at the
        // commits they are at now, so the output of two is kept.
        if let base, let from = base.sha, let to = item.sha {
            guard item.id != base.id else {
                return Request(id: "base:\(base.id)@\(from)", header: .comparison(base: base, target: nil), localOutput: "")
            }
            return Request(id: "compare:\(base.id)@\(from) \(item.id)@\(to)", header: .comparison(base: base, target: item),
                           script: GitRepository.gitScript,
                           arguments: [root, "diff", "--no-color", "--no-ext-diff", "-M", from, to, "--"], isFixed: true)
        }
        switch item {
        case .change(let change):
            let whole = wholeFiles.contains(change.path)
            return Request(id: "\(item.id):\(change.status)\(whole ? ":whole" : "")", header: .change(change),
                           script: GitRepository.changeScript,
                           arguments: [root, change.path, change.originalPath ?? "", whole ? "100000" : "3",
                                       change.groups.map(\.rawValue).joined(separator: " ")])
        case .folder(_, let path):
            let changes = snapshot.changes.filter { GitTree.path($0.path, isIn: path) }
            let groups = GitChange.Group.allCases.filter { group in changes.contains { $0.groups.contains(group) } }
            let names = groups.map(\.rawValue).joined(separator: " ")
            return Request(id: "\(item.id):\(names)", header: .folder(path, changes), script: GitRepository.changeScript,
                           arguments: [root, path, "", "3", names])
        case .branch(let branch):
            // Its card: the latest commits, read with its history.
            let log = log(of: branch)
            return Request(id: "\(item.id):\(log?.commits.first?.sha ?? log?.error ?? "reading")", header: .branch(branch, log),
                           localOutput: "")
        case .commit(let commit):
            return Request(id: item.id, header: .commit(commit, nil), script: GitRepository.commitScript,
                           arguments: [root, commit.sha], isFixed: true)
        case .stash(let stash):
            return Request(id: item.id, header: .stash(stash), script: GitRepository.gitScript,
                           arguments: [root, "stash", "show", "--patch", "--no-color", "--no-ext-diff", "-M", stash.sha],
                           isFixed: true)
        case .file:
            return nil
        }
    }

    // MARK: Screenshots

    #if DEBUG
    /// Drives an instance without keystrokes, for screenshots of a build in
    /// the background. WorkspaceStore hands it the `spec` of a `dev.muxify.git`
    /// notification, such as "open=1;keys=3 enter j;diff=1", "layout=split",
    /// "filter=git", "shot=/tmp/a.png", or "close=1".
    func applyDemo(_ fields: [String: String]) {
        if fields["close"] != nil { close(); return }
        if fields["open"] != nil, !isOpen { open() }
        if let layout = fields["layout"].flatMap(Layout.init(rawValue:)) { self.layout = layout }
        if let filter = fields["filter"] { self.filter = filter }
        // Key spellings, as in the config: "4 j j enter shift+down".
        for name in (fields["keys"] ?? "").split(separator: " ") {
            if let trigger = try? KeyTrigger(String(name)), let command = Self.commands[trigger], command != .copy { perform(command) }
        }
        if fields["diff"] != nil { setFocus(.diff) }
        if let lines = fields["scroll"].flatMap(Int.init) { scrollDiff(by: lines) }
        // `drag=2:4-3:10` drags from the 3rd line's 5th character to the
        // 4th line's 11th; `word=2:6` double-clicks; `copyto=<path>` saves
        // what ⌘C would copy.
        func point(_ spec: Substring) -> (row: Int, location: CGPoint)? {
            let numbers = spec.split(separator: ":").compactMap { Int($0) }
            let lines = diffRows.indices.filter { diffRows[$0].isLine }
            guard numbers.count == 2, lines.indices.contains(numbers[0]), let frame = lineFrames[lines[numbers[0]]] else { return nil }
            let wrap = numbers[1] / textMetrics.columns
            let left = layout == .split ? frame.minX + (frame.width + 1) / 2 : frame.minX
            let x = left + textMetrics.codeX + (CGFloat(numbers[1] % textMetrics.columns) + 0.3) * textMetrics.charWidth
            return (lines[numbers[0]], CGPoint(x: x, y: frame.minY + (CGFloat(wrap) + 0.5) * textMetrics.lineHeight))
        }
        if let ends = fields["drag"]?.split(separator: "-"), ends.count == 2, let from = point(ends[0]), let to = point(ends[1]) {
            mouseDown(at: from.location, row: from.row, clicks: 1, extending: false)
            mouseDragged(to: to.location)
            mouseUp()
        }
        if let word = fields["word"].flatMap({ point(Substring($0)) }) {
            mouseDown(at: word.location, row: word.row, clicks: 2, extending: false)
            mouseUp()
        }
        if let path = fields["copyto"] { try? (selectedText ?? "").write(toFile: path, atomically: true, encoding: .utf8) }
        // `summary=<text>` and `description=<text>` type a commit message
        // (`\n` for a new line); `commitnow=1` commits it.
        if let summary = fields["summary"] { commitSummary = summary }
        if let description = fields["description"] { commitDescription = description.replacingOccurrences(of: "\\n", with: "\n") }
        if fields["commitnow"] != nil { commit() }
        // `discardnow=1` picks the Discard changes menu's highlighted option.
        if fields["discardnow"] != nil, let discard { confirmDiscard(discard.option) }
        // `shot=<path>` saves the App Window as drawn, for shells that
        // aren't allowed to record the screen.
        if let path = fields["shot"], let view = store?.terminalHost.window?.contentView,
           let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif
}
