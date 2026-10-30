import AppKit
import MuxifyCore
import Observation

struct MoveDraft {
    enum Scope: String, CaseIterable { case pane = "Pane", window = "Window", session = "Session" }
    enum Resolution { case loading, ready }
    enum DestinationStep: Equatable { case topics, sessions(topic: String?) }
    let window: TmuxWindow
    let paneID: String
    var scope: Scope
    var includesTab = false
    var resolution: Resolution = .ready
    var destination: DestinationStep = .topics
}

enum PaletteText {
    /// New Topic, or Edit Tags: one field of chips that holds the Topic's Tags, and ↩ writes them.
    case tags(TagField)
    case renameTopic(TopicRecord)
    /// Set Topic Note: the field starts with the current Note, and ↩ on an empty field clears it.
    case topicNote(TopicRecord)
    case renameWindow(TmuxWindow)
    /// The Session of this Window.
    case renameSession(TmuxWindow)
    /// New Worktree: the name of the Worktree from this checkout.
    case worktreeName(SessionChoice)
}

@MainActor @Observable
final class PaletteConfirmation {
    enum Target {
        case settle(TopicRecord)
        case forget(TopicRecord)
        case killWindow(TmuxWindow)
        /// The Session of this Window.
        case killSession(TmuxWindow)
        /// The Session of this Window leaves its Topic and stops.
        case removeAndKill(TmuxWindow)
        /// Remove Worktree: ⌘↩ also stops the Sessions that use it.
        case removeWorktree(MuxifyWorktreeSummary)
    }
    enum Choices {
        case loading
        case failed(String)
        case ready([TopicSettleSession], [TopicForgetChoices.Worktree])
    }
    var target: Target
    var choices: Choices = .loading
    var removedWorktrees: Set<String> = []
    var reviewedPaneIDs: Set<String>?
    var impactChanged = false
    /// Remove Worktree's Force row: remove the Worktree with changes, or after a failed preDelete hook.
    var force = false

    init(_ target: Target) { self.target = target }

    var requiresCommandReturn: Bool {
        switch target {
        case .forget, .killWindow, .killSession, .removeAndKill: return true
        // ↩ removes a Worktree that no Session uses; one that a Session uses goes only with its Sessions, on ⌘↩.
        case .removeWorktree(let worktree): return !worktree.sessions.isEmpty
        case .settle:
            guard case .ready(let sessions, _) = choices else { return true }
            return sessions.contains { $0.disposition == .kill }
        }
    }

    /// Whether the Worktree row can switch to Remove: no Session that stays live works in it.
    func canRemove(_ tree: TopicForgetChoices.Worktree) -> Bool {
        switch (target, choices) {
        case (.removeAndKill(let window), _): return tree.canRemove(killing: [window.sessionID])
        case (_, .ready(let sessions, _)): return tree.canRemove(sessions: sessions)
        default: return false
        }
    }
}

/// Add a Session with the new Worktree toggle on, or New Worktree: where the new Worktree from `choice` starts
/// (ADR 0039, ADR 0062).
@MainActor @Observable
final class WorktreeStartDraft {
    enum Starts {
        case loading
        case failed(String)
        case ready([WorktreeStartChoice])
    }
    enum Purpose {
        /// A Session of this Topic, in a Worktree named from its slug.
        case addSession(TopicRecord)
        /// A Muxify Worktree with this name, and a No Topic Session in it.
        case newWorktree(name: String)
    }
    let purpose: Purpose
    let choice: SessionChoice
    var starts: Starts = .loading

    init(topic: TopicRecord, choice: SessionChoice) {
        purpose = .addSession(topic)
        self.choice = choice
    }

    init(newWorktree name: String, choice: SessionChoice) {
        purpose = .newWorktree(name: name)
        self.choice = choice
    }
}

