import AppKit
import GhosttyKit
import Observation
import MuxifyCore

struct SessionGroup: Identifiable, Equatable {
    let id: String
    let name: String
    var windows: [TmuxWindow]
}

/// App state: the tmux Windows in the sidebar, the one libghostty surface
/// running our tmux client, and a Browser per Window.
///
/// The terminal is a single `tmux attach` client attached straight to your
/// Sessions. Clicking a sidebar Window runs `switch-client -c <our tty> -t
/// <window>`, so tmux renders it with all its Panes, and anything you do
/// inside tmux (prefix+n, choose-tree, …) is reflected back into the sidebar.
@MainActor @Observable
final class WorkspaceStore {
    private(set) var wakeToast: String?
    @ObservationIgnored private var wakeToastDismiss: DispatchWorkItem?
    @ObservationIgnored private var unreadVisit: String?
    @ObservationIgnored private var explicitReadVisits = AgentReadVisits()
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var pendingReads = 0
    private var readSnapshotPending = false
    private var pendingReadNavigations: Set<UUID> = []

    private(set) var newTopicFailure: String?
    /// When each Topic, Session and SessionPath was last looked at; the lists rank by it.
    private(set) var visits = VisitLog(defaults: .standard)
    /// The SessionPaths on this App Window's Environment, as `refreshSessionPaths` found them last.
    private(set) var sessionPaths: [SessionPath] = []
    private(set) var sessionPathWarnings: [String] = []
    var sessionPathWarningsDismissed = false
    /// Resolves a path on this App Window's Environment: with `realpath` on this Mac, else through the SessionPaths found there.
    var folders: FolderResolver { isRemote ? .remote(sessionPaths) : .local }
    var topicConfig: Config.Topics { configStore.config.topics }

    /// Looks for the Config's SessionPaths again, on the Environment's machine and off the main thread. A sheet
    /// or palette opens at once, and a folder made since the last look joins it a moment later. Topics read
    /// the Local SessionPaths from the Config, so a Local App Window hands them over.
    func refreshSessionPaths() {
        let config = self.config
        let found = { [weak self] (sessionPaths: [SessionPath]) in
            guard let self, self.config.sessionRoots == config.sessionRoots, self.config.sessionAliases == config.sessionAliases else { return }
            if self.sessionPaths != sessionPaths { self.sessionPaths = sessionPaths }
            let warnings = SessionPathDiscovery.warnings(in: sessionPaths)
            if self.sessionPathWarnings != warnings {
                self.sessionPathWarnings = warnings
                self.sessionPathWarningsDismissed = false
            }
            if !self.isRemote { self.configStore.updateSessionPaths(sessionPaths, foundFor: config) }
        }
        guard isRemote else {
            let roots = config.sessionRoots, aliases = config.sessionAliases
            DispatchQueue.global(qos: .userInitiated).async {
                let sessionPaths = SessionPathDiscovery.discover(roots, aliases: aliases)
                DispatchQueue.main.async { found(sessionPaths) }
            }
            return
        }
        guard let connection else { return }
        guard !config.sessionRoots.isEmpty else { return found([]) }
        let current = generation
        connection.runScriptAsync(SessionPathDiscovery.script, arguments: SessionPathDiscovery.arguments(for: config.sessionRoots)) { [weak self] result in
            guard let self, self.generation == current else { return }
            switch result {
            case .success(let output): found(SessionPathDiscovery.sessionPaths(in: output, roots: config.sessionRoots, aliases: config.sessionAliases))
            case .failure(let error): NSLog("muxify: SessionPaths: \(error)")
            }
        }
    }

    /// The New Topic list, or the Add Session list of `topic`, ranked for `query`.
    func sessionPathList(query: String, addingTo topic: TopicRecord? = nil) -> PickList<SessionChoice> {
        let rows = SessionPathRows.build(sessionPaths: sessionPaths, windows: windows, records: topicWatcher.records, titles: topics.titles,
                                     addingTo: topic)
        return SessionPathRows.list(rows, query: query, visits: visits)
    }

    func presentNewTopic(keepingHistory: Bool = false) {
        guard !isRemote, !changingTopic else { return }
        newTopicFailure = nil
        palette.begin(.text(.tags(TagField(mode: .newTopic, defined: topicConfig.tags))), keepingHistory: keepingHistory)
    }

    /// Makes an open Topic with no Session and shows it, so the user adds its first SessionPath from there.
    func createTopic(title: String, tags: [Tag] = []) {
        perform(TopicRequest(.create(title: title, sessionPath: nil, tags: tags.isEmpty ? nil : tags)), presenting: .newTopic)
    }

    /// Edit Tags for an open Topic: one field with its Tags as chips.
    func presentEditTags(of id: String, keepingHistory: Bool = false) {
        topicWatcher.reload()
        guard !changingTopic, !isRemote, let defined = topicConfig.tags,
              let topic = topicWatcher.records.first(where: { $0.id == id && $0.settledAt == nil }) else { return }
        palette.begin(.text(.tags(TagField(mode: .editTags(topic), defined: defined, chips: defined.shown(topic.tags).map(\.tag)))),
                      keepingHistory: keepingHistory)
    }

    /// Tags go through the Topic service, as `muxify topic tag` does (ADR 0032).
    func setTags(of id: String, _ tags: [Tag]) {
        perform(TopicRequest(.tags(.set(tags)), target: .topic(.id(id))))
    }

    /// Puts a Topic with no live Session in place of the terminal and makes it the Active Topic: an empty Topic
    /// offers Add a Session, a Dormant or Settled one offers Reopen and Start Fresh. Selecting a Window ends it.
    func showEmptyTopic(_ id: String) {
        let entering = topicSelection.emptyTopicID != id
        topicSelection.showsEmptyNoTopic = false
        topicSelection.emptyTopicID = id
        sidebarMode = .topics
        updateTopicSelection()
        if entering { readTopicsOnVisit([id]) }
        if !palette.isOpen { surface?.window?.makeFirstResponder(nil) }
    }

    private(set) var changingTopic = false {
        didSet {
            if oldValue && !changingTopic {
                DispatchQueue.main.async { [weak self] in self?.drainTopicRequests() }
            }
        }
    }
    private var topicEditGeneration = 0
    private var pendingNextTopic: TopicGroupID?
    @ObservationIgnored private var topicRequests: [TopicRequest] = []

    /// Move for the selected Window's Session, in the Command Palette's view. Nothing happens with Topics off.
    func presentMoveSession(keepingHistory: Bool = false) {
        guard !isRemote, topics.topicsEnabled, let window = selectedWindow else { return }
        topicWatcher.reload()
        palette.openMove(window, keepingHistory: keepingHistory)
    }

    /// Move for the selected Window, in the Command Palette's view. Nothing happens with Topics off.
    func presentMoveWindow(keepingHistory: Bool = false) {
        guard !isRemote, topics.topicsEnabled, let window = selectedWindow else { return }
        topicWatcher.reload()
        palette.openMove(window, scope: .window, keepingHistory: keepingHistory)
    }

    /// Types `text` into `responder`, the view that had Focus before the palette opened: at the cursor of a web
    /// page or a text field, as typed keys are. From the terminal, or from a view that takes no text, it goes to
    /// the prompt of the active Pane as one shell word.
    func paste(_ text: String, into responder: NSResponder?) {
        if !(responder is TerminalSurfaceView), let input = responder as? NSTextInputClient {
            input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return
        }
        pasteIntoTerminal(PaletteCatalog.shellWord(text))
    }

    /// Types `text` at the prompt of the active Pane of the selected Window, without Enter.
    private func pasteIntoTerminal(_ text: String) {
        guard let pane = selectedWindow?.activePaneID, !pane.isEmpty else {
            showGoFailure("No Window is selected.")
            return
        }
        runAsync(Tmux.sendKeysArguments(target: pane, keys: [text], literal: true, client: clientTTY ?? surface?.ttyName)) { [weak self] result in
            if case .failure(let error) = result { self?.showGoFailure(String(describing: error)) }
        }
    }

    /// Goes to the Session in `target.directory`, or starts one there in No Topic. A second press while the
    /// first Session is still being created does nothing.
    func openDirectory(_ target: OpenDirectory) {
        if let window = EntryWindow.ofSession(windows.filter { $0.sessionName == target.name }) { select(window) }
        else if !pendingOpenings.values.contains(where: { $0.name == target.name }) { startSession(in: target.directory, named: target.name) }
    }

    /// Starts another Session, allocating +2, +3, etc. in the selected row's Topic or No Topic scope.
    func newSession(in target: OpenDirectory, topic: String? = nil) {
        if let topic, !isRemote {
            perform(TopicRequest(.addSession(sessionPath: target.directory.path, workingCopy: .directory, name: target.name), target: .topic(.id(topic))))
            return
        }
        guard pendingOpenings[target.directory] == nil else { return }
        startSession(in: target.directory, named: SessionNaming.available(target.name, taken: Set(windows.map(\.sessionName))))
    }

