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
    private(set) var attachmentStatus: String?
    @ObservationIgnored private var attachmentStatusID = UUID()
    @ObservationIgnored private var pendingTopicPresentation: (EnvironmentRevision, () -> Void)?
    @ObservationIgnored private var readVisits = AgentReadVisits()
    @ObservationIgnored private var readWindowID: String?
    @ObservationIgnored private var viewingEpoch = 0
    private var environmentModule = EnvironmentReader()
    @ObservationIgnored private let localEnvironment: EnvironmentWatchClient
    private enum RemoteWatchMode {
        case pending
        case copied(EnvironmentWatchClient)
        case fallback(EnvironmentWatchClient)

        var client: EnvironmentWatchClient? {
            switch self {
            case .pending: return nil
            case .copied(let client), .fallback(let client): return client
            }
        }
    }
    private var remoteWatch: RemoteWatchMode = .pending
    var supportsTopics: Bool {
        if !isRemote { return true }
        if case .copied = remoteWatch { return true }
        return false
    }
    private var activeWatch: EnvironmentWatchClient? { isRemote ? remoteWatch.client : localEnvironment }
    private enum ClientRegistration {
        case pending(EnvironmentClientMarker)
        case registered(EnvironmentClientMarker)
        case retry(EnvironmentClientMarker, after: Date)

        var marker: EnvironmentClientMarker {
            switch self {
            case .pending(let marker), .registered(let marker), .retry(let marker, _): return marker
            }
        }
    }
    @ObservationIgnored private var clientRegistration: ClientRegistration?

    private(set) var newTopicFailure: String?
    /// When each Topic, Session and SessionPath was last looked at; the lists rank by it.
    private(set) var visits = VisitLog(defaults: .standard)
    /// The SessionPaths on this App Window's Environment, as `refreshSessionPaths` found them last.
    private(set) var sessionPaths: [SessionPath] = []
    private(set) var sessionPathWarnings: [String] = []
    var sessionPathWarningsDismissed = false
    /// Resolves a path on this App Window's Environment: with `realpath` on this Mac, else through the SessionPaths found there.
    var folders: FolderResolver { isRemote ? .remote(sessionPaths) : .local }
    var topicConfig: Config.Topics { config.topics }

    /// Looks for the Config's SessionPaths again, on the Environment's machine and off the main thread. A sheet
    /// or palette opens at once, and a folder made since the last look joins it a moment later. Until the first
    /// look finishes, the output of the last saved look shows.
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
        let roots = config.sessionRoots, aliases = config.sessionAliases
        guard !roots.isEmpty else { return found([]) }
        let arguments = SessionPathDiscovery.arguments(for: roots)
        let cache = SessionPathCache(file: MuxifyPaths().sessionPathCache(remote: activeEnvironment?.name))
        if sessionPaths.isEmpty, let output = cache.output(for: arguments) {
            found(SessionPathDiscovery.sessionPaths(in: output, roots: roots, aliases: aliases))
        }
        guard isRemote else {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let output = SessionPathDiscovery.output(for: roots) else { return }
                cache.save(output, for: arguments)
                let sessionPaths = SessionPathDiscovery.sessionPaths(in: output, roots: roots, aliases: aliases)
                DispatchQueue.main.async { found(sessionPaths) }
            }
            return
        }
        guard let connection else { return }
        let current = generation
        connection.runScriptAsync(SessionPathDiscovery.script, arguments: arguments) { [weak self] result in
            guard let self, self.generation == current else { return }
            switch result {
            case .success(let output):
                DispatchQueue.global(qos: .utility).async { cache.save(output, for: arguments) }
                found(SessionPathDiscovery.sessionPaths(in: output, roots: roots, aliases: aliases))
            case .failure(let error): Diagnostics.report("SessionPaths: \(error)")
            }
        }
    }

    @ObservationIgnored private lazy var sessionPathRowsCache = ObservedCache { [unowned self] in
        SessionPathRows.build(sessionPaths: sessionPaths, windows: windows, records: topicContents.records, titles: topics.titles)
    }

    var sessionPathRows: [SessionPathRow] { sessionPathRowsCache.value }

    func presentNewTopic(keepingHistory: Bool = false) {
        guard supportsTopics, !changingTopic else { return }
        newTopicFailure = nil
        palette.begin(.text(.tags(TagField(mode: .newTopic, defined: topicConfig.tags))), keepingHistory: keepingHistory)
    }

    /// Makes an open Topic with no Session and shows it, so the user adds its first SessionPath from there.
    func createTopic(title: String, tags: [Tag] = []) {
        perform(EnvironmentRequest(.create(title: title, tags: tags.isEmpty ? nil : tags)), presenting: .newTopic)
    }

    /// Edit Tags for an open Topic: one field with its Tags as chips.
    func presentEditTags(of id: String, keepingHistory: Bool = false) {
        environmentModule.reloadRecords()
        guard !changingTopic, supportsTopics, let defined = topicConfig.tags,
              let topic = topicContents.records.first(where: { $0.id == id && $0.settledAt == nil }) else { return }
        palette.begin(.text(.tags(TagField(mode: .editTags(topic), defined: defined, chips: defined.shown(topic.tags).map(\.tag)))),
                      keepingHistory: keepingHistory)
    }

    /// Tags go through the Topic service, as `muxify topic tag` does (ADR 0032).
    func setTags(of id: String, _ tags: [Tag]) {
        perform(EnvironmentRequest(.tags(.set(tags)), target: .topic(.id(id))))
    }

    /// Puts a Topic with no live Session in place of the terminal and makes it the Active Topic: an empty Topic
    /// offers Add a Session, a Dormant or Settled one offers Reopen and Start Fresh. Selecting a Window ends it.
    func showEmptyTopic(_ id: String) {
        route(.go(.emptyTopic(.topic(id))))
        sidebarMode = .topics
        if !palette.isOpen { surface?.window?.makeFirstResponder(nil) }
    }

    private(set) var changingTopic = false {
        didSet {
            if oldValue && !changingTopic {
                DispatchQueue.main.async { [weak self] in self?.drainTopicRequests() }
            }
        }
    }
    @ObservationIgnored private var topicRequests: [EnvironmentRequest] = []

    /// Move for the selected Window's Session, in the Command Palette's view. Nothing happens with Topics off.
    func presentMoveSession(keepingHistory: Bool = false) {
        guard supportsTopics, topics.topicsEnabled, let window = selectedWindow else { return }
        environmentModule.reloadRecords()
        palette.openMove(window, keepingHistory: keepingHistory)
    }

    /// Move for the selected Window, in the Command Palette's view. Nothing happens with Topics off.
    func presentMoveWindow(keepingHistory: Bool = false) {
        guard supportsTopics, topics.topicsEnabled, let window = selectedWindow else { return }
        environmentModule.reloadRecords()
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
        guard let pane = PaneID(rawValue: pane) else { return }
        performOperation(.sendText(pane: pane, text: text)) { [weak self] receipt in
            if case .failed(let error) = receipt.value { self?.showGoFailure(String(describing: error)) }
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
        if let topic, supportsTopics {
            perform(EnvironmentRequest(.addSession(sessionPath: target.directory.path, workingCopy: .directory, name: target.name), target: .topic(.id(topic))))
            return
        }
        guard pendingOpenings[target.directory] == nil else { return }
        startSession(in: target.directory, named: target.name)
    }

    /// Starts a No Topic Session at `directory` and shows it. The service names it under the edit lock, so a name that
    /// a Session has gets +2. A second press before the snapshot shows the Session does nothing.
    private func startSession(in directory: Folder, named name: String) {
        pendingOpenings[directory] = (name, Date().addingTimeInterval(5))
        perform(EnvironmentRequest(.newSession(sessionPath: directory.path, name: name)), presenting: .newSession(directory))
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
            route(.go(.emptyTopic(.noTopic)))
            sidebarMode = .topics
            if !palette.isOpen { terminalHost.window?.makeFirstResponder(nil) }
        }
    }

    /// Goes to the Worktree because a Git View asked to (ADR 0041): the most recent Window with a Pane in it, with
    /// that Pane active, else Go to… on the Worktree's Session Path. Nothing starts until the user picks a row.
    func goToWorktree(_ worktree: Folder) {
        let window = WorktreeWindow.mostRecent(in: worktree, windows: windows, panes: panes, resolver: folders) {
            visits.last(.session(name: $0.sessionName))
        }
        guard let window else {
            palette.openGoTo(at: worktree)
            return
        }
        if let pane = panes.first(where: { $0.windowID == window.id && worktree.contains(folders.folder($0.path)) && !$0.path.isEmpty }),
           !pane.isActive {
            select(TopicsModel.PaneRow(pane: pane, window: window, agent: nil, isUnderWindowRow: true))
        } else {
            select(window)
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
        let target: EnvironmentTarget?
        switch draft.scope {
        case .pane: target = PaneID(rawValue: draft.paneID).map(EnvironmentTarget.pane)
        case .window: target = WindowID(rawValue: window.id).map(EnvironmentTarget.window)
        case .session: target = SessionID(rawValue: window.sessionID).map(EnvironmentTarget.session)
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
        perform(EnvironmentRequest(.move(to: to), target: target), presenting: .move(source: window.id, tab: tab))
    }

    private func entryWindow(of id: TopicGroupID) -> TmuxWindow? {
        if id == .noTopic {
            let open = Set(topicContents.records.filter { $0.settledAt == nil }.map(\.id))
            let locked = Set(topics.rows.compactMap { row -> String? in
                if case .locked(let sessionID) = row.id { return sessionID }
                return nil
            })
            let members = windows.filter { ($0.topicID.map { !open.contains($0) } ?? true) && !locked.contains($0.sessionID) }
            if let last = members.first(where: { $0.id == topicSelection.lastWindowByGroup[.noTopic] }) { return last }
            return EntryWindow.ofSession(members)
        }
        guard let row = topics.rows.first(where: { $0.id == id }) else { return nil }
        return EntryWindow.of(row, lastWindowByGroup: topicSelection.lastWindowByGroup, visits: visits)
    }

    private func showGoFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not go there"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The Sidebar drag: the card goes next to another card.
    func moveTopic(_ id: TopicListID, to placement: TopicPlacement) {
        guard let target = Self.target(of: id), let anchor = Self.ref(of: placement.anchorID) else { return }
        let move: CardMove = if case .before = placement { .before(anchor) } else { .after(anchor) }
        perform(EnvironmentRequest(.moveCard(move), target: target))
    }

    /// The Sidebar drag across the Guests line or the Bench line: the two cards exchange their places. A card dropped
    /// on an Open Place fills it. While the Bench is hidden, the card that goes to the Bench shows under the line until
    /// the Sidebar folds it in.
    func tradeCard(_ id: TopicListID, with other: TopicListID) {
        guard let inPlay = topicConfig.inPlay else { return }
        if case .openPlace(let place) = other, case .topic(let topic) = id {
            let places = topics.cut(inPlay: inPlay).places
            guard let index = places.firstIndex(where: { if case .openPlace(place) = $0 { return true } else { return false } }) else { return }
            return fillOpenPlace(index + 1, with: topic)
        }
        guard let target = Self.target(of: id), let ref = Self.ref(of: other) else { return }
        let cut = topics.split(inPlay: inPlay)
        if !benchShown, benchPeek != .all, cut.bench.contains(where: { $0.id.listID == id || $0.id.listID == other }) {
            let leaving = cut.inPlay.map(\.id).first { $0.listID == id || $0.listID == other }
            benchPeek = leaving.map(TopicsModel.BenchPeek.card)
        }
        perform(EnvironmentRequest(.moveCard(.trade(ref)), target: target))
    }

    /// Fill an Open Place goes through the Topic service, as `muxify topic fill-place` does.
    func fillOpenPlace(_ place: Int, with topic: String) {
        perform(EnvironmentRequest(.fillOpenPlace(place: place), target: .topic(.id(topic))))
    }

    /// The step that asks what fills the Open Place at In Play place `place`.
    func presentFillOpenPlace(_ place: Int) {
        guard !isRemote, !changingTopic, topicConfig.inPlay != nil else { return }
        palette.begin(.fillOpenPlace(place))
    }

    /// Move Up and Move Down: MuxifyCore finds the neighbor among the cards that the Topics list shows.
    func moveCard(_ id: TopicListID, _ step: TopicCards.Step) {
        guard let target = Self.target(of: id) else { return }
        perform(EnvironmentRequest(.moveCard(step == .up ? .up : .down), target: target))
    }

    private static func target(of card: TopicListID) -> EnvironmentTarget? {
        switch card {
        case .topic(let id): return .topic(.id(id))
        case .lock(let sessionID): return SessionID(rawValue: sessionID).map(EnvironmentTarget.session)
        case .openPlace: return nil
        }
    }

    private static func ref(of card: TopicListID) -> TopicListRef? {
        switch card {
        case .topic(let id): return .topic(.id(id))
        case .lock(let sessionID): return SessionID(rawValue: sessionID).map(TopicListRef.lock)
        case .openPlace: return nil
        }
    }

    func pinTopic(_ id: String, _ pinned: Bool) {
        perform(EnvironmentRequest(pinned ? .pin : .unpin, target: .topic(.id(id))))
    }

    /// Whether the Session is Locked; nil when it cannot be: it is in an open Topic, or Topics are off.
    func lockState(ofSession sessionID: String) -> Bool? {
        guard supportsTopics, topics.topicsEnabled, let window = windows.first(where: { $0.sessionID == sessionID }) else { return nil }
        if let id = window.topicID, topicContents.records.contains(where: { $0.id == id && $0.settledAt == nil }) { return nil }
        return topics.lockedSessionIDs.contains(sessionID)
    }

    /// Lock and Unlock go through the Topic service, as `muxify session lock` does (ADR 0032).
    func setLock(ofSession sessionID: String, _ locked: Bool) {
        guard lockState(ofSession: sessionID) != nil, let id = SessionID(rawValue: sessionID) else { return }
        perform(EnvironmentRequest(locked ? .lock : .unlock, target: .session(id)))
    }

    /// A card that Make a Guest and End Guest act on: a Topic, or a No Topic Session, which is a Guest through its Lock.
    enum GuestCard: Equatable {
        case topic(String)
        case session(String)
    }

    /// Whether the card is a Guest; nil when neither Make a Guest nor End Guest applies to it: the Config does not set
    /// `topics.in_play`, or the card is a Topic that is not on the Bench. A Guest Topic leaves through Bench Topic, so End
    /// Guest is only for a Guest Session.
    func guestState(of card: GuestCard) -> Bool? {
        guard let inPlay = topicConfig.inPlay, !isRemote, topics.topicsEnabled else { return nil }
        switch card {
        case .session(let id): return lockState(ofSession: id)
        case .topic(let id): return topics.split(inPlay: inPlay).bench.contains { $0.id == .topic(id) } ? false : nil
        }
    }

    /// Bench Topic applies to a Topic In Play: in an In Play place, or a Guest Topic. Not to a Benched or Pinned Topic.
    func canBench(_ id: String) -> Bool {
        guard let inPlay = topicConfig.inPlay, !isRemote, topics.topicsEnabled else { return false }
        return topics.split(inPlay: inPlay).inPlay.contains { $0.id == .topic(id) }
    }

    /// Bench Topic goes through the Topic service, as `muxify topic bench` does.
    func benchTopic(_ id: String) {
        guard canBench(id), !changingTopic else { return }
        perform(EnvironmentRequest(.benchTopic, target: .topic(.id(id))))
    }

    /// The card that the Make a Guest and End Guest Commands act on: the Active Topic, else the Session of the Location.
    var currentGuestCard: GuestCard? {
        if let id = activeTopicID { return .topic(id) }
        return selectedWindow.map { .session($0.sessionID) }
    }

    /// Make a Guest and End Guest go through the Topic service, as `muxify topic make-guest` and `muxify session lock`
    /// do. A Session is a Guest through its Lock.
    func setGuest(_ card: GuestCard, _ guest: Bool) {
        guard guestState(of: card) == !guest else { return }
        switch card {
        case .topic(let id): perform(EnvironmentRequest(.makeGuest, target: .topic(.id(id))))
        case .session(let id): setLock(ofSession: id, guest)
        }
    }

    func toggleLockOfCurrentSession() {
        guard let id = selectedWindow?.sessionID, let locked = lockState(ofSession: id) else { return }
        setLock(ofSession: id, !locked)
    }

    /// Whether Move Topic Up (`previous`) or Down (`next`) can move the card of the Active Topic or Locked Session, as
    /// the card's own Move Up and Move Down do. Not at that end of the cards with its Pin, for No Topic, for a Settled
    /// Topic, and outside Topics mode, where the cards do not show.
    func canMoveActiveCard(_ direction: StepDirection) -> Bool {
        guard supportsTopics, !changingTopic, topics.mode == .topics, let active = topics.activeTopic else { return false }
        return topics.neighbors(of: active).placement(direction) != nil
    }

    func moveActiveCard(_ direction: StepDirection) {
        guard canMoveActiveCard(direction), let id = topics.activeTopic?.listID else { return }
        moveCard(id, direction == .previous ? .up : .down)
    }

    /// The Active Topic when it is open, which Pin Topic and Unpin Topic act on.
    var pinnableActiveTopic: TopicRecord? {
        guard supportsTopics, let id = activeTopicID else { return nil }
        return topicContents.records.first { $0.id == id && $0.settledAt == nil }
    }

    func togglePinOfActiveTopic() {
        if let topic = pinnableActiveTopic { pinTopic(topic.id, !topic.isPinned) }
    }

    func changeTopic(_ source: TopicMembershipPlan.Source, destination: TopicRecord? = nil, title: String = "") {
        let target: EnvironmentTarget?
        switch source {
        case .session(let window): target = SessionID(rawValue: window.sessionID).map(EnvironmentTarget.session)
        case .window(let window): target = WindowID(rawValue: window.id).map(EnvironmentTarget.window)
        case .pane(let pane, _): target = .pane(pane)
        }
        guard let target else { return }
        let to: TopicDestination = destination.map { .topic(.id($0.id)) } ?? .newTopic(title: title)
        perform(EnvironmentRequest(.move(to: to), target: target), presenting: .membership(selecting: source.window.id))
    }

    func removeWindowFromTopic(_ window: TmuxWindow) {
        var draft = MoveDraft(window: window, paneID: window.activePaneID, scope: .window)
        draft.destination = .sessions(topic: nil)
        palette.begin(.move(draft), keepingHistory: true)
    }

    func removeFromTopic(_ window: TmuxWindow) {
        guard let session = SessionID(rawValue: window.sessionID) else { return }
        perform(EnvironmentRequest(.removeFromTopic, target: .session(session)), presenting: .membership(selecting: nil))
    }

    /// The Session leaves its Topic and stops. The palette shows the Topic's next Session, or the Empty Topic.
    func removeAndKill(_ window: TmuxWindow, worktrees: [String]) {
        guard let session = SessionID(rawValue: window.sessionID) else { return }
        perform(EnvironmentRequest(.removeAndKill(worktrees: worktrees), target: .session(session)))
    }

    func presentRenameTopic(keepingHistory: Bool = false) {
        environmentModule.reloadRecords()
        guard !changingTopic, supportsTopics,
              let topic = topicContents.records.first(where: { $0.id == activeTopicID && $0.settledAt == nil }) else { return }
        palette.begin(.text(.renameTopic(topic)), text: topic.title ?? "", keepingHistory: keepingHistory)
    }

    func presentAddSession(toTopic id: String? = nil, keepingHistory: Bool = false) {
        environmentModule.reloadRecords()
        let selected = id ?? activeTopicID
        guard let topic = topicContents.records.first(where: { $0.id == selected && $0.settledAt == nil }),
              !changingTopic, supportsTopics else { return }
        palette.begin(.addSession(topic), keepingHistory: keepingHistory)
        refreshSessionPaths()
    }

    func renameTopic(_ id: String, to title: String) {
        perform(EnvironmentRequest(.rename(title: title), target: .topic(.id(id))))
    }

    /// Set Topic Note on the open Topic `id`, else on the Active Topic.
    func presentSetTopicNote(of id: String? = nil, keepingHistory: Bool = false) {
        environmentModule.reloadRecords()
        let selected = id ?? activeTopicID
        guard !changingTopic, supportsTopics,
              let topic = topicContents.records.first(where: { $0.id == selected && $0.settledAt == nil }) else { return }
        palette.begin(.text(.topicNote(topic)), text: topic.note ?? "", keepingHistory: keepingHistory)
    }

    /// Nil clears the Topic Note.
    func setTopicNote(of id: String, _ note: String?) {
        perform(EnvironmentRequest(.note(note), target: .topic(.id(id))))
    }

    /// Puts a Session before or after another Session of its Topic, which then keeps the order the user gave.
    func moveSession(_ sessionID: String, to placement: TopicSessionPlacement) {
        guard let session = SessionID(rawValue: sessionID) else { return }
        perform(EnvironmentRequest(.moveSession(to: placement), target: .session(session)))
    }

    func sortSessionsByCreation(ofTopic id: String) {
        perform(EnvironmentRequest(.sortSessions, target: .topic(.id(id))))
    }

    /// `newWorktree` opens the Session on a new Worktree from the chosen one, which starts as it says; it needs a
    /// repository row.
    func addSession(_ choice: SessionChoice, toTopic id: String, newWorktree: WorktreeStart?) {
        perform(EnvironmentRequest(.addSession(sessionPath: choice.sessionPath.folder.path,
                                               workingCopy: choice.workingCopy(newWorktree: newWorktree != nil, start: newWorktree ?? .head), name: choice.name),
                             target: .topic(.id(id))))
    }

    /// Moves a Pane into a new Untitled Topic: the Pane that the terminal shows, or the Window's or Pane's id.
    func presentMovePane(_ target: EnvironmentTarget?, includesTab: Bool = false, keepingHistory: Bool = false) {
        guard supportsTopics, let window = selectedWindow else { return }
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
                let result = await topicQueries().inventory()
                guard generation == environment, palette.invocation == token,
                      case .move(let draft) = palette.flow else { return }
                guard case .success(let snapshot) = result else {
                    palette.close()
                    if case .failure(let error) = result { showTopicFailure(error) }
                    return
                }
                let windowID = snapshot.clients.first { $0.tty == tty }?.windowID ?? window.id
                guard let source = snapshot.windows.first(where: { $0.id == windowID && $0.sourceID == draft.window.sourceID }) else {
                    palette.close()
                    return
                }
                palette.replaceFlow(.move(MoveDraft(window: source, paneID: source.activePaneID, scope: draft.scope,
                                                    includesTab: draft.includesTab)))
            }
        }
    }

    /// The open Topic of the Window the user looks at, or of the empty-Topic view; nil for No Topic.
    var activeTopicID: String? {
        if case .topic(let id) = topics.activeTopic { return id }
        return nil
    }

    /// When the Config sets `topics.in_play`, each Lock becomes a Guest at the end of In Play (ADR 0061). The flag in
    /// UserDefaults says that this Mac gathered them for the `in_play` now set, so a restart or a reload does not move
    /// the Guests again.
    private func gatherGuestsWhenInPlayIsSet() {
        let key = "guestsGathered"
        guard !isRemote, topics.topicsEnabled else { return }
        guard topicConfig.inPlay != nil else {
            if UserDefaults.standard.bool(forKey: key) { UserDefaults.standard.set(false, forKey: key) }
            return
        }
        guard !UserDefaults.standard.bool(forKey: key), !changingTopic else { return }
        changingTopic = true
        let environment = generation
        environmentModule.perform(EnvironmentRequest(.runtime(.gatherGuests)), topics: topicConfig) { [weak self] receipt in
            guard let self, self.generation == environment else { return }
            self.changingTopic = false
            self.environmentModule.reloadRecords()
            if case .failed(let failure) = receipt.value { NSLog("muxify: topics: gather Guests: \(failure.message)") }
            else { UserDefaults.standard.set(true, forKey: key) }
        }
    }

    func presentSettleTopic(_ id: String? = nil, keepingHistory: Bool = false) {
        environmentModule.reloadRecords()
        let selected = id ?? activeTopicID
        if let topic = topicContents.records.first(where: { $0.id == selected && $0.settledAt == nil }) { palette.begin(.confirm(PaletteConfirmation(.settle(topic))), keepingHistory: keepingHistory) }
    }

    func presentForgetTopic(_ id: String, keepingHistory: Bool = false) {
        environmentModule.reloadRecords()
        guard let topic = topicContents.records.first(where: { $0.id == id }) else { return }
        guard !changingTopic, supportsTopics else { return }
        palette.begin(.confirm(PaletteConfirmation(.forget(topic))), keepingHistory: keepingHistory)
    }

    func forgetTopic(_ id: String, choices: [TopicSettleSession], worktrees: [String]) {
        perform(EnvironmentRequest(.forget(choices: choices, worktrees: worktrees), target: .topic(.id(id)), expectedSessionIDs: choices.map(\.id)))
    }

    func settleTopic(_ id: String, choices: [TopicSettleSession], outcome: String) {
        let next = activeTopicID == id ? nextTopic(after: id) : nil
        perform(EnvironmentRequest(.settle(choices: choices, outcome: outcome), target: .topic(.id(id)), expectedSessionIDs: choices.map(\.id)), presenting: .settle(next))
    }

    func reopenTopic(_ id: String, _ choice: TopicReopening.Choice) {
        let command: EnvironmentCommand
        switch choice {
        case .reopen: command = .reopen
        case .startFresh: command = .startFresh
        }
        perform(EnvironmentRequest(command, target: .topic(.id(id))))
    }

    /// The open Topic has a Session to create, the same test that makes the empty-Topic view offer the Reopen choice.
    /// An Empty Topic remembers no Session, so going to it offers Add a Session and creates nothing implicitly.
    private func reopensOnArrival(_ id: String) -> Bool {
        guard topicContents.records.contains(where: { $0.id == id && $0.settledAt == nil && !$0.sessions.isEmpty }),
              case .success(let reopening)? = reopening(id, .reopen) else { return false }
        return !reopening.sessions.isEmpty
    }

    /// What `reopenTopic` would create now, for the panel to show before the user chooses.
    func reopening(_ id: String, _ choice: TopicReopening.Choice) -> Result<TopicReopening, Error>? {
        guard let topic = topicContents.records.first(where: { $0.id == id }) else { return nil }
        return Result {
            try TopicReopening(topic: topic, records: topicContents.records, windows: windows, sessionPaths: sessionPaths,
                               existingDirectories: Set(environmentModule.state?.existingWorktrees ?? []), choice: choice)
        }
    }

    private func enqueueTopicRequest(_ request: EnvironmentRequest) {
        topicRequests.append(request)
        drainTopicRequests()
    }

    private func drainTopicRequests() {
        guard !isShuttingDown, !changingTopic, !topicRequests.isEmpty else { return }
        if perform(topicRequests[0]) { topicRequests.removeFirst() }
    }

    /// How the app shows a finished Topic request.
    enum TopicPresentation {
        case edit
        case newTopic
        /// As `edit`; a failure lets the user press again at once for this folder.
        case newSession(Folder)
        /// A Session or Window that moved shows where it is now; nothing else changes.
        case membership(selecting: String?)
        case settle(TopicGroupID?)
        case move(source: String, tab: BrowserTab?)
        /// The Location goes to this card, as Go to Topic does.
        case goTo(TopicGroupID)
    }

    /// For an edit in the Active Environment, save Browser state and pending Topic memory before the edit.
    @discardableResult
    func perform(_ request: EnvironmentRequest, presenting presentation: TopicPresentation = .edit) -> Bool {
        guard !isShuttingDown, !changingTopic else { return false }
        guard connection != nil, !isTransitioning else { return false }
        let module = environmentModule
        let browserValues = pendingBrowserStates
        let dirty = dirtyBrowsers
        changingTopic = true
        let client = clientTTY ?? (isRemote ? nil : surface?.ttyName)
        let environment = generation
        let invocation = palette.invocation
        module.perform(request, client: client, sessionPaths: sessionPaths, topics: topicConfig, worktreesRoot: config.worktreesRoot,
                       preparing: browserValues) { [weak self] receipt in
            guard let self, self.generation == environment else { return }
            if case .failed = receipt.value {} else {
                for value in browserValues where self.dirtyBrowsers[value.window.rawValue] == dirty[value.window.rawValue] {
                    self.dirtyBrowsers[value.window.rawValue] = nil
                }
            }
            let present = { [weak self] in
                self?.present(receipt.value, as: presentation, invocation: invocation, revision: receipt.revision)
            }
            if case .failed = receipt.value { present() }
            else {
                self.pendingTopicPresentation = (receipt.revision, { present() })
                self.refresh()
            }
        }
        return true
    }

    func topicQueries() -> EnvironmentQueries {
        activeWatch?.queries(sessionPaths: sessionPaths, topics: topicConfig) ?? EnvironmentQueries { _ in
            .failed(TopicFailure(kind: .cancelled, phase: .nothingChanged, message: "The Environment is not ready."))
        }
    }

    /// The Muxify Worktrees of the Environment that the App Window shows, for Remove Worktree (ADR 0062).
    func listWorktrees() async -> EnvironmentResponse {
        await withCheckedContinuation { continuation in
            environmentModule.perform(EnvironmentRequest(.listWorktrees(all: true, from: nil)), worktreesRoot: config.worktreesRoot) {
                continuation.resume(returning: $0.value)
            }
        }
    }

    private func present(_ response: EnvironmentResponse, as presentation: TopicPresentation, invocation: UUID, revision: EnvironmentRevision?) {
        environmentModule.reloadRecords()
        changingTopic = false
        let ownsPalette = palette.invocation == invocation
        switch response {
        case .topics, .topic, .worktrees, .paneSearch:
            break
        case .readChanged:
            break
        case .failed(let failure):
            if case .newSession(let directory) = presentation { pendingOpenings[directory] = nil }
            if case .newTopic = presentation, failure.phase == .nothingChanged, ownsPalette {
                newTopicFailure = "Could not save the Topic. \(failure.message)"
            } else if failure.kind == .topicMembershipChanged || failure.kind == .panesChanged, ownsPalette {
                if case .confirm(let draft) = palette.flow { draft.impactChanged = true }
                palette.loadFlow()
            } else {
                showFailedTopicRequest(failure)
            }
        case .changed(let change):
            switch presentation {
            case .membership(let windowID):
                if ownsPalette, case .addSession = palette.flow { palette.close() }
                if let id = windowID.flatMap(WindowID.init(rawValue:)) { route(.go(.window(id), readsOnArrival: true)) }
            case .settle(let next):
                if ownsPalette { palette.close() }
                route(.settled(next: next))
            case .move(let source, let tab):
                if case .window(let destination)? = change.shown {
                    if let tab, source != destination.rawValue {
                        browser(for: source).moveTab(tab, to: browser(for: destination.rawValue))
                    }
                    if let revision { route(.result(.window(destination), revision: revision)) }
                }
            case .goTo(let card):
                if ownsPalette { palette.close() }
                goToTopic(card)
            case .edit, .newTopic, .newSession:
                if ownsPalette { palette.close() }
                switch change.shown {
                case .emptyTopic(.topic(let id))?:
                    showEmptyTopic(id)
                    if case .newTopic = presentation, ownsPalette { presentAddSession(toTopic: id) }
                case .window(let id)?:
                    if let revision { route(.result(.window(id), revision: revision)) }
                    // A new tmux Window or Session names no Topic and leaves the Sidebar in its mode.
                    if change.topicID != nil { sidebarMode = .topics }
                    moveFocusIntoWindow()
                    if surface == nil || surface?.processExited == true,
                       let window = windows.first(where: { $0.id == id.rawValue })
                        ?? (try? connection?.snapshot())?.windows.first(where: { $0.id == id.rawValue }) {
                        route(.attach(id), target: Target(window))
                    }
                case .emptyTopic?, nil:
                    break
                }
            }
        }
        // Only an edit can make a tmux Window to attach to. A Read change on a stopped server leaves it
        // stopped: an attach there would start the server with a new Session.
        var changed = false
        if case .changed = response { changed = true }
        refresh(attachIfNeeded: changed && surface == nil)
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

    /// A Location can name a Window before a read lists it, so that first read records the visit too.
    private func recordVisit() {
        guard let window = selectedWindow else { return }
        let group: TopicGroupID = window.topicID.map { id in
            topicContents.records.contains { $0.id == id && $0.settledAt == nil } ? .topic(id) : .noTopic
        } ?? .noTopic
        // A mutating call on `visits` notifies its readers even when it records nothing, and this runs on each refresh.
        var log = visits
        guard log.record(window, group: group, sessionPaths: sessionPaths, folders: folders, at: Date()) else { return }
        visits = log
        visits.save(to: .standard)
    }

    var topicContents: TopicContents { environmentModule.records }
    var topicSelection = TopicSelection()
    private(set) var topicBranches = TopicBranches()
    /// The last read, so a refresh runs `ps` only when a Topic Pane starts another program.
    @ObservationIgnored private var paneCommandLines = PaneCommandLines()

    /// Whether the Settled group is open, and the Settled pages shown.
    var topicGroups = TopicGroupsState()
    /// Whether the Bench shows. Only the user shows or hides it. Each App Window has its own, and no restart keeps it.
    var benchShown = false
    var benchPeek: TopicsModel.BenchPeek?

    /// Built again only after a change to what it reads. The Sidebar, the menus
    /// and the terminal area read it many times in each update, and each build is expensive.
    var topics: TopicsModel { topicsCache.value }
    @ObservationIgnored private lazy var topicsCache = ObservedCache { [unowned self] in buildTopics() }

    private func buildTopics() -> TopicsModel {
        var config = self.config
        // The fallback cannot read Topic records on the Remote machine.
        if !supportsTopics { config.sidebar.topics = false }
        return TopicsModel(records: topicContents.records, openPlaces: topicContents.openPlaces, windows: windows, config: config,
                           selection: topicSelection, location: location, mode: sidebarMode, groups: topicGroups, benchShown: benchShown,
                           benchPeek: benchPeek, agents: agents,
                           panes: panesVisible ? panes : nil)
    }

    var sidebarFormatContexts: SidebarFormatContexts { sidebarFormatsCache.value }
    @ObservationIgnored private lazy var sidebarFormatsCache = ObservedCache { [unowned self] in
        SidebarFormatContexts(model: topics, windows: windows, panes: panes, agents: agents,
                              branches: topicBranches, records: topicContents.records, sessionPaths: sessionPaths,
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

    /// Shows or hides the Bench, while the Topics list has one.
    func toggleBench() {
        guard topics.isBenchShown != nil else { return }
        benchPeek = nil
        benchShown.toggle()
    }

    /// Choose In Play needs `topics.in_play` and a card that is not Pinned. In Sessions mode too: In Play is a place in
    /// the Topics list, which both modes share.
    var canChooseInPlay: Bool {
        supportsTopics && !changingTopic && topics.topicsEnabled && topicConfig.inPlay != nil && topics.rows.contains { !$0.isPinned }
    }

    /// The check step of Choose In Play, with the In Play Topics and the Guest Topics checked.
    func presentChooseInPlay(keepingHistory: Bool = false) {
        guard canChooseInPlay, let inPlay = topicConfig.inPlay else { return }
        let topics = self.topics.split(inPlay: inPlay).inPlay.filter { if case .topic = $0.id { return true } else { return false } }
        let draft = CheckDraft(action: .chooseInPlay(places: inPlay), checked: Set(topics.map(\.id)))
        palette.begin(.check(draft), keepingHistory: keepingHistory)
    }

    /// Choose In Play goes through the Topic service, as `muxify topic choose-in-play` does.
    func chooseInPlay(_ cards: [TopicGroupID]) {
        perform(EnvironmentRequest(.chooseInPlay(cards.compactMap { $0.listID.flatMap(Self.ref(of:)) })))
    }

    /// The card of the Location while it is In Play and the Bench has a card for Replace from Bench to put in its place.
    /// In Sessions mode too: In Play is a place in the Topics list, which both modes share.
    private var replaceableCard: TopicGroupID? {
        guard supportsTopics, !changingTopic, topics.topicsEnabled, let inPlay = topicConfig.inPlay, let active = topics.activeTopic else { return nil }
        let cards = topics.split(inPlay: inPlay)
        return !cards.bench.isEmpty && cards.inPlay.contains { $0.id == active } ? active : nil
    }

    var canReplaceFromBench: Bool { replaceableCard != nil }

    func presentReplaceFromBench(keepingHistory: Bool = false) {
        guard let card = replaceableCard else { return }
        palette.begin(.replaceFromBench(card), keepingHistory: keepingHistory)
    }

    /// Replace from Bench goes through the Topic service, as `muxify topic replace-from-bench` does. Then the Location
    /// goes to the card that came In Play; the command line leaves the Location, as its other order verbs do.
    func replaceFromBench(_ card: TopicGroupID, with benched: TopicGroupID) {
        guard let target = card.listID.flatMap(Self.target(of:)), let ref = benched.listID.flatMap(Self.ref(of:)) else { return }
        perform(EnvironmentRequest(.replaceFromBench(with: ref), target: target), presenting: .goTo(benched))
    }

    /// Going to a Settled Topic opens its group, so the Sidebar shows it; leaving the group closes it.
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
    private var router = Router()
    var location: Location? { router.location }
    var selectedWindowID: String? { location?.windowID?.rawValue }
    var showsEmptyPage: Bool {
        if case .emptyTopic = location { return true }
        return false
    }

    private func locationChanged(from old: Location?) {
        rememberSelection()
        recordVisit()
        updateTopicSelection()
        let previousID = old?.windowID?.rawValue
        guard selectedWindowID != previousID else { return }
        // A Window starts in its Terminal, as moveFocusIntoWindow gives it, not in the side the last Window used.
        lastFocus = nil
        paneFinder.close()
        let previous = previousID.flatMap { gitViews[$0] }
        let coveredWindow = previous?.isOpen == true
        previous?.suspend()
        if let gitView = selectedWindowID.flatMap({ gitViews[$0] }), gitView.isOpen {
            gitView.resume()
        } else if coveredWindow {
            moveFocusIntoWindow()
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
    let pills = Pills()
    /// Find in Pane, over the Terminal of the current Window.
    let paneFinder = PaneFinder()
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
        var sidebar = config.sidebar
        if !supportsTopics { sidebar.topics = false }
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
    @ObservationIgnored private var browsers: [String: Browser] = [:]
    /// Each Window's Git View, made when it first opens and kept while the
    /// Window lives. Observed, for the sidebar's Git View icons.
    private var gitViews: [String: GitView] = [:]
    /// The Git Views' Copied commits, by repository: shared by every Window in any Worktree of it.
    @ObservationIgnored private let copiedCommits = CopiedCommits()
    @ObservationIgnored private var persistWork: [String: DispatchWorkItem] = [:]
    /// Keep changes dirty until tmux confirms the write, including commands
    /// already submitted when a window closes. Never flush unchanged Browsers
    /// over newer state saved by another App Window.
    @ObservationIgnored private var dirtyBrowsers: [String: UUID] = [:]
    /// Windows whose `@muxify_open` we consumed and are clearing.
    @ObservationIgnored private var consumingOpen = Set<String>()
    @ObservationIgnored private var rememberedWindowID: String?
    @ObservationIgnored private var clientTTY: String?
    /// Sessions a SessionPath row is creating, by directory, until a snapshot lists them or a few seconds pass.
    @ObservationIgnored private var pendingOpenings: [Folder: (name: String, deadline: Date)] = [:]
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var activationObserver: Any?
    @ObservationIgnored private var deactivationObserver: Any?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var connection: TmuxConnection?
    private var generation: UUID { environmentModule.id }
    private var isTransitioning = false
    @ObservationIgnored private var reconnectWork: DispatchWorkItem?
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var attachmentTarget: Target?
    @ObservationIgnored private var attachmentReadsOnArrival = false
    @ObservationIgnored private var bootstrapIntent: Router.IntentID?
    @ObservationIgnored private var pendingAttachment: (intent: Router.IntentID, revision: EnvironmentRevision)?
    @ObservationIgnored private var attachmentReadRequested = false
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
    /// Starts serving Browser commands for the server whose socket it gets, and returns the path to publish.
    @ObservationIgnored var serveBrowserAgent: ((_ tmuxSocket: String) -> String?)?
    /// Whether this store wrote `BrowserAgentChannel.option`, so its connection removes it when it retires.
    @ObservationIgnored private var publishedBrowserSocket = false
    #if DEBUG
    @ObservationIgnored private var gitDemoObserver: NSObjectProtocol?
    #endif

    /// Browser History of this Mac, for the Browsers of this App Window.
    let browserHistory: BrowserHistory

    init(configStore: ConfigStore, environment: RemoteEnvironment? = nil, localEnvironment: EnvironmentWatchClient? = nil,
         browserHistory: BrowserHistory = .shared) {
        self.localEnvironment = localEnvironment ?? AppWindows.makeLocalEnvironment(config: configStore.config)
        self.configStore = configStore
        self.browserHistory = browserHistory
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
        if !isRemote { refreshSessionPaths() }
        theme = GhosttyRuntime.shared.theme
        guard GhosttyRuntime.shared.app != nil else {
            terminalMessage = "libghostty failed to initialize."
            return
        }
        installKeyMonitor()
        terminalHost.onFirstResponderChange = { [weak self] in self?.readFocusedPanel() }
        paneFinder.perform = { [weak self] operation, completion in
            self?.performOperation(.paneSearch(operation)) { receipt in
                switch receipt.value {
                case .paneSearch(let result): completion(.success(result))
                case .failed(let error): completion(.failure(error))
                default: completion(.failure(TmuxError.notReady))
                }
            } ?? false
        }
        paneFinder.windowID = { [weak self] in self?.selectedWindowID }
        paneFinder.styles = { [weak self] in self?.findStyles ?? PaneSearch.Styles(match: "", current: "") }
        // Coming back to Muxify reads the Agents in the Window on screen.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            guard let self else { return }
            self.readActiveTopicOnEntry()
            self.refresh()
        } }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stopReadingTerminal() } }
        startConnection()
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
    private func transition(to next: RemoteEnvironment?, target: Target? = nil, createSessionIfNeeded: Bool = true,
                            readsOnArrival: Bool = false) {
        guard !isShuttingDown else { return }
        paneFinder.close()
        receiveHintInput(.reset)
        if next != activeEnvironment {
            remoteConfig = nil
            remoteConfigPath = nil
            sessionPaths = []
        }
        activeEnvironment = next
        attachmentTarget = target
        attachmentReadsOnArrival = readsOnArrival
        self.createSessionIfNeeded = createSessionIfNeeded
        let oldModule = environmentModule
        let oldWatch = remoteWatch.client
        remoteWatch = .pending
        environmentModule = EnvironmentReader()
        attachmentReadRequested = false
        changingTopic = false
        pendingTopicPresentation = nil
        attachmentStatusID = UUID()
        attachmentStatus = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        isConnected = false
        environmentStatus = next == nil ? "Switching to Local" : "Connecting to \(next!.name)…"
        terminalMessage = nil
        guard !isTransitioning else {
            connectionCleanup.run(drainPersistence: { let done = $0; oldModule.retire { if let oldWatch { oldWatch.stop(completion: done) } else { done() } } },
                                  retire: {}, closeSurface: {}, cleanup: {})
            return
        }
        isTransitioning = true
        let oldConnection = connection
        let oldSurface = surface
        let flush = pendingBrowserStates
        persistFinalState(on: oldModule, connection: oldConnection, browsers: flush)
        surface = nil
        terminalHost.show(nil)
        clearServerState()
        connection = nil
        connectionCleanup.run(drainPersistence: { let done = $0; oldModule.retire { if let oldWatch { oldWatch.stop(completion: done) } else { done() } } },
                              retire: { oldConnection?.retire() },
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
        var sshExecutable = "/usr/bin/ssh"
        #if DEBUG
        if TestDriver.isRunning, let fixture = ProcessInfo.processInfo.environment["MUXIFY_TEST_SSH"] {
            sshExecutable = fixture
        }
        #endif
        do { connection = try TmuxConnection(environment: activeEnvironment, sshExecutable: sshExecutable) }
        catch {
            terminalMessage = String(describing: error)
            environmentStatus = "Could not start \(environmentName)"
            return
        }
        guard let connection else { return }
        let moduleID = UUID()
        clientRegistration = nil
        let driver = TerminalAttachmentDriver(store: self, connection: connection, generation: moduleID)
        environmentModule = EnvironmentReader(id: moduleID, client: isRemote ? nil : localEnvironment, attachmentDriver: driver)
        if !isRemote {
            environmentModule.onDisconnect = { [weak self] in
                guard let self, self.generation == moduleID else { return }
                self.paneFinder.close()
                self.isConnected = false
                self.pendingAttachment = nil
                self.route(.serverChanged)
                if self.pendingTopicPresentation != nil || self.changingTopic {
                    self.pendingTopicPresentation = nil
                    self.changingTopic = false
                    self.showTopicAlert("The Environment connection was lost.", detail: "Check the Topic before trying again.")
                }
            }
        }
        if isRemote {
            environmentStatus = "Connecting to \(environmentName)…"
            route(.attach(attachmentTarget.flatMap { WindowID(rawValue: $0.windowID) }, readsOnArrival: attachmentReadsOnArrival),
                  target: attachmentTarget, reconnectIfNeeded: false)
        } else {
            environmentStatus = "Local"
            isConnected = true
            refresh(attachIfNeeded: true)
        }
        drainTopicRequests()
    }

    private func clearServerState() {
        persistWork.values.forEach { $0.cancel() }
        persistWork.removeAll()
        dirtyBrowsers.removeAll()
        browsers.values.forEach { $0.tearDown() }
        browsers.removeAll()
        removeGitViews()
        consumingOpen.removeAll()
        readVisits = AgentReadVisits()
        readWindowID = nil
        viewingEpoch += 1
        pendingAttachment = nil
        bootstrapIntent = nil
        windows = []
        agents = []
        palette.close()
        route(.serverChanged)
        topicSelection = TopicSelection()
        hasNoSessions = false
        rememberedWindowID = nil
        clientTTY = nil
        serverID = nil
        serverRunning = false
        homeDirectory = NSHomeDirectory()
    }

    /// Called before AppKit commits to quitting. Snapshot UI-owned Browser
    /// state here, then wait asynchronously for every owned transport to close.
    func shutdown(completion: @escaping () -> Void) {
        receiveHintInput(.reset)
        guard !isShuttingDown else { connectionCleanup.whenFinished(completion); return }
        paneFinder.close()
        isShuttingDown = true
        started = false
        let oldModule = environmentModule
        let oldWatch = remoteWatch.client
        remoteWatch = .pending
        environmentModule = EnvironmentReader()
        attachmentReadRequested = false
        changingTopic = false
        pendingTopicPresentation = nil
        removeGitViews()
        reconnectWork?.cancel()
        reconnectWork = nil
        persistWork.values.forEach { $0.cancel() }
        persistWork.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        let oldConnection = connection
        let oldSurface = surface
        let flush = pendingBrowserStates
        persistFinalState(on: oldModule, connection: oldConnection, browsers: flush)
        browsers.values.forEach { $0.tearDown() }
        browsers.removeAll()
        dirtyBrowsers.removeAll()
        connection = nil
        surface = nil
        terminalHost.show(nil)
        connectionCleanup.run(drainPersistence: { done in
            oldModule.retire { if let oldWatch { oldWatch.stop(completion: done) } else { done() } }
        },
                              retire: { oldConnection?.retire() },
                              closeSurface: { oldSurface?.close() },
                              cleanup: { oldConnection?.cleanup() })
        connectionCleanup.whenFinished(completion)
    }

    @discardableResult
    private func performOperation(_ operation: EnvironmentOperation,
                                  completion: @escaping (EnvironmentWriteReceipt<EnvironmentResponse>) -> Void = { _ in }) -> Bool {
        guard connection != nil, !isTransitioning, !isRemote || isConnected else { return false }
        let current = generation
        environmentModule.perform(EnvironmentRequest(.runtime(operation)), client: clientTTY ?? (isRemote ? nil : surface?.ttyName)) { [weak self] receipt in
            if case .failed(let failure) = receipt.value { Diagnostics.report("Environment request failed: \(failure)") }
            guard let self, self.generation == current else { return }
            completion(receipt)
        }
        return true
    }

    // MARK: - Polling

    func refresh(attachIfNeeded: Bool = false) {
        guard connection != nil, !isTransitioning, !isRemote || surface != nil else { return }
        let current = generation
        attachmentReadRequested = attachmentReadRequested || attachIfNeeded
        environmentModule.read(context: { [weak self] in
            guard let self else { return (0, false) }
            self.environmentModule.updateRules(settings: EnvironmentRuleSettings(config: self.configStore.config),
                viewing: EnvironmentViewing(client: self.clientTTY ?? (self.isRemote ? nil : self.surface?.ttyName),
                    window: self.shownReadScope?.windowID, visible: self.observesTerminal && self.shownReadScope != nil))
            return (self.viewingEpoch, self.attachmentReadRequested)
        }, receive: { [weak self] state, context in
            guard let self, self.generation == current, !self.isRemote || self.surface != nil else { return }
            let (viewing, allowAttach) = context
            guard viewing == self.viewingEpoch else {
                self.environmentModule.invalidateRead()
                self.refresh(attachIfNeeded: allowAttach)
                return
            }
            defer {
                if let pending = self.pendingTopicPresentation, state.revision.isAfter(pending.0) {
                    self.pendingTopicPresentation = nil
                    if state.records.current != nil { pending.1() }
                    else {
                        self.changingTopic = false
                        self.showTopicAlert("The request finished.", detail: "Could not read the saved Topic records.")
                    }
                }
            }
            switch state.inventory {
            case .current(let snapshot):
                if let intent = self.bootstrapIntent {
                    self.bootstrapIntent = nil
                    self.pendingAttachment = (intent, state.revision)
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
                } else {
                    self.isConnected = true
                }
                guard state.records.current != nil else { return }
                if allowAttach { self.attachmentReadRequested = false }
                if self.topicBranches != state.branches { self.topicBranches = state.branches }
                self.paneCommandLines = snapshot.commandLines
                self.apply(snapshot, revision: state.revision, attachIfNeeded: allowAttach)
            case .unavailable(_, let error):
                self.isConnected = false
                if error != .tmux(.notReady) { self.environmentStatus = "Waiting for \(self.environmentName): \(error)" }
            }
        })
    }

    private func apply(_ snapshot: TmuxSnapshot, revision: EnvironmentRevision, attachIfNeeded: Bool) {
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
        if serverRunning != snapshot.serverRunning { serverRunning = snapshot.serverRunning }
        let ownTTY = clientTTY ?? (isRemote ? nil : surface?.ttyName)
        if !isRemote, surface?.processExited == false {
            updateClientMarker(snapshot.clients.first { $0.tty == ownTTY && !$0.isControl })
        }
        let facts = routingFacts(snapshot: snapshot, allowAttach: attachIfNeeded)
        if let command = pendingAttachment, facts.ownClientWindow != nil, surface?.processExited == false {
            pendingAttachment = nil
            route(.commandFinished(command.intent, .success, revision: command.revision), facts: facts)
        }
        route(.read(revision), facts: facts)
        readWindowID = facts.ownClientWindow?.rawValue
        if isTransitioning { return }
        updateTopicSelection()
        if let unresolvedSelectedWindowID, selectedWindow?.id == unresolvedSelectedWindowID {
            moveFocusIntoWindow()
        }
        recordVisit()
        consumeOpenRequests()
        publishBrowserSocket(snapshot)
        reportViewingAndVisits(snapshot.panes)
        gatherGuestsWhenInPlayIsSet()

        if snapshot.serverRunning {
            let live = Set(windows.map(\.id))
            for id in browsers.keys where !live.contains(id) {
                browsers[id]?.tearDown()
                browsers[id] = nil
                dirtyBrowsers[id] = nil
                persistWork.removeValue(forKey: id)?.cancel()
            }
            for id in gitViews.keys where !live.contains(id) {
                gitViews.removeValue(forKey: id)?.close()
            }
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
        if let window = WindowID(rawValue: selectedWindowID) { performOperation(.rememberWindow(window)) }
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

    private static let terminalStartFailure = "Could not start the terminal."

    /// A Mac out of pseudo-terminals is a common reason a Terminal can't start, and nothing else says so: the message
    /// names who holds them when use is high, and the log gets the whole census either way.
    private func explainTerminalStartFailure() {
        let current = generation
        let message = terminalMessage
        DispatchQueue.global(qos: .utility).async {
            let census = PTYCensus.take()
            Diagnostics.report("terminal did not start. \(census.summary)")
            guard census.isHigh else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, self.terminalMessage == message else { return }
                self.terminalMessage = "\(Self.terminalStartFailure) \(census.explanation)"
            }
        }
    }

    private func attach(to target: Target?, intent: Router.IntentID, createSessionIfNeeded: Bool = true) {
        let destination = target.flatMap { target -> EnvironmentAttachment.Destination? in
            guard let session = SessionID(rawValue: target.sessionID), let window = WindowID(rawValue: target.windowID) else { return nil }
            return .init(session: session, window: window)
        }
        let plan = EnvironmentAttachment(destination: destination, directory: target?.path,
                                         createSessionIfNeeded: createSessionIfNeeded)
        let current = generation
        updateClientMarker(nil)
        if let connection, isRemote, remoteWatch.client == nil {
            let driver = TerminalAttachmentDriver(store: self, connection: connection, generation: current)
            driver.attach(plan) { [weak self] result in
                guard let self, self.generation == current else { return }
                switch result {
                case .failure(let error):
                    self.terminalMessage = "\(Self.terminalStartFailure) \(error)"
                    self.explainTerminalStartFailure()
                    self.route(.commandFinished(intent, .failure, revision: self.environmentModule.revision))
                case .success:
                    self.prepareRemoteWatch(connection: connection, driver: driver, intent: intent, generation: current)
                }
            }
            return
        }
        environmentModule.perform(EnvironmentRequest(.runtime(.attach(plan)))) { [weak self] receipt in
            guard let self, self.generation == current else { return }
            if case .failed(let failure) = receipt.value {
                self.terminalMessage = "\(Self.terminalStartFailure) \(failure.message)"
                self.explainTerminalStartFailure()
                self.route(.commandFinished(intent, .failure, revision: receipt.revision))
            } else {
                self.pendingAttachment = (intent, receipt.revision)
                self.refresh()
            }
        }
    }

    private func prepareRemoteWatch(connection: TmuxConnection, driver: TerminalAttachmentDriver,
                                    intent: Router.IntentID, generation: UUID) {
        guard let binary = Bundle.main.resourceURL?.appendingPathComponent("bin/muxify") else { return }
        Task {
            let result = await Task.detached { Result { try RemoteWatch.prepare(connection: connection, binary: binary) } }.value
            guard self.generation == generation, surface?.processExited == false, !isShuttingDown else { return }
            switch result {
            case .failure(let error):
                terminalMessage = "Could not start the Remote Environment. " + String(describing: error)
                route(.commandFinished(intent, .failure, revision: environmentModule.revision))
            case .success(let invocation):
                let settings = EnvironmentRuleSettings(config: configStore.config)
                let client: EnvironmentWatchClient
                if let invocation {
                    client = EnvironmentWatchClient(invocation: invocation, settings: settings)
                    remoteWatch = .copied(client)
                } else {
                    client = EnvironmentWatchClient(fallback: connection, rulesScope: connection.rulesScope, settings: settings,
                                                   scripts: connection, environmentName: activeEnvironment?.name,
                                                   commandLines: { try? connection.runScript(PaneCommandLines.script) })
                    remoteWatch = .fallback(client)
                }
                environmentModule = EnvironmentReader(id: generation, client: client, attachmentDriver: driver)
                environmentModule.onDisconnect = { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.paneFinder.close()
                    self.isConnected = false
                    self.pendingAttachment = nil
                    self.route(.serverChanged)
                    if self.changingTopic {
                        self.pendingTopicPresentation = nil
                        self.changingTopic = false
                        self.showTopicAlert("The Environment connection was lost.", detail: "Check the Topic before trying again.")
                    }
                }
                bootstrapIntent = intent
                client.start()
                refresh()
            }
        }
    }

    @MainActor private final class TerminalAttachmentDriver: EnvironmentAttachmentDriver {
        weak var store: WorkspaceStore?
        let connection: TmuxConnection
        let generation: UUID

        init(store: WorkspaceStore, connection: TmuxConnection, generation: UUID) {
            self.store = store
            self.connection = connection
            self.generation = generation
        }

        func attach(_ plan: EnvironmentAttachment, completion: @escaping (Result<Void, Error>) -> Void) {
            guard let store, store.generation == generation,
                  let command = try? connection.terminalCommand(plan),
                  let view = TerminalSurfaceView(command: command, workingDirectory: connection.isRemote ? nil : plan.directory, delegate: store)
            else { completion(.failure(TmuxError.cancelled)); return }
            if let previous = store.pendingAttachment {
                store.route(.commandFinished(previous.intent, .failure, revision: previous.revision))
            }
            store.pendingAttachment = nil
            let oldSurface = store.surface
            store.surface = view
            oldSurface?.close()
            store.clientTTY = nil
            store.terminalMessage = nil
            store.hasNoSessions = false
            store.terminalHost.show(view)
            store.moveFocusIntoWindow()
            let fail: (Error) -> Void = { [weak store] error in
                view.close()
                if let store, store.generation == self.generation, store.surface === view {
                    store.surface = nil
                    store.clientTTY = nil
                    store.terminalHost.show(nil)
                }
                completion(.failure(error))
            }
            Task { [connection, generation, weak store] in
                let deadline = Date().addingTimeInterval(30)
                while Date() < deadline {
                    guard let store, store.generation == generation, !view.processExited else {
                        fail(TmuxError.cancelled)
                        return
                    }
                    let tty = view.ttyName
                    let ready = await Task.detached { connection.attachmentReady(tty: tty) }.value
                    guard store.generation == generation, !view.processExited else {
                        fail(TmuxError.cancelled)
                        return
                    }
                    if ready { completion(.success(())); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                fail(TmuxError.timedOut)
            }
        }
    }

    private func updateClientMarker(_ client: TmuxClient?) {
        guard !isRemote else { return }
        let previous = clientRegistration
        if let previous, previous.marker.pid == client?.pid {
            guard case .retry(_, let after) = previous, Date() >= after else { return }
        } else if let previous {
            environmentModule.perform(EnvironmentRequest(.runtime(.removeClient(previous.marker.id)))) { receipt in
                if case .failed(let failure) = receipt.value { Diagnostics.report("Client removal failed: \(failure)") }
            }
            clientRegistration = nil
        }
        guard let client else { return }
        let marker = clientRegistration?.marker ?? EnvironmentClientMarker(id: UUID(), pid: client.pid, tty: client.tty,
                                                                            home: NSHomeDirectory(), host: Tmux.hostName)
        clientRegistration = .pending(marker)
        let current = generation
        environmentModule.perform(EnvironmentRequest(.runtime(.registerClient(marker)))) { [weak self] receipt in
            guard let self, self.generation == current, self.clientRegistration?.marker.id == marker.id else { return }
            if case .failed(let failure) = receipt.value {
                self.clientRegistration = .retry(marker, after: Date().addingTimeInterval(5))
                Diagnostics.report("Client registration failed: \(failure)")
            } else {
                self.clientRegistration = .registered(marker)
            }
        }
    }

    private func persistFinalState(on module: EnvironmentReader, connection: TmuxConnection?, browsers: [EnvironmentBrowserState]) {
        guard let connection else { return }
        if !browsers.isEmpty {
            module.perform(EnvironmentRequest(.runtime(.browser(browsers)))) { receipt in
                if case .failed(let failure) = receipt.value { Diagnostics.report("final Browser save failed: \(failure)") }
            }
        }
        if publishedBrowserSocket {
            publishedBrowserSocket = false
            module.perform(EnvironmentRequest(.runtime(.browserSocket(nil)))) { receipt in
                if case .failed(let failure) = receipt.value { Diagnostics.report("Browser socket removal failed: \(failure)") }
            }
        }
        guard let marker = connection.remote?.markerID ?? clientRegistration?.marker.id else { return }
        module.perform(EnvironmentRequest(.runtime(.removeClient(marker)))) { receipt in
            if case .failed(let failure) = receipt.value { Diagnostics.report("Client removal failed: \(failure)") }
        }
    }

    func reattach() {
        if isRemote { reconnectAttempt = 0; transition(to: activeEnvironment); return }
        let target = (selectedWindow ?? Self.initialWindow(in: windows)).map(Target.init)
        route(.attach(target.flatMap { WindowID(rawValue: $0.windowID) }), target: target)
    }

    func select(_ window: TmuxWindow, onFailure: ((Error) -> Void)? = nil) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }) else { return }
        guard connection != nil, !isTransitioning, !isRemote || isConnected,
              let id = WindowID(rawValue: window.id) else { return }
        route(.go(.window(id), readsOnArrival: true), onFailure: onFailure)
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

    /// Shows what a `muxify://select` URL names (`muxify session open`, `window open`, `topic open`).
    func select(_ request: SelectRequest) {
        route(.request(request, at: Date()))
        if started { refresh() }
    }

    /// Switches to the Agent's Window with its Pane active. The Pane is
    /// selected first (tmux commands run in order) so the Window shows up
    /// with the Agent already focused.
    func select(_ agent: Agent) {
        guard agents.contains(where: { $0.id == agent.id && $0.sourceID == agent.sourceID }) else { return }
        if let pane = PaneID(rawValue: agent.paneID) { performOperation(.selectPane(pane)) }
        if let window = windows.first(where: { $0.id == agent.windowID }) {
            select(window)
        } else {
            switchClient(to: Target(sessionID: agent.sessionID, windowID: agent.windowID, path: nil))
        }
    }

    /// Shows the Pane's Window with that Pane active.
    func select(_ pane: TopicsModel.PaneRow) {
        if let pane = PaneID(rawValue: pane.pane.id) { performOperation(.selectPane(pane)) }
        select(pane.window)
    }

    var currentReadTarget: ReadPlan.Place? {
        if case .emptyTopic(.topic(let id)) = location { return .topic(id) }
        return selectedWindow.map { AgentReadScope(window: $0).target }
    }

    private var canWriteAgentRead: Bool {
        connection != nil && isConnected && environmentModule.isReady
    }

    private func readDecision(_ change: ReadChange, in target: ReadPlan.Place) -> ReadPlan.Decision {
        let busy = isTransitioning || router.hasPendingClientCommand || router.intent != nil
            || (isConnected && !environmentModule.isReady)
        return ReadPlan.decide(change, in: target, records: topicContents.records, agents: agents, windows: windows,
                               busy: busy, agentsWritable: canWriteAgentRead)
    }

    func canChangeRead(_ change: ReadChange, in target: ReadPlan.Place?) -> Bool {
        guard let target, case .change = readDecision(change, in: target) else { return false }
        return true
    }

    /// Mark Read or Mark Unread on a target that a row names. It does what it can, without a Pill.
    func changeRead(_ change: ReadChange, in target: ReadPlan.Place?) {
        guard let target, canChangeRead(change, in: target) else { return }
        applyRead(change, in: target)
    }

    /// The Command, the menu item and the shortcut: Mark Read on the current target. An Explanation Pill says why
    /// nothing changed, or that a Read of the Zoomed Pane left hidden Panes Unread.
    func markCurrentRead() {
        guard let target = currentReadTarget else { return }
        switch readDecision(.read, in: target) {
        case .refused(let refusal):
            if let pill = Pill(readRefusal: refusal, in: target) { pills.show(pill) }
        case .change(_, let hidden):
            applyRead(.read, in: target)
            if hidden > 0 { pills.show(Pill(readOfZoomedPaneLeaving: hidden)) }
        }
    }

    private func applyRead(_ change: ReadChange, in target: ReadPlan.Place) {
        guard let request = target.request(change) else { return }
        if canWriteAgentRead { reportViewingAndVisits(panes) }
        else {
            readVisits = AgentReadVisits()
            _ = readVisits.consume(showing: shownReadScope, panes: panes, observing: observesTerminal)
        }
        perform(request)
    }

    func readActiveTopicOnEntry() {
        guard NSApp.isActive, terminalHost.window?.isKeyWindow == true,
              case .emptyTopic(.topic(let id)) = location else { return }
        readTopicsOnVisit([id])
    }

    private func readTopicsOnVisit(_ ids: Set<String>) {
        guard supportsTopics, !isTransitioning, connection != nil else { return }
        let current = generation
        for id in ids.sorted() {
            environmentModule.perform(EnvironmentRequest(.runtime(.visit(.emptyTopic(id), manualRead: config.notifications.manualRead)))) { [weak self] receipt in
                guard let self, self.generation == current else { return }
                if case .failed(let failure) = receipt.value { self.showTopicFailure(failure) }
            }
        }
    }

    func stopReadingTerminal() {
        readVisits.hide()
        environmentModule.updateRules(settings: EnvironmentRuleSettings(config: configStore.config), viewing: EnvironmentViewing())
        viewingEpoch += 1
    }

    func terminalVisibilityChanged() {
        if !panelLayout.shows(.terminal) || currentGitView?.isOpen == true { stopReadingTerminal() }
        refresh()
    }

    private var observesTerminal: Bool {
        NSApp.isActive && terminalHost.window?.isKeyWindow == true
    }

    private var shownReadScope: AgentReadScope? {
        guard !showsEmptyPage, panelLayout.shows(.terminal), currentGitView?.isOpen != true,
              router.intent == nil, !router.hasPendingClientCommand,
              selectedWindowID == readWindowID else { return nil }
        return selectedWindow.map(AgentReadScope.init)
    }

    var currentReadSummary: String? {
        switch currentReadTarget {
        case .window:
            return selectedWindow.map { "Window: " + $0.displayTitle }
        case .pane(let id):
            return "Zoomed Pane: " + (panes.first { $0.id == id }?.label ?? id)
        case .topic(let id):
            return "Topic: " + (topics.titles[id] ?? id)
        default: return nil
        }
    }

    private func reportViewingAndVisits(_ panes: [TmuxPane]) {
        let scope = shownReadScope
        environmentModule.updateRules(settings: EnvironmentRuleSettings(config: configStore.config),
            viewing: EnvironmentViewing(client: clientTTY ?? (isRemote ? nil : surface?.ttyName),
                                        window: scope?.windowID, visible: observesTerminal && scope != nil))
        let visited = router.intent == nil && !router.hasPendingClientCommand
            ? readVisits.consume(showing: scope, panes: panes, observing: observesTerminal) : []
        if !visited.isEmpty, let window = (scope?.windowID).flatMap(WindowID.init(rawValue:)) {
            _ = performOperation(.visit(.panes(window: window, shown: Set(visited.compactMap(PaneID.init(rawValue:)))),
                                        manualRead: configStore.config.notifications.manualRead))
        }
    }

    private func routingFacts(snapshot: TmuxSnapshot? = nil, allowAttach: Bool = false) -> Router.Facts {
        let groups = Set(topics.rows.map(\.id)).union([.noTopic])
        let entries = Dictionary(uniqueKeysWithValues: groups.compactMap { group -> (TopicGroupID, WindowID)? in
            guard let window = entryWindow(of: group), let id = WindowID(rawValue: window.id) else { return nil }
            return (group, id)
        })
        let tty = clientTTY ?? (isRemote ? nil : surface?.ttyName)
        let client = snapshot?.clients.first { $0.tty == tty && !$0.isControl }
        return Router.Facts(windows: windows, ownClientWindow: client.flatMap { WindowID(rawValue: $0.windowID) },
                            records: topicContents.records, entryWindows: entries,
                            hasTerminal: surface != nil && surface?.processExited == false,
                            allowAttach: allowAttach, rememberedWindow: snapshot?.lastWindowID.flatMap(WindowID.init(rawValue:)),
                            initialWindow: Self.initialWindow(in: windows).flatMap { WindowID(rawValue: $0.id) }, now: Date())
    }

    private func route(_ event: Router.Event, facts: Router.Facts? = nil, target: Target? = nil,
                       reconnectIfNeeded: Bool = true, onFailure: ((Error) -> Void)? = nil) {
        let old = location
        let facts = facts ?? routingFacts()
        var next = router
        let effects = next.handle(event, facts)
        // Each tmux read routes, and an unchanged write would still build `topics` and the whole Sidebar again.
        if next != router { router = next }
        if old != location { locationChanged(from: old) }
        for effect in effects {
            switch effect {
            case .visit(let location):
                rememberSelection()
                recordVisit()
                updateTopicSelection()
                if case .emptyTopic(.topic(let id)) = location, old != location { readTopicsOnVisit([id]) }
            case .enterRead(let id):
                readVisits.enter(windowID: id.rawValue)
            case .requestTopic(let group):
                goToTopic(group)
            case .switchClient(let id, let intent):
                if let destination = windows.first(where: { $0.id == id.rawValue }).map(Target.init)
                    ?? target.flatMap({ $0.windowID == id.rawValue ? $0 : nil }) {
                    executeSwitch(to: destination, intent: intent, onFailure: onFailure)
                }
            case .attach(let id, let intent):
                let destination = id.flatMap { id in
                    windows.first(where: { $0.id == id.rawValue }).map(Target.init)
                        ?? target.flatMap { $0.windowID == id.rawValue ? $0 : nil }
                }
                if isRemote, !isConnected, reconnectIfNeeded {
                    let readsOnArrival: Bool
                    if case .window(let pending) = router.intent, pending.id == intent {
                        readsOnArrival = pending.readsOnArrival
                    } else {
                        readsOnArrival = false
                    }
                    transition(to: activeEnvironment, target: destination, createSessionIfNeeded: false,
                               readsOnArrival: readsOnArrival)
                } else {
                    attach(to: destination, intent: intent, createSessionIfNeeded: isRemote ? createSessionIfNeeded : true)
                }
            }
        }
    }

    private func switchClient(to target: Target, onFailure: ((Error) -> Void)? = nil) {
        guard connection != nil, !isTransitioning, !isRemote || isConnected,
              let id = WindowID(rawValue: target.windowID) else { return }
        route(.go(.window(id), readsOnArrival: true), target: target, onFailure: onFailure)
    }

    private func executeSwitch(to target: Target, intent: Router.IntentID, onFailure: ((Error) -> Void)? = nil) {
        moveFocusIntoWindow()
        guard let surface, !surface.processExited, let tty = clientTTY ?? (isRemote ? nil : surface.ttyName) else {
            if isRemote {
                let readsOnArrival: Bool
                if case .window(let pending) = router.intent, pending.id == intent {
                    readsOnArrival = pending.readsOnArrival
                } else {
                    readsOnArrival = false
                }
                transition(to: activeEnvironment, target: target, createSessionIfNeeded: false,
                           readsOnArrival: readsOnArrival)
            } else {
                attach(to: target, intent: intent)
            }
            return
        }
        clientTTY = tty
        guard let session = SessionID(rawValue: target.sessionID), let window = WindowID(rawValue: target.windowID) else { return }
        performOperation(.switchClient(session: session, window: window)) { [weak self] receipt in
            guard let self else { return }
            switch receipt.value {
            case .failed(let error):
                self.route(.commandFinished(intent, .failure, revision: receipt.revision))
                onFailure?(error)
            default:
                self.route(.commandFinished(intent, .success, revision: receipt.revision))
            }
            self.refresh()
        }
    }

    var terminalHasFocus: Bool {
        guard let surface else { return false }
        return surface.window?.firstResponder === surface
    }

    /// `keyFocus` as of the last change of the window's first responder, which SwiftUI cannot observe by itself. Nil
    /// while no view has it.
    private var focusedPanel: PanelLayout.Side?
    /// The side a Focus move goes to, until the first responder changes. The marker hides meanwhile, so it never
    /// shows the side that Focus is leaving.
    private var incomingFocus: PanelLayout.Side?

    /// The holder that had Focus last, for the Focus rule. A palette's field or a sheet's field is not a holder.
    private var lastFocus: FocusHolder?

    func readFocusedPanel() {
        guard let window = terminalHost.window else { return }
        focusedPanel = window.firstResponder is NSView ? keyFocus : nil
        incomingFocus = nil
        if window.firstResponder is NSView {
            if let holder = focusHolder { lastFocus = holder }
        } else {
            // One turn, so a route or a close that gives Focus somewhere goes first.
            DispatchQueue.main.async { [weak self] in self?.restoreFocus() }
        }
    }

    /// The holder that has Focus now, nil while a palette's field or another view has it.
    private var focusHolder: FocusHolder? {
        guard !palette.isOpen else { return nil }
        if terminalSideHasFocus { return .terminal }
        if currentGitView?.hasKeyFocus == true { return .gitView }
        return browserHasFocus ? .browser : nil
    }

    /// The Focus rule (ADR 0065): the App Window itself holds Focus only while nothing takes input, so Focus goes
    /// back to a view when the window is still the first responder a turn after it became one.
    private func restoreFocus() {
        guard let window = terminalHost.window else { return }
        let gap = FocusGap(firstResponderIsView: window.firstResponder is NSView, paletteIsOpen: palette.isOpen,
                           sheetIsOpen: window.attachedSheet != nil || NSApp.modalWindow != nil,
                           showsEmptyPage: showsEmptyPage, gitViewIsOpen: currentGitView?.isOpen == true,
                           layout: panelLayout, lastFocus: lastFocus)
        switch gap.focusToRestore {
        case .terminal?: moveFocus(into: .terminal)
        case .browser?: moveFocus(into: .browser)
        case .gitView?: currentGitView?.takeFocus()
        case nil: break
        }
    }

    /// Only a move to the other side changes the first responder, which ends the move.
    private func expectFocus(in side: PanelLayout.Side) {
        if focusedPanel != side { incomingFocus = side }
    }

    /// `ui.focus_marker`: the side that shows the marker. None while a side is alone, with no other side to tell it
    /// from, or while a Command Palette has Focus.
    var focusMarkerSide: PanelLayout.Side? {
        guard config.focusMarker, panelLayout.shows(.terminal), panelLayout.shows(.browser), !palette.isOpen,
              incomingFocus == nil else { return nil }
        return focusedPanel
    }

    /// The Terminal or its Find in Pane field has Focus.
    private var terminalSideHasFocus: Bool { terminalHasFocus || paneFinder.findFieldHasFocus }

    /// The current Window's Browser has Focus (its page or omnibox).
    var browserHasFocus: Bool {
        !terminalSideHasFocus && currentGitView?.hasKeyFocus != true && panelLayout.shows(.browser)
    }

    private var focusedSide: PanelLayout.Side { browserHasFocus ? .browser : .terminal }

    /// The side whose keybinds act, nil while the Git View has Focus.
    private var keyFocus: PanelLayout.Side? { terminalSideHasFocus ? .terminal : browserHasFocus ? .browser : nil }

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
        // The Window's Git View, open over its sides; one just gone to
        // takes Focus once it's on screen.
        if let gitView = selectedWindowID.flatMap({ gitViews[$0] }), gitView.isOpen { return gitView.takeFocus() }
        moveFocus(into: panelLayout.shows(.terminal) ? .terminal : .browser)
    }

    /// When a side with Focus disappears, Focus moves to the side still shown.
    private func keepFocusOnScreen() {
        let layout = panelLayout
        if !layout.shows(.terminal), terminalSideHasFocus {
            currentBrowser?.requestFocus()
        } else if !layout.shows(.browser), !terminalSideHasFocus {
            focusTerminal()
        }
    }

    /// Makes the Terminal the first responder. A hidden Terminal never takes Focus.
    func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let surface, panelLayout.shows(.terminal), !showsEmptyPage, !palette.isOpen else { return }
            expectFocus(in: .terminal)
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
        guard let window = WindowID(rawValue: sibling.id) else { return }
        perform(EnvironmentRequest(.newWindow(command: nil), target: .window(window)))
    }

    func newSession() {
        let cwd = selectedWindow?.path ?? homeDirectory
        let topic = topicContents.records.first { $0.id == selectedWindow?.topicID && $0.settledAt == nil }
        let base = selectedWindow.map { SessionNaming.base(of: $0.sessionName, topic: topic) }
            ?? SessionPath.sessionName((cwd as NSString).lastPathComponent)
        newSession(in: OpenDirectory(directory: Folder(path: cwd, real: folders.folder(cwd).real), name: base), topic: topic?.id)
    }

    /// The Window, or its whole Session with `session`, and its Panes as they are now: what the Kill confirm step
    /// shows the user. It reads tmux and changes nothing.
    func reviewKill(_ window: TmuxWindow, session: Bool, completion: @escaping (Result<(window: TmuxWindow, paneIDs: Set<String>), Error>) -> Void) {
        guard connection != nil else { completion(.failure(TmuxError.notReady)); return }
        let current = generation
        Task {
            let inventory = await topicQueries().inventory().mapError { $0 as Error }
            let result = inventory.flatMap { snapshot in
                Result {
                    let members = snapshot.windows.filter {
                        $0.sourceID == window.sourceID && (session ? $0.sessionID == window.sessionID : $0.id == window.id)
                    }
                    guard let fresh = members.first(where: { $0.id == window.id }) ?? members.first else { throw TmuxError.notReady }
                    let windowIDs = Set(members.map(\.id))
                    return (window: fresh, paneIDs: Set(snapshot.panes.filter { windowIDs.contains($0.windowID) }.map(\.id)))
                }
            }
            guard self.generation == current else { return }
            completion(result)
        }
    }

    /// Kills the Window, or its whole Session, while its Panes are the `reviewed` ones. Otherwise the request fails
    /// with `panes_changed`, and the confirm step shows the Panes again.
    func kill(_ window: TmuxWindow, session: Bool, reviewed: Set<String>) {
        let target: EnvironmentTarget? = session ? SessionID(rawValue: window.sessionID).map(EnvironmentTarget.session)
                                                 : WindowID(rawValue: window.id).map(EnvironmentTarget.window)
        guard let target else { return }
        perform(EnvironmentRequest(session ? .killSession : .killWindow, target: target, expectedPaneIDs: Set(reviewed.compactMap(PaneID.init))))
    }

    func renameSession(_ window: TmuxWindow, to name: String) {
        guard windows.contains(where: { $0.sessionID == window.sessionID && $0.sourceID == window.sourceID }),
              let session = SessionID(rawValue: window.sessionID) else { return }
        perform(EnvironmentRequest(.renameSession(name: name), target: .session(session)))
    }

    func renameWindow(_ window: TmuxWindow, to name: String) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }), let id = WindowID(rawValue: window.id) else { return }
        perform(EnvironmentRequest(.renameWindow(name: name), target: .window(id)))
    }

    /// Puts a Window before or after another Window of its Session, which keeps its current Window.
    func moveWindow(_ window: TmuxWindow, to placement: DropPlacement<String>) {
        guard windows.contains(where: { $0.id == window.id && $0.sourceID == window.sourceID }),
              let anchor = windows.first(where: { $0.id == placement.anchor && $0.sourceID == window.sourceID }),
              anchor.sessionID == window.sessionID, anchor.id != window.id,
              let id = WindowID(rawValue: window.id), let anchorID = WindowID(rawValue: anchor.id) else { return }
        let to: WindowPlacement = if case .before = placement { .before(anchorID) } else { .after(anchorID) }
        perform(EnvironmentRequest(.moveWindow(to: to), target: .window(id)))
    }

    /// A click on a card's Window row selects it, and a drag moves it within its Session.
    var windowRowDrag: WindowRowDrag {
        WindowRowDrag(isEnabled: !changingTopic, select: { [weak self] in self?.select($0) },
                      move: { [weak self] in self?.moveWindow($0, to: $1) })
    }

    private func runOnCurrentPane(_ action: PaneAction) {
        guard let window = selectedWindowID.flatMap(WindowID.init(rawValue:)) else { return }
        performOperation(.pane(window: window, action: action))
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
                for problem in loaded.problems { Diagnostics.report("config: \(problem)") }
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
        environmentModule.reloadRecords()
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
        guard let session = SessionID(rawValue: sessionID) else { return }
        performOperation(.editorWindow(session: session, after: nil, directory: homeDirectory, command: editor)) { [weak self] receipt in
            guard let self, case .changed(let change) = receipt.value, let window = change.window else { return }
            self.switchClient(to: Target(sessionID: sessionID, windowID: window.rawValue, path: nil))
        }
    }

    /// Runs the Git View's editor command for `file` at `line` in a new Window
    /// right after `windowID`, in `directory`, and goes to it while the
    /// Location is still `windowID`. A move made while git and tmux answered
    /// is newer, so it wins (ADR 0044). When the editor's Window closes, the
    /// Router goes to its earlier sibling, the Window with the Git View. On a
    /// Remote Environment tmux runs the command there, so it edits that
    /// machine's file.
    func openInEditor(file: String, line: Int, from windowID: String, in directory: String) {
        let origin = windows.first(where: { $0.id == windowID })
        guard let sessionID = origin?.sessionID ?? selectedWindow?.sessionID else { return }
        let command = config.gitView.editorShellCommand(file: file, line: line)
        guard let session = SessionID(rawValue: sessionID) else { return }
        performOperation(.editorWindow(session: session, after: origin.flatMap { WindowID(rawValue: $0.id) }, directory: directory, command: command)) { [weak self] receipt in
            guard let self, case .changed(let change) = receipt.value, let editor = change.window,
                  self.selectedWindowID == windowID else { return }
            self.switchClient(to: Target(sessionID: sessionID, windowID: editor.rawValue, path: nil))
        }
    }

    // MARK: - Git View

    /// The Window's Git View, made on first use.
    func gitView(for windowID: String) -> GitView {
        if let gitView = gitViews[windowID] { return gitView }
        let gitView = GitView(windowID: windowID)
        gitView.store = self
        gitView.copiedStore = copiedCommits
        gitViews[windowID] = gitView
        return gitView
    }

    /// The Git View of the Location's Window, once it has opened there; nil
    /// on an Empty Topic page. Views don't make one, so `gitViews` changes
    /// only in actions.
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
        gitViews.values.forEach { $0.close() }
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

    /// Runs a Git View network command, such as `git fetch`, on the Environment's machine in a pseudo-terminal,
    /// so its credential prompts go to `onPrompt`. Returns the command, to answer or cancel.
    @discardableResult
    func runGitNetworkScript(_ script: String, arguments: [String], timeout: TimeInterval = 120,
                             onPrompt: @escaping (GitCredentialPrompt) -> Void,
                             completion: @escaping (Result<String, Error>) -> Void) -> TerminalCommand? {
        guard let connection, !isTransitioning, !isRemote || isConnected else {
            completion(.failure(GitViewError(message: "Not connected to \(environmentName).")))
            return nil
        }
        let current = generation
        weak var command: TerminalCommand?
        let started = connection.startTerminalScript(script, arguments: arguments, timeout: timeout, onPrompt: { [weak self] prompt in
            guard let self, self.generation == current else {
                // Nobody is left to answer the question, so the command would wait on it forever.
                command?.cancel()
                return
            }
            onPrompt(prompt)
        }, completion: { [weak self] result in
            guard let self, self.generation == current else { return }
            completion(result)
        })
        command = started
        return started
    }

    // MARK: - Browser

    /// What the current Window shows of its Terminal and Browser.
    var panelLayout: PanelLayout { currentBrowser?.layout ?? PanelLayout() }

    /// The Window's Browser, restored from its tmux options on first use.
    func browser(for windowID: String) -> Browser {
        if let browser = browsers[windowID] { return browser }
        let stored = windows.first { $0.id == windowID }?.storedBrowser ?? StoredBrowser()
        let browser = Browser(windowID: windowID, stored: stored, discoversLocalServers: !isRemote, history: browserHistory)
        let current = generation
        browser.topicID = { [weak self] in self?.windows.first { $0.id == windowID }?.topicID }
        browser.onChange = { [weak self] browser in
            guard let self, self.generation == current else { return }
            persistWindow(browser.windowID)
        }
        browser.onShownChange = { [weak self] browser in
            guard let self, self.generation == current, browser.windowID == self.selectedWindowID else { return }
            keepFocusOnScreen()
            terminalVisibilityChanged()
        }
        browser.onFocusRequest = { [weak self] browser in
            guard let self, self.generation == current, browser.windowID == self.selectedWindowID else { return }
            expectFocus(in: .browser)
        }
        browser.onCopyURL = { [weak self] url in
            guard let self, self.generation == current else { return }
            self.pills.show(Pill(.confirmation, title: "Copied URL", value: url))
        }
        browsers[windowID] = browser
        return browser
    }

    /// The Window's Browser if something has shown or used it, without restoring it from tmux.
    func loadedBrowser(for windowID: String) -> Browser? { browsers[windowID] }

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

    /// Moves Focus from the Browser to the Terminal, and from anywhere else to
    /// the Browser (`toggle_focus`).
    func toggleFocus() {
        focus(browserHasFocus ? .terminal : .browser)
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
        if NSApp.currentEvent?.type == .keyDown, terminalSideHasFocus || currentGitView?.hasKeyFocus == true { return }
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
            guard let id = WindowID(rawValue: window.id) else { continue }
            performOperation(.consumeOpen(id)) { [weak self] _ in
                self?.consumingOpen.remove(window.id)
            }
        }
    }

    /// The App Window that consumes `@muxify_open` also serves Browser commands, so a Tab that an Agent opens
    /// is in the Browser that its next command reaches. Written again whenever the option differs, for
    /// example after another App Window's connection removed it.
    private func publishBrowserSocket(_ snapshot: TmuxSnapshot) {
        guard !isRemote, snapshot.serverRunning, shouldConsumeOpenRequests?() ?? true, let socket = snapshot.socketPath,
              let path = serveBrowserAgent?(socket), snapshot.browserSocket != path else { return }
        publishedBrowserSocket = true
        performOperation(.browserSocket(path)) { receipt in
            if case .failed(let failure) = receipt.value { Diagnostics.report("Browser socket publish failed: \(failure)") }
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
            guard let window = WindowID(rawValue: id) else { return }
            self.performOperation(.browser([EnvironmentBrowserState(window: window, browser: browser.stored)])) { [weak self] receipt in
                guard let self, case .changed = receipt.value, self.dirtyBrowsers[id] == revision else { return }
                self.dirtyBrowsers[id] = nil
            }
        }
        persistWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    var pendingBrowserStates: [EnvironmentBrowserState] {
        dirtyBrowsers.keys.sorted().compactMap { id in
            guard let window = WindowID(rawValue: id), let browser = browsers[id] else { return nil }
            return EnvironmentBrowserState(window: window, browser: browser.stored)
        }
    }

    // MARK: - Keyboard

    func perform(_ action: ConfigAction) {
        switch action {
        case .newAppWindow: onNewAppWindow?()
        case .newTopic: if supportsTopics { presentNewTopic() }
        case .movePane: if supportsTopics { presentMovePane(nil) }
        case .moveWindow: presentMoveWindow()
        case .moveSession: if supportsTopics { presentMoveSession() }
        case .addSessionToTopic: if supportsTopics { presentAddSession() }
        case .settleTopic: if supportsTopics { presentSettleTopic() }
        case .removeSessionFromTopic:
            if supportsTopics, !changingTopic, let window = selectedWindow, window.topicID != nil, window.topicID == activeTopicID { removeFromTopic(window) }
        case .forgetTopic: if let id = activeTopicID, topicContents.records.contains(where: { $0.id == id && $0.settledAt == nil }) { presentForgetTopic(id) }
        case .renameTopic: presentRenameTopic()
        case .setTopicNote: presentSetTopicNote()
        case .toggleLock: toggleLockOfCurrentSession()
        case .moveTopicUp: moveActiveCard(.previous)
        case .moveTopicDown: moveActiveCard(.next)
        case .togglePinTopic: togglePinOfActiveTopic()
        case .markRead: markCurrentRead()
        case .markUnread: changeRead(.unread, in: currentReadTarget)
        case .markAllRead: changeRead(.read, in: .environment)
        case .toggleSidebar: toggleSidebar()
        case .toggleBench: toggleBench()
        case .chooseInPlay: presentChooseInPlay()
        case .replaceFromBench: presentReplaceFromBench()
        case .toggleTerminal: toggle(.terminal)
        case .toggleBrowser: toggle(.browser)
        case .toggleGitView: toggleGitView()
        case .toggleMaximize: toggleMaximize()
        case .toggleMaximizeTerminal: toggleMaximize(.terminal)
        case .toggleMaximizeBrowser: toggleMaximize(.browser)
        case .focusTerminal: focus(.terminal)
        case .focusBrowser: focus(.browser)
        case .toggleFocus: toggleFocus()
        case .toggleZoomPane: toggleZoomOfCurrentPane()
        case .resizePaneLeft: resizeCurrentPane("-L")
        case .resizePaneRight: resizeCurrentPane("-R")
        case .resizePaneUp: resizeCurrentPane("-U")
        case .resizePaneDown: resizeCurrentPane("-D")
        case .findInPane: showFindInPane()
        case .findInPage: browserCommand { $0.activeTab?.showFind() }
        case .selectNextTab: browserCommand { $0.selectTab(offset: 1) }
        case .selectPrevTab: browserCommand { $0.selectTab(offset: -1) }
        case .browserBack: browserCommand { $0.activeTab?.goBack() }
        case .browserForward: browserCommand { $0.activeTab?.goForward() }
        case .closeTab: browserCommand { $0.closeActiveTab() }
        case .reopenClosedTab: currentBrowser?.reopenClosedTab()
        case .selectCard1, .selectCard2, .selectCard3, .selectCard4, .selectCard5,
             .selectCard6, .selectCard7, .selectCard8, .selectCard9,
             .selectWindow1, .selectWindow2, .selectWindow3, .selectWindow4, .selectWindow5,
             .selectWindow6, .selectWindow7, .selectWindow8, .selectWindow9,
             .selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5,
             .selectTab6, .selectTab7, .selectTab8, .selectTab9:
            if let selection = action.quickSwitchSelection { quickSwitch(selection) }
        case .selectNextWindow, .selectPrevWindow, .selectNextTopicWindow, .selectPrevTopicWindow,
             .selectNextSession, .selectPrevSession, .selectNextTopic, .selectPrevTopic:
            guard let step = action.step else { return }
            // Windows and Tabs share their step keys: with the Browser's Focus, a Window step goes to a Tab.
            if browserHasFocus, step.level == .window || step.level == .topicWindow {
                browserCommand { $0.selectTab(offset: step.direction == .next ? 1 : -1) }
            } else {
                self.step(step.level, step.direction)
            }
        }
    }

    /// Opens Find in Pane over the Terminal, or selects its query while it is open.
    func showFindInPane() {
        guard selectedWindow != nil, surface != nil, !showsEmptyPage, panelLayout.shows(.terminal) else { return }
        paneFinder.show()
    }

    /// `ui.find_colors` as tmux styles. A system color takes its light appearance's value, so the highlight is the
    /// same in every theme.
    private var findStyles: PaneSearch.Styles {
        func style(_ color: MarkColor.Single) -> String {
            var resolved = NSColor.black
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                resolved = color.nsColor.usingColorSpace(.sRGB) ?? .black
            }
            func channel(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
            return PaneSearch.style(red: channel(resolved.redComponent), green: channel(resolved.greenComponent),
                                    blue: channel(resolved.blueComponent))
        }
        let colors = config.findColors
        return PaneSearch.Styles(match: style(colors.match), current: style(colors.current))
    }

    /// Closes Find in Pane, which leaves copy mode, and gives Focus back to the Terminal.
    func closeFindInPane() {
        paneFinder.close()
        focusTerminal()
    }

    /// Runs a `keybindings.find` action on the find bar whose field has Focus. False passes the key on.
    private func performFind(_ action: FindAction) -> Bool {
        if paneFinder.isShown, paneFinder.findFieldHasFocus {
            switch action {
            case .next: paneFinder.findNext()
            case .prev: paneFinder.findPrevious()
            case .close: closeFindInPane()
            }
            return true
        }
        if paneFinder.isShown, action == .close, terminalHasFocus {
            // tmux gives the key to the active Pane. Only the searched Pane's close ends the search (ADR 0051).
            paneFinder.closeIfPaneIsActive()
            return false
        }
        guard let browser = currentBrowser, let tab = browser.activeTab, tab.isFindShown, tab.findFieldHasFocus else { return false }
        switch action {
        case .next: tab.findNext()
        case .prev: tab.findPrevious()
        case .close:
            tab.closeFind()
            browser.requestFocus()
        }
        return true
    }

    func toggleZoomOfCurrentPane() {
        runOnCurrentPane(.zoom)
    }

    /// Moves the current Pane's border by 10 cells, as Ghostty's resize_split does.
    private func resizeCurrentPane(_ direction: String) {
        let direction: PaneDirection = switch direction {
        case "-U": .up
        case "-D": .down
        case "-L": .left
        default: .right
        }
        runOnCurrentPane(.resize(direction, amount: 10))
    }

    /// The Config's keybinds, which act before the terminal, Browser and menu
    /// see the key, so they win over Ghostty and page keybinds. ⌘W never
    /// closes the app window (which would quit Muxify).
    /// Other keys in the terminal are left to Ghostty/tmux bindings.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }
    }

    @discardableResult
    func performConfiguredShortcut(_ trigger: KeyTrigger) -> Bool {
        guard !isShuttingDown, let action = config.keybinds.action(for: trigger, focus: keyFocus) else { return false }
        perform(action)
        return true
    }

    private static let closeWindow = KeyTrigger(modifiers: .command, key: .character("w"))

    #if DEBUG
    /// Delivers a key press as AppKit does, without the keyboard: the keybinds,
    /// then the App Window's views, then the menu (scripts/verify/README.md).
    func deliverKeyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let window = terminalHost.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode),
              let passed = handleKeyEvent(event) else { return }
        if !window.performKeyEquivalent(with: passed) { _ = NSApp.mainMenu?.performKeyEquivalent(with: passed) }
    }
    #endif

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
            // A key that composes text in an input method stays with the field.
            if let action = config.findKeybinds.action(for: trigger),
               (event.window?.firstResponder as? NSTextView)?.hasMarkedText() != true, performFind(action) { return nil }
            if let target = config.commandPalettes.first(where: { $0.triggers.contains(trigger) }) {
                palette.toggle(target)
                return nil
            }
            let keybinds = config.keybinds
            if performConfiguredShortcut(trigger) { return nil }
            if keybinds.suppressesDefaultAppWindowShortcut(trigger, focus: keyFocus) { return nil }
            // ⌘W that no keybind took goes on to Ghostty from the Terminal, and
            // elsewhere does nothing, so it never closes the App Window.
            if trigger == Self.closeWindow, !terminalHasFocus { return nil }
        }
        return event
    }
}