enum PaletteFlow {
    case move(MoveDraft)
    case addSession(TopicRecord)
    /// A row for each start of the new Worktree, and a typed ref.
    case worktreeStart(WorktreeStartDraft)
    /// New Worktree: the checkout it starts from. Its name and start come next.
    case newWorktree
    /// Remove Worktree: the Muxify Worktree it removes. A confirm step comes next.
    case removeWorktree(RemoveWorktreeDraft)
    /// Check cards of the Topics list, then go on with them.
    case check(CheckDraft)
    /// Choose In Play: the card for one In Play place.
    case order(OrderDraft)
    case text(PaletteText)
    case confirm(PaletteConfirmation)
    /// Replace from Bench: a Benched card takes the place of this card In Play.
    case replaceFromBench(TopicGroupID)
    /// Clear Browser History: a row for each `ClearRange`, and the chosen row clears.
    case clearHistory

    @MainActor var placeholder: String {
        switch self {
        case .check: "Topics and Locked Sessions, or #tag"
        case .order(let draft): "What goes at place \(draft.place)?"
        case .replaceFromBench: "What comes In Play?"
        case .clearHistory: "Which visits?"
        case .move(let draft): draft.destination == .topics ? "Topic or new title" : "Destination Session"
        case .addSession: "Search Sessions and Session Paths"
        case .worktreeStart: "Branch, or a ref to start at"
        case .newWorktree: "Repository or Worktree to start from"
        case .removeWorktree: "Muxify Worktree"
        case .text(.worktreeName): "Worktree name"
        case .text(.renameWindow): "Window name"
        case .text(.renameSession): "Session name"
        case .text(.topicNote): "What were you doing here?"
        case .text(.tags(let field)):
            switch field.mode {
            case .newTopic: "Untitled"
            case .editTags: "#tag"
            }
        case .text: "Untitled"
        case .confirm(let draft):
            switch draft.target {
            case .settle: "Outcome note (optional)"
            case .forget, .killWindow, .killSession, .removeAndKill, .removeWorktree: "Review and confirm"
            }
        }
    }
}

enum PaletteChoice: Equatable {
    case move(MoveDestination)
    case sessionPath(SessionChoice)
    /// A row of a check step: Space or a click checks it, and ↩ goes on (`CheckDraft.goingOn`).
    case check(TopicGroupID)
    /// A Tag row of a field that takes Tags: ⇥ or ↩ makes it a chip.
    case tag(Tag)
    case session(String)
    case worktree(String)
    case worktreeStart(WorktreeStart)
    /// A Muxify Worktree by its record's id, in Remove Worktree.
    case muxifyWorktree(String)
    /// Remove Worktree's Force row.
    case force
    /// A card of the Topics list, in a step that chooses one.
    case card(TopicGroupID)
    case clearHistory(ClearRange)
    case accept
}

extension CommandPalette {
    var breadcrumb: String? {
        if case .search(let config, let tag?) = presentation { return "\(config.name) › " + tag.description }
        guard let flow else { return nil }
        switch flow {
        case .move(let draft): return "\(draft.scope.rawValue) \(draft.window.displayTitle) › Move to"
        case .addSession(let topic): return "\(topicTitle(topic)) › Add a Session"
        case .worktreeStart(let draft):
            switch draft.purpose {
            case .addSession(let topic): return "\(topicTitle(topic)) › Add a Session › \(draft.choice.displayName) › New Worktree from"
            case .newWorktree(let name): return "New Worktree › \(draft.choice.displayName) › \(name) from"
            }
        case .newWorktree: return "New Worktree"
        case .removeWorktree: return "Remove Worktree"
        case .text(.worktreeName(let choice)): return "New Worktree › \(choice.displayName)"
        case .check(let draft): return "\(draft.action.title) › Check"
        case .order(let draft): return "Choose In Play › Place \(draft.place)"
        case .replaceFromBench(let card): return "\(cardTitle(card)) › Replace from Bench"
        case .clearHistory: return "Clear Browser History"
        case .text(.tags(let field)):
            switch field.mode {
            case .newTopic: return "New Topic"
            case .editTags(let topic): return "\(topicTitle(topic)) › Edit Tags"
            }
        case .text(.renameTopic(let topic)): return "\(topicTitle(topic)) › Rename"
        case .text(.topicNote(let topic)): return "\(topicTitle(topic)) › Topic Note"
        case .text(.renameWindow(let window)): return "\(window.displayTitle) › Rename"
        case .text(.renameSession(let window)): return "\(window.sessionName) › Rename"
        case .confirm(let draft):
            switch draft.target {
            case .settle(let topic): return "\(topicTitle(topic)) › Settle"
            case .forget(let topic): return "\(topicTitle(topic)) › Forget"
            case .killWindow(let window): return "\(window.displayTitle) › Kill Window"
            case .killSession(let window): return "\(window.sessionName) › Kill Session"
            case .removeAndKill(let window): return "\(window.sessionName) › Remove from Topic and Kill"
            case .removeWorktree(let worktree): return "\(worktree.name) › Remove Worktree"
            }
        }
    }