    /// Starts a tmux Session at `directory` and switches to it. tmux refusing a duplicate name means an
    /// earlier press won the race, so that Session is selected instead; two presses end on one Session.
    private func startSession(in directory: Folder, named name: String) {
        pendingOpenings[directory] = (name, Date().addingTimeInterval(5))
        runAsync(["new-session", "-d", "-P", "-F", "#{session_id}:#{window_id}", "-s", name, "-c", directory.path]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output):
                let ids = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
                guard ids.count == 2 else { return }
                self.switchClient(to: Target(sessionID: ids[0], windowID: ids[1], path: directory.path))
            case .failure(let error):
                self.pendingOpenings[directory] = nil
                if String(describing: error).contains("duplicate session") { self.selectSession(named: name) }
                else { self.showGoFailure("Could not start a Session in \(directory.path). \(error)") }
            }
        }
    }

    /// Goes to the Topic because the user asked to: a click, a Hint key, ↩ on its palette row or Go to Topic.
    /// A Dormant Topic that remembers a Session is Reopened at once; any other Topic shows as in `showTopic`.
    func goToTopic(_ id: TopicGroupID) {
        if case .topic(let topicID) = id, entryWindow(of: id) == nil, !changingTopic, reopensOnArrival(topicID) {
            reopenTopic(topicID, .reopen)
        } else {
            showTopic(id)
        }
    }

    /// Shows the Topic without creating anything, as Next Topic does: its entry Window, or its Reopen choice when it
    /// is Dormant. tmux keeps each Window's active Pane, so this lands on the Pane last used there.
    func showTopic(_ id: TopicGroupID) {
        if let window = entryWindow(of: id) { select(window) }
        else if case .topic(let topicID) = id { showEmptyTopic(topicID) }
        else {
            topicSelection.showsEmptyNoTopic = true
            topicSelection.emptyTopicID = nil
            selectedWindowID = nil
            pendingSelection = nil
            recoveryPending = false
            sidebarMode = .topics
            updateTopicSelection()
            if !palette.isOpen { terminalHost.window?.makeFirstResponder(nil) }
        }
    }

    /// Goes to the Session's active Window, as its palette row does.
    func goToSession(_ sessionID: String) {
        if let window = EntryWindow.ofSession(windows.filter { $0.sessionID == sessionID }) { select(window) }
    }

    func nextTopic(after id: String, skipping others: Set<String> = []) -> TopicGroupID {
        topics.nextTopic(after: id, skipping: others)
    }

    func move(_ draft: MoveDraft, to destination: MoveDestination) {
        guard let window = windows.first(where: { $0.id == draft.window.id && $0.sourceID == draft.window.sourceID }) else { return }
        let target: TopicTarget?
        switch draft.scope {
        case .pane: target = PaneID(rawValue: draft.paneID).map(TopicTarget.pane)
        case .window: target = WindowID(rawValue: window.id).map(TopicTarget.window)
        case .session: target = SessionID(rawValue: window.sessionID).map(TopicTarget.session)
        }
        guard let target else { return }
        let to: TopicDestination
        switch destination {
        case .topic(let id): to = .topic(.id(id))
        case .noTopic: to = .newSession(topic: nil)
        case .session(let id):
            guard let session = SessionID(rawValue: id) else { return }
            to = .session(session)
        case .newSession(let topic): to = .newSession(topic: topic.map(TopicRef.id))
        case .newTopic(let title): to = .newTopic(title: title)
        case .newWindow(let title): to = .newWindow(title: title)
        }
        let tab = draft.scope == .pane && draft.includesTab ? browser(for: window.id).activeTab : nil
        perform(TopicRequest(.move(to: to), target: target), presenting: .move(source: window.id, tab: tab))
    }

    private func entryWindow(of id: TopicGroupID) -> TmuxWindow? {
        if id == .noTopic {
            let open = Set(topicWatcher.records.filter { $0.settledAt == nil }.map(\.id))
            let locked = Set(topics.rows.compactMap { row -> String? in
                if case .locked(let sessionID) = row.id { return sessionID }
                return nil
            })
            let members = windows.filter { ($0.topicID.map { !open.contains($0) } ?? true) && !locked.contains($0.sessionID) }
            if let last = members.first(where: { $0.id == topicSelection.lastWindowByGroup[.noTopic] }) { return last }
            return EntryWindow.ofSession(members)
        }
        guard let row = (topics.rows + topics.snoozedRows).first(where: { $0.id == id }) else { return nil }
        return EntryWindow.of(row, lastWindowByGroup: topicSelection.lastWindowByGroup, visits: visits)
    }

    private func showGoFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not go there"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func moveTopic(_ id: TopicListID, to placement: TopicPlacement) {
        guard !changingTopic else { return }
        do {
            writeLocks(try topicWatcher.write(locks: liveLocks) { try $0.move(id, to: placement) })
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not move the Topic"
            alert.informativeText = "Some Topic positions may have been saved. The Sidebar shows the saved order. \(error)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func pinTopic(_ id: String, _ pinned: Bool) {
        guard !changingTopic else { return }
        do {
            writeLocks(try topicWatcher.write(locks: liveLocks) { try $0.pin(id, pinned) })
        } catch {
            let alert = NSAlert()
            alert.messageText = pinned ? "Could not pin the Topic" : "Could not unpin the Topic"
            alert.informativeText = "Some Topic positions may have been saved. The Sidebar shows the saved order. \(error)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// The Locked Sessions as the last tmux read gives them. A change of the Topic order includes them (ADR 0018).
    private var liveLocks: [SessionLock] { isRemote ? [] : SessionLock.locks(in: windows, records: topicWatcher.records) }

    /// tmux keeps a Lock's order, so a change of order that moved or renumbered Locks writes them there.
    private func writeLocks(_ locks: [SessionLock]) {
        for lock in locks { runAsync(lock.setOption) { [weak self] _ in self?.refresh() } }
    }

    /// Whether the Session is Locked; nil when it cannot be: it is in an open Topic, or Topics are off or Remote.
    func lockState(ofSession sessionID: String) -> Bool? {
        guard !isRemote, topics.topicsEnabled, let window = windows.first(where: { $0.sessionID == sessionID }) else { return nil }
        if let id = window.topicID, topicWatcher.records.contains(where: { $0.id == id && $0.settledAt == nil }) { return nil }
        return topics.lockedSessionIDs.contains(sessionID)
    }

    /// Lock and Unlock go through the Topic service, as `muxify session lock` does (ADR 0032).
    func setLock(ofSession sessionID: String, _ locked: Bool) {
        guard lockState(ofSession: sessionID) != nil, let id = SessionID(rawValue: sessionID) else { return }
        perform(TopicRequest(locked ? .lock : .unlock, target: .session(id)))
    }

    func toggleLockOfCurrentSession() {
        guard let id = selectedWindow?.sessionID, let locked = lockState(ofSession: id) else { return }
        setLock(ofSession: id, !locked)
    }

    /// Where Move Topic Up (`previous`) or Down (`next`) puts the card of the Active Topic or Locked Session, as the
    /// card's own Move Up and Move Down do. Nil at that end of the cards with its Pin, for No Topic, for a Snoozed or
    /// Settled Topic, and outside Topics mode, where the cards do not show.
    func activeCardMove(_ direction: StepDirection) -> (id: TopicListID, placement: TopicPlacement)? {
        guard !isRemote, !changingTopic, topics.mode == .topics, let active = topics.activeTopic, let id = active.listID,
              let placement = topics.neighbors(of: active).placement(direction) else { return nil }
        return (id, placement)
    }

    func moveActiveCard(_ direction: StepDirection) {
        if let move = activeCardMove(direction) { moveTopic(move.id, to: move.placement) }
    }

    /// The Active Topic when it is open or Snoozed, which Pin Topic and Unpin Topic act on.
    var pinnableActiveTopic: TopicRecord? {
        guard !isRemote, let id = activeTopicID else { return nil }
        return topicWatcher.records.first { $0.id == id && $0.settledAt == nil }
    }

    func togglePinOfActiveTopic() {
        if let topic = pinnableActiveTopic { pinTopic(topic.id, !topic.isPinned) }
    }

    /// The Active Topic when it is Snoozed, which Unsnooze Topic acts on.
    var snoozedActiveTopicID: String? {
        guard !isRemote, let id = activeTopicID, topics.snoozedTopicIDs.contains(id) else { return nil }
        return id
    }

    func changeTopic(_ source: TopicMembershipPlan.Source, destination: TopicRecord? = nil, title: String = "") {
        let target: TopicTarget?
        switch source {
        case .session(let window): target = SessionID(rawValue: window.sessionID).map(TopicTarget.session)
        case .window(let window): target = WindowID(rawValue: window.id).map(TopicTarget.window)
        case .pane(let pane, _): target = .pane(pane)
        }
        guard let target else { return }
        let to: TopicDestination = destination.map { .topic(.id($0.id)) } ?? .newTopic(title: title)
        perform(TopicRequest(.move(to: to), target: target), presenting: .membership(selecting: source.window.id))
    }

    func removeWindowFromTopic(_ window: TmuxWindow) {
        var draft = MoveDraft(window: window, paneID: window.activePaneID, scope: .window)
        draft.destination = .sessions(topic: nil)
        palette.begin(.move(draft), keepingHistory: true)
    }

    func removeFromTopic(_ window: TmuxWindow) {
        guard let session = SessionID(rawValue: window.sessionID) else { return }
        perform(TopicRequest(.removeFromTopic, target: .session(session)), presenting: .membership(selecting: nil))
    }

    /// The Session leaves its Topic and stops. The palette shows the Topic's next Session, or the Empty Topic.
    func removeAndKill(_ window: TmuxWindow, worktrees: [String]) {
        guard let session = SessionID(rawValue: window.sessionID) else { return }
        perform(TopicRequest(.removeAndKill(worktrees: worktrees), target: .session(session)))
    }

    func presentRenameTopic(keepingHistory: Bool = false) {
        topicWatcher.reload()
        guard !changingTopic, !isRemote,
              let topic = topicWatcher.records.first(where: { $0.id == activeTopicID && $0.settledAt == nil }) else { return }
        palette.begin(.text(.renameTopic(topic)), text: topic.title ?? "", keepingHistory: keepingHistory)
    }

    func presentAddSession(toTopic id: String? = nil, keepingHistory: Bool = false) {
        topicWatcher.reload()
        let selected = id ?? activeTopicID
        guard let topic = topicWatcher.records.first(where: { $0.id == selected && $0.settledAt == nil }),
              !changingTopic, !isRemote else { return }
        palette.begin(.addSession(topic), keepingHistory: keepingHistory)
        refreshSessionPaths()
    }

    func renameTopic(_ id: String, to title: String) {
        perform(TopicRequest(.rename(title: title), target: .topic(.id(id))))
    }

    /// Puts a Session before or after another Session of its Topic, which then keeps the order the user gave.
    func moveSession(_ sessionID: String, to placement: TopicSessionPlacement) {
        guard let session = SessionID(rawValue: sessionID) else { return }
        perform(TopicRequest(.moveSession(to: placement), target: .session(session)))
    }

    func sortSessionsByCreation(ofTopic id: String) {
        perform(TopicRequest(.sortSessions, target: .topic(.id(id))))
    }

    func suggestTopicTitle(for id: String, completion: @escaping (String) -> Void) {
        topicWatcher.reload()
        guard var topic = topicWatcher.records.first(where: { $0.id == id && $0.settledAt == nil }) else {
            showTopicTitleFailure("The Topic is no longer open.")
            return
        }
        topic.sessions = rememberedTopics[id]?.sessions ?? topic.sessions
        let commands = topicConfig.titleCommandFallbacks
        let sessionPaths = sessionPaths
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try TopicTitleSuggester(commands: commands).suggest(for: .topic(topic, TmuxServer.app.snapshot(), sessionPaths))
            }
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(let title): completion(title)
                    case .failure(let error): self.showTopicTitleFailure(String(describing: error))
                    }
                }
            }
        }
    }

    func suggestNewTopicTitle(completion: @escaping (String) -> Void) {
        let commands = topicConfig.titleCommandFallbacks
        let windowID = selectedWindowID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () -> String in
                let snapshot = TmuxServer.app.snapshot()
                let window = windowID.flatMap { id in snapshot.windows.first { $0.id == id } }
                let pane = window.flatMap { window in snapshot.panes.first { $0.id == window.activePaneID } }
                return try TopicTitleSuggester(commands: commands).suggest(for: .newTopic(pane, nil))
            }
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(let title): completion(title)
                    case .failure(let error): self.showTopicTitleFailure(String(describing: error))
                    }
                }
            }
        }
    }

    private func showTopicTitleFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not suggest a Topic title"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// `newWorktree` opens the Session on a new Worktree from the chosen one; it needs a repository row.
    func addSession(_ choice: SessionChoice, toTopic id: String, newWorktree: Bool) {
        perform(TopicRequest(.addSession(sessionPath: choice.sessionPath.folder.path, workingCopy: choice.workingCopy(newWorktree: newWorktree), name: choice.name),
                             target: .topic(.id(id))))
    }

    /// Moves a Pane into a new Untitled Topic: the Pane that the terminal shows, or the Window's or Pane's id.
    func presentMovePane(_ target: TopicTarget?, includesTab: Bool = false, keepingHistory: Bool = false) {
        guard !isRemote, let window = selectedWindow else { return }
        switch target {
        case .window(let id):
            if let source = windows.first(where: { $0.id == id.rawValue }) { palette.openMove(source, scope: .pane, includesTab: includesTab, keepingHistory: keepingHistory) }
        case .pane(let id):
            if let pane = panes.first(where: { $0.id == id.rawValue }),
               let source = windows.first(where: { $0.id == pane.windowID }) { palette.openMove(source, scope: .pane, paneID: id.rawValue, includesTab: includesTab, keepingHistory: keepingHistory) }
        default:
            palette.begin(.move(MoveDraft(window: window, paneID: window.activePaneID, scope: .pane, includesTab: includesTab, resolution: .loading)),
                          keepingHistory: keepingHistory)
            let token = palette.invocation
            let environment = generation
            let tty = clientTTY ?? surface?.ttyName
            Task {
                let snapshot = await Task.detached { TmuxServer.app.snapshot() }.value
                guard generation == environment, palette.invocation == token,
                      case .move(let draft) = palette.flow else { return }
                let windowID = snapshot.clients.first { $0.tty == tty }?.windowID ?? window.id
                guard var source = snapshot.windows.first(where: { $0.id == windowID }) else {
                    palette.close()
                    return
                }
                source.sourceID = draft.window.sourceID
                palette.replaceFlow(.move(MoveDraft(window: source, paneID: source.activePaneID, scope: draft.scope,
                                                    includesTab: draft.includesTab)))
            }
        }
    }

    /// Snooze Topics… and Unsnooze Topics… start at the check step: with nothing checked, or with the Topics of a
    /// Tag for "Snooze its Topics…".
    func presentCheck(_ draft: CheckDraft, keepingHistory: Bool = false) {
        topicWatcher.reload()
        palette.begin(.check(draft), keepingHistory: keepingHistory)
    }

    /// Snooze Topic: the "until" step of the same flow, so ⌫ goes back to the check step with the Topic checked.
    func presentSnooze(_ id: String, keepingHistory: Bool = false) {
        topicWatcher.reload()
        guard topicWatcher.records.contains(where: { $0.id == id && $0.settledAt == nil }) else { return }
        palette.begin(.snoozeUntil([id]), keepingHistory: keepingHistory)
    }

    /// Unsnooze Topic: the Active Topic at once while it is Snoozed, else a choice of one Snoozed Topic.
    func presentUnsnoozeTopic(keepingHistory: Bool = false) {
        if let id = snoozedActiveTopicID {
            palette.close(restoringFocus: false)
            unsnoozeTopic(id)
            return
        }
        guard !isRemote, !topics.snoozedRows.isEmpty else { return }
        topicWatcher.reload()
        palette.begin(.unsnoozeTopic, keepingHistory: keepingHistory)
    }

    /// One write for all of `ids`, so Topics whose Snooze ends together keep their order. Returns the open Topics
    /// among them.
    @discardableResult
    private func clearSnoozes(_ ids: [String]) -> [String] {
        guard !changingTopic, !ids.isEmpty else { return [] }
        do {
            let (cleared, moved) = try topicWatcher.write(locks: liveLocks) { transaction -> ([String], [SessionLock]) in
                let saves = transaction.records.filter { ids.contains($0.id) && $0.settledAt == nil }.map { record in
                    var save = record
                    save.snoozedUntil = nil
                    return save
                }
                return (saves.map(\.id), try transaction.setSnoozes(saves, insertPosition: topicConfig.insertPosition))
            }
            writeLocks(moved)
            return cleared
        } catch {
            showTopicFailure(error)
            return []
        }
    }

    /// One write for the whole set. When the Active Topic is in the set, the Next Topic outside the set opens.
    func snoozeTopics(_ ids: [String], until deadline: SnoozeDeadline) {
        guard !changingTopic else { return }
        let next = activeTopicID.flatMap { ids.contains($0) ? nextTopic(after: $0, skipping: Set(ids)) : nil }
        do {
            let snoozed = try topicWatcher.write { transaction -> Bool in
                let saves = SnoozeSet(ids, until: deadline, records: transaction.records).saves
                try transaction.setSnoozes(saves)
                return !saves.isEmpty
            }
            guard snoozed else { return }
            palette.close()
            if let next { showTopic(next) }
        } catch { showTopicFailure(error) }
    }

    /// Unsnooze Topics…: one write for the whole set.
    func unsnoozeTopics(_ ids: [String]) {
        guard !clearSnoozes(ids).isEmpty else { return }
        palette.close()
    }

    /// The Sidebar's Unsnooze: back to the Topics list, and to its Window when it has one. A Dormant
    /// Topic stays Dormant, because Unsnooze changes nothing in tmux.
    func unsnoozeTopic(_ id: String) {
        guard !clearSnoozes([id]).isEmpty else { return }
        if let window = entryWindow(of: .topic(id)) { select(window) }
    }

    /// The open Topic of the Window the user looks at, or of the empty-Topic view; nil for No Topic.
    var activeTopicID: String? {
        if case .topic(let id) = topics.activeTopic { return id }
        return nil
    }

    /// One Zen at a time: while Zen is on, the Zen action ends it.
    func toggleZen(keeping id: String, keepingHistory: Bool = false) {
        topicWatcher.reload()
        if topicWatcher.zen != nil { endZen() } else { palette.begin(.zen(id), keepingHistory: keepingHistory) }
    }

    /// The Zen menu item and the `toggle_zen` key keep the Active Topic. No Topic and a Locked Session are not Topics,
    /// and Zen starts only in Topics mode, so otherwise they can only end Zen.
    func toggleZenOfActiveTopic(keepingHistory: Bool = false) {
        if let id = activeTopicID, topics.mode == .topics { toggleZen(keeping: id, keepingHistory: keepingHistory) } else { endZen() }
    }

    var canToggleZenOfActiveTopic: Bool { topicWatcher.zen != nil || (activeTopicID != nil && topics.mode == .topics) }

    /// One write: the store puts the Zen record down before the Snoozes, so a Topic Snoozed by Zen is always in it.
    func startZen(keeping id: String, until deadline: SnoozeDeadline) {
        guard !changingTopic else { return }
        do {
            let started = try topicWatcher.write { transaction -> Bool in
                guard transaction.zen == nil else { return false }
                let (zen, saves) = ZenRecord.start(keeping: id, until: deadline, records: transaction.records)
                transaction.zen = zen
                try transaction.setSnoozes(saves)
                return true
            }
            if started { palette.close() }
        } catch { showTopicFailure(error) }
    }

    /// Ending twice is safe: a restored Topic no longer has Zen's Snooze, so a second end skips it.
    func endZen() {
        guard !changingTopic else { return }
        do {
            writeLocks(try topicWatcher.write(locks: liveLocks) { transaction -> [SessionLock] in
                guard let zen = transaction.zen else { return [] }
                let moved = try transaction.setSnoozes(zen.end(records: transaction.records, now: Date()),
                                                       insertPosition: topicConfig.insertPosition)
                transaction.zen = nil
                return moved
            })
        } catch { showTopicFailure(error) }
    }

    /// Wakes the due Topics with one toast line each. When Zen's time comes, its Topics wake with them and
    /// share one line. Settling the kept Topic, in any App Window or through `muxify topic`, ends Zen.
    private func wakeTopics() {
        guard !changingTopic else { return }
        if let zen = topicWatcher.zen, !topicWatcher.records.contains(where: { $0.id == zen.keptTopicID && $0.settledAt == nil }) {
            endZen()
        }
        let endingZen = topicWatcher.zen.flatMap { $0.deadline?.isDue(at: Date()) == true ? $0 : nil }
        let zenTopicIDs = Set(endingZen?.changes.map(\.topicID) ?? [])
        let wakes = topics.dueWakes
        let woken = Set(clearSnoozes(wakes.map(\.id)))
        var messages: [String] = []
        var zenWoken = 0
        for wake in wakes where woken.contains(wake.id) {
            if zenTopicIDs.contains(wake.id) { zenWoken += 1 } else { messages.append(wake.message) }
        }
        if endingZen != nil {
            do {
                try topicWatcher.write { $0.zen = nil }
                messages.insert(zenWoken == 0 ? "Zen ended" : "Zen ended: \(zenWoken) Topic\(zenWoken == 1 ? " is" : "s are") back", at: 0)
            } catch { NSLog("muxify: ending Zen: \(error)") }
        }
        guard !messages.isEmpty else { return }
        wakeToastDismiss?.cancel()
        wakeToast = messages.joined(separator: "\n")
        let dismiss = DispatchWorkItem { [weak self] in self?.wakeToast = nil }
        wakeToastDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: dismiss)
    }

    func presentSettleTopic(_ id: String? = nil, keepingHistory: Bool = false) {
        topicWatcher.reload()
        let selected = id ?? activeTopicID
        if let topic = topicWatcher.records.first(where: { $0.id == selected && $0.settledAt == nil }) { palette.begin(.confirm(PaletteConfirmation(.settle(topic))), keepingHistory: keepingHistory) }
    }

    func presentForgetTopic(_ id: String, keepingHistory: Bool = false) {
        topicWatcher.reload()
        guard let topic = topicWatcher.records.first(where: { $0.id == id }) else { return }
        guard !changingTopic, !isRemote else { return }
        palette.begin(.confirm(PaletteConfirmation(.forget(topic))), keepingHistory: keepingHistory)
    }

    func forgetTopic(_ id: String, choices: [TopicSettleSession], worktrees: [String]) {
        if topicSelection.emptyTopicID == id { topicSelection.emptyTopicID = nil }
        perform(TopicRequest(.forget(choices: choices, worktrees: worktrees), target: .topic(.id(id)), expectedSessionIDs: choices.map(\.id)))
    }

    func settleTopic(_ id: String, choices: [TopicSettleSession], outcome: String) {
        let next = activeTopicID == id ? nextTopic(after: id) : nil
        perform(TopicRequest(.settle(choices: choices, outcome: outcome), target: .topic(.id(id)), expectedSessionIDs: choices.map(\.id)), presenting: .settle(next))
    }

    func reopenTopic(_ id: String, _ choice: TopicReopening.Choice) {
        let command: TopicCommand
        switch choice {
        case .reopen: command = .reopen
        case .startFresh: command = .startFresh
        }
        perform(TopicRequest(command, target: .topic(.id(id))))
    }

    /// The open Topic has a Session to create, the same test that makes the empty-Topic view offer the Reopen choice.
    /// An Empty Topic remembers no Session, so going to it offers Add a Session and creates nothing implicitly.
    private func reopensOnArrival(_ id: String) -> Bool {
        guard topicWatcher.records.contains(where: { $0.id == id && $0.settledAt == nil && !$0.sessions.isEmpty }),
              case .success(let reopening)? = reopening(id, .reopen) else { return false }
        return !reopening.sessions.isEmpty
    }

    /// What `reopenTopic` would create now, for the panel to show before the user chooses.
    func reopening(_ id: String, _ choice: TopicReopening.Choice) -> Result<TopicReopening, Error>? {
        guard let topic = topicWatcher.records.first(where: { $0.id == id }) else { return nil }
        return Result {
            try TopicReopening(topic: topic, records: topicWatcher.records, windows: windows, sessionPaths: sessionPaths,
                               existingDirectories: TopicReopening.existingWorktrees(of: topic), choice: choice)
        }
    }

    private func enqueueTopicRequest(_ request: TopicRequest) {
        topicRequests.append(request)
        drainTopicRequests()
    }

    private func drainTopicRequests() {
        guard !changingTopic, !topicRequests.isEmpty else { return }
        perform(topicRequests.removeFirst())
    }

    /// How the app shows a finished Topic request.
    enum TopicPresentation {
        case edit
        case newTopic
        /// A Session or Window that moved shows where it is now; nothing else changes.
        case membership(selecting: String?)
        case settle(TopicGroupID?)
        case move(source: String, tab: BrowserTab?)
    }

    /// The one path for every Topic edit of the app. The app's unsaved memory goes to disk and to tmux first,
    /// so the service reads the same truth as any other process.
    func perform(_ request: TopicRequest, presenting presentation: TopicPresentation = .edit) {
        guard !changingTopic else { return }
        flushTopicMemory()
        let browserCommands = pendingBrowserCommands
        changingTopic = true
        topicEditGeneration += 1
        if case .membership(let windowID?) = presentation { pendingSelection = (windowID, Date().addingTimeInterval(5), false) }
        let client = clientTTY ?? surface?.ttyName
        let service = topicService()
        let environment = generation
        let invocation = palette.invocation
        Task { [weak self] in
            let response = await Task.detached(priority: .userInitiated) {
                for arguments in browserCommands { _ = try? TmuxServer.app.run(arguments) }
                return service.handle(request, client: client)
            }.value
            guard let self else { return }
            guard self.generation == environment else {
                self.changingTopic = false
                self.topicWatcher.reload()
                self.refresh(attachIfNeeded: true)
                return
            }
            self.present(response, as: presentation, invocation: invocation)
        }
    }

    /// The service on the Local server, with the SessionPaths as git reported them last.
    func topicService() -> TopicService {
        TopicService(paths: topicWatcher.store.paths, server: .app, sessionPaths: sessionPaths, topics: topicConfig)
    }

    private func present(_ response: TopicResponse, as presentation: TopicPresentation, invocation: UUID) {
        topicWatcher.reload()
        changingTopic = false
        let ownsPalette = palette.invocation == invocation
        switch response {
        case .topics, .topic, .snoozeChanged:
            break
        case .failed(let failure):
            pendingSelection = nil
            if case .newTopic = presentation, failure.phase == .nothingChanged, ownsPalette {
                newTopicFailure = "Could not save the Topic. \(failure.message)"
            } else if failure.kind == .topicMembershipChanged, ownsPalette {
                if case .confirm(let draft) = palette.flow { draft.impactChanged = true }
                palette.loadFlow()
            } else {
                showFailedTopicRequest(failure)
            }
        case .changed(let change):
            switch presentation {
            case .membership(let windowID):
                if let windowID { selectedWindowID = windowID }
            case .settle(let next):
                if ownsPalette { palette.close(restoringFocus: false) }
                pendingNextTopic = next
            case .move(let source, let tab):
                if case .window(let destination)? = change.shown {
                    if let tab, source != destination.rawValue {
                        browser(for: source).moveTab(tab, to: browser(for: destination.rawValue))
                    }
                    pendingSelection = (destination.rawValue, Date().addingTimeInterval(5), false)
                    selectedWindowID = destination.rawValue
                }
            case .edit, .newTopic:
                if ownsPalette { palette.close(restoringFocus: false) }
                switch change.shown {
                case .emptyTopic(let id)?:
                    showEmptyTopic(id)
                    if case .newTopic = presentation, ownsPalette { presentAddSession(toTopic: id) }
                case .window(let id)?:
                    pendingSession = nil
                    pendingSelection = (id.rawValue, Date().addingTimeInterval(5), false)
                    selectedWindowID = id.rawValue
                    sidebarMode = .topics
                    moveFocusIntoWindow()
                    if surface == nil || surface?.processExited == true,
                       let window = windows.first(where: { $0.id == id.rawValue })
                        ?? TmuxServer.app.snapshot().windows.first(where: { $0.id == id.rawValue }) {
                        attach(to: Target(window))
                    }
                case nil:
                    break
                }
            }
        }
        refresh(attachIfNeeded: surface == nil)
    }

    /// Writes the remembered Sessions that wait for their write delay.
    private func flushTopicMemory() {
        for id in Array(topicSnapshots.keys) {
            topicPersistWork[id]?.cancel()
            topicPersistWork[id] = nil
            persistRememberedTopic(id)
        }
    }

    private func showFailedTopicRequest(_ failure: TopicFailure) {
        showTopicAlert(failure.phase.summary, detail: failure.message)
    }

    private func showTopicFailure(_ error: Error) {
        showTopicAlert("No changes were made.", detail: String(describing: error))
    }

    private func showTopicAlert(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = "Could not change the Topic"
        alert.informativeText = message + " " + detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Every way of reaching a Window ends in `selectedWindowID`, so this is the one place a visit is recorded.
    /// The snapshot that first lists the Window records it too, when the selection came before the Windows.
    private func recordVisit() {
        guard let window = selectedWindow else { return }
        let group: TopicGroupID = window.topicID.map { id in
            topicWatcher.records.contains { $0.id == id && $0.settledAt == nil } ? .topic(id) : .noTopic
        } ?? .noTopic
        // A mutating call on `visits` notifies its readers even when it records nothing, and this runs on each refresh.
        var log = visits
        guard log.record(window, group: group, sessionPaths: sessionPaths, folders: folders, at: Date()) else { return }
        visits = log
        visits.save(to: .standard)
    }

    let topicWatcher = TopicWatcher()
    var topicSelection = TopicSelection()
    private(set) var topicBranches = TopicBranches()
    /// The last read, so a refresh runs `ps` only when a Topic Pane starts another program.
    @ObservationIgnored private var paneCommandLines = PaneCommandLines()

    /// The open Snoozed or Settled group, and the Settled pages shown.
    var topicGroups = TopicGroupsState()

    /// Built again only after a change to what it reads, or when a Snooze deadline passes. The Sidebar, the menus
    /// and the terminal area read it many times in each update, and each build is expensive.
    var topics: TopicsModel { topicsCache.value }
    @ObservationIgnored private lazy var topicsCache = ObservedCache(expiry: \.changesAt) { [unowned self] in buildTopics() }

    private func buildTopics() -> TopicsModel {
        var selection = topicSelection
        selection.windowID = selectedWindowID
        var config = self.config
        // Topic records and SessionPaths are on this Mac; a Remote App Window shows Sessions only.
        if isRemote { config.sidebar.topics = false }
        return TopicsModel(records: topicWatcher.records, windows: windows, config: config,
                           selection: selection, mode: sidebarMode, groups: topicGroups, agents: agents,
                           panes: panesVisible ? panes : nil, zen: isRemote ? nil : topicWatcher.zen)
    }

    var sidebarFormatContexts: SidebarFormatContexts { sidebarFormatsCache.value }
    @ObservationIgnored private lazy var sidebarFormatsCache = ObservedCache { [unowned self] in
        SidebarFormatContexts(model: topics, windows: windows, panes: panes, agents: agents,
                              branches: topicBranches, records: topicWatcher.records, sessionPaths: sessionPaths,
                              tabCounts: Dictionary(windows.map { ($0.id, tabCount(for: $0)) },
                                                    uniquingKeysWith: { first, _ in first }))
    }

    func sidebarWindowRow(_ window: TmuxWindow) -> SidebarFormats.WindowRowContent {
        config.sidebar.formats.windowRow(in: sidebarFormatContexts.windows[window.id] ?? .init(), mode: topics.mode)
    }

    func sidebarText(_ object: SidebarFormats.Object, context: SidebarFormat.Context?) -> SidebarFormats.Text {
        config.sidebar.formats.text(for: object, in: context ?? .init(), mode: topics.mode)
    }

    /// What the `topic.tags` Format gives for each of the card's Tags; nil when it shows none or `tag_placement` is `none`.
    func cardTags(_ row: TopicsModel.Row) -> CardTags? {
        guard config.sidebar.tagPlacement != .none, !row.tags.isEmpty, let context = sidebarFormatContexts.topics[row.id] else { return nil }
        let items = config.sidebar.formats.topicTags[topics.mode].items(in: context).compactMap { item in
            row.tags.indices.contains(item.index) ? CardTags.Item(shown: row.tags[item.index], text: item.text) : nil
        }
        return items.isEmpty ? nil : CardTags(placement: config.sidebar.tagPlacement, items: items, identifier: row.id.accessibilityID)
    }

    /// Going to a Snoozed or Settled Topic opens its group, so the Sidebar shows it; leaving the group closes it.
    func updateTopicSelection() {
        let model = topics
        var groups = topicGroups
        groups.follow(model)
        if groups != topicGroups { topicGroups = groups }
        var selection = topicSelection
        selection.select(windowID: selectedWindowID, activeTopic: model.activeTopic)
        // This runs on each refresh. An unchanged write still notifies every reader of `topics`.
        if selection != topicSelection { topicSelection = selection }
    }

    private(set) var windows: [TmuxWindow] = []
    /// Agents reporting through their Pane's options (ADR 0004), in tmux order.
    private(set) var agents: [Agent] = []
    private(set) var panes: [TmuxPane] = []
    private(set) var serverRunning = true
    private(set) var selectedWindowID: String? {
        didSet {
            // A selected Window ends the Empty Topic; a Window that goes away, as when the tmux server stops, does not.
            if selectedWindowID != nil, selectedWindowID != oldValue { topicSelection.emptyTopicID = nil }
            if selectedWindowID != nil { topicSelection.showsEmptyNoTopic = false }
            windowRecovery.selected(selectedWindowID)
            rememberSelection()
            recordVisit()
            updateTopicSelection()
            guard selectedWindowID != oldValue else { return }
            // Each Window has its own Git View, which stays open or closed,
            // as it was, while another Window is shown.
            let previous = oldValue.flatMap { gitViews[$0] }
            let coveredWindow = previous?.isOpen == true
            previous?.suspend()
            if let gitView = selectedWindowID.flatMap({ gitViews[$0] }), gitView.isOpen {
                gitView.resume()
            } else if coveredWindow {
                moveFocusIntoWindow()
            }
        }
    }
    private(set) var surface: TerminalSurfaceView?
    private(set) var terminalMessage: String?
    private(set) var activeEnvironment: RemoteEnvironment?
    private(set) var environmentStatus = "Local"
    private(set) var isConnected = false
    /// True only after a successful inventory, never inferred from an SSH error.
    private(set) var hasNoSessions = false
    var remoteEnvironments: [RemoteEnvironment] { configStore.config.remoteEnvironments }
    /// A Remote Environment's own Config, as last read without a syntax
    /// error; nil when that machine has none (ADR 0010).
    private(set) var remoteConfig: LoadedConfig?
    var remoteProblemsDismissed = false
    /// The Config this App Window runs with: its Remote Environment's own
    /// when that machine has one, else the local Config.
    var config: Config { remoteConfig?.config ?? configStore.config }
    /// From the last look at `sessions.paths` on the Environment's machine.
    let palette = CommandPalette()
    let hintHold = HintHold()
    var isRemote: Bool { activeEnvironment != nil }
    var environmentName: String { activeEnvironment?.name ?? "Local" }
    /// The Ghostty theme's colors; the header and sidebar follow them.
    private(set) var theme: TerminalTheme?

    /// The Sidebar mode the user picked. `TopicsModel.mode` is the one shown, because the Config can turn a mode off.
    var sidebarMode = SidebarMode(rawValue: UserDefaults.standard.string(forKey: "sidebarWorkView") ?? "") ?? .topics {
        didSet { UserDefaults.standard.set(sidebarMode.rawValue, forKey: "sidebarWorkView") }
    }
    /// The open Session cards, by name (names survive tmux server restarts, ids don't). Sessions mode and the
    /// No Topic card in Topics mode share them, so a card opened in either is open in both.
    var openSessionCards = Set(UserDefaults.standard.stringArray(forKey: "expandedSessions") ?? []) {
        didSet { UserDefaults.standard.set(Array(openSessionCards), forKey: "expandedSessions") }
    }
    var sidebarVisible = UserDefaults.standard.object(forKey: "sidebarVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sidebarVisible, forKey: "sidebarVisible") }
    }
    /// The sidebar's two sections, shown or hidden from the View menu.
    var sessionsVisible = UserDefaults.standard.object(forKey: "sessionsVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sessionsVisible, forKey: "sessionsVisible") }
    }
    private var showAgents = ShowAgents()
    /// Show Agents for the Sidebar mode shown now; each mode keeps its own value.
    var agentsVisible: Bool {
        get { configStore.config.sidebar.agents[shownSidebarMode] ?? showAgents[shownSidebarMode] }
        set { showAgents[shownSidebarMode] = newValue }
    }
    /// The Sidebar mode on screen. Reads only the Config and `sidebarMode`, so a menu that shows it is not
    /// rebuilt on every tmux refresh, as it would be through `topics`.
    var shownSidebarMode: SidebarMode {
        var sidebar = configStore.config.sidebar
        if isRemote { sidebar.topics = false }
        return sidebar.shownMode(chosen: sidebarMode)
    }
    /// One value for both Sidebar modes, off until the user turns it on.
    var panesVisible: Bool {
        get { configStore.config.sidebar.panes ?? showPanes }
        set { showPanes = newValue }
    }
    private var showPanes = UserDefaults.standard.bool(forKey: "panesVisible") {
        didSet { UserDefaults.standard.set(showPanes, forKey: "panesVisible") }
    }

    var selectedWindow: TmuxWindow? {
        guard let selectedWindowID else { return nil }
        return windows.first { $0.id == selectedWindowID }
    }

    var sessions: [SessionGroup] {
        var groups: [SessionGroup] = []
        for window in windows {
            if let last = groups.indices.last, groups[last].id == window.sessionID {
                groups[last].windows.append(window)
            } else {
                groups.append(SessionGroup(id: window.sessionID, name: window.sessionName, windows: [window]))
            }
        }
        return groups
    }

    @ObservationIgnored let terminalHost = TerminalHostView()
    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let events = TmuxEvents()
    @ObservationIgnored private var browsers: [String: Browser] = [:]
    @ObservationIgnored private var topicSnapshots: [String: TmuxSnapshot] = [:]
    @ObservationIgnored private var rememberedTopics: [String: TopicRecord] = [:]
    /// The record's `sessions` on disk when its pending snapshot was taken.
    @ObservationIgnored private var topicSnapshotBases: [String: [JSONValue]] = [:]
    @ObservationIgnored private var memoryServerID: String?
    @ObservationIgnored private var topicPersistWork: [String: DispatchWorkItem] = [:]
    /// Each Window's Git View, made when it first opens and kept while the
    /// Window lives. Observed, for the sidebar's Git View icons.
    private var gitViews: [String: GitView] = [:]
    @ObservationIgnored private var persistWork: [String: DispatchWorkItem] = [:]
    /// Keep changes dirty until tmux confirms the write, including commands
    /// already submitted when a window closes. Never flush unchanged Browsers
    /// over newer state saved by another App Window.
    @ObservationIgnored private var dirtyBrowsers: [String: UUID] = [:]
    /// Windows whose `@muxify_open` we consumed and are clearing.
    @ObservationIgnored private var consumingOpen = Set<String>()
    @ObservationIgnored private var rememberedWindowID: String?
    @ObservationIgnored private var clientTTY: String?
    /// A click we sent to tmux that the next snapshots may not reflect yet.
    private var pendingSelection: (windowID: String, deadline: Date, readsOnArrival: Bool)?
    /// A Session asked for by name (`muxify session open`) that the snapshot
    /// may not list yet: Muxify is just launching, or it was just created.
    @ObservationIgnored private var pendingSession: (name: String, deadline: Date)?
    /// Sessions a SessionPath row is creating, by directory, until a snapshot lists them or a few seconds pass.
    @ObservationIgnored private var pendingOpenings: [Folder: (name: String, deadline: Date)] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var isRefreshing = false
    /// Something changed while a snapshot was in flight; take another one.
    @ObservationIgnored private var refreshAgain = false
    /// Each Pane's `@muxify_agent_status` in the last snapshot, to catch changes.
    @ObservationIgnored private var agentStatuses: [String: String] = [:]
    @ObservationIgnored private var activationObserver: Any?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var connection: TmuxConnection?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isTransitioning = false
    @ObservationIgnored private var reconnectWork: DispatchWorkItem?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var windowRecovery = WindowRecovery()
    @ObservationIgnored private var recoveryPending = false
    @ObservationIgnored private var attachmentTarget: Target?
    @ObservationIgnored private var createSessionIfNeeded = true
    @ObservationIgnored private var serverID: String?
    @ObservationIgnored private(set) var homeDirectory = NSHomeDirectory()
    /// Where the Remote Environment's Config is, or would be.
    @ObservationIgnored private var remoteConfigPath: String?
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private let connectionCleanup = ConnectionCleanup()
    @ObservationIgnored var onSelectEnvironment: ((String?) -> Void)?
    @ObservationIgnored var onNewAppWindow: (() -> Void)?
    @ObservationIgnored var shouldConsumeOpenRequests: (() -> Bool)?
    #if DEBUG
    @ObservationIgnored private var gitDemoObserver: NSObjectProtocol?
    #endif

    init(configStore: ConfigStore, environment: RemoteEnvironment? = nil) {
        self.configStore = configStore
        activeEnvironment = environment
        palette.store = self
        #if DEBUG
        observeGitDemoRequests()
        #endif
        // Browser state used to be kept here, keyed by window id; it now lives
        // on the tmux Windows (ADR 0003).
        UserDefaults.standard.removeObject(forKey: "browserURLs")
        UserDefaults.standard.removeObject(forKey: "browserVisible")
        // Replaced by browserShare, so the Browser scales with the window.
        UserDefaults.standard.removeObject(forKey: "browserWidth")
    }

    func start() {
        guard !started, !isShuttingDown else { return }
        started = true
        // Topics live on this Mac, so a Remote App Window leaves them alone.
        if !isRemote {
            topicWatcher.start()
            refreshSessionPaths()
        }
        theme = GhosttyRuntime.shared.theme
        guard GhosttyRuntime.shared.app != nil else {
            terminalMessage = "libghostty failed to initialize."
            return
        }
        installKeyMonitor()
        // Coming back to Muxify reads the Agents in the Window on screen.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.readActiveTopicOnEntry()
            self.refresh()
        } }
        startConnection()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Environments

    func selectEnvironment(named name: String?) {
        guard !isShuttingDown else { return }
        onSelectEnvironment?(name)
    }

    func reconcileEnvironments() {
        guard let activeEnvironment else { return }
        let next = remoteEnvironments.first { $0.name == activeEnvironment.name }
        if next != activeEnvironment { transition(to: next) }
    }

    /// Reconnect after transport/config changes. Environment clicks instead
    /// open or focus another App Window through the app coordinator.
    private func transition(to next: RemoteEnvironment?, target: Target? = nil, createSessionIfNeeded: Bool = true) {
        guard !isShuttingDown else { return }
        receiveHintInput(.reset)
        if next != activeEnvironment {
            remoteConfig = nil
            remoteConfigPath = nil
            sessionPaths = []
        }
        activeEnvironment = next
        attachmentTarget = target
        self.createSessionIfNeeded = createSessionIfNeeded
        generation = UUID()
        reconnectWork?.cancel()
        reconnectWork = nil
        isConnected = false
        environmentStatus = next == nil ? "Switching to Local" : "Connecting to \(next!.name)…"
        terminalMessage = nil
        guard !isTransitioning else { return }
        isTransitioning = true
        let oldConnection = connection
        let oldSurface = surface
        let flush = pendingBrowserCommands
        events.stop()
        surface = nil
        terminalHost.show(nil)
        clearServerState()
        connection = nil
        connectionCleanup.run(retire: { oldConnection?.retire(flushing: flush) },
                              closeSurface: { oldSurface?.close() },
                              cleanup: { oldConnection?.cleanup() }) { [weak self] in
            guard let self else { return }
            self.isTransitioning = false
            guard self.started, !self.isShuttingDown else { return }
            self.startConnection()
        }
    }

    private func startConnection() {
        guard !isTransitioning else { return }
        if !isRemote, Tmux.binary == nil {
            terminalMessage = "tmux was not found. Install it with `brew install tmux`."
            environmentStatus = "Local tmux was not found"
            return
        }
        do { connection = try TmuxConnection(environment: activeEnvironment) }
        catch {
            terminalMessage = String(describing: error)
            environmentStatus = "Could not start \(environmentName)"
            return
        }
        let current = generation
        events.onEvent = { [weak self] event in
            guard let self, self.generation == current else { return }
            self.handle(event)
        }
        if isRemote {
            environmentStatus = "Connecting to \(environmentName)…"
            attach(to: attachmentTarget, createSessionIfNeeded: createSessionIfNeeded)
        } else {
            environmentStatus = "Local"
            isConnected = true
            refresh(attachIfNeeded: true)
        }
    }

    private func clearServerState() {
        persistWork.values.forEach { $0.cancel() }
        persistWork.removeAll()
        dirtyBrowsers.removeAll()
        browsers.values.forEach { $0.tearDown() }
        browsers.removeAll()
        removeGitViews()
        consumingOpen.removeAll()
        agentStatuses.removeAll()
        unreadVisit = nil
        explicitReadVisits = AgentReadVisits()
        readGeneration += 1
        pendingReads = 0
        pendingReadNavigations.removeAll()
        readSnapshotPending = false
        windows = []
        agents = []
        palette.close(restoringFocus: false)
        topicSelection.emptyTopicID = nil
        topicSelection.showsEmptyNoTopic = false
        pendingNextTopic = nil
        selectedWindowID = nil
        windowRecovery = WindowRecovery()
        recoveryPending = false
        hasNoSessions = false
        rememberedWindowID = nil
        clientTTY = nil
        serverID = nil
        pendingSelection = nil
        pendingSession = nil
        isRefreshing = false
        refreshAgain = false
        serverRunning = false
        homeDirectory = NSHomeDirectory()
    }

    /// Called before AppKit commits to quitting. Snapshot UI-owned Browser
    /// state here, then wait asynchronously for every owned transport to close.
    func shutdown(completion: @escaping () -> Void) {
        receiveHintInput(.reset)
        guard !isShuttingDown else { connectionCleanup.whenFinished(completion); return }
        isShuttingDown = true
        started = false
        generation = UUID()
        timer?.invalidate()
        timer = nil
        removeGitViews()
        reconnectWork?.cancel()
        reconnectWork = nil
        persistWork.values.forEach { $0.cancel() }
        persistWork.removeAll()
        events.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        let oldConnection = connection
        let oldSurface = surface
        let flush = pendingBrowserCommands
        browsers.values.forEach { $0.tearDown() }
        browsers.removeAll()
        dirtyBrowsers.removeAll()
        connection = nil
        surface = nil
        terminalHost.show(nil)
        connectionCleanup.run(retire: { oldConnection?.retire(flushing: flush) },
                              closeSurface: { oldSurface?.close() },
                              cleanup: { oldConnection?.cleanup() })
        connectionCleanup.whenFinished(completion)
    }

    /// Every completion belongs to the connection that submitted it, never to
    /// whatever Environment happens to be selected when it finishes.
    private func runAsync(_ args: [String], completion: ((Result<String, Error>) -> Void)? = nil) {
        guard let connection, !isTransitioning, !isRemote || isConnected else { return }
        let current = generation
        connection.runAsync(args) { [weak self] result in
            guard let self, self.generation == current else { return }
            if case .failure(let error) = result { NSLog("muxify: tmux command failed: \(error)") }
            completion?(result)
        }
    }

    // MARK: - Polling

    func refresh(attachIfNeeded: Bool = false) {
        guard let connection, !isTransitioning, !changingTopic, pendingReads == 0 else { return }
        // A closed remote master cannot be polled. Its foreground owner reports
        // a final snapshot; a new attachment owns all subsequent operations.
        guard !isRemote || surface != nil else { return }
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        let current = generation
        let topicGeneration = topicEditGeneration
        let readGeneration = self.readGeneration
        let records = topicWatcher.records
        let remote = isRemote
        let commandLines = paneCommandLines
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> TmuxSnapshot in
                var snapshot = try connection.snapshot()
                snapshot.commandLines = commandLines.updating(for: snapshot) { try? connection.runScript(PaneCommandLines.script) }
                return snapshot
            }
            let snapshot = try? result.get()
            let paths = (snapshot?.windows.map(\.sessionPath) ?? []) + (snapshot?.panes.map(\.path) ?? [])
            let branches = remote ? TopicBranches() : TopicBranches(records: records, paths: paths.map(Folder.local)) {
                try? String(contentsOfFile: $0, encoding: .utf8)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == current, !self.isRemote || self.surface != nil else { return }
                self.isRefreshing = false
                switch result {
                case .success(let snapshot):
                    guard topicGeneration == self.topicEditGeneration, readGeneration == self.readGeneration, !self.changingTopic else {
                        self.refresh()
                        return
                    }
                    if self.isRemote {
                        let connecting = !self.isConnected
                        self.clientTTY = snapshot.ownClientTTY
                        self.homeDirectory = snapshot.homeDirectory ?? self.homeDirectory
                        self.isConnected = true
                        if connecting { self.loadRemoteConfig() }
                        self.environmentStatus = "Connected to \(self.environmentName)"
                        self.reconnectAttempt = 0
                        self.terminalMessage = nil
                    } else if !self.isConnected {
                        // A failed read while tmux starts marks a Local Environment disconnected; a good one ends that.
                        self.isConnected = true
                    }
                    if self.topicBranches != branches { self.topicBranches = branches }
                    self.paneCommandLines = snapshot.commandLines
                    self.apply(snapshot, attachIfNeeded: attachIfNeeded)
                case .failure(let error):
                    self.isConnected = false
                    self.memoryServerID = nil
                    if !self.isRemote, self.surface == nil { self.terminalMessage = String(describing: error) }
                    if error as? TmuxError != .notReady {
                        self.environmentStatus = "Waiting for \(self.environmentName): \(error)"
                    }
                }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    /// Resolve switches against a fresh inventory. A close may also emit a
    /// Window switch; following it early would lose our previous-Window fallback.
    private func handle(_ event: TmuxEvents.Event) {
        refresh()
    }

    private func apply(_ snapshot: TmuxSnapshot, attachIfNeeded: Bool) {
        if let serverID, let next = snapshot.serverID, serverID != next {
            clearServerState()
            clientTTY = snapshot.ownClientTTY
            homeDirectory = snapshot.homeDirectory ?? NSHomeDirectory()
        }
        serverID = snapshot.serverID
        if serverRunning, !snapshot.serverRunning {
            browsers.values.forEach { $0.tearDown() }
            browsers.removeAll()
            removeGitViews()
            persistWork.values.forEach { $0.cancel() }
            persistWork.removeAll()
            dirtyBrowsers.removeAll()
        }
        let listedBefore = windows
        if !changingTopic { rememberTopics(in: snapshot) }
        let unresolvedSelectedWindowID = selectedWindow == nil ? selectedWindowID : nil
        if windows != snapshot.windows { windows = snapshot.windows }
        let now = Date()
        pendingOpenings = pendingOpenings.filter { _, opening in
            now < opening.deadline && !snapshot.windows.contains { $0.sessionName == opening.name }
        }
        hasNoSessions = snapshot.windows.isEmpty
        let agents = Agent.list(panes: snapshot.panes, windows: snapshot.windows, ordered: false)
        if self.agents != agents { self.agents = agents }
        if panes != snapshot.panes { panes = snapshot.panes }
        readSnapshotPending = false
        if serverRunning != snapshot.serverRunning { serverRunning = snapshot.serverRunning }
        let ownTTY = clientTTY ?? (isRemote ? nil : surface?.ttyName)
        if !isRemote, surface?.processExited == false {
            connection?.updateLocalClient(snapshot.clients.first { $0.tty == ownTTY && !$0.isControl })
        }
        if recoveryPending, let ownTTY,
           snapshot.clients.contains(where: { $0.tty == ownTTY && $0.windowID == selectedWindowID }) {
            recoveryPending = false
        }

        if let next = pendingNextTopic {
            pendingNextTopic = nil
            recoveryPending = false
            showTopic(next)
        } else if topicSelection.showsEmptyNoTopic {
            recoveryPending = false
        } else if !changingTopic, attachIfNeeded, surface == nil {
            rememberedWindowID = snapshot.lastWindowID
            let last = snapshot.lastWindowID.flatMap { id in snapshot.windows.first { $0.id == id } }
            let requested = takePendingSession(in: snapshot.windows)
            attach(to: (requested ?? last ?? Self.initialWindow(in: snapshot.windows)).map(Target.init))
        } else if !changingTopic, recoveryPending || windowRecovery.selectionDisappeared(in: windows) {
            let fallback = windowRecovery.fallback(in: windows, listedBefore: listedBefore)
            let target = recoveryPending ? selectedWindow ?? fallback : fallback
            pendingSelection = nil
            if let target {
                recoveryPending = true
                if isRemote, surface == nil || surface?.processExited == true {
                    transition(to: activeEnvironment, target: Target(target), createSessionIfNeeded: false)
                    return
                }
                switchClient(to: Target(target))
            } else if !changingTopic {
                selectedWindowID = nil
                recoveryPending = false
                windowRecovery = WindowRecovery()
            }
        } else if !changingTopic {
            followClient(snapshot.clients)
            if surface != nil, let window = takePendingSession(in: windows) { select(window) }
        }
        updateTopicSelection()
        if let unresolvedSelectedWindowID, selectedWindow?.id == unresolvedSelectedWindowID {
            moveFocusIntoWindow()
        }
        recordVisit()
        consumeOpenRequests()
        if !updateUnread(snapshot.panes) { wakeTopics() }

        // (Re)start listening once there is a Session to attach to.
        if snapshot.serverRunning, isConnected, !events.isRunning,
           let sessionID = selectedWindow?.sessionID ?? windows.first?.sessionID {
            if let connection { events.start(sessionID: sessionID, connection: connection) }
        }

        if snapshot.serverRunning {
            let live = Set(windows.map(\.id))
            for id in browsers.keys where !live.contains(id) {
                browsers[id]?.tearDown()
                browsers[id] = nil
                dirtyBrowsers[id] = nil
                persistWork.removeValue(forKey: id)?.cancel()
            }
            for id in gitViews.keys where !live.contains(id) {
                gitViews.removeValue(forKey: id)?.close(restoringFocus: false)
            }
        }
    }

    /// The sidebar follows whatever window our tmux client is showing.
    private func followClient(_ clients: [TmuxClient]) {
        if clientTTY == nil, !isRemote { clientTTY = surface?.ttyName }
        if let tty = clientTTY, let client = clients.first(where: { $0.tty == tty }) {
            if let pending = pendingSelection, client.windowID == pending.windowID || Date() > pending.deadline {
                if pending.readsOnArrival, client.windowID == pending.windowID {
                    explicitReadVisits.enter(windowID: client.windowID, windows: windows)
                }
                pendingSelection = nil
            }
            if client.windowID == selectedWindowID { recoveryPending = false }
            if pendingSelection == nil, selectedWindowID != client.windowID {
                selectedWindowID = client.windowID
            }
        } else if surface == nil, let selectedWindowID, !windows.contains(where: { $0.id == selectedWindowID }) {
            self.selectedWindowID = nil
        }
    }

    /// The current window of the most recently used Session.
    private static func initialWindow(in windows: [TmuxWindow]) -> TmuxWindow? {
        windows.filter(\.isActive).max { $0.sessionActivity < $1.sessionActivity } ?? windows.first
    }

    /// Stored server-wide in tmux rather than in preferences, so it can't
    /// outlive the server and point at a reused window id.
    private func rememberSelection() {
        guard let selectedWindowID, selectedWindowID != rememberedWindowID else { return }
        rememberedWindowID = selectedWindowID
        runAsync(["set-option", "-gq", Tmux.lastWindowOption, selectedWindowID])
    }

    // MARK: - Terminal

    private struct Target {
        let sessionID: String
        let windowID: String
        let path: String?

        init(_ window: TmuxWindow) {
            self.init(sessionID: window.sessionID, windowID: window.id, path: window.path)
        }

        init(sessionID: String, windowID: String, path: String?) {
            self.sessionID = sessionID
            self.windowID = windowID
            self.path = path
        }

        var tmuxTarget: String { "\(sessionID):\(windowID)" }
    }

    /// Starts our tmux client on `target`, or a fresh session if there is none.
    private func attach(to target: Target?, readsOnArrival: Bool = false, createSessionIfNeeded: Bool = true) {
        let args = target.map { ["-u", "attach-session", "-t", $0.tmuxTarget] }
            ?? ["-u", "new-session", "-A", "-s", "main", "-c", NSHomeDirectory()]
        guard let connection, let command = try? connection.terminalCommand(args, target: target?.tmuxTarget, createSessionIfNeeded: createSessionIfNeeded),
              let view = TerminalSurfaceView(command: command, workingDirectory: isRemote ? nil : target?.path, delegate: self)
        else {
            terminalMessage = "Could not start the terminal."
            return
        }
        connection.updateLocalClient(nil)
        surface?.close()
        surface = view
        clientTTY = nil
        terminalMessage = nil
        hasNoSessions = false
        selectedWindowID = target?.windowID
        if let target { pendingSelection = (target.windowID, Date().addingTimeInterval(3), readsOnArrival) }
        terminalHost.show(view)
        moveFocusIntoWindow()
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == current else { return }
            self.refresh()
        }
    }

    func reattach() {
        if isRemote { reconnectAttempt = 0; transition(to: activeEnvironment); return }
        attach(to: (selectedWindow ?? Self.initialWindow(in: windows)).map(Target.init))
    }

    func select(_ window: TmuxWindow, onFailure: ((Error) -> Void)? = nil) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        if topicSelection.emptyTopicID != nil || topicSelection.showsEmptyNoTopic {
            topicSelection.emptyTopicID = nil
            topicSelection.showsEmptyNoTopic = false
            updateTopicSelection()
        }
        switchClient(to: Target(window), onFailure: onFailure)
    }

    /// Ghostty's numbered and last tab actions. Only the selected Session's
    /// Windows participate, in the same order as the Sidebar.
    private func navigateWindows(_ navigation: WindowNavigation) {
        guard let current = selectedWindow else { return }
        let siblings = quickSwitchWindows
        guard let currentIndex = siblings.firstIndex(of: current),
              let targetIndex = navigation.targetIndex(currentIndex: currentIndex, count: siblings.count)
        else { return }
        select(siblings[targetIndex])
    }

    /// Shows the Session's current Window (`muxify session open <name>`).
    func selectSession(named name: String) {
        pendingSession = (name, Date().addingTimeInterval(5))
        // Before the terminal exists, the first snapshot attaches to it.
        guard started, surface != nil else { return }
        if let window = takePendingSession(in: windows) { select(window) } else { refresh() }
    }

    /// The requested Session's current Window once a snapshot lists it. The
    /// request is dropped when found, or after a few seconds.
    private func takePendingSession(in windows: [TmuxWindow]) -> TmuxWindow? {
        guard let pending = pendingSession else { return nil }
        let window = windows.first { $0.sessionName == pending.name && $0.isActive }
            ?? windows.first { $0.sessionName == pending.name }
        if window != nil || Date() > pending.deadline { pendingSession = nil }
        return window
    }

    /// Switches to the Agent's Window with its Pane active. The Pane is
    /// selected first (tmux commands run in order) so the Window shows up
    /// with the Agent already focused.
    func select(_ agent: Agent) {
        guard agents.contains(where: { $0.id == agent.id && $0.sourceID == agent.sourceID }) else { return }
        runAsync(["select-pane", "-t", agent.paneID])
        if let window = windows.first(where: { $0.id == agent.windowID }) {
            select(window)
        } else {
            switchClient(to: Target(sessionID: agent.sessionID, windowID: agent.windowID, path: nil))
        }
    }

    /// Shows the Pane's Window with that Pane active.
    func select(_ pane: TopicsModel.PaneRow) {
        runAsync(["select-pane", "-t", pane.pane.id])
        select(pane.window)
    }

    enum ReadTarget {
        case environment
        case topic(String)
        case session(String)
        case window(String)
        case pane(String)
    }

    var currentReadTarget: ReadTarget? {
        if let id = activeTopicID { return .topic(id) }
        return selectedWindow.map { .session($0.sessionID) }
    }

    private func agents(for change: ReadChange, in target: ReadTarget) -> [Agent] {
        agents.filter { agent in
            guard change.applies(unread: agent.unread, status: agent.status) else { return false }
            switch target {
            case .environment: return true
            case .topic(let id): return windows.contains { $0.id == agent.windowID && $0.topicID == id }
            case .session(let id): return agent.sessionID == id
            case .window(let id): return agent.windowID == id
            case .pane(let id): return agent.paneID == id
            }
        }
    }

    private func topicReadIDs(in target: ReadTarget) -> Set<String> {
        guard !isRemote else { return [] }
        switch target {
        case .topic(let id): return topicWatcher.records.contains { $0.id == id } ? [id] : []
        case .environment: return Set(topicWatcher.records.map(\.id))
        default: return []
        }
    }

    private var canWriteAgentRead: Bool {
        connection != nil && isConnected && pendingReads == 0 && !readSnapshotPending
    }

    func canChangeRead(_ change: ReadChange, in target: ReadTarget?) -> Bool {
        guard let target, !isTransitioning, pendingReadNavigations.isEmpty,
              pendingSelection == nil else { return false }
        if isConnected, pendingReads > 0 || readSnapshotPending { return false }
        let ids = topicReadIDs(in: target)
        if case .topic = target, !ids.isEmpty { return true }
        if change == .read, topicWatcher.records.contains(where: { ids.contains($0.id) && $0.isUnread }) { return true }
        return canWriteAgentRead && !agents(for: change, in: target).isEmpty
    }

    func changeRead(_ change: ReadChange, in target: ReadTarget?) {
        guard let target, canChangeRead(change, in: target) else { return }
        // Earlier visits must not clear a later explicit mark.
        var commands = canWriteAgentRead ? unreadChanges(panes) : []
        if !canWriteAgentRead {
            explicitReadVisits = AgentReadVisits()
            unreadVisit = topicSelection.emptyTopicID == nil && NSApp.isActive && terminalHost.window?.isKeyWindow == true ? selectedWindowID : nil
        }
        guard writeTopicUnread(change == .unread, ids: topicReadIDs(in: target)) else { return }
        if canWriteAgentRead {
            commands += agents(for: change, in: target).map { unreadCommand(change == .unread, paneID: $0.paneID) }
            if !commands.isEmpty { writeUnread(commands) }
        }
    }

    @discardableResult
    private func writeTopicUnread(_ unread: Bool, ids: Set<String>) -> Bool {
        guard !isRemote, !isTransitioning, !ids.isEmpty else { return true }
        do {
            try topicWatcher.write { transaction in
                for record in transaction.records where ids.contains(record.id) && record.isUnread != unread {
                    try transaction.update(record.id) { $0.isUnread = unread }
                }
            }
            return true
        } catch {
            showTopicFailure(error)
            return false
        }
    }

    func readActiveTopicOnEntry() {
        guard NSApp.isActive, terminalHost.window?.isKeyWindow == true,
              let id = topicSelection.emptyTopicID else { return }
        readTopicsOnVisit([id])
    }

    private func readTopicsOnVisit(_ ids: Set<String>) {
        guard !config.notifications.manualRead else { return }
        writeTopicUnread(false, ids: ids)
    }

    private func unreadCommand(_ unread: Bool, paneID: String) -> [String] {
        unread
            ? ["set-option", "-pq", "-t", paneID, Tmux.agentUnreadOption, "1"]
            : ["set-option", "-pqu", "-t", paneID, Tmux.agentUnreadOption]
    }

    private func writeUnread(_ commands: [[String]]) {
        readGeneration += 1
        pendingReads += 1
        readSnapshotPending = true
        runAsync(Array(commands.joined(separator: [";"]))) { [weak self] _ in
            guard let self else { return }
            self.pendingReads -= 1
            self.readGeneration += 1
            self.refresh()
        }
    }

    private func unreadChanges(_ panes: [TmuxPane]) -> [[String]] {
        let lookingAt = topicSelection.emptyTopicID == nil && NSApp.isActive && terminalHost.window?.isKeyWindow == true ? selectedWindowID : nil
        let entering = lookingAt != unreadVisit
        let topic = entering ? lookingAt.flatMap { id in windows.first { $0.id == id }?.topicID } : nil
        unreadVisit = lookingAt
        let visited = Set(windows.filter { (entering && $0.id == lookingAt) || (topic != nil && $0.topicID == topic) }.map(\.id))
            .union(explicitReadVisits.consume(in: windows))
        readTopicsOnVisit(Set(windows.filter { visited.contains($0.id) }.compactMap(\.topicID)))
        var commands: [[String]] = []
        for pane in panes {
            let reading: AgentReading = visited.contains(pane.windowID) ? .visiting : pane.windowID == lookingAt ? .viewing : .away
            let change = AgentUnread.change(for: pane, previousStatus: agentStatuses[pane.id],
                                            reading: reading, manualRead: config.notifications.manualRead)
            agentStatuses[pane.id] = pane.agentStatus
            if let unread = change { commands.append(unreadCommand(unread, paneID: pane.id)) }
        }
        let live = Set(panes.map(\.id))
        agentStatuses = agentStatuses.filter { live.contains($0.key) }
        return commands
    }

    /// Persist Unread before the next snapshot counts wake Notifications.
    private func updateUnread(_ panes: [TmuxPane]) -> Bool {
        let commands = unreadChanges(panes)
        guard !commands.isEmpty else { return false }
        writeUnread(commands)
        return true
    }

    private func switchClient(to target: Target, onFailure: ((Error) -> Void)? = nil) {
        guard connection != nil, !isTransitioning, !isRemote || isConnected else { return }
        let previousWindowID = selectedWindowID
        let previousTopicSelection = topicSelection
        selectedWindowID = target.windowID
        pendingSelection = (target.windowID, Date().addingTimeInterval(isRemote ? 10 : 2), false)
        moveFocusIntoWindow()
        guard let surface, !surface.processExited, let tty = clientTTY ?? (isRemote ? nil : surface.ttyName) else {
            if isRemote { return }
            attach(to: target, readsOnArrival: true)
            return
        }
        clientTTY = tty
        let navigation = UUID()
        pendingReadNavigations.insert(navigation)
        runAsync(["switch-client", "-c", tty, "-t", target.tmuxTarget]) { [weak self] result in
            guard let self, self.pendingReadNavigations.remove(navigation) != nil else { return }
            if case .failure(let error) = result {
                if self.pendingSelection?.windowID == target.windowID {
                    self.pendingSelection = nil
                    self.selectedWindowID = previousWindowID
                    self.topicSelection = previousTopicSelection
                }
                onFailure?(error)
            } else {
                self.explicitReadVisits.enter(windowID: target.windowID, windows: self.windows)
            }
            self.refresh()
        }
    }

    var terminalHasFocus: Bool {
        guard let surface else { return false }
        return surface.window?.firstResponder === surface
    }

    /// The current Window's Browser has Focus (its page or omnibox).
    var browserHasFocus: Bool {
        !terminalHasFocus && currentGitView?.hasKeyFocus != true && panelLayout.shows(.browser)
    }

    private var focusedSide: PanelLayout.Side { browserHasFocus ? .browser : .terminal }

    func moveFocus(into side: PanelLayout.Side) {
        switch side {
        case .terminal: focusTerminal()
        case .browser: currentBrowser?.requestFocus()
        }
    }

    /// Switching Windows and closing a sheet give Focus back to the Window:
    /// to its Terminal, or to its Browser while the Terminal is hidden.
    func moveFocusIntoWindow() {
        guard !palette.isOpen else { return }
        // The Window's Git View, open over its sides; one just selected
        // takes Focus once it's on screen.
        if let gitView = selectedWindowID.flatMap({ gitViews[$0] }), gitView.isOpen { return gitView.takeFocus() }
        moveFocus(into: panelLayout.shows(.terminal) ? .terminal : .browser)
    }

    /// When a side with Focus disappears, Focus moves to the side still shown.
    private func keepFocusOnScreen() {
        let layout = panelLayout
        if !layout.shows(.terminal), terminalHasFocus {
            currentBrowser?.requestFocus()
        } else if !layout.shows(.browser), !terminalHasFocus {
            focusTerminal()
        }
    }

    /// Makes the Terminal the first responder. A hidden Terminal never takes Focus.
    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let surface, panelLayout.shows(.terminal), topics.emptyTopic == nil,
                  !topicSelection.showsEmptyNoTopic, !palette.isOpen else { return }
            surface.window?.makeFirstResponder(surface)
        }
    }

    // MARK: - tmux commands

    func newWindow(beside window: TmuxWindow) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        newWindow(inSession: window.sessionID)
    }

    func newWindow(inSession sessionID: String? = nil) {
        guard let sessionID = sessionID ?? selectedWindow?.sessionID ?? windows.first?.sessionID,
              let sibling = selectedWindow?.sessionID == sessionID ? selectedWindow : windows.first(where: { $0.sessionID == sessionID })
        else {
            newSession()
            return
        }
        // -d, then switch only our client: other Sessions' current windows stay put.
        let args = ["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "\(sessionID):", "-c", sibling.path]
        runAsync(args) { [weak self] result in
            guard let self, case .success(let output) = result else { return }
            let windowID = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.switchClient(to: Target(sessionID: sessionID, windowID: windowID, path: sibling.path))
        }
    }

    func newSession() {
        let cwd = selectedWindow?.path ?? homeDirectory
        let topic = isRemote ? nil : topicWatcher.records.first { $0.id == selectedWindow?.topicID && $0.settledAt == nil }
        let base = selectedWindow.map { SessionNaming.base(of: $0.sessionName, topic: topic) }
            ?? SessionPath.sessionName((cwd as NSString).lastPathComponent)
        newSession(in: OpenDirectory(directory: Folder(path: cwd, real: folders.folder(cwd).real), name: base), topic: topic?.id)
    }

    /// Kills the Window, or its whole Session with `session`, only while its Panes are the ones the user reviewed.
    /// Otherwise the completion gets the Window and Panes as they are now, for the user to review again.
    func checkKill(_ window: TmuxWindow, session: Bool, expectedPaneIDs: Set<String>?,
                    completion: @escaping (Result<(window: TmuxWindow, paneIDs: Set<String>)?, Error>) -> Void) {
        guard let connection else { completion(.failure(TmuxError.notReady)); return }
        flushTopicMemory()
        let current = generation
        let paths = topicWatcher.store.paths
        let order = topicConfig.sessionOrder
        Task {
            let result = await Task.detached { () -> Result<(window: TmuxWindow, paneIDs: Set<String>)?, Error> in
                Result {
                    let snapshot = try connection.snapshot()
                    let members = snapshot.windows.filter {
                        $0.sourceID == window.sourceID && (session ? $0.sessionID == window.sessionID : $0.id == window.id)
                    }
                    guard let fresh = members.first(where: { $0.id == window.id }) ?? members.first else { throw TmuxError.notReady }
                    let windowIDs = Set(members.map(\.id))
                    let paneIDs = Set(snapshot.panes.filter { windowIDs.contains($0.windowID) }.map(\.id))
                    guard let expectedPaneIDs, expectedPaneIDs == paneIDs else { return (fresh, paneIDs) }
                    _ = try connection.run(session ? ["kill-session", "-t", window.sessionID] : ["kill-window", "-t", window.id])
                    if !connection.isRemote, let topicID = fresh.topicID {
                        var remaining = snapshot
                        remaining.windows.removeAll { session ? $0.sessionID == fresh.sessionID : $0.id == fresh.id }
                        remaining.panes.removeAll { paneIDs.contains($0.id) }
                        try TopicStore(paths: paths).write { transaction in
                            try transaction.update(topicID) { record in
                                if let updated = record.remembering(remaining, order: order, previously: snapshot.windows) { record = updated }
                            }
                        }
                    }
                    return nil
                }
            }.value
            guard self.generation == current else { return }
            self.topicWatcher.reload()
            completion(result)
            self.refresh()
        }
    }

    func renameSession(_ window: TmuxWindow, to name: String) {
        guard windows.contains(where: { $0.sessionID == window.sessionID && $0.sourceID == window.sourceID }) else { return }
        guard (try? SessionNaming.validate(name)) != nil else { return }
        let topic = isRemote ? nil : topicWatcher.records.first { $0.id == window.topicID && $0.settledAt == nil }
        let fullName = SessionNaming.available(name, topic: topic?.slug, taken: Set(windows.filter { $0.sessionID != window.sessionID }.map(\.sessionName)))
        runAsync(["rename-session", "-t", window.sessionID, fullName]) { [weak self] _ in self?.refresh() }
    }

    func renameWindow(_ window: TmuxWindow, to name: String) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        runAsync(["rename-window", "-t", window.id, name]) { [weak self] _ in self?.refresh() }
    }

    /// Puts a Window before or after another Window of its Session, which keeps its current Window.
    func moveWindow(_ window: TmuxWindow, to placement: DropPlacement<String>) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }),
              let anchor = windows.first(where: { $0.id == placement.anchor && $0.sourceID == window.sourceID }),
              anchor.sessionID == window.sessionID, anchor.id != window.id else { return }
        let side = if case .before = placement { "-b" } else { "-a" }
        runAsync(["move-window", "-d", side, "-s", window.id, "-t", anchor.id]) { [weak self] _ in self?.refresh() }
    }

    /// A click on a card's Window row selects it, and a long press moves it within its Session.
    var windowRowDrag: WindowRowDrag {
        WindowRowDrag(isEnabled: !changingTopic, select: { [weak self] in self?.select($0) },
                      move: { [weak self] in self?.moveWindow($0, to: $1) })
    }

    /// Runs a tmux command against the pane our client currently has focused.
    private func runOnCurrentPane(_ makeArgs: @escaping (_ paneID: String, _ windowID: String) -> [String]) {
        // display-message's -c is a message recipient, not a dependable format
        // context. Another client (including the event listener) may otherwise
        // supply its current Pane. Window selection is queued before this call.
        guard let windowID = selectedWindowID else { return }
        runAsync(["display-message", "-p", "-t", windowID, "#{pane_id} #{window_id}"]) { [weak self] result in
            guard case .success(let output) = result else { return }
            let ids = output.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard ids.count == 2 else { return }
            self?.runAsync(makeArgs(ids[0], ids[1])) { _ in self?.refresh() }
        }
    }

    // MARK: - Config and Command Palettes

    /// Reads the Remote Environment's own Config (ADR 0010): on connecting,
    /// on Reload Config and when a Command Palette opens. Not watched.
    func loadRemoteConfig(then completion: (() -> Void)? = nil) {
        guard let environment = activeEnvironment, let connection, isConnected else {
            completion?()
            return
        }
        let current = generation
        connection.runScriptAsync(RemoteConfigFile.script) { [weak self] result in
            guard let self, self.generation == current else { return }
            defer { completion?() }
            // A failed read keeps what this App Window has.
            guard case .success(let output) = result, let file = RemoteConfigFile.parse(output) else { return }
            self.remoteConfigPath = file.path
            guard let text = file.text else {
                if self.remoteConfig != nil { self.remoteConfig = nil }
                return
            }
            let shown = "\(environment.host):\(Paths.tildify(file.path, home: self.homeDirectory))"
            var loaded = self.remoteConfig ?? LoadedConfig()
            loaded.update(with: Config.load(path: shown, isRemote: true) { $0 == shown ? text : nil })
            if loaded != self.remoteConfig {
                for problem in loaded.problems { NSLog("muxify: config: \(problem)") }
                self.remoteConfig = loaded
                self.remoteProblemsDismissed = false
            }
        }
    }

    /// Reloads the local Config with Reload Config, then this App Window's
    /// remote one.
    func reloadConfig() {
        configStore.reload()
        loadRemoteConfig()
    }

    /// A Remote Environment's Config is read again whenever a palette opens,
    /// and the SessionPaths are looked for again (the last ones show meanwhile).
    func paletteDidOpen(_ palette: CommandPaletteConfig) {
        if !isRemote { topicWatcher.reload() }
        if isRemote { loadRemoteConfig { [weak self] in self?.refreshSessionPaths() } } else { refreshSessionPaths() }
    }

    /// Opens the Config this App Window uses. A Remote Environment's own
    /// Config opens in that machine's editor, in a new tmux Window.
    func openConfig() {
        guard isRemote else {
            configStore.openInEditor()
            return
        }
        guard isConnected else { return }
        guard remoteConfig != nil, let path = remoteConfigPath else {
            let file = remoteConfigPath.map { Paths.tildify($0, home: homeDirectory) } ?? "~/.config/muxify/config.yaml"
            let alert = NSAlert()
            alert.messageText = "\(environmentName) has no Muxify Config"
            alert.informativeText = "This App Window uses your local Config. To give \(environmentName) its own, create \(file) there."
            alert.addButton(withTitle: "Open Local Config")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { configStore.openInEditor() }
            return
        }
        guard let sessionID = selectedWindow?.sessionID ?? windows.first?.sessionID else { return }
        // Run by tmux's default shell, which may be fish: plain words only.
        let editor = "sh -c " + Tmux.shellQuote("exec \"${VISUAL:-${EDITOR:-vi}}\" \"$1\"") + " sh " + Tmux.shellQuote(path)
        let args = ["new-window", "-d", "-P", "-F", "#{window_id}", "-t", "\(sessionID):", "-c", homeDirectory, editor]
        runAsync(args) { [weak self] result in
            guard let self, case .success(let output) = result else { return }
            let windowID = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.switchClient(to: Target(sessionID: sessionID, windowID: windowID, path: nil))
        }
    }

    // MARK: - Git View

    /// The Window's Git View, made on first use.
    func gitView(for windowID: String) -> GitView {
        if let gitView = gitViews[windowID] { return gitView }
        let gitView = GitView(windowID: windowID)
        gitView.store = self
        gitViews[windowID] = gitView
        return gitView
    }

    /// The selected Window's Git View, once it has opened there. Views
    /// don't make one, so `gitViews` changes only in actions.
    var currentGitView: GitView? {
        selectedWindowID.flatMap { gitViews[$0] }
    }

    func toggleGitView() {
        guard let id = selectedWindowID else { return }
        gitView(for: id).toggle()
    }

    /// For the sidebar's Git View icon.
    func isGitViewOpen(in windowID: String) -> Bool {
        gitViews[windowID]?.isOpen == true
    }

    private func removeGitViews() {
        gitViews.values.forEach { $0.close(restoringFocus: false) }
        gitViews.removeAll()
    }

    #if DEBUG
    /// Drives the Git View without keystrokes, for screenshots of a build in
    /// the background: post `dev.muxify.git` with this process's pid as the
    /// object and a `spec` (see `GitView.applyDemo`). `window=@12` selects
    /// that Window first.
    private func observeGitDemoRequests() {
        gitDemoObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("dev.muxify.git"),
            object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
        ) { [weak self] note in
            let spec = note.userInfo?["spec"] as? String ?? ""
            MainActor.assumeIsolated { self?.applyGitDemo(spec) }
        }
    }

    private func applyGitDemo(_ spec: String) {
        guard terminalHost.window?.isVisible == true else { return }
        let fields = Dictionary(spec.split(separator: ";").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { _, last in last })
        if let id = fields["window"], let window = windows.first(where: { $0.id == id }) { select(window) }
        selectedWindowID.map(gitView(for:))?.applyDemo(fields)
    }
    #endif

    /// Runs a Git View script on the Environment's machine, like the
    /// Session Paths scan.
    func runGitScript(_ script: String, arguments: [String], timeout: TimeInterval = 30,
                      completion: @escaping (Result<String, Error>) -> Void) {
        guard let connection, !isTransitioning, !isRemote || isConnected else {
            completion(.failure(GitViewError(message: "Not connected to \(environmentName).")))
            return
        }
        let current = generation
        connection.runScriptAsync(script, arguments: arguments, timeout: timeout) { [weak self] result in
            guard let self, self.generation == current else { return }
            completion(result)
        }
    }

    // MARK: - Browser

    /// What the current Window shows of its Terminal and Browser.
    var panelLayout: PanelLayout { currentBrowser?.layout ?? PanelLayout() }

    /// The Window's Browser, restored from its tmux options on first use.
    func browser(for windowID: String) -> Browser {
        if let browser = browsers[windowID] { return browser }
        let stored = windows.first { $0.id == windowID }?.storedBrowser ?? StoredBrowser()
        let browser = Browser(windowID: windowID, stored: stored, discoversLocalServers: !isRemote)
        let current = generation
        browser.onChange = { [weak self] browser in
            guard let self, self.generation == current else { return }
            persistWindow(browser.windowID)
        }
        browser.onShownChange = { [weak self] browser in
            guard let self, self.generation == current, browser.windowID == self.selectedWindowID else { return }
            keepFocusOnScreen()
        }
        browser.onCopyURL = { [weak self] url in
            guard let self, self.generation == current else { return }
            self.palette.showCopied(title: "Copied URL", value: url)
        }
        browsers[windowID] = browser
        return browser
    }

    var currentBrowser: Browser? {
        selectedWindow.map { browser(for: $0.id) }
    }

    /// For the sidebar badge, without restoring Browsers nobody has looked at.
    func tabCount(for window: TmuxWindow) -> Int {
        browsers[window.id]?.tabs.count ?? window.storedBrowser.tabURLs.count
    }

    var sidebarShown: Bool { sidebarVisible && !panelLayout.hidesSidebar }

    func toggleSidebar() {
        commitMaximize()
        sidebarVisible.toggle()
    }

    func canToggle(_ side: PanelLayout.Side) -> Bool {
        currentBrowser != nil && panelLayout.canToggle(side)
    }

    /// Shows or hides the current Window's `side`. A side that appears takes Focus.
    func toggle(_ side: PanelLayout.Side) {
        guard let browser = currentBrowser, browser.layout.canToggle(side) else { return }
        commitMaximize()
        browser.toggle(side)
        if browser.layout.shows(side) { moveFocus(into: side) }
    }

    func canMaximize(_ side: PanelLayout.Side) -> Bool {
        currentBrowser != nil && panelLayout.canMaximize(side, sidebarShown: sidebarShown)
    }

    /// Maximizes the current Window's `side` and moves Focus into it, or
    /// restores when `side` is Maximized already.
    func toggleMaximize(_ side: PanelLayout.Side) {
        guard let browser = currentBrowser else { return }
        browser.toggleMaximize(side, sidebarShown: sidebarShown)
        if browser.layout.maximized == side { moveFocus(into: side) }
    }

    var canToggleMaximize: Bool { canMaximize(panelLayout.maximized ?? focusedSide) }

    /// Maximizes the side that has Focus, or restores.
    func toggleMaximize() {
        toggleMaximize(panelLayout.maximized ?? focusedSide)
    }

    /// Moves Focus into the current Window's `side`, also when Maximize of the
    /// other side or a toggle hides it (`focus_terminal`, `focus_browser`).
    func focus(_ side: PanelLayout.Side) {
        currentBrowser?.reveal(side)
        moveFocus(into: side)
    }

    /// A toggle used while Maximized starts from what is on screen: the
    /// Maximized side alone, and no Sidebar.
    private func commitMaximize() {
        guard let browser = currentBrowser, browser.layout.maximized != nil else { return }
        sidebarVisible = false
        browser.commitMaximize()
    }

    func focusAddressBar() {
        guard let browser = currentBrowser else { return }
        if !browser.layout.shows(.browser) { toggle(.browser) }
        browser.focusRequest = .addressBar
    }

    /// Menu actions for the Browser. Their shortcuts only count when Focus is
    /// outside the terminal, where Ghostty/tmux bindings own the keys;
    /// clicking the menu item always works.
    func browserCommand(opensBrowser: Bool = false, _ body: (Browser) -> Void) {
        if NSApp.currentEvent?.type == .keyDown, terminalHasFocus || currentGitView?.hasKeyFocus == true { return }
        if NSApp.currentEvent?.type == .keyDown, !opensBrowser, !panelLayout.shows(.browser) { return }
        guard let browser = currentBrowser else { return }
        if opensBrowser, !browser.layout.shows(.browser) { commitMaximize() }
        body(browser)
    }

    /// Opens `url` as a Tab in a Window's Browser (the current Window by
    /// default). For another Window it happens quietly: you aren't moved.
    func openInBrowser(_ url: URL, windowID: String? = nil) {
        guard let id = windowID ?? selectedWindowID else {
            NSWorkspace.shared.open(url)
            return
        }
        browser(for: id).open(url)
    }

    /// Programs inside a Window open Tabs with
    /// `tmux set -w -t "$TMUX_PANE" @muxify_open <url>` (several URLs may be
    /// space-separated); we open them and clear the option.
    private func consumeOpenRequests() {
        // Several Local App Windows can see the same tmux option. Only one
        // should consume it, not open duplicate Tabs in every Browser view.
        guard shouldConsumeOpenRequests?() ?? true else { return }
        for window in windows where !window.openRequests.isEmpty && !consumingOpen.contains(window.id) {
            consumingOpen.insert(window.id)
            for request in window.openRequests {
                if let url = Omnibox.url(for: request) { openInBrowser(url, windowID: window.id) }
            }
            runAsync(["set-option", "-wqu", "-t", window.id, Tmux.openOption]) { [weak self] _ in
                self?.consumingOpen.remove(window.id)
            }
        }
    }

    /// Writes Browser state onto its tmux Window, coalescing bursts of
    /// changes (redirects, quick Tab switching) into one tmux call.
    private func persistWindow(_ id: String) {
        guard !isShuttingDown else { return }
        let current = generation
        let revision = UUID()
        dirtyBrowsers[id] = revision
        persistWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current, let browser = self.browsers[id] else { return }
            self.persistWork[id] = nil
            self.runAsync(browser.stored.setOptionArgs(windowID: id)) { [weak self] result in
                guard let self, case .success = result, self.dirtyBrowsers[id] == revision else { return }
                self.dirtyBrowsers[id] = nil
            }
        }
        persistWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    var pendingBrowserCommands: [[String]] {
        dirtyBrowsers.keys.sorted().compactMap { id in browsers[id]?.stored.setOptionArgs(windowID: id) }
    }

    private func rememberTopics(in snapshot: TmuxSnapshot) {
        let continuous = snapshot.serverRunning && snapshot.serverID != nil && snapshot.serverID == memoryServerID
        memoryServerID = snapshot.serverRunning ? snapshot.serverID : nil
        for record in topicWatcher.records {
            var previous = record
            previous.sessions = rememberedTopics[record.id]?.sessions ?? record.sessions
            if let updated = previous.remembering(snapshot, order: topicConfig.sessionOrder,
                branches: topicBranches, previously: continuous ? windows : []) {
                rememberedTopics[record.id] = updated
                topicSnapshots[record.id] = snapshot
                topicSnapshotBases[record.id] = record.sessions
                topicPersistWork[record.id]?.cancel()
                topicPersistWork[record.id] = nil
            }
            let id = record.id
            guard topicPersistWork[id] == nil, topicSnapshots[id] != nil else { continue }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.topicPersistWork[id] = nil
                guard !self.changingTopic else { return }
                self.persistRememberedTopic(id)
            }
            topicPersistWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// Writes the Sessions that the last snapshot gave the Topic onto its record as it is on disk now.
    /// When another writer changed the Sessions after the snapshot, as `muxify topic remove` does, the snapshot
    /// is stale and is dropped: it would put a removed Session back, and the Topic would be Dormant, not Empty.
    private func persistRememberedTopic(_ id: String) {
        guard let updated = rememberedTopics[id] else { return }
        let base = topicSnapshotBases[id]
        do {
            try topicWatcher.write { transaction in
                guard let current = transaction.records.first(where: { $0.id == id }), current.sessions == base else { return }
                try transaction.update(id) { $0.sessions = updated.sessions }
            }
            rememberedTopics[id] = nil
            topicSnapshots[id] = nil
            topicSnapshotBases[id] = nil
        } catch { NSLog("muxify: remembering Topic \(id): \(error)") }
    }

    // MARK: - Keyboard

    func perform(_ action: ConfigAction) {
        switch action {
        case .newAppWindow: onNewAppWindow?()
        case .newTopic: if !isRemote { presentNewTopic() }
        case .movePane: if !isRemote { presentMovePane(nil) }
        case .moveWindow: presentMoveWindow()
        case .moveSession: if !isRemote { presentMoveSession() }
        case .addSessionToTopic: if !isRemote { presentAddSession() }
        case .snoozeTopic: if !isRemote, let id = activeTopicID { presentSnooze(id) }
        case .snoozeTopics: if !isRemote { presentCheck(CheckDraft(action: .snooze)) }
        case .unsnoozeTopics: if !isRemote { presentCheck(CheckDraft(action: .unsnooze)) }
        case .toggleZen: if !isRemote { toggleZenOfActiveTopic() }
        case .settleTopic: if !isRemote { presentSettleTopic() }
        case .removeSessionFromTopic:
            if !isRemote, !changingTopic, let window = selectedWindow, window.topicID != nil, window.topicID == activeTopicID { removeFromTopic(window) }
        case .forgetTopic: if let id = activeTopicID, topicWatcher.records.contains(where: { $0.id == id && $0.settledAt == nil }) { presentForgetTopic(id) }
        case .renameTopic: presentRenameTopic()
        case .toggleLock: toggleLockOfCurrentSession()
        case .moveTopicUp: moveActiveCard(.previous)
        case .moveTopicDown: moveActiveCard(.next)
        case .togglePinTopic: togglePinOfActiveTopic()
        case .unsnoozeTopic: presentUnsnoozeTopic()
        case .markRead: changeRead(.read, in: currentReadTarget)
        case .markUnread: changeRead(.unread, in: currentReadTarget)
        case .markAllRead: changeRead(.read, in: .environment)
        case .toggleSidebar: toggleSidebar()
        case .toggleTerminal: toggle(.terminal)
        case .toggleBrowser: toggle(.browser)
        case .toggleGitView: toggleGitView()
        case .toggleMaximize: toggleMaximize()
        case .toggleMaximizeTerminal: toggleMaximize(.terminal)
        case .toggleMaximizeBrowser: toggleMaximize(.browser)
        case .focusTerminal: focus(.terminal)
        case .focusBrowser: focus(.browser)
        case .selectCard1, .selectCard2, .selectCard3, .selectCard4, .selectCard5,
             .selectCard6, .selectCard7, .selectCard8, .selectCard9,
             .selectWindow1, .selectWindow2, .selectWindow3, .selectWindow4, .selectWindow5,
             .selectWindow6, .selectWindow7, .selectWindow8, .selectWindow9,
             .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
             .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            if let selection = action.quickSwitchSelection { quickSwitch(selection) }
        case .selectNextWindow, .selectPrevWindow, .selectNextTopicWindow, .selectPrevTopicWindow,
             .selectNextSession, .selectPrevSession, .selectNextTopic, .selectPrevTopic:
            if let step = action.step { self.step(step.level, step.direction) }
        }
    }

    /// The Config's keybinds, which act before the terminal, Browser and menu
    /// see the key, so they win over Ghostty and page keybinds. Then shortcuts
    /// the menu can't express: ⌘W closes a Tab when the Browser has focus and
    /// never the app window (which would quit Muxify); ⌃Tab and ⌃⇧Tab switch Tabs.
    /// Other keys in the terminal are left to Ghostty/tmux bindings.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    @discardableResult
    func performConfiguredShortcut(_ trigger: KeyTrigger) -> Bool {
        guard !isShuttingDown, let action = config.keybinds.action(for: trigger) else { return false }
        // ⌘G, the Git View's, is Find Next while the Browser is finding.
        if trigger == Self.findNext, browserHasFocus, currentBrowser?.activeTab?.isFindShown == true { return false }
        perform(action)
        return true
    }

    private static let closeTab = KeyTrigger(modifiers: .command, key: .character("w"))
    private static let findNext = KeyTrigger(modifiers: .command, key: .character("g"))

    func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard !isShuttingDown, let window = terminalHost.window, event.window === window else { return event }
        if event.type == .flagsChanged {
            receiveHintInput(.modifiers(KeyTrigger.Modifiers(event.modifierFlags)))
            if palette.isOpen { receiveHintInput(.reset) }
            return event
        }
        if event.type == .keyUp {
            receiveHintInput(.keyUp(event.keyCode))
            return event
        }
        receiveHintInput(.keyDown(event.keyCode))
        if let trigger = KeyTrigger(event) {
            if palette.handle(trigger, in: event) { return nil }
            if currentGitView?.handle(trigger, in: event) == true { return nil }
            let config = self.config
            if let target = config.commandPalettes.first(where: { $0.triggers.contains(trigger) }) {
                palette.toggle(target)
                return nil
            }
            let keybinds = config.keybinds
            if performConfiguredShortcut(trigger) { return nil }
            if keybinds.suppressesDefaultAppWindowShortcut(trigger) { return nil }
            if trigger == Self.closeTab {
                if browserHasFocus { browserCommand { $0.closeActiveTab() } }
                return nil
            }
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 0x30, flags == .control || flags == [.control, .shift], browserHasFocus {
            currentBrowser?.selectTab(offset: flags.contains(.shift) ? -1 : 1)
            return nil
        }
        return event
    }
}

