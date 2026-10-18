import AppKit
import Observation
import MuxifyCore

/// A panel of the Git View's sidebar. They are stacked as in lazygit, and
/// tab goes from one to the next.
enum GitPanel: String, CaseIterable {
    case changes, history, stashes
    /// The files of the selected commit, stash or branch.
    case files

    var title: String {
        switch self {
        case .changes: "Changes"
        case .history: "History"
        case .stashes: "Stashes"
        case .files: "Diff files"
        }
    }

    var symbol: String {
        switch self {
        case .changes: "plusminus"
        case .history: "clock"
        case .stashes: "archivebox"
        case .files: "doc.on.doc"
        }
    }

    /// lazygit's number for the panel. 3, its branches, opens the branch
    /// menu, and 1 shows the current branch.
    var key: Int? {
        switch self {
        case .changes: 2
        case .history: 4
        case .stashes: 5
        case .files: nil
        }
    }
}

/// The Git View of one App Window (CONTEXT.md): a read-only look at the
/// repository in the current Window's folder, as a navigator. Panels of
/// changed files, commits, stashes and the selected commit's files, and the
/// selection's diff beside them.
@MainActor @Observable
final class GitView {
    /// Something in a panel, or a branch from the toolbar.
    enum Item: Equatable, Identifiable {
        case change(GitChange)
        /// A folder of the Changes tree or of the Diff files.
        case folder(GitPanel, String)
        case commit(GitCommit)
        case stash(GitStash)
        case branch(GitBranch)
        /// A file of the Diff files, by path.
        case file(String)

        var id: String {
            switch self {
            case .change(let change): "change:\(change.path)"
            case .folder(let panel, let path): "folder:\(panel.rawValue):\(path)"
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
    }

    /// A row of a panel as shown.
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

    enum Focus { case list, diff }

    enum Layout: String { case unified, split }

    /// The side of a split diff whose lines are selected.
    enum Side { case old, new }

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
            /// A branch against `base`, with the commits it has that `base`
            /// doesn't. No base: the branch you're on, and nothing to compare.
            case branch(GitBranch, base: String?, commits: [GitCommit])
            case stash(GitStash)
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
            /// The commit, branch, stash or folder card.
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
        case status, branches, panel(GitPanel)
        case down, up, top, bottom
        case nextPanel, previousPanel, enter, focusDiff, focusList
        case scroll(lines: Int), halfPage(Int)
        case nextHunk, previousHunk, nextFile, previousFile
        case extend(Int), range, hunk, copy
        case toggleFolder, collapseAll, expandAll
        case filter, back, close, refresh
    }

    private(set) var isOpen = false
    /// The Window's folder, which may be anywhere in the repository.
    private(set) var folder = ""
    private(set) var snapshot: GitSnapshot?
    private(set) var error: String?
    /// Reading on opening or after R, when the toolbar shows a spinner.
    private(set) var isReading = false
    /// The panel the keys move in, whose selection the diff pane shows.
    private(set) var panel = GitPanel.changes
    private(set) var focus = Focus.list
    /// Each panel's selection by item id, kept while another panel has the
    /// keys, as in lazygit. None in Diff files shows all of them.
    private(set) var selections: [GitPanel: String] = [:]
    /// The commit, stash or branch the Diff files are the files of.
    private(set) var owner: Item?
    /// Folded folders of the Changes tree and of the Diff files.
    private(set) var collapsedFolders: [GitPanel: Set<String>] = [:]
    var filter = "" {
        didSet { if filter != oldValue { keepSelectionVisible() } }
    }
    /// The filter field has keyboard focus; the view keeps it current.
    var isFiltering = false
    /// Asks the view to put keyboard focus in the filter field.
    var wantsFilterFocus = false
    /// Asks the toolbar to open its branch menu.
    var wantsBranches = false
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
    /// The selected diff lines, as `diffRows` indexes: the line the keys
    /// move, and the other end of a range.
    private(set) var cursor: Int?
    private(set) var anchor: Int?
    private(set) var side = Side.new
    /// The diff row at the top of the pane; the view scrolls to it.
    var scrollRow: Int?
    /// The diff's scroll view, for paging and for finding the lines on it.
    @ObservationIgnored var diffHeight: CGFloat = 600
    @ObservationIgnored var diffWidth: CGFloat = 800
    /// Where the diff lines on screen are, in the scroll view.
    @ObservationIgnored var lineFrames: [Int: CGRect] = [:]