    var stepNote: String? {
        guard let store else { return nil }
        guard let flow else {
            guard case .command(let command)? = selected(in: results)?.pick.payload?.ref, let title = command.commandReturnTitle else { return nil }
            return "↩ Run · ⌘↩ " + title
        }
        switch flow {
        case .move(let draft) where draft.resolution == .loading: return "Reading the active Pane…"
        case .text(.tags(let field)):
            if case .newTopic = field.mode {
                return store.newTopicFailure ?? tagNote(field) ?? "Makes an empty Topic. Its first Session comes next."
            }
            return tagNote(field)
        case .text(.renameTopic): return "Leave it blank for an Untitled Topic."
        case .text(.topicNote): return "Leave it blank to clear the Note."
        case .worktreeStart(let draft):
            switch draft.starts {
            case .loading: return "Reading the branches…"
            case .failed(let message): return message
            case .ready:
                if case .newWorktree(let name) = draft.purpose {
                    return "HEAD or a ref starts the branch \(name), or checks it out when it exists. Removing the Worktree keeps the branch."
                }
                return "HEAD or a ref starts a new branch. Check out uses the branch, and Settle never deletes it."
            }
        case .newWorktree: return "Its project's .worktree.json copies files in, and postCreate runs in its new Session."
        case .text(.worktreeName): return "It names the branch, the folder and the Session."
        case .removeWorktree(let draft):
            switch draft.rows {
            case .loading: return "Reading the Muxify Worktrees…"
            case .failed(let message): return message
            case .ready(let worktrees): return worktrees.isEmpty ? "Muxify made no Worktree here yet." : nil
            }
        case .check(let draft): return checkNote(draft)
        case .order(let draft): return orderNote(draft)
        case .replaceFromBench(let card): return "\(cardTitle(card)) goes to the end of the Bench."
        case .clearHistory: return "Browser History forgets the pages you visited in this time. ↩ clears at once."
        case .confirm(let draft):
            if case .loading = draft.choices { return "Checking Sessions and Worktrees…" }
            if case .failed(let message) = draft.choices { return message }
            if draft.impactChanged { return "The Sessions, Windows or Panes changed. Review them and confirm again." }
            switch draft.target {
            case .settle(let topic): return nextTopicNote([topic.id])
            case .forget: return "This removes the Topic for good. It cannot be Reopened."
            case .killWindow: return "This stops every process in the Window."
            case .killSession: return "This stops every process in the Session."
            case .removeAndKill(let window):
                let topic = topicTitle(id: window.topicID ?? "")
                let others = store.windows.contains { $0.topicID == window.topicID && $0.sessionID != window.sessionID }
                return "This stops every process in the Session. \(topic) stays open" + (others ? "." : ", Empty.")
            case .removeWorktree(let worktree):
                return worktree.sessions.isEmpty ? "↩ removes the Worktree." : "⌘↩ stops every process in its Sessions and removes it."
            }
        default: return nil
        }
    }

    var requiresCommandReturn: Bool {
        if case .confirm(let draft) = flow { return draft.requiresCommandReturn }
        return false
    }

    var canAccept: Bool {
        guard store?.changingTopic != true else { return false }
        if case .move(let draft) = flow, draft.resolution == .loading { return false }
        if case .confirm(let draft) = flow {
            if case .ready = draft.choices { return true }
            return false
        }
        switch flow {
        case .text(.renameWindow), .text(.renameSession), .text(.worktreeName): return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .text(.tags(let field)): return field.text(query).refusedWords.isEmpty
        default: break
        }
        return acceptsText || selected(in: results)?.pick.payload != nil
    }