// MARK: - muxify:// URLs

extension WorkspaceStore {
    /// Scriptable entry points, e.g. from a shell inside tmux:
    ///   open "muxify://open?url=localhost:3000&window=$(tmux display -p '#{window_id}')"
    ///   open "muxify://select?window=@12"
    ///   open "muxify://select?topic=5c1e…"
    ///   open "muxify://toggle-browser"
    func handle(_ url: URL) {
        guard url.scheme == "muxify" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        switch url.host {
        case "topic":
            do { enqueueTopicRequest(try EnvironmentRequest(url: url)) }
            catch { showTopicFailure(error) }
        case "select":
            if let id = value("window") { select(.window(id)) }
            else if let name = value("session") { select(.session(name)) }
            else if let id = value("topic") { select(.topic(id)) }
        case "open":
            guard let input = value("url"), let target = Omnibox.url(for: input) else { return }
            openInBrowser(target, windowID: value("window"))
        case "toggle-browser":
            toggle(.browser)
        default:
            Diagnostics.report("unknown URL \(url)")
        }
    }
}

// MARK: - libghostty actions

extension WorkspaceStore: @preconcurrency GhosttyRuntimeDelegate {
    func ghosttyPasteAttachments(from pasteboard: NSPasteboard, into view: TerminalSurfaceView) -> Bool {
        // Preserve Local file drops, including directory paths. Raw clipboard
        // images are staged locally; Remote files must be transferred first.
        if !isRemote, pasteboard.types?.contains(.fileURL) == true { return false }
        do {
            guard let attachments = try TerminalAttachments.capture(pasteboard) else { return false }
            guard view === surface, isConnected, let connection, let client = clientTTY ?? view.ttyName else {
                attachments.removeLocalCopy()
                showAttachmentStatus("Could not paste: the Terminal is not connected.")
                return true
            }
            let current = generation
            let statusID = showAttachmentStatus(isRemote ? "Uploading attachment…" : "Preparing attachment…", dismiss: false)
            let module = environmentModule
            connection.prepareAttachments(attachments, client: client) { [weak self] result in
                switch result {
                case .success(let paste):
                    module.perform(EnvironmentRequest(.runtime(.pasteText(pane: paste.pane, text: paste.text)))) { [weak self] receipt in
                        guard let self, self.generation == current, self.attachmentStatusID == statusID else { return }
                        if case .failed(let failure) = receipt.value { self.showAttachmentStatus("Could not paste attachment: \(failure)") }
                        else { self.showAttachmentStatus("Attachment pasted.") }
                    }
                case .failure(let error):
                    guard let self, self.generation == current, self.attachmentStatusID == statusID else { return }
                    self.showAttachmentStatus("Could not paste attachment: \(error)")
                }
            }
        } catch {
            showAttachmentStatus("Could not prepare attachment: \(error)")
        }
        return true
    }

