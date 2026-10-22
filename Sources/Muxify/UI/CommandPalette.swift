import AppKit
import SwiftUI
import MuxifyCore

// MARK: - State

@MainActor @Observable
final class CommandPalette {
    enum Presentation {
        /// A Tag filter shows only the Topics with that Tag.
        case search(CommandPaletteConfig, tagFilter: Tag? = nil)
        case flow(PaletteFlow)
    }
    struct PreviousStep {
        let presentation: Presentation
        let query: String
        let selectedID: String?
        let selection: Set<PaletteSource>
    }
    private(set) var presentation: Presentation?
    var history: [PreviousStep] = []
    var invocation = UUID()
    /// Add a Session's New Worktree option. Each step starts with it off, so one SessionPath's choice never carries to the next.
    var newWorktree = false
    var current: CommandPaletteConfig? {
        if case .search(let config, _) = presentation { return config }
        return nil
    }
    var tagFilter: Tag? {
        if case .search(_, let tag) = presentation { return tag }
        return nil
    }
    var flow: PaletteFlow? {
        if case .flow(let flow) = presentation { return flow }
        return nil
    }
    var moving: TmuxWindow? {
        if case .move(let draft) = flow { return draft.window }
        return nil
    }
    var query = "" {
        didSet {
            if query != oldValue {
                selectedID = nil
                queryRevision += 1
                // Any change of the text, also one that is not a key press, puts the caret back in the text.
                if let flow = flow?.receiving(.toText) { presentation = .flow(flow) }
            }
        }
    }
    private(set) var queryRevision = 0
    var suggestionRequest = UUID()
    /// nil selects the first result.
    var selectedID: String?
    /// The Source buttons that are on: the palette's `sources` when it opens.
    var selection: Set<PaletteSource> = [] {
        didSet { if selection != oldValue { selectedID = nil } }
    }
    var showsActions = false
    var actionIndex = 0
    /// What the last Copy put on the pasteboard, shown briefly at the App Window's bottom.
    private(set) var copied: PaletteCopy?

    @ObservationIgnored weak var store: WorkspaceStore?
    @ObservationIgnored private var copiedWork: DispatchWorkItem?
    @ObservationIgnored private var previousResponder: NSResponder?
    #if DEBUG
    @ObservationIgnored private var demoObserver: NSObjectProtocol?
    #endif

    init() {
        #if DEBUG
        observeDemoRequests()
        #endif
    }

    var isOpen: Bool { presentation != nil }

    var placeholder: String {
        if let flow { return flow.placeholder }
        if let tagFilter { return "Topics with \(tagFilter)" }
        return current?.placeholder ?? ""
    }

    var theme: PaletteTheme { PaletteTheme(store?.theme) }

    /// One button per Source this App Window has; ⌘1… switch them on and off.
    var sourceButtons: [PaletteSource] {
        guard let current else { return [] }
        return current.allSources.filter { $0 != .topics || catalog?.offersTopics == true }
    }

    /// The palette's own Sources that this App Window has, else every Source button.
    private var openingSelection: Set<PaletteSource> {
        let own = Set(current?.sources ?? []).intersection(sourceButtons)
        return own.isEmpty ? Set(sourceButtons) : own
    }

    /// The last Source button that is on stays on.
    func toggleSource(_ source: PaletteSource) {
        if !selection.contains(source) {
            selection.insert(source)
        } else if selection.count > 1 {
            selection.remove(source)
        }
    }

    // MARK: Results

    var catalog: PaletteCatalog? {
        guard let store else { return nil }
        return PaletteCatalog(windows: store.windows, agents: store.agents, sessionPaths: store.sessionPaths, folders: store.folders,
                              selectedWindowID: store.selectedWindowID, homeDirectory: store.homeDirectory,
                              topics: store.isRemote ? nil : store.topics, records: store.topicWatcher.records,
                              lastWindowByGroup: store.topicSelection.lastWindowByGroup, visits: store.visits, commands: commands,
                              commandShortcuts: Dictionary(uniqueKeysWithValues: commands.compactMap { command in
                                  shortcut(for: command).map { (command, $0) }
                              }), agentMarks: store.topics.agentMarks)
    }

    var results: PickList<PaletteItem> {
        guard let catalog else { return .empty }
        if let flow { return flowResults(flow) }
        return catalog.list(sourceButtons.filter(selection.contains), query: query, tagFilter: tagFilter)
    }