    var acceptsText: Bool {
        switch flow {
        case .text, .confirm: true
        default: false
        }
    }

    func topicTitle(_ topic: TopicRecord) -> String {
        store?.topics.titles[topic.id] ?? topic.title ?? topic.slug ?? "Untitled Topic"
    }

    func topicTitle(id: String) -> String {
        store?.topics.titles[id] ?? store?.topicWatcher.records.first { $0.id == id }.map(topicTitle) ?? "Untitled Topic"
    }

    func nextTopicNote(_ ids: [String]) -> String? {
        guard let store, let active = store.activeTopicID, ids.contains(active) else { return nil }
        let next = store.nextTopic(after: active, skipping: Set(ids))
        let title = store.topics.rows.first { $0.id == next }?.title ?? "No Topic"
        return "Then opens: " + title
    }

    func flowResults(_ flow: PaletteFlow) -> PickList<PaletteItem> {
        guard let store else { return .empty }
        switch flow {
        case .move(let draft):
            guard let catalog else { return .empty }
            if case .sessions(let topic) = draft.destination {
                return catalog.destinationList(draft.window, topic: topic, query: query, rules: store.config.rules(for: .moveSession))
            }
            return catalog.moveList(draft.window, query: query, scope: draft.scope, rules: store.config.rules(for: .move))
        case .check(let draft): return checkRows(draft)
        case .order(let draft): return orderRows(draft)
        case .replaceFromBench: return benchRows()
        case .clearHistory:
            let rows = ClearRange.allCases.map { range in
                PickCandidate(id: "clear-" + range.title, kind: .command, title: range.title, isDestructive: range == .allTime,
                              pick: .available(PaletteItem(ref: .choice(.clearHistory(range)))))
            }
            return FuzzyRanker.list([PickSectionInput(id: "ranges", rule: .ranked(showsWhenEmpty: true), candidates: rows, shorterTitleFirst: false)],
                                    query: FuzzyQuery(query), rules: PickRules())
        case .addSession(let topic):
            return catalog?.addSessionList(topic: topic.id, query: query, rows: store.sessionPathRows, rules: store.config.rules(for: .addSession)) ?? .empty
        case .worktreeStart(let draft): return worktreeStartRows(draft, rules: store.config.rules(for: .worktreeStart))
        case .newWorktree: return newWorktreeRows(query: query, rules: store.config.rules(for: .newWorktree))
        case .removeWorktree(let draft): return removeWorktreeRows(draft, query: query, rules: store.config.rules(for: .removeWorktree))
        case .text(.tags(let field)): return tagRows(field, rules: store.config.rules(for: .tags))
        case .text: return .empty
        case .confirm(let draft): return confirmationRows(draft)
        }
    }

    /// A typed ref first, then HEAD, then each local branch. A branch that another Worktree has checked out cannot be
    /// chosen: git checks out a branch in one Worktree only.
    private func worktreeStartRows(_ draft: WorktreeStartDraft, rules: PickRules) -> PickList<PaletteItem> {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var top: [PickCandidate<PaletteItem>] = []
        if !typed.isEmpty { top.append(choiceRow("typed", "Start at \(typed)", choice: .worktreeStart(.ref(typed)))) }
        top.append(choiceRow("head", "HEAD of " + (draft.choice.worktree?.branch ?? draft.choice.displayName), choice: .worktreeStart(.head)))
        guard case .ready(let branches) = draft.starts else { return FuzzyRanker.fixed(top) }
        let rows = branches.map { start in
            PickCandidate(id: "branch-" + start.branch, kind: .command, title: "Check out \(start.branch)", fields: [.detail(start.checkedOutAt ?? "")],
                          pick: start.checkedOutAt == nil ? .available(PaletteItem(ref: .choice(.worktreeStart(.branch(start.branch)))))
                                                          : .blocked(reason: "Checked out"))
        }
        return FuzzyRanker.list([PickSectionInput(id: "start", rule: .fixed, candidates: top),
                                 PickSectionInput(id: "branches", rule: .ranked(showsWhenEmpty: true), candidates: rows)],
                                query: FuzzyQuery(typed), rules: rules)
    }