    @discardableResult
    private func showAttachmentStatus(_ message: String, dismiss: Bool = true) -> UUID {
        let id = UUID()
        attachmentStatusID = id
        attachmentStatus = message
        if dismiss {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.attachmentStatusID == id else { return }
                self.attachmentStatus = nil
            }
        }
        return id
    }

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
        let direction: PaneDirection = switch direction {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: .down
        case GHOSTTY_SPLIT_DIRECTION_UP: .up
        default: .right
        }
        runOnCurrentPane(.split(direction))
    }

    func ghosttyGotoSplit(_ direction: ghostty_action_goto_split_e) {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: runOnCurrentPane(.previous)
        case GHOSTTY_GOTO_SPLIT_NEXT: runOnCurrentPane(.next)
        case GHOSTTY_GOTO_SPLIT_UP: runOnCurrentPane(.select(.up))
        case GHOSTTY_GOTO_SPLIT_DOWN: runOnCurrentPane(.select(.down))
        case GHOSTTY_GOTO_SPLIT_LEFT: runOnCurrentPane(.select(.left))
        default: runOnCurrentPane(.select(.right))
        }
    }

    func ghosttyToggleSplitZoom() { toggleZoomOfCurrentPane() }
    func ghosttyStartSearch() { showFindInPane() }

    func ghosttyEqualizeSplits() { runOnCurrentPane(.equalize) }

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
        updateClientMarker(nil)
        if let command = pendingAttachment {
            pendingAttachment = nil
            route(.commandFinished(command.intent, .failure, revision: command.revision))
        }
        view.close()
        surface = nil
        clientTTY = nil
        terminalHost.show(nil)
        if let remote = connection?.remote {
            let finalInventory = remote.exitStatus == 0 ? connection?.closedSnapshot : nil
            let finalState = finalInventory ?? environmentModule.state?.inventory.lastKnown
            if let client = remoteWatch.client {
                environmentModule.retire { client.stop {} }
            }
            pendingTopicPresentation = nil
            changingTopic = false
            isConnected = false
            let message = remote.failureMessage
            if remote.exitStatus == 0 {
                if let snapshot = finalState {
                    windows = snapshot.windows
                    panes = snapshot.panes
                    agents = Agent.list(panes: snapshot.panes, windows: snapshot.windows, ordered: false)
                    hasNoSessions = snapshot.windows.isEmpty
                    serverRunning = snapshot.serverRunning
                    if hasNoSessions {
                        terminalMessage = nil
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
    /// Called when the window's first responder changes, so the Focus marker follows Focus however it moved.
    var onFirstResponderChange: @MainActor () -> Void = {}
    private var responderObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onFirstResponderChange() } }
        }
    }

    func show(_ view: NSView?) {
        current?.removeFromSuperview()
        current = view
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }
}