    func selected(in list: PickList<PaletteItem>) -> PickRow<PaletteItem>? {
        list.rows.first { $0.id == selectedID } ?? list.rows.first { $0.pick.payload != nil }
    }

    /// The actions menu's entries; Jump To is the first. A blocked row has none.
    func actions(for row: PickRow<PaletteItem>) -> [PaletteAction] {
        guard let item = row.pick.payload else { return [] }
        if flow != nil || item.kind == .command { return [.jumpTo] }
        if case .tag = item.ref { return [.jumpTo, .snoozeTopic] }
        var actions: [PaletteAction] = [.jumpTo]
        if store?.canChangeRead(.read, in: item.readTarget) == true { actions.append(.markRead) }
        if store?.canChangeRead(.unread, in: item.readTarget) == true { actions.append(.markUnread) }
        switch item.ref {
        case .topic(let id, _):
            guard let store, !store.isRemote, let topic = store.topicWatcher.records.first(where: { $0.id == id }) else { return actions }
            if topic.settledAt == nil {
                actions += topic.snoozedUntil == nil ? [.snoozeTopic] : [.unsnoozeTopic]
                // Zen starts only in Topics mode; while it is on, the action ends it.
                actions += store.topics.mode == .topics || store.topicWatcher.zen != nil ? [.startZen] : []
                actions += [.settleTopic, .addSessionToTopic, .rename] + (store.topicConfig.tags == nil ? [] : [.editTags])
                    + [.suggestTopicTitle, topic.isPinned ? .unpinTopic : .pinTopic]
            }
            if topic.settledAt != nil || (!topic.sessions.isEmpty && !store.windows.contains(where: { $0.topicID == id })) {
                actions += [.reopenTopic, .startTopicFresh]
            }
            actions += [.forgetTopic]
        case .session(let session):
            if store?.isRemote == false {
                actions += [.move]
                if session.windows.first?.topicID != nil { actions += [.removeFromTopic, .removeFromTopicAndKill] }
            }
            if let locked = store?.lockState(ofSession: session.id) { actions += [locked ? .unlockSession : .lockSession] }
            actions += [.newSession, .rename, .newWindow, .killSession]
        case .window(let window):
            if store?.isRemote == false { actions += [.move]; if window.topicID != nil { actions += [.removeFromTopic] } }
            actions += [.rename, .newWindow, .killWindow]
        case .agent:
            if store?.isRemote == false { actions += [.move] }
        case .sessionPath: actions += [.newSession]
        case .choice, .command, .tag: break
        }
        if !item.path.isEmpty { actions += [.copyFolder]; if store?.isRemote == false { actions += [.revealFolder] } }
        if item.target != nil { actions += [.copyTmuxTarget] }
        if row.paste != nil { actions += [.pasteFolder] }
        return actions
    }

    func title(of action: PaletteAction, for row: PickRow<PaletteItem>) -> String {
        guard let item = row.pick.payload else { return action.rawValue }
        switch action {
        case .jumpTo:
            switch item.kind {
            case _ where moving != nil: return "Move Here"
            case .topic, .snoozedTopic:
                guard case .topic(let id, nil) = item.ref,
                      store?.topicWatcher.records.first(where: { $0.id == id })?.sessions.isEmpty == false else { return "Go to Topic" }
                return "Reopen Topic"
            case .settledTopic: return "Reopen Topic"
            case .tag: return flow == nil ? "Show its Topics" : "Choose Tag"
            case .session: return "Switch to Session"
            // A SessionPath row's target is the Session ↩ goes to; without one, ↩ starts it.
            case .sessionPath, .worktree: return item.target == nil ? "Open as Session" : "Switch to Session"
            case .window: return "Open Window"
            case .agent: return "Jump to Agent"
            case .command: return "Run"
            }
        case .markRead: return "Mark Read"
        case .markUnread: return "Mark Unread"
        case .newSession: return "New Session"
        case .copyFolder: return "Copy Path"
        case .copyTmuxTarget: return item.kind == .agent ? "Copy Pane ID" : "Copy tmux Target"
        case .pasteFolder: return "Paste Path"
        case .snoozeTopic: return item.kind == .tag ? "Snooze its Topics…" : "Snooze Topic"
        case .move: return "Move to…"
        case .addSessionToTopic: return "Add a Session"
        case .rename: return "Rename"
        case .editTags: return "Edit Tags…"
        case .suggestTopicTitle: return "Suggest title from Agents"
        case .startZen: return store?.topicWatcher.zen == nil ? "Zen" : "End Zen"
        case .settleTopic: return "Settle"
        case .forgetTopic: return "Forget"
        case .unsnoozeTopic: return "Unsnooze"
        case .reopenTopic: return "Reopen"
        case .startTopicFresh: return "Start Fresh"
        case .pinTopic: return "Pin"
        case .unpinTopic: return "Unpin"
        case .removeFromTopic: return "Remove from Topic"
        case .removeFromTopicAndKill: return "Remove from Topic and Kill…"
        case .newWindow: return "New Window"
        case .revealFolder: return "Reveal in Finder"
        case .killWindow: return "Kill Window"
        case .killSession: return "Kill Session"
        case .lockSession: return "Lock"
        case .unlockSession: return "Unlock"
        default: return action.rawValue
        }
    }