    private func choiceRow(_ id: String, _ title: String, detail: String = "", trailing: String = "",
                           choice: PaletteChoice) -> PickCandidate<PaletteItem> {
        PickCandidate(id: id, kind: .command, title: title, fields: [.detail(detail)], trailing: trailing,
                      pick: .available(PaletteItem(ref: .choice(choice))))
    }

    private func confirmationRows(_ draft: PaletteConfirmation) -> PickList<PaletteItem> {
        guard case .ready(let sessions, let worktrees) = draft.choices else { return .empty }
        if case .removeWorktree(let worktree) = draft.target { return FuzzyRanker.fixed(removeWorktreeConfirmationRows(worktree, draft: draft)) }
        var rows = sessions.flatMap { session in
            let windows = store?.windows.filter { $0.sessionID == session.id } ?? []
            let working = store?.agents.filter { $0.sessionID == session.id && $0.status == .working } ?? []
            let windowCount = session.reviewedWindows?.count ?? windows.count
            let paneCount = session.reviewedWindows?.values.reduce(0) { $0 + $1.count } ?? windows.reduce(0) { $0 + $1.paneCount }
            let row = choiceRow("session-" + session.id, session.name,
                                detail: "\(windowCount) Windows · \(paneCount) Panes" + (working.isEmpty ? "" : " · Agent working"),
                                trailing: session.disposition == .kill ? "Kill" : "Keep with no Topic", choice: .session(session.id))
            // Kill is the default, so the user sees each working Agent it stops before ⌘↩.
            guard session.disposition == .kill else { return [row] }
            return [row] + working.map { agent in
                PickCandidate(id: "agent-" + agent.id, kind: .agent, title: agent.kind.displayName, pick: .blocked(reason: "Working · will stop"))
            }
        }
        for session in sessions where session.worktree != nil && session.disposition == .kill {
            if case .settle = draft.target {
                rows.append(choiceRow("worktree-" + session.id, session.worktree?.path ?? "",
                                      trailing: session.removeWorktree ? "Remove merged Worktree" : "Keep Worktree",
                                      choice: .worktree(session.id)))
            }
        }
        if case .removeAndKill(let window) = draft.target {
            let windows = store?.windows.filter { $0.sessionID == window.sessionID } ?? []
            rows.append(choiceRow("kill-session", "Kill \(window.sessionName)",
                                  detail: "\(windows.count) Windows · \(windows.reduce(0) { $0 + $1.paneCount }) Panes", choice: .accept))
            for agent in store?.agents.filter({ $0.sessionID == window.sessionID }) ?? [] {
                rows.append(PickCandidate(id: "agent-" + agent.id, kind: .agent, title: agent.kind.displayName, pick: .blocked(reason: "Will stop")))
            }
        }
        for tree in worktrees {
            let canRemove = draft.canRemove(tree)
            rows.append(PickCandidate(id: "worktree-" + tree.id, kind: .worktree, title: tree.id,
                                      trailing: canRemove && draft.removedWorktrees.contains(tree.id) ? "Remove" : "Keep",
                                      pick: canRemove ? .available(PaletteItem(ref: .choice(.worktree(tree.id))))
                                        : .blocked(reason: tree.isClean ? "A kept Session uses it" : "Has changes or cannot be checked")))
        }
        if case .killWindow(let window) = draft.target {
            rows.append(choiceRow("kill-window", "Kill \(window.displayTitle)", detail: "\(window.paneCount) Panes", choice: .accept))
            for agent in store?.agents.filter({ $0.windowID == window.id }) ?? [] {
                rows.append(PickCandidate(id: "agent-" + agent.id, kind: .agent, title: agent.kind.displayName, pick: .blocked(reason: "Will stop")))
            }
        }
        if case .killSession(let window) = draft.target {
            let windows = store?.windows.filter { $0.sessionID == window.sessionID } ?? []
            rows.append(choiceRow("kill-session", "Kill \(window.sessionName)",
                                  detail: "\(windows.count) Windows · \(draft.reviewedPaneIDs?.count ?? 0) Panes", choice: .accept))
            for agent in store?.agents.filter({ $0.sessionID == window.sessionID }) ?? [] {
                rows.append(PickCandidate(id: "agent-" + agent.id, kind: .agent, title: agent.kind.displayName, pick: .blocked(reason: "Will stop")))
            }
        }
        return FuzzyRanker.fixed(rows)
    }