// MARK: - muxify:// URLs

extension WorkspaceStore {
    /// Scriptable entry points, e.g. from a shell inside tmux:
    ///   open "muxify://open?url=localhost:3000&window=$(tmux display -p '#{window_id}')"
    ///   open "muxify://select?window=@12"
    ///   open "muxify://toggle-browser"
    func handle(_ url: URL) {
        guard url.scheme == "muxify" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        switch url.host {
        case "topic":
            do { enqueueTopicRequest(try TopicRequest(url: url)) }
            catch { showTopicFailure(error) }
        case "select":
            if let id = value("window") {
                if let window = windows.first(where: { $0.id == id }) { select(window) }
            } else if let name = value("session") {
                selectSession(named: name)
            }
        case "open":
            guard let input = value("url"), let target = Omnibox.url(for: input) else { return }
            openInBrowser(target, windowID: value("window"))
        case "toggle-browser":
            toggle(.browser)
        default:
            NSLog("muxify: unknown URL \(url)")
        }
    }
}

// MARK: - libghostty actions

extension WorkspaceStore: @preconcurrency GhosttyRuntimeDelegate {
    func ghosttyOpenURL(_ url: URL) {
        // Cmd+click on a link in the terminal opens it as a Tab in this Window's Browser, with Focus on the page.
        if let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            openInBrowser(url)
            currentBrowser?.requestFocus()
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func ghosttyThemeChanged(_ theme: TerminalTheme) {
        self.theme = theme
    }

    func ghosttyReloadConfig() {
        reloadConfig()
    }

    func ghosttyNewTab() { newWindow() }
    func ghosttyNewWindow() { onNewAppWindow?() }

    func ghosttyNewSplit(_ direction: ghostty_action_split_direction_e) {
        let flags: [String]
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: flags = ["-h", "-b"]
        case GHOSTTY_SPLIT_DIRECTION_DOWN: flags = ["-v"]
        case GHOSTTY_SPLIT_DIRECTION_UP: flags = ["-v", "-b"]
        default: flags = ["-h"]
        }
        runOnCurrentPane { pane, _ in ["split-window"] + flags + ["-t", pane, "-c", "#{pane_current_path}"] }
    }

    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e) {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: runOnCurrentPane { _, window in ["select-pane", "-t", "\(window).-"] }
        case GHOSTTY_GOTO_SPLIT_NEXT: runOnCurrentPane { _, window in ["select-pane", "-t", "\(window).+"] }
        case GHOSTTY_GOTO_SPLIT_UP: runOnCurrentPane { pane, _ in ["select-pane", "-U", "-t", pane] }
        case GHOSTTY_GOTO_SPLIT_DOWN: runOnCurrentPane { pane, _ in ["select-pane", "-D", "-t", pane] }
        case GHOSTTY_GOTO_SPLIT_LEFT: runOnCurrentPane { pane, _ in ["select-pane", "-L", "-t", pane] }
        default: runOnCurrentPane { pane, _ in ["select-pane", "-R", "-t", pane] }
        }
    }

    func ghosttyToggleSplitZoom() {
        runOnCurrentPane { pane, _ in ["resize-pane", "-Z", "-t", pane] }
    }

    func ghosttyEqualizeSplits() {
        runOnCurrentPane { pane, _ in ["select-layout", "-E", "-t", pane] }
    }

    func ghosttyGotoTab(_ tab: Int32) {
        switch tab {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: step(.window, .previous)
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: step(.window, .next)
        case GHOSTTY_GOTO_TAB_LAST.rawValue: navigateWindows(.last)
        default: navigateWindows(.position(Int(tab)))
        }
    }

    func ghosttySurfaceClosed(_ view: TerminalSurfaceView) {
        guard view === surface else {
            view.close()
            return
        }
        // A close request (e.g. cmd+w) while tmux is still attached: keep the client.
        guard view.processExited else { return }
        connection?.updateLocalClient(nil)
        view.close()
        surface = nil
        clientTTY = nil
        terminalHost.show(nil)
        if let remote = connection?.remote {
            // Any snapshot submitted before exit belongs to the old live
            // attachment and must not overwrite the final inventory.
            isRefreshing = false
            refreshAgain = false
            events.stop()
            isConnected = false
            let message = remote.failureMessage
            if remote.exitStatus == 0 {
                if let snapshot = connection?.closedSnapshot {
                    terminalMessage = nil
                    apply(snapshot, attachIfNeeded: false)
                    // apply may have started a recovery on another connection.
                    if isTransitioning { return }
                    if hasNoSessions {
                        environmentStatus = "No tmux Sessions in \(environmentName)"
                        return
                    }
                }
                environmentStatus = "Detached from \(environmentName)"
                terminalMessage = "Detached from remote tmux."
            } else {
                environmentStatus = "Disconnected from \(environmentName)"
                terminalMessage = message.isEmpty ? "SSH connection closed." : message
            }
            if remote.shouldReconnect {
                let delay = min(pow(2, Double(min(reconnectAttempt, 5))), 30)
                reconnectAttempt += 1
                environmentStatus += ". Reconnecting in \(Int(delay))s…"
                let current = generation
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.transition(to: self.activeEnvironment, createSessionIfNeeded: false)
                }
                reconnectWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
            return
        }
        refresh()
    }
}

/// Plain AppKit container the SwiftUI layout embeds; the terminal surface view
/// is swapped in and out of it without SwiftUI recreating anything.
final class TerminalHostView: NSView {
    private weak var current: NSView?

    func show(_ view: NSView?) {
        current?.removeFromSuperview()
        current = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}