    /// As menus write it, e.g. `⌘C`.
    func shortcut(for action: PaletteAction) -> String? {
        store?.config.paletteKeybinds.firstTrigger(for: action)?.symbol
    }

    // MARK: Opening and closing

    /// Its own keybinding closes a palette; another palette's switches to
    /// that one and keeps what is typed.
    func toggle(_ palette: CommandPaletteConfig) {
        if current?.name == palette.name {
            close()
            return
        }
        open()
        history = []
        invocation = UUID()
        presentation = .search(palette)
        store?.paletteDidOpen(palette)
        selection = openingSelection
    }

    func openMove(_ window: TmuxWindow, scope: MoveDraft.Scope = .session, paneID: String? = nil,
                  includesTab: Bool = false, keepingHistory: Bool = false) {
        begin(.move(MoveDraft(window: window, paneID: paneID ?? window.activePaneID, scope: scope, includesTab: includesTab)),
              keepingHistory: keepingHistory)
    }

    func begin(_ flow: PaletteFlow, text: String = "", keepingHistory: Bool = false) {
        guard store?.changingTopic != true else { return }
        if keepingHistory, let presentation {
            history.append(PreviousStep(presentation: presentation, query: query, selectedID: selectedID, selection: selection))
        } else {
            history = []
        }
        open()
        invocation = UUID()
        presentation = .flow(flow)
        query = text
        selectedID = nil
        newWorktree = false
        loadFlow()
    }

    func back() {
        guard query.isEmpty else { return }
        if showsActions { showsActions = false; return }
        if receiveChipKey(.deleteBackward(textIsEmpty: true)) { return }
        if case .search(let config, _?) = presentation { presentation = .search(config); selectedID = nil; return }
        invocation = UUID()
        if let earlier = flow?.earlierStep { replaceFlow(earlier); return }
        guard let previous = history.popLast() else { close(); return }
        presentation = previous.presentation
        query = previous.query
        selectedID = previous.selectedID
        selection = previous.selection
        showsActions = false
    }

    func replaceFlow(_ flow: PaletteFlow) {
        presentation = .flow(flow)
        selectedID = nil
    }

    private func open() {
        store?.hintHold.receive(.reset)
        if !isOpen {
            previousResponder = store?.terminalHost.window?.firstResponder
            query = ""
            selectedID = nil
        }
        showsActions = false
        actionIndex = 0
    }

    func close(restoringFocus: Bool = true) {
        guard isOpen else { return }
        presentation = nil
        history = []
        invocation = UUID()
        showsActions = false
        let responder = previousResponder
        previousResponder = nil
        guard restoringFocus, let store else { return }
        DispatchQueue.main.async { [weak store] in
            guard let store, !store.palette.isOpen else { return }
            if let responder, let window = store.terminalHost.window, window.makeFirstResponder(responder) { return }
            store.focusTerminal()
        }
    }

    // MARK: Running actions