    @ObservationIgnored weak var store: WorkspaceStore?
    /// Holds keyboard focus while the Git View has it (see `GitKeyCatcher`).
    @ObservationIgnored weak var keyView: NSView?
    /// The tmux Window it opened for; selecting another one closes it.
    @ObservationIgnored private(set) var windowID: String?
    @ObservationIgnored private var previousResponder: NSResponder?
    @ObservationIgnored private var wantsFocus = false
    @ObservationIgnored private var snapshotGeneration = 0
    @ObservationIgnored private var contentWork: DispatchWorkItem?
    @ObservationIgnored private var loadingID: String?
    @ObservationIgnored private var shownScope = Scope.all
    /// v: moving the cursor extends the range, as in lazygit.
    @ObservationIgnored private var isRangeSelecting = false
    /// Entering Diff files before they were read: select the first once
    /// they are.
    @ObservationIgnored private var wantsFirstFile = false
    /// Changes shown with all of their lines.
    @ObservationIgnored private var wholeFiles = Set<String>()
    /// Commits and stashes don't change, so their output is kept.
    @ObservationIgnored private var fixedOutputs: [String: String] = [:]
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var activationObserver: Any?
    #if DEBUG
    @ObservationIgnored private var demoObserver: NSObjectProtocol?
    #endif

    /// The terminal's size; code is in the system's monospaced font.
    var fontSize: CGFloat { max(11, (GhosttyRuntime.shared.fontSize ?? 13) - 1) }
    var colors: GitColors { GitColors(store?.theme) }

    init() {
        #if DEBUG
        observeDemoRequests()
        #endif
    }