    func loadFlow() {
        if case .worktreeStart(let draft) = flow {
            if case .newWorktree = draft.purpose { loadNewWorktreeStarts(draft) } else { loadWorktreeStarts(draft) }
            return
        }
        if case .removeWorktree(let draft) = flow { loadRemoveWorktrees(draft); return }
        guard let store, case .confirm(let draft) = flow else { return }
        let target: EnvironmentTarget
        let forget: Bool
        switch draft.target {
        case .killWindow(let window):
            loadKill(window, session: false, draft: draft)
            return
        case .killSession(let window):
            loadKill(window, session: true, draft: draft)
            return
        case .removeAndKill(let window):
            loadRemoveAndKill(window, draft: draft)
            return
        case .removeWorktree:
            // The row of the first step is the review: the confirm step reads nothing more.
            draft.choices = .ready([], [])
            return
        case .settle(let topic): target = .topic(.id(topic.id)); forget = false
        case .forget(let topic): target = .topic(.id(topic.id)); forget = true
        }
        draft.choices = .loading
        let token = invocation
        let service = store.topicService()
        Task {
            if forget {
                let result = await Task.detached { service.forgetChoices(for: target) }.value
                guard self.invocation == token else { return }
                switch result {
                case .success(let choices): draft.choices = .ready(choices.sessions, choices.worktrees)
                case .failure(let error): draft.choices = .failed(error.message)
                }
            } else {
                let result = await Task.detached { service.settleChoices(for: target) }.value
                guard self.invocation == token else { return }
                switch result {
                case .success(let choices): draft.choices = .ready(choices, [])
                case .failure(let error): draft.choices = .failed(error.message)
                }
            }
        }
    }

    private func loadWorktreeStarts(_ draft: WorktreeStartDraft) {
        guard let store, let worktree = draft.choice.worktree else { return }
        let token = invocation
        let service = store.topicService()
        Task {
            let result = await Task.detached { service.worktreeStarts(from: worktree.folder.path) }.value
            guard self.invocation == token else { return }
            switch result {
            case .success(let starts): draft.starts = .ready(starts)
            case .failure(let error): draft.starts = .failed(error.message)
            }
        }
    }

    /// Cleanup is always opt-in, even for a clean Muxify-created Worktree.
    private func loadRemoveAndKill(_ window: TmuxWindow, draft: PaletteConfirmation) {
        guard let store, let session = SessionID(rawValue: window.sessionID) else { return }
        draft.choices = .loading
        let token = invocation
        let service = store.topicService()
        Task {
            let result = await Task.detached { service.removeAndKillWorktree(of: .session(session)) }.value
            guard self.invocation == token else { return }
            switch result {
            case .success(let tree):
                let trees = tree.map { [$0] } ?? []
                draft.removedWorktrees = []
                draft.choices = .ready([], trees)
            case .failure(let error): draft.choices = .failed(error.message)
            }
        }
    }

    /// The review of the confirm step. After a `panes_changed` failure, `impactChanged` stays set, so the step says why
    /// it asks again.
    private func loadKill(_ window: TmuxWindow, session: Bool, draft: PaletteConfirmation) {
        guard let store else { return }
        let token = invocation
        draft.choices = .loading
        store.reviewKill(window, session: session) { [weak self] result in
            guard let self, self.invocation == token else { return }
            switch result {
            case .success(let impact):
                draft.target = session ? .killSession(impact.window) : .killWindow(impact.window)
                draft.reviewedPaneIDs = impact.paneIDs
                draft.choices = .ready([], [])
            case .failure(let error): draft.choices = .failed(error.localizedDescription)
            }
        }
    }

    func changeMoveScope(_ scope: MoveDraft.Scope) {
        guard case .move(var draft) = flow else { return }
        draft.scope = scope
        draft.destination = .topics
        replaceFlow(.move(draft))
    }