    func perform(_ action: PaletteAction, on row: PickRow<PaletteItem>) {
        guard let store, let item = row.pick.payload else { return }
        if case .choice(let choice) = item.ref {
            // A click on a check step's row checks it, as Space does; ↩ is what goes on.
            if case .check(let checkRow) = choice { check(checkRow, highlighting: row.id) }
            else if choice == .accept { acceptSelected() } else { accept(choice) }
            return
        }
        if action == .jumpTo, case .tag(let tag) = item.ref, let current {
            presentation = .search(current, tagFilter: tag)
            query = ""
            selectedID = nil
            return
        }
        switch action {
        case .jumpTo:
            if case .command(let command) = item.ref {
                run(command)
                return
            }
            close(restoringFocus: false)
            switch item.ref {
            case .topic(let id, let window):
                if let window { store.select(window) } else { store.goToTopic(.topic(id)) }
            case .agent(let agent): store.select(agent)
            case .window(let window): store.select(window)
            case .session(let session):
                if let window = EntryWindow.ofSession(session.windows) { store.select(window) }
            case .sessionPath(let target): store.openDirectory(target)
            case .tag: break
            case .choice: break
            case .command: break
            }
        case .newSession:
            close(restoringFocus: false)
            switch item.ref {
            case .sessionPath(let target): store.newSession(in: target)
            case .session(let session):
                guard let window = EntryWindow.ofSession(session.windows) else { return }
                let topic = store.isRemote ? nil : store.topicWatcher.records.first { $0.id == window.topicID && $0.settledAt == nil }
                store.newSession(in: OpenDirectory(directory: store.folders.folder(window.sessionPath.isEmpty ? window.path : window.sessionPath),
                    name: SessionNaming.base(of: window.sessionName, topic: topic)), topic: topic?.id)
            default: break
            }
        case .copyFolder:
            copy(item.path, title: "Copied Path", shown: Paths.tildify(item.path, home: store.homeDirectory))
        case .copyTmuxTarget:
            guard let target = item.target else { return }
            copy(target, title: item.kind == .agent ? "Copied Pane ID" : "Copied tmux Target", shown: target)
        case .pasteFolder:
            guard let paste = row.paste else { return }
            let responder = previousResponder
            close()
            // close() gives Focus back on the next turn of the main queue; the text follows it there.
            DispatchQueue.main.async { [weak store] in store?.paste(paste, into: responder) }
        default: performRowAction(action, item: item)
        }
    }

