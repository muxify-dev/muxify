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
    case renameWindow(TmuxWindow)
    /// The Session of this Window.
    case renameSession(TmuxWindow)
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

    init(_ target: Target) { self.target = target }

    var requiresCommandReturn: Bool {
        switch target {
        case .forget, .killWindow, .killSession, .removeAndKill: return true
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

enum PaletteFlow {
    case move(MoveDraft)
    case addSession(TopicRecord)
    /// Snooze Topics… or Unsnooze Topics…: check Topics, then go on with them.
    case check(CheckDraft)
    /// The "until" step of a Snooze of these Topics. ⌫ goes back to the check step with them checked.
    case snoozeUntil(Set<String>)
    /// Unsnooze Topic while the Active Topic is not Snoozed: choose one Snoozed Topic.
    case unsnoozeTopic
    case zen(String)
    case text(PaletteText)
    case confirm(PaletteConfirmation)

    /// The step that ⌫ in the empty field goes back to inside the flow; nil goes back to what opened the flow.
    var earlierStep: PaletteFlow? {
        guard case .snoozeUntil(let ids) = self else { return nil }
        return .check(CheckDraft(action: .snooze, checked: ids))
    }

    @MainActor var placeholder: String {
        switch self {
        case .check: "Topics or #Tags"
        case .move(let draft): draft.destination == .topics ? "Topic or new title" : "Destination Session"
        case .addSession: "Search Sessions and Session Paths"
        case .unsnoozeTopic: "Search Snoozed Topics"
        case .snoozeUntil, .zen: "Choose a preset or type 2h, 1300, fri 10:00"
        case .text(.renameWindow): "Window name"
        case .text(.renameSession): "Session name"
        case .text(.tags(let field)):
            switch field.mode {
            case .newTopic: "Untitled"
            case .editTags: "#tag"
            }
        case .text: "Untitled"
        case .confirm(let draft):
            switch draft.target {
            case .settle: "Outcome note (optional)"
            case .forget, .killWindow, .killSession, .removeAndKill: "Review and confirm"
            }
        }
    }
}

enum PaletteChoice: Equatable {
    case move(MoveDestination)
    case sessionPath(SessionChoice)
    case deadline(SnoozeDeadline)
    /// A row of a check step: Space or a click checks it, and ↩ goes on or checks (`CheckRow.returnOutcome`).
    case check(CheckRow)
    /// A row of Unsnooze Topic's choice.
    case unsnooze(String)
    /// A Tag row of a field that takes Tags: ⇥ or ↩ makes it a chip.
    case tag(Tag)
    case session(String)
    case worktree(String)
    case accept
}

extension CommandPalette {
    var breadcrumb: String? {
        if case .search(let config, let tag?) = presentation { return "\(config.name) › " + tag.description }
        guard let flow else { return nil }
        switch flow {
        case .move(let draft): return "\(draft.scope.rawValue) \(draft.window.displayTitle) › Move to"
        case .addSession(let topic): return "\(topicTitle(topic)) › Add a Session"
        case .check(let draft): return "\(draft.action.verb) Topics › check"
        case .snoozeUntil(let set):
            let ids = listOrder(set, .snooze)
            return "\(ids.count == 1 ? topicTitle(id: ids[0]) : "\(ids.count) Topics") › Snooze › until"
        case .unsnoozeTopic: return "Unsnooze Topic"
        case .zen: return "Zen › until"
        case .text(.tags(let field)):
            switch field.mode {
            case .newTopic: return "New Topic"
            case .editTags(let topic): return "\(topicTitle(topic)) › Edit Tags"
            }
        case .text(.renameTopic(let topic)): return "\(topicTitle(topic)) › Rename"
        case .text(.renameWindow(let window)): return "\(window.displayTitle) › Rename"
        case .text(.renameSession(let window)): return "\(window.sessionName) › Rename"
        case .confirm(let draft):
            switch draft.target {
            case .settle(let topic): return "\(topicTitle(topic)) › Settle"
            case .forget(let topic): return "\(topicTitle(topic)) › Forget"
            case .killWindow(let window): return "\(window.displayTitle) › Kill Window"
            case .killSession(let window): return "\(window.sessionName) › Kill Session"
            case .removeAndKill(let window): return "\(window.sessionName) › Remove from Topic and Kill"
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
        case .check(let draft): return checkNote(draft)
        case .snoozeUntil(let ids): return snoozeNote(listOrder(ids, .snooze))
        case .zen(let kept):
            let saves = ZenRecord.start(keeping: kept, until: selectedDeadline ?? .never, records: store.topicWatcher.records).saves
            return "Snoozes: " + saves.map { topicTitle(id: $0.id) }.joined(separator: ", ")
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
        case .text(.renameWindow), .text(.renameSession): return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    var canSuggestTitle: Bool {
        switch flow {
        case .text(.tags(let field)):
            if case .newTopic = field.mode { true } else { false }
        case .text(.renameTopic): true
        default: false
        }
    }

    func topicTitle(_ topic: TopicRecord) -> String {
        store?.topics.titles[topic.id] ?? topic.title ?? topic.slug ?? "Untitled Topic"
    }

    func topicTitle(id: String) -> String {
        store?.topics.titles[id] ?? store?.topicWatcher.records.first { $0.id == id }.map(topicTitle) ?? "Untitled Topic"
    }

    private var selectedDeadline: SnoozeDeadline? {
        if case .choice(.deadline(let deadline)) = selected(in: results)?.pick.payload?.ref { return deadline }
        return nil
    }

    func nextTopicNote(_ ids: [String]) -> String? {
        guard let store, let active = store.activeTopicID, ids.contains(active) else { return nil }
        let next = store.nextTopic(after: active, skipping: Set(ids))
        let title = store.topics.rows.first { $0.id == next }?.title ?? "No Topic"
        return "Then opens: " + title
    }

    /// Names each Snooze that the highlighted time makes shorter, because that time replaces it.
    private func snoozeNote(_ ids: [String]) -> String? {
        guard let store else { return nil }
        var parts: [String] = []
        if ids.count > 1 { parts.append("Snoozes: " + ids.map(topicTitle(id:)).joined(separator: ", ")) }
        if let deadline = selectedDeadline {
            let shortened = SnoozeSet(ids, until: deadline, records: store.topicWatcher.records).shortened
            if !shortened.isEmpty { parts.append("Gets shorter: " + shortened.map(topicTitle(id:)).joined(separator: ", ")) }
        }
        parts += [nextTopicNote(ids)].compactMap { $0 }
        parts.append("⌫ goes back to check")
        return parts.joined(separator: " · ")
    }

    func flowResults(_ flow: PaletteFlow) -> PickList<PaletteItem> {
        guard let store else { return .empty }
        switch flow {
        case .move(let draft):
            guard let catalog else { return .empty }
            if case .sessions(let topic) = draft.destination { return catalog.destinationList(draft.window, topic: topic, query: query) }
            return catalog.moveList(draft.window, query: query, scope: draft.scope)
        case .check(let draft): return checkRows(draft)
        case .unsnoozeTopic: return unsnoozeRows()
        case .addSession(let topic):
            let list = store.sessionPathList(query: query, addingTo: topic)
            let paths = PickList(sections: list.sections.map { section in
                PickSection(id: section.id, title: section.title, rows: section.rows.map { row in
                    let pick: Pick<PaletteItem>
                    switch row.pick {
                    case .available(let choice): pick = .available(PaletteItem(kind: .sessionPath, ref: .choice(.sessionPath(choice))))
                    case .blocked(let reason): pick = .blocked(reason: reason)
                    }
                    return PickRow(id: row.id, symbol: row.symbol, title: row.title, detail: row.detail,
                                   tags: row.tags, trailing: row.trailing, mark: row.mark,
                                   pick: pick, paste: nil, snooze: nil)
                })
            })
            return PickList(sections: (catalog?.addSessionList(topic: topic.id, query: query).sections ?? []) + paths.sections)
        case .snoozeUntil, .zen:
            let now = Date()
            var choices: [(String, String, SnoozeDeadline)] = []
            if !query.isEmpty, let schedule = SnoozeSchedule(query, typed: true), let deadline = schedule.deadline(from: now) {
                choices = [("typed", query, deadline)]
            } else {
                choices = store.topicConfig.snoozePresets.enumerated().compactMap { index, preset in
                    preset.schedule.deadline(from: now).map { (String(index), preset.label, $0) }
                }
                if !choices.contains(where: { $0.2 == .never }) { choices.append(("never", "Until I unsnooze", .never)) }
                choices = choices.filter { query.isEmpty || $0.1.localizedCaseInsensitiveContains(query) }
            }
            return fixed(choices.map { choiceRow($0.0, $0.1, detail: $0.2.description, choice: .deadline($0.2)) })
        case .text(.tags(let field)): return tagRows(field)
        case .text: return .empty
        case .confirm(let draft): return confirmationRows(draft)
        }
    }

    private func choiceRow(_ id: String, _ title: String, detail: String = "", trailing: String = "",
                           choice: PaletteChoice) -> PickCandidate<PaletteItem> {
        PickCandidate(id: id, title: title, fields: [.detail(detail)], trailing: trailing,
                      pick: .available(PaletteItem(kind: .command, ref: .choice(choice))))
    }

    private func fixed(_ candidates: [PickCandidate<PaletteItem>]) -> PickList<PaletteItem> {
        FuzzyRanker.list([PickSectionInput(id: "choices", rule: .fixed, candidates: candidates)], query: FuzzyQuery(""))
    }

    private func confirmationRows(_ draft: PaletteConfirmation) -> PickList<PaletteItem> {
        guard case .ready(let sessions, let worktrees) = draft.choices else { return .empty }
        var rows = sessions.map { session in
            let windows = store?.windows.filter { $0.sessionID == session.id } ?? []
            let working = store?.agents.contains { $0.sessionID == session.id && $0.status == .working } == true
            let windowCount = session.reviewedWindows?.count ?? windows.count
            let paneCount = session.reviewedWindows?.values.reduce(0) { $0 + $1.count } ?? windows.reduce(0) { $0 + $1.paneCount }
            return choiceRow("session-" + session.id, session.name,
                      detail: "\(windowCount) Windows · \(paneCount) Panes" + (working ? " · Agent working" : ""),
                      trailing: session.disposition == .kill ? "Kill" : "Keep with no Topic", choice: .session(session.id))
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
                rows.append(PickCandidate(id: "agent-" + agent.id, title: agent.kind.displayName, pick: .blocked(reason: "Will stop")))
            }
        }
        for tree in worktrees {
            let canRemove = draft.canRemove(tree)
            rows.append(PickCandidate(id: "worktree-" + tree.id, title: tree.id,
                                      trailing: canRemove && draft.removedWorktrees.contains(tree.id) ? "Remove" : "Keep",
                                      pick: canRemove ? .available(PaletteItem(kind: .worktree, ref: .choice(.worktree(tree.id))))
                                        : .blocked(reason: tree.isClean ? "A kept Session uses it" : "Has changes or cannot be checked")))
        }
        if case .killWindow(let window) = draft.target {
            rows.append(choiceRow("kill-window", "Kill \(window.displayTitle)", detail: "\(window.paneCount) Panes", choice: .accept))
            for agent in store?.agents.filter({ $0.windowID == window.id }) ?? [] {
                rows.append(PickCandidate(id: "agent-" + agent.id, title: agent.kind.displayName, pick: .blocked(reason: "Will stop")))
            }
        }
        if case .killSession(let window) = draft.target {
            let windows = store?.windows.filter { $0.sessionID == window.sessionID } ?? []
            rows.append(choiceRow("kill-session", "Kill \(window.sessionName)",
                                  detail: "\(windows.count) Windows · \(draft.reviewedPaneIDs?.count ?? 0) Panes", choice: .accept))
            for agent in store?.agents.filter({ $0.sessionID == window.sessionID }) ?? [] {
                rows.append(PickCandidate(id: "agent-" + agent.id, title: agent.kind.displayName, pick: .blocked(reason: "Will stop")))
            }
        }
        return fixed(rows)
    }

    func loadFlow() {
        guard let store, case .confirm(let draft) = flow else { return }
        let target: TopicTarget
        let forget: Bool
        switch draft.target {
        case .killWindow(let window):
            loadKill(window, session: false, draft: draft, submitting: false)
            return
        case .killSession(let window):
            loadKill(window, session: true, draft: draft, submitting: false)
            return
        case .removeAndKill(let window):
            loadRemoveAndKill(window, draft: draft)
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

    /// Cleanup is always opt-in, even for a clean Muxify-created Worktree.
    private func loadRemoveAndKill(_ window: TmuxWindow, draft: PaletteConfirmation) {
        guard let store, let session = SessionID(rawValue: window.sessionID) else { return }
        draft.choices = .loading
        let token = invocation
        let service = store.topicService()
        Task {
            let result = await Task.detached { service.removeAndKillWorktree(of: session) }.value
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

    private func loadKill(_ window: TmuxWindow, session: Bool, draft: PaletteConfirmation, submitting: Bool) {
        guard let store else { return }
        let token = invocation
        let expected = submitting ? draft.reviewedPaneIDs : nil
        draft.choices = .loading
        store.checkKill(window, session: session, expectedPaneIDs: expected) { [weak self] result in
            guard let self, self.invocation == token else { return }
            switch result {
            case .success(nil): self.close()
            case .success(.some(let impact)):
                draft.target = session ? .killSession(impact.window) : .killWindow(impact.window)
                draft.reviewedPaneIDs = impact.paneIDs
                draft.impactChanged = submitting
                draft.choices = .ready([], [])
            case .failure(let error): draft.choices = .failed(error.localizedDescription)
            }
        }
    }

    func suggestTitle() {
        guard let store else { return }
        let token = invocation
        let revision = queryRevision
        let request = UUID()
        suggestionRequest = request
        let receive: (String) -> Void = { [weak self] title in
            guard let self, self.invocation == token, self.queryRevision == revision,
                  self.suggestionRequest == request else { return }
            self.query = title
        }
        switch flow {
        case .text(.tags(let field)):
            if case .newTopic = field.mode { store.suggestNewTopicTitle(completion: receive) }
        case .text(.renameTopic(let topic)): store.suggestTopicTitle(for: topic.id, completion: receive)
        default: break
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
        case .session, .worktree, .tag: accept(choice)
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
                let open = Set(store.topicWatcher.records.filter { $0.settledAt == nil }.map(\.id))
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
            store.addSession(sessionPath, toTopic: topic.id, newWorktree: newWorktree)
        case (.addSession(let topic), .session(let id)):
            guard let window = store.windows.first(where: { $0.sessionID == id }) else { return }
            store.changeTopic(.session(window), destination: topic)
        case (.snoozeUntil(let ids), .deadline(let deadline)): store.snoozeTopics(listOrder(ids, .snooze), until: deadline)
        case (.check, .check(let row)): returnOnCheck(row)
        case (.unsnoozeTopic, .unsnooze(let id)):
            close()
            store.unsnoozeTopic(id)
        case (_, .tag(let tag)): addTagChip(tag)
        case (.zen(let kept), .deadline(let deadline)): store.startZen(keeping: kept, until: deadline)
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
            case .renameWindow(let window):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                store.renameWindow(window, to: value)
                close()
            case .renameSession(let window):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                store.renameSession(window, to: value)
                close()
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
            case .killWindow(let window): loadKill(window, session: false, draft: draft, submitting: true)
            case .killSession(let window): loadKill(window, session: true, draft: draft, submitting: true)
            case .removeAndKill(let window):
                store.removeAndKill(window, worktrees: worktrees.filter { draft.removedWorktrees.contains($0.id) && draft.canRemove($0) }.map(\.id))
            }
        default: break
        }
    }

    func handleFlow(_ trigger: KeyTrigger) -> Bool {
        if trigger == KeyTrigger(modifiers: [], key: .special(.enter)) { acceptSelected(); return true }
        if trigger == KeyTrigger(modifiers: .command, key: .special(.enter)) { acceptSelected(commandReturn: true); return true }
        if case .confirm = flow, query.isEmpty, trigger == KeyTrigger(modifiers: [], key: .character(" ")) { toggleSelected(); return true }
        if case .check = flow {
            // The query of a check step never holds a space, so Space always checks (ADR 0035).
            if [KeyTrigger(modifiers: [], key: .character(" ")), KeyTrigger(modifiers: [], key: .special(.tab))].contains(trigger) {
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
            case .suggestTopicTitle: suggestTitle()
            default: return false
            }
            return true
        }
        return false
    }
}