    func toggleTab() {
        guard case .move(var draft) = flow, draft.scope == .pane else { return }
        draft.includesTab.toggle()
        replaceFlow(.move(draft))
    }

    func acceptSelected(commandReturn: Bool = false) {
        // Before `canAccept`: the draft that a Tag row completes is a Tag word that no Tag matches yet.
        if case .choice(.tag(let tag))? = selected(in: results)?.pick.payload?.ref { accept(.tag(tag)); return }
        guard canAccept else { return }
        if requiresCommandReturn && !commandReturn { return }
        if flow == nil, commandReturn, case .command(let command)? = selected(in: results)?.pick.payload?.ref,
           command.commandReturnTitle != nil {
            runCommandReturn(command)
            return
        }
        if acceptsText { accept(.accept) }
        else if case .choice(let choice) = selected(in: results)?.pick.payload?.ref { accept(choice) }
        else if let row = selected(in: results) { perform(.jumpTo, on: row) }
    }

    func toggleSelected() {
        guard case .choice(let choice) = selected(in: results)?.pick.payload?.ref else { return }
        switch choice {
        case .session, .worktree, .tag, .force: accept(choice)
        default: break
        }
    }

    func accept(_ choice: PaletteChoice) {
        guard let store, let flow, !store.changingTopic else { return }
        switch (flow, choice) {
        case (.move(var draft), .move(let destination)):
            guard draft.resolution == .ready else { return }
            if draft.scope != .session {
                let target: String?
                switch destination {
                case .topic(let id): target = id
                case .noTopic: target = nil
                default:
                    close(restoringFocus: false)
                    store.move(draft, to: destination)
                    return
                }
                let open = catalog?.openTopicIDs ?? []
                let ids = Set(store.windows.filter {
                    $0.topicID.flatMap { open.contains($0) ? $0 : nil } == target && $0.sessionID != draft.window.sessionID
                }.map(\.sessionID))
                if target == nil || ids.count > 1 {
                    draft.destination = .sessions(topic: target)
                    begin(.move(draft), keepingHistory: true)
                    return
                }
            }
            close(restoringFocus: false)
            store.move(draft, to: destination)
        case (.addSession(let topic), .sessionPath(let sessionPath)):
            if newWorktree, sessionPath.worktree != nil {
                begin(.worktreeStart(WorktreeStartDraft(topic: topic, choice: sessionPath)), keepingHistory: true)
            } else {
                store.addSession(sessionPath, toTopic: topic.id, newWorktree: nil)
            }
        case (.worktreeStart(let draft), .worktreeStart(let start)):
            switch draft.purpose {
            case .addSession(let topic): store.addSession(draft.choice, toTopic: topic.id, newWorktree: start)
            case .newWorktree(let name): store.createWorktree(from: draft.choice, name: name, start: start)
            }
        case (.newWorktree, .sessionPath(let choice)):
            begin(.text(.worktreeName(choice)), keepingHistory: true)
        case (.removeWorktree(let list), .muxifyWorktree(let id)):
            guard case .ready(let worktrees) = list.rows, let worktree = worktrees.first(where: { $0.id == id }) else { return }
            begin(.confirm(PaletteConfirmation(.removeWorktree(worktree))), keepingHistory: true)
        case (.confirm(let draft), .force):
            draft.force.toggle()
        case (.addSession(let topic), .session(let id)):
            guard let window = store.windows.first(where: { $0.sessionID == id }) else { return }
            store.changeTopic(.session(window), destination: topic)
        case (.check, .check(let id)): returnOnCheck(id)
        case (.order(let draft), .card(let id)): order(draft.placing(id))
        case (.replaceFromBench(let card), .card(let benched)): store.replaceFromBench(card, with: benched)
        case (.clearHistory, .clearHistory(let range)):
            close()
            store.browserHistory.clear(range)
        case (_, .tag(let tag)): addTagChip(tag)
        case (.text(let text), .accept):
            let value = query
            switch text {
            case .tags(let field):
                let typed = field.text(value)
                guard typed.refusedWords.isEmpty else { return }
                switch field.mode {
                case .newTopic: store.createTopic(title: typed.title, tags: typed.tags)
                case .editTags(let topic): store.setTags(of: topic.id, typed.tags)
                }
            case .renameTopic(let topic): store.renameTopic(topic.id, to: value)
            case .topicNote(let topic): store.setTopicNote(of: topic.id, value)
            case .renameWindow(let window):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                store.renameWindow(window, to: value)
                close()
            case .renameSession(let window):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                store.renameSession(window, to: value)
                close()
            case .worktreeName(let choice):
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                begin(.worktreeStart(WorktreeStartDraft(newWorktree: name, choice: choice)), keepingHistory: true)
            }
        case (.confirm(let draft), .session(let id)):
            guard case .ready(var sessions, let worktrees) = draft.choices,
                  let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[index].disposition = sessions[index].disposition == .kill ? .keep : .kill
            if sessions[index].disposition == .keep { sessions[index].removeWorktree = false }
            draft.choices = .ready(sessions, worktrees)
        case (.confirm(let draft), .worktree(let id)):
            guard case .ready(var sessions, let worktrees) = draft.choices else { return }
            if case .settle = draft.target, let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].removeWorktree.toggle()
                draft.choices = .ready(sessions, worktrees)
            } else if let tree = worktrees.first(where: { $0.id == id }), draft.canRemove(tree) {
                if !draft.removedWorktrees.insert(id).inserted { draft.removedWorktrees.remove(id) }
            }
        case (.confirm(let draft), .accept):
            guard case .ready(let sessions, let worktrees) = draft.choices else { return }
            switch draft.target {
            case .settle(let topic): store.settleTopic(topic.id, choices: sessions, outcome: query)
            case .forget(let topic):
                let removed = worktrees.filter { draft.removedWorktrees.contains($0.id) && $0.canRemove(sessions: sessions) }.map(\.id)
                store.forgetTopic(topic.id, choices: sessions, worktrees: removed)
            case .killWindow(let window): store.kill(window, session: false, reviewed: draft.reviewedPaneIDs ?? [])
            case .killSession(let window): store.kill(window, session: true, reviewed: draft.reviewedPaneIDs ?? [])
            case .removeAndKill(let window):
                store.removeAndKill(window, worktrees: worktrees.filter { draft.removedWorktrees.contains($0.id) && draft.canRemove($0) }.map(\.id))
            case .removeWorktree(let worktree):
                store.removeWorktree(worktree, kill: !worktree.sessions.isEmpty, force: draft.force)
            }
        default: break
        }
    }

    func handleFlow(_ trigger: KeyTrigger) -> Bool {
        if trigger == KeyTrigger(modifiers: [], key: .special(.enter)) { acceptSelected(); return true }
        if trigger == KeyTrigger(modifiers: .command, key: .special(.enter)) { acceptSelected(commandReturn: true); return true }
        if case .confirm = flow, query.isEmpty, trigger == KeyTrigger(modifiers: [], key: .character(" ")) { toggleSelected(); return true }
        if case .check = flow {
            // Space checks only in an empty field, so a query can hold a space; ⇥ always checks.
            if trigger == KeyTrigger(modifiers: [], key: .special(.tab)) || (query.isEmpty && trigger == KeyTrigger(modifiers: [], key: .character(" "))) {
                checkSelected()
                return true
            }
            if trigger == KeyTrigger(modifiers: .command, key: .character("a")) { checkShown(); return true }
        }
        if trigger == KeyTrigger(modifiers: [], key: .special(.tab)), case .choice(.tag(let tag))? = selected(in: results)?.pick.payload?.ref {
            addTagChip(tag)
            return true
        }
        if trigger == KeyTrigger(modifiers: [], key: .character(" ")), completeTagDraft() { return true }
        if let action = store?.config.paletteKeybinds.action(for: trigger) {
            switch action {
            case .choosePane: changeMoveScope(.pane)
            case .chooseWindow: changeMoveScope(.window)
            case .chooseSession: changeMoveScope(.session)
            case .toggleIncludeTab: toggleTab()
            case .toggleNewWorktree:
                if case .addSession = flow { newWorktree.toggle() }
            default: return false
            }
            return true
        }
        return false
    }
}