    /// The palette fades out while the pill springs in at the App Window's bottom.
    private func copy(_ value: String, title: String, shown: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.12)) { close() }
        showCopied(title: title, value: shown)
    }

    /// Shared by palette and Browser copies, without taking Focus.
    func showCopied(title: String, value: String) {
        copiedWork?.cancel()
        let confirmation = PaletteCopy(title: title, value: value)
        withAnimation(.spring(duration: 0.4, bounce: 0.35)) { copied = confirmation }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.copied?.id == confirmation.id else { return }
                withAnimation(.easeIn(duration: 0.2)) { self.copied = nil }
            }
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Keys

    /// Sees each key in the App Window before the other keybinds while a
    /// palette is open and its search field has focus. ⎋ and ⌘1–⌘9 are fixed;
    /// the rest come from `keybindings.command_palette`.
    func handle(_ trigger: KeyTrigger, in event: NSEvent) -> Bool {
        guard isOpen, let store else { return false }
        // Clicked away (into the terminal or a page): typing goes there.
        guard (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true else {
            close(restoringFocus: false)
            return false
        }
        if trigger == Self.escape { close(); return true }
        if let editor = event.window?.firstResponder as? NSTextView, handleChipKey(trigger, editor: editor) { return true }
        if trigger == KeyTrigger(modifiers: [], key: .special(.backspace)), query.isEmpty {
            back()
            return true
        }
        if flow != nil, handleFlow(trigger) { return true }
        let list = results
        let item = selected(in: list)
        if trigger == KeyTrigger(modifiers: .command, key: .special(.enter)), case .command(let command)? = item?.pick.payload?.ref,
           command.commandReturnTitle != nil {
            acceptSelected(commandReturn: true)
            return true
        }
        if let action = store.config.paletteKeybinds.action(for: trigger) {
            switch action {
            case .selectNext, .selectPrev:
                let delta = action == .selectNext ? 1 : -1
                if showsActions, let item, case let count = actions(for: item).count, count > 0 {
                    actionIndex = (actionIndex + delta + count) % count
                } else {
                    move(delta, in: list)
                }
                return true
            case .showActions:
                toggleActions(for: item)
                return true
            default:
                // With nothing to act on, ⌘C still copies the search text.
                guard let item else { return false }
                let available = actions(for: item)
                if showsActions, action == .jumpTo, !available.isEmpty {
                    perform(available[min(actionIndex, available.count - 1)], on: item)
                } else if available.contains(action) {
                    perform(action, on: item)
                }
                return true
            }
        }
        if let index = Self.commandDigits.firstIndex(of: trigger), sourceButtons.indices.contains(index) {
            toggleSource(sourceButtons[index])
            return true
        }
        return false
    }

    /// The menu opens only over a row it has actions for; a blocked row has none.
    func toggleActions(for row: PickRow<PaletteItem>?) {
        actionIndex = 0
        guard let row, !actions(for: row).isEmpty else {
            showsActions = false
            return
        }
        showsActions.toggle()
    }

    /// Steps over blocked rows, as the first selection does.
    func move(_ delta: Int, in list: PickList<PaletteItem>) {
        let rows = list.rows.filter { $0.pick.payload != nil }
        guard !rows.isEmpty else { return }
        if let flow = flow?.receiving(.toText) { presentation = .flow(flow) }
        let current = rows.firstIndex { $0.id == selected(in: list)?.id } ?? 0
        selectedID = rows[(current + delta + rows.count) % rows.count].id
        showsActions = false
    }

    private static let escape = KeyTrigger(modifiers: [], key: .special(.escape))
    private static let commandDigits = (1...9).map { KeyTrigger(modifiers: .command, key: .character(Character("\($0)"))) }

    // MARK: Screenshots

    #if DEBUG
    /// Drives an instance into a state without keystrokes, for screenshots of
    /// a build running in the background: post `dev.muxify.palette` with this
    /// process's pid as the object and a `spec` such as
    /// "palette=Sessions;query=mux;down=2;actions=1;action=1;sources=agents,windows",
    /// or "close=1".
    private func observeDemoRequests() {
        demoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.muxify.palette"),
            object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
        ) { [weak self] note in
            let spec = note.userInfo?["spec"] as? String ?? ""
            MainActor.assumeIsolated { self?.applyDemo(spec) }
        }
    }

    private func applyDemo(_ spec: String) {
        let fields = Dictionary(spec.split(separator: ";").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : parts.first.map { ($0, "") }
        }, uniquingKeysWith: { _, last in last })
        if fields["close"] != nil { close(); return }
        guard let palettes = store?.config.commandPalettes,
              let palette = palettes.first(where: { $0.name == fields["palette"] }) ?? palettes.first else { return }
        if current?.name != palette.name { toggle(palette) }
        if let sources = fields["sources"] {
            selection = Set(sources.split(separator: ",").compactMap { PaletteSource(rawValue: String($0)) })
        }
        query = fields["query"] ?? ""
        for _ in 0..<(Int(fields["down"] ?? "") ?? 0) { move(1, in: results) }
        showsActions = fields["actions"] == "1"
        actionIndex = Int(fields["action"] ?? "") ?? 0
    }
    #endif
}

// MARK: - Theme

/// A Copy's confirmation: "Copied Path" and what was copied.
struct PaletteCopy: Equatable {
    let id = UUID()
    let title: String
    let value: String
}

/// The Sidebar's colors (Ghostty background shaded toward the foreground)
/// plus the Ghostty theme's ANSI colors. System colors without a theme.
struct PaletteTheme {
    let chrome: Color
    let background: Color
    let foreground: Color
    let separator: Color
    let colorScheme: ColorScheme
    private let ansiColors: [Color]

    init(_ theme: TerminalTheme?) {
        if let theme {
            chrome = Color(nsColor: theme.chrome)
            background = Color(nsColor: theme.background)
            foreground = Color(nsColor: theme.foreground)
            separator = Color(nsColor: theme.separator)
            colorScheme = theme.isDark ? .dark : .light
            ansiColors = theme.ansi.map { Color(nsColor: $0) }
        } else {
            chrome = Color(nsColor: .windowBackgroundColor)
            background = Color(nsColor: .textBackgroundColor)
            foreground = Color(nsColor: .labelColor)
            separator = Color(nsColor: .separatorColor)
            colorScheme = .light
            ansiColors = []
        }
    }

    /// ANSI color `index` (0–15), or a system stand-in.
    func ansi(_ index: Int) -> Color {
        if ansiColors.indices.contains(index) { return ansiColors[index] }
        let fallback: [Color] = [.black, .red, .green, .yellow, .blue, .purple, .cyan, .white]
        return index == 8 ? .gray : fallback[index % 8]
    }

    var red: Color { ansi(1) }
    var green: Color { ansi(2) }
    var yellow: Color { ansi(3) }
    var blue: Color { ansi(4) }
    var magenta: Color { ansi(5) }
    var cyan: Color { ansi(6) }
}