    // MARK: Opening and closing

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// Opens on the current Window's folder, where it was left when that is
    /// the folder it last showed.
    func open() {
        guard !isOpen, let store, let window = store.selectedWindow else { return }
        previousResponder = store.terminalHost.window?.firstResponder
        windowID = window.id
        if folder != window.path {
            folder = window.path
            snapshot = nil
            error = nil
            content = nil
            diffRows = []
            fileHeader = nil
            selections = [:]
            owner = nil
            panel = .changes
            collapsedFolders = [:]
            filter = ""
            focus = .list
            wholeFiles = []
            clearLineSelection()
        }
        isOpen = true
        wantsFocus = true
        DispatchQueue.main.async { [weak self] in self?.focusKeyView() }
        refresh(showingProgress: true)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func close(restoringFocus: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        isFiltering = false
        wantsBranches = false
        windowID = nil
        wantsFocus = false
        contentWork?.cancel()
        loadingID = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        let responder = previousResponder
        previousResponder = nil
        guard restoringFocus, let store else { return }
        DispatchQueue.main.async { [weak store] in
            guard let store else { return }
            if let responder, responder !== self.keyView,
               let window = store.terminalHost.window, window.makeFirstResponder(responder) { return }
            store.focusTerminal()
        }
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
        guard isOpen, let keyView, let window = keyView.window else { return }
        wantsFocus = false
        if !hasKeyFocus(in: window) { window.makeFirstResponder(keyView) }
    }

    /// The key view is in a window only once SwiftUI has shown the Git View.
    func keyViewDidAppear() {
        if wantsFocus { focusKeyView() }
    }

    func setFocus(_ focus: Focus) {
        if focus == .diff, visibleCursor() == nil {
            cursor = firstLine()
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

    // MARK: Panels

    /// The panels as shown, top to bottom. The Diff files go right under
    /// the commit's or stash's panel, or on top for a branch.
    var panels: [GitPanel] {
        switch owner {
        case .commit?: [.changes, .history, .files, .stashes]
        case .stash?: [.changes, .history, .stashes, .files]
        case .branch?: [.files, .changes, .history, .stashes]
        default: [.changes, .history, .stashes]
        }
    }

    /// A panel's rows: the Changes and Diff files as trees, and the History
    /// with its graph. A filter shows the matches with their folders open.
    func rows(in panel: GitPanel) -> [Row] {
        guard let snapshot else { return [] }
        let words = filter.lowercased().split(separator: " ").map(String.init)
        func matches(_ item: Item) -> Bool {
            words.isEmpty || words.allSatisfy(item.text.lowercased().contains)
        }
        func note(_ text: String) -> [Row] { [Row(text: text)] }
        switch panel {
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
            return tree(changes.map(\.path), in: .changes, folding: words.isEmpty) { index in
                Row(item: .change(changes[index]), isStaged: changes[index].isStaged)
            } folder: { path in
                !unstaged.contains(path)
            }
        case .history:
            let rows = snapshot.commits.indices.compactMap { index -> Row? in
                let commit = snapshot.commits[index]
                guard matches(.commit(commit)) else { return nil }
                return Row(item: .commit(commit), graph: words.isEmpty && snapshot.graph.indices.contains(index) ? snapshot.graph[index] : nil)
            }
            return rows.isEmpty ? note(snapshot.commits.isEmpty ? "No commits yet" : "No matches") : rows
        case .stashes:
            let rows = snapshot.stashes.map(Item.stash).filter(matches).map { Row(item: $0) }
            return rows.isEmpty ? note(snapshot.stashes.isEmpty ? "No stashes" : "No matches") : rows
        case .files:
            guard owner != nil else { return [] }
            if let content, content.id == request()?.id, content.error != nil { return note("Could not read the files") }
            guard let files = ownerFiles else { return note("Reading…") }
            let shown = files.filter { matches(.file($0.path)) }
            guard !shown.isEmpty else { return note(files.isEmpty ? "No changes" : "No matches") }
            return tree(shown.map(\.path), in: .files, folding: words.isEmpty) { index in
                Row(item: .file(shown[index].path))
            } folder: { _ in false }
        }
    }

    /// How many files, commits or stashes a panel has, folded or not; with
    /// a filter, how many match.
    func count(in panel: GitPanel) -> Int {
        guard let snapshot else { return 0 }
        let words = filter.lowercased().split(separator: " ").map(String.init)
        func matches(_ item: Item) -> Bool {
            words.isEmpty || words.allSatisfy(item.text.lowercased().contains)
        }
        switch panel {
        case .changes: return snapshot.changes.filter { matches(.change($0)) }.count
        case .history: return snapshot.commits.filter { matches(.commit($0)) }.count
        case .stashes: return snapshot.stashes.filter { matches(.stash($0)) }.count
        case .files: return ownerFiles?.filter { matches(.file($0.path)) }.count ?? 0
        }
    }

    private func tree(_ paths: [String], in panel: GitPanel, folding: Bool, file: (Int) -> Row,
                      folder isStaged: (String) -> Bool) -> [Row] {
        GitTree.nodes(paths, collapsed: folding ? collapsedFolders[panel] ?? [] : []).map { node in
            var row = node.file.map(file) ?? Row(item: .folder(panel, node.path), text: node.name, isStaged: isStaged(node.path))
            row.depth = node.depth
            return row
        }
    }

    /// The items the selection moves through, in order.
    func items(in panel: GitPanel) -> [Item] {
        rows(in: panel).compactMap(\.item)
    }

    /// A panel's selection, also when a folded folder or the filter hides it.
    func selectedItem(in panel: GitPanel) -> Item? {
        guard let id = selections[panel], let snapshot else { return nil }
        switch panel {
        case .changes:
            if let change = snapshot.changes.first(where: { Item.change($0).id == id }) { return .change(change) }
            let path = String(id.dropFirst("folder:changes:".count))
            return id.hasPrefix("folder:changes:") && snapshot.changes.contains { GitTree.path($0.path, isIn: path) }
                ? .folder(.changes, path) : nil
        case .history:
            return snapshot.commits.first { Item.commit($0).id == id }.map(Item.commit)
        case .stashes:
            return snapshot.stashes.first { Item.stash($0).id == id }.map(Item.stash)
        case .files:
            guard let files = ownerFiles else { return nil }
            if let file = files.first(where: { Item.file($0.path).id == id }) { return .file(file.path) }
            let path = String(id.dropFirst("folder:files:".count))
            return id.hasPrefix("folder:files:") && files.contains { GitTree.path($0.path, isIn: path) } ? .folder(.files, path) : nil
        }
    }

    /// The Diff files, once the owner's diff has been read.
    var ownerFiles: [GitPatchFile]? {
        guard owner != nil, let content, content.error == nil, content.id == request()?.id else { return nil }
        return content.patch.files
    }

    /// What the diff pane shows the diff of: the change or folder in
    /// Changes, else what the Diff files are of.
    var contentItem: Item? {
        panel == .changes ? selectedItem(in: .changes) : owner
    }

    var scope: Scope {
        guard panel == .files else { return .all }
        switch selectedItem(in: .files) {
        case .file(let path)?: return .file(path)
        case .folder(_, let path)?: return .folder(path)
        default: return .all
        }
    }

    /// A click on a row.
    func select(_ item: Item, in panel: GitPanel) {
        focus = .list
        choose(item, in: panel)
        focusKeyView()
    }

    /// A branch from the toolbar's menu, or 1 for the current one: what it
    /// changes against main or the current branch, with its Diff files.
    func select(_ branch: GitBranch) {
        focus = .list
        setOwner(.branch(branch))
        panel = .files
        showSelection()
        focusKeyView()
    }

    /// Gives `panel` the keys, on what it had selected, else its first item.
    func activate(_ panel: GitPanel) {
        focus = .list
        let items = items(in: panel)
        let kept = items.first { $0.id == selections[panel] }
        if panel == .files {
            // Into a commit's files, as enter in lazygit: on its first file.
            let first = items.first { !$0.isFolder }
            wantsFirstFile = kept == nil && first == nil
            choose(kept ?? first, in: .files)
        } else {
            choose(kept ?? items.first { !$0.isFolder } ?? items.first, in: panel)
        }
        focusKeyView()
    }

    private func canActivate(_ panel: GitPanel) -> Bool {
        panel == .files ? owner != nil : !items(in: panel).isEmpty
    }

    /// Tab: the next panel down that has something in it, round to the top.
    private func cycle(_ step: Int) {
        let panels = panels
        let start = panels.firstIndex(of: panel) ?? 0
        for offset in 1..<panels.count {
            let next = panels[((start + step * offset) % panels.count + panels.count) % panels.count]
            if canActivate(next) {
                activate(next)
                return
            }
        }
    }

    /// Selects without moving keyboard focus. Changes have no Diff files;
    /// a commit or stash has its own.
    private func choose(_ item: Item?, in panel: GitPanel) {
        self.panel = panel
        selections[panel] = item?.id
        switch panel {
        case .changes: setOwner(nil)
        case .history, .stashes: setOwner(item)
        case .files: break
        }
        showSelection()
    }

    private func setOwner(_ item: Item?) {
        if owner?.id != item?.id { selections[.files] = nil }
        owner = item
    }

    private func move(by delta: Int) {
        let items = items(in: panel)
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selections[panel] } ?? (delta > 0 ? -1 : items.count)
        let next = min(max(current + delta, 0), items.count - 1)
        guard items[next].id != selections[panel] else { return }
        choose(items[next], in: panel)
    }

    /// Esc from the Diff files: back to the commit or stash.
    private func leaveFiles() {
        switch owner {
        case .commit?: choose(owner, in: .history)
        case .stash?: choose(owner, in: .stashes)
        default: activate(.changes)
        }
    }

    func toggleFolder(_ path: String, in panel: GitPanel) {
        var folded = collapsedFolders[panel] ?? []
        if folded.remove(path) == nil { folded.insert(path) }
        collapsedFolders[panel] = folded
    }

    /// `-` folds every folder of the panel, `=` opens them, as in lazygit.
    private func foldAll(_ folding: Bool) {
        guard panel == .changes || panel == .files else { return }
        guard folding else {
            collapsedFolders[panel] = []
            return
        }
        let paths = panel == .changes ? snapshot?.changes.map(\.path) ?? [] : ownerFiles?.map(\.path) ?? []
        collapsedFolders[panel] = Set(GitTree.nodes(paths).filter { $0.file == nil }.map(\.path))
        // A file now folded away: select its top folder.
        if let id = selections[panel], !items(in: panel).contains(where: { $0.id == id }),
           let top = items(in: panel).first(where: { item in
               guard case .folder(_, let path) = item else { return false }
               return id.hasSuffix(":" + path) || id.contains(":\(path)/")
           }) {
            choose(top, in: panel)
        }
    }

    /// A filter can take the selection away; select the first match.
    private func keepSelectionVisible() {
        guard !filter.isEmpty else { return }
        let items = items(in: panel)
        guard !items.isEmpty, !items.contains(where: { $0.id == selections[panel] }) else { return }
        choose(items.first { !$0.isFolder } ?? items[0], in: panel)
    }

    // MARK: Keys

    /// Sees each key in the App Window before Muxify's keybinds while the
    /// Git View or its filter field has focus. Keys it doesn't use, such as
    /// ⌘B, go on to them.
    func handle(_ trigger: KeyTrigger, in event: NSEvent) -> Bool {
        guard isOpen else { return false }
        if isFiltering, event.window === keyView?.window {
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
        guard hasKeyFocus(in: event.window), let command = Self.commands[trigger] else { return false }
        perform(command)
        return true
    }

    private static let escape = try! KeyTrigger("escape")
    private static let enter = try! KeyTrigger("enter")
    private static let down = try! KeyTrigger("down")
    private static let up = try! KeyTrigger("up")
    private static let ctrlJ = try! KeyTrigger("ctrl+j")
    private static let ctrlK = try! KeyTrigger("ctrl+k")

    static let commands: [KeyTrigger: Command] = {
        let spelling: KeyValuePairs<String, Command> = [
            "1": .status, "2": .panel(.changes), "3": .branches, "4": .panel(.history), "5": .panel(.stashes),
            "j": .down, "down": .down, "k": .up, "up": .up, "shift+comma": .top, "shift+period": .bottom,
            "tab": .nextPanel, "shift+tab": .previousPanel, "enter": .enter,
            "l": .focusDiff, "right": .focusDiff, "h": .focusList, "left": .focusList,
            "shift+j": .scroll(lines: 3), "shift+k": .scroll(lines: -3), "ctrl+d": .halfPage(1), "ctrl+u": .halfPage(-1),
            "alt+down": .nextHunk, "alt+up": .previousHunk, "right_bracket": .nextFile, "left_bracket": .previousFile,
            "shift+down": .extend(1), "shift+up": .extend(-1), "v": .range, "a": .hunk, "y": .copy, "cmd+c": .copy,
            "space": .toggleFolder, "minus": .collapseAll, "equal": .expandAll,
            "slash": .filter, "escape": .back, "q": .close, "shift+r": .refresh,
        ]
        return Dictionary(uniqueKeysWithValues: spelling.map { (try! KeyTrigger($0), $1) })
    }()

    func perform(_ command: Command) {
        switch command {
        case .status:
            if let head = snapshot?.branches.first(where: \.isHead) { select(head) }
        case .branches:
            wantsBranches = true
        case .panel(let panel):
            activate(panel)
        case .down, .up:
            let delta = command == .down ? 1 : -1
            if focus == .diff { moveCursor(by: delta) } else { move(by: delta) }
        case .top, .bottom:
            if focus == .diff {
                let lines = diffRows.indices.filter { diffRows[$0].isLine }
                cursor = command == .top ? lines.first : lines.last
                anchor = isRangeSelecting ? anchor : nil
                scrollRow = command == .top ? diffRows.first?.id : diffRows.last?.id
            } else {
                move(by: command == .top ? -Int.max / 2 : Int.max / 2)
            }
        case .nextPanel, .previousPanel:
            cycle(command == .nextPanel ? 1 : -1)
        case .enter:
            guard focus == .list else { return }
            switch selectedItem(in: panel) {
            case .folder(let tree, let path)?: toggleFolder(path, in: tree)
            case .commit?, .stash?: activate(.files)
            case nil: if panel == .files { activate(.files) }
            default: setFocus(.diff)
            }
        case .focusDiff:
            setFocus(.diff)
        case .focusList:
            if focus == .diff { setFocus(.list) } else if panel == .files { leaveFiles() }
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
            anchor = isRangeSelecting ? cursor : nil
        case .hunk:
            if focus == .diff { selectHunk() }
        case .copy:
            copySelection()
        case .toggleFolder:
            if focus == .list, case .folder(let tree, let path)? = selectedItem(in: panel) { toggleFolder(path, in: tree) }
        case .collapseAll, .expandAll:
            if focus == .list { foldAll(command == .collapseAll) }
        case .filter:
            wantsFilterFocus = true
        case .back:
            if focus == .diff {
                if anchor != nil { clearLineSelection(keepingCursor: true) } else { setFocus(.list) }
            } else if panel == .files {
                leaveFiles()
            } else if !filter.isEmpty {
                filter = ""
            } else {
                close()
            }
        case .close:
            close()
        case .refresh:
            refresh(showingProgress: true)
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
        let reference = focus == .diff ? cursor ?? topIndex : topIndex
        return ((hunks.lastIndex { $0 <= reference } ?? 0) + 1, hunks.count)
    }

    /// With the keys in the diff, the cursor goes to the hunk's first change.
    func jumpToHunk(forward: Bool) {
        let hunks = diffRows.indices.filter { diffRows[$0].isHunk }
        let reference = focus == .diff ? cursor ?? topIndex : topIndex
        let current = hunks.last { $0 <= reference }
        let target = forward ? hunks.first { $0 > reference } : hunks.last { $0 < (focus == .diff ? current ?? reference : reference) }
        guard let target else { return }
        scrollRow = diffRows[target].id
        if focus == .diff {
            let lines = diffRows.indices.dropFirst(target + 1).prefix { !diffRows[$0].isHunk }.filter { diffRows[$0].isLine }
            cursor = lines.first { diffRows[$0].isChange } ?? lines.first ?? cursor
            anchor = nil
            isRangeSelecting = false
        }
    }

    /// For a single file, the next one in its panel; in a commit, branch or
    /// stash, the next file's diff.
    func jumpToFile(forward: Bool) {
        if fileHeader != nil {
            if let item = neighbor(forward: forward) { select(item, in: panel) }
            return
        }
        let top = topIndex
        let files = diffRows.indices.filter { if case .file = diffRows[$0].kind { true } else { false } }
        let target = forward ? files.first { $0 > top } : files.last { $0 < top }
        if let target { scrollRow = diffRows[target].id }
    }

    /// The file after or before the selected one in its panel, for the
    /// end-of-file footer and `]`/`[`.
    func neighbor(forward: Bool) -> Item? {
        guard panel == .changes || panel == .files else { return nil }
        let files = items(in: panel).filter { !$0.isFolder }
        guard let index = files.firstIndex(where: { $0.id == selections[panel] }) else { return nil }
        let next = index + (forward ? 1 : -1)
        return files.indices.contains(next) ? files[next] : nil
    }

    func showWholeFile() {
        guard panel == .changes, case .change(let change)? = selectedItem(in: .changes) else { return }
        wholeFiles.insert(change.path)
        loadContent(reload: true)
    }

    func copy(_ value: String, title: String, shown: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        store?.palette.showCopied(title: title, value: shown ?? value)
    }

    // MARK: Selecting lines

    /// The diff rows selected: a range, or the cursor's line.
    var selectedLines: ClosedRange<Int>? {
        guard let cursor else { return nil }
        let anchor = anchor ?? cursor
        return min(anchor, cursor)...max(anchor, cursor)
    }

    func isLineSelected(_ row: Int) -> Bool {
        focus == .diff && selectedLines?.contains(row) == true
    }

    /// A click on a diff line, with shift to extend the selection to it.
    func pressLine(_ row: Int, side: Side, extending: Bool) {
        isRangeSelecting = false
        if extending, let cursor {
            if anchor == nil { anchor = cursor }
        } else {
            anchor = nil
            self.side = side
        }
        cursor = row
        focus = .diff
        focusKeyView()
    }

    /// Dragging from a line selects to the one under `point`.
    func dragLine(to point: CGPoint) {
        guard let row = lineFrames.first(where: { $0.value.minY <= point.y && point.y < $0.value.maxY })?.key,
              row != cursor else { return }
        if anchor == nil { anchor = cursor }
        cursor = row
    }

    private func clearLineSelection(keepingCursor: Bool = false) {
        if !keepingCursor { cursor = nil }
        anchor = nil
        isRangeSelecting = false
    }

    /// The cursor, unless scrolled out of sight; keys then start from the
    /// top of the pane.
    private func visibleCursor() -> Int? {
        guard let cursor, diffRows.indices.contains(cursor), let frame = lineFrames[cursor],
              frame.maxY > 0, frame.minY < diffHeight else { return nil }
        return cursor
    }

    /// The first change on screen, as lazygit starts on the first change.
    private func firstLine() -> Int? {
        let lines = diffRows.indices.dropFirst(topIndex).filter { diffRows[$0].isLine }
        let onScreen = lines.prefix(max(8, Int(diffHeight / (fontSize * 1.6))))
        return onScreen.first { diffRows[$0].isChange } ?? lines.first ?? diffRows.indices.last { diffRows[$0].isLine }
    }

    private func moveCursor(by delta: Int, extending: Bool = false) {
        guard let start = visibleCursor() else {
            cursor = firstLine()
            anchor = nil
            isRangeSelecting = false
            return
        }
        if extending || isRangeSelecting {
            if anchor == nil { anchor = start }
        } else {
            anchor = nil
        }
        var index = start
        for _ in 0..<abs(delta) {
            guard let next = (delta > 0 ? diffRows.indices.dropFirst(index + 1).first { diffRows[$0].isLine }
                                        : diffRows.indices.prefix(index).last { diffRows[$0].isLine }) else { break }
            index = next
        }
        cursor = index
    }

    /// a: the cursor's hunk, all of it.
    private func selectHunk() {
        guard let cursor = visibleCursor() ?? firstLine(), let hunk = diffRows[cursor].hunk, let file = diffRows[cursor].file else { return }
        let lines = diffRows.indices.filter { diffRows[$0].isLine && diffRows[$0].hunk == hunk && diffRows[$0].file == file }
        anchor = lines.first
        self.cursor = lines.last
        isRangeSelecting = false
    }

    /// y or ⌘C: the selected lines' code, without the +/− markers; in the
    /// list, the selection's path, hash or name.
    private func copySelection() {
        guard focus == .diff else {
            switch selectedItem(in: panel) ?? owner {
            case .change(let change)?: copy(change.path, title: "Copied Path")
            case .folder(_, let path)?, .file(let path)?: copy(path, title: "Copied Path")
            case .commit(let commit)?: copy(commit.sha, title: "Copied Hash", shown: commit.shortSHA)
            case .stash(let stash)?: copy(stash.sha, title: "Copied Hash", shown: String(stash.sha.prefix(8)))
            case .branch(let branch)?: copy(branch.name, title: "Copied Branch")
            case nil: break
            }
            return
        }
        guard let range = selectedLines else { return }
        let lines = range.compactMap { index -> String? in
            guard diffRows.indices.contains(index) else { return nil }
            switch diffRows[index].kind {
            case .line(let line): return line.kind == .note ? nil : line.text
            case .pair(let old, let new):
                guard let line = side == .old ? old : new, line.kind != .note else { return nil }
                return line.text
            default: return nil
            }
        }
        guard let first = lines.first else { return }
        copy(lines.joined(separator: "\n"), title: lines.count == 1 ? "Copied Line" : "Copied \(lines.count) Lines",
             shown: first.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Diff rows

    private func rebuildDiffRows(keepingPosition: Bool) {
        let kept = keepingPosition ? position : nil
        let scope = scope
        shownScope = scope
        lineFrames = [:]
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
        if !keepingPosition || cursor.map({ !diffRows.indices.contains($0) || !diffRows[$0].isLine }) == true {
            clearLineSelection()
        }
        if let kept, let row = diffRows.first(where: { $0.file == kept.file && $0.hunk == kept.hunk }) {
            scrollRow = row.id
        } else {
            scrollRow = diffRows.first?.id
        }
        if focus == .diff, cursor == nil { cursor = firstLine() }
    }

    static func diffRows(for content: Content, layout: Layout, wholeFile: Bool = false, scope: Scope = .all) -> [DiffRow] {
        var rows: [DiffRow] = []
        func add(_ kind: DiffRow.Kind, file: Int? = nil, hunk: Int? = nil) {
            rows.append(DiffRow(id: rows.count, kind: kind, file: file, hunk: hunk))
        }
        let isChange = if case .change = content.header { true } else { false }
        let isSingleFile = isChange || { if case .file = scope { true } else { false } }()
        if !isSingleFile, scope == .all { add(.card) }
        if let error = content.error {
            add(.message(error))
            return rows
        }
        let files = content.patch.files.filter { scope.contains($0.path) }
        if files.isEmpty {
            if case .branch(_, nil, _) = content.header { return rows }
            add(.message("No changes"))
        }
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
                    for line in hunk.lines { add(.line(line), file: file.id, hunk: index) }
                case .split:
                    for pair in hunk.pairs { add(.pair(old: pair.old, new: pair.new), file: file.id, hunk: index) }
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
    /// and when Muxify comes to the front. Each panel keeps its selection.
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

    private func apply(_ next: GitSnapshot) {
        let previous = Dictionary(uniqueKeysWithValues: [GitPanel.changes, .history, .stashes].map { ($0, items(in: $0).map(\.id)) })
        error = nil
        if snapshot != next { snapshot = next }
        if selections.isEmpty, owner == nil {
            // The first read: the first change, else the latest commit.
            if let change = items(in: .changes).first(where: { !$0.isFolder }) {
                panel = .changes
                selections[.changes] = change.id
            } else if let commit = items(in: .history).first {
                panel = .history
                selections[.history] = commit.id
                owner = commit
            }
        } else {
            // The same file, commit or stash, else the one now where it was.
            for panel in previous.keys where selections[panel] != nil && selectedItem(in: panel) == nil {
                let items = items(in: panel)
                let old = previous[panel]?.firstIndex(of: selections[panel]!)
                selections[panel] = old.flatMap { items.isEmpty ? nil : items[min($0, items.count - 1)].id }
            }
            switch panel {
            case .changes: setOwner(nil)
            case .history, .stashes: setOwner(selectedItem(in: panel))
            case .files:
                if let fresh = owner.flatMap(refreshed) {
                    owner = fresh
                } else {
                    setOwner(nil)
                    panel = .changes
                }
            }
        }
        loadContent(reload: true)
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
            case .branch(let branch, let base?, _):
                let parsed = GitRepository.parseBranchDetail(output)
                header = .branch(branch, base: base, commits: parsed.commits)
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
                if self.wantsFirstFile, self.panel == .files, self.selections[.files] == nil {
                    self.selections[.files] = self.items(in: .files).first { !$0.isFolder }?.id
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
        guard let snapshot, let item = contentItem else { return nil }
        let root = snapshot.root
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
            // The branch you're on is compared with main; the others with it.
            let base = branch.isHead ? snapshot.mainBranch.flatMap { $0 == branch.name ? nil : $0 } : "HEAD"
            guard let base else {
                return Request(id: item.id, header: .branch(branch, base: nil, commits: Array(snapshot.commits.prefix(20))),
                               localOutput: "")
            }
            let name = base == "HEAD" ? snapshot.head : base
            return Request(id: "\(item.id)...\(name)", header: .branch(branch, base: name, commits: []),
                           script: GitRepository.branchScript, arguments: [root, base, branch.name])
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

    // MARK: Panel heights

    /// Splits the sidebar's height between the panels, top to bottom: each
    /// needing less than its share, like two stashes, gets what it needs,
    /// and the rest is shared by weight. A nil want takes any room.
    nonisolated static func panelHeights(wants: [CGFloat?], weights: [CGFloat], minimum: CGFloat, total: CGFloat) -> [CGFloat] {
        var heights = wants.map { min($0 ?? .infinity, minimum) }
        var remaining = total - heights.reduce(0, +)
        var open = wants.indices.filter { heights[$0] < wants[$0] ?? .infinity }
        while remaining > 0.5, !open.isEmpty {
            let weight = open.reduce(0) { $0 + weights[$1] }
            var stillOpen: [Int] = []
            var used: CGFloat = 0
            for index in open {
                let share = remaining * weights[index] / weight
                let room = (wants[index] ?? .infinity) - heights[index]
                heights[index] += min(share, room)
                used += min(share, room)
                if room > share { stillOpen.append(index) }
            }
            remaining -= used
            if stillOpen.count == open.count { break }
            open = stillOpen
        }
        return heights
    }

    // MARK: Screenshots

    #if DEBUG
    /// Drives an instance without keystrokes, for screenshots of a build in
    /// the background: post `dev.muxify.git` with this process's pid as the
    /// object and a `spec` such as "open=1;keys=4 j enter j;diff=1",
    /// "layout=split", "filter=git", "shot=/tmp/a.png", or "close=1".
    private func observeDemoRequests() {
        demoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.muxify.git"),
            object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
        ) { [weak self] note in
            let spec = note.userInfo?["spec"] as? String ?? ""
            MainActor.assumeIsolated { self?.applyDemo(spec) }
        }
    }

    private func applyDemo(_ spec: String) {
        guard store?.terminalHost.window?.isVisible == true else { return }
        let fields = Dictionary(spec.split(separator: ";").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { _, last in last })
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
