import AppKit
import MuxifyCore
import Observation

/// Remove Worktree: the Muxify Worktrees of the App Window's Environment, read when the step opens (ADR 0062).
@MainActor @Observable
final class RemoveWorktreeDraft {
    enum Rows {
        case loading
        case failed(String)
        case ready([MuxifyWorktreeSummary])
    }
    var rows: Rows = .loading
}

extension CommandPalette {
    /// New Worktree's first step: each checkout of a repository, with the repository of the current Pane first.
    func newWorktreeRows(query: String, rules: PickRules) -> PickList<PaletteItem> {
        guard let store else { return .empty }
        let choices = store.sessionPathRows.map(\.choice).filter { $0.worktree != nil }
        let current = store.selectedWindow.flatMap { window in SessionChoice.containing(Folder.local(window.path), in: store.sessionPaths) }
        func row(_ choice: SessionChoice) -> PickCandidate<PaletteItem> {
            PickCandidate(id: choice.id, kind: choice.isWorktree ? .worktree : .sessionPath, symbol: "□", title: choice.displayName,
                          fields: [.detail(choice.directory.path)] + choice.nameFields,
                          pick: .available(PaletteItem(ref: .choice(.sessionPath(choice)))))
        }
        let first = choices.filter { $0.sessionPath.folder == current?.sessionPath.folder }
        let rest = choices.filter { $0.sessionPath.folder != current?.sessionPath.folder }
        return FuzzyRanker.list([PickSectionInput(id: "current", rule: .ranked(showsWhenEmpty: true), candidates: first.map(row)),
                                 PickSectionInput(id: "checkouts", rule: .ranked(showsWhenEmpty: true), candidates: rest.map(row))],
                                query: FuzzyQuery(query), rules: rules)
    }

    /// Remove Worktree's first step: one row for each Muxify Worktree, with its branch, folder and state.
    func removeWorktreeRows(_ draft: RemoveWorktreeDraft, query: String, rules: PickRules) -> PickList<PaletteItem> {
        guard case .ready(let worktrees) = draft.rows else { return .empty }
        let rows = worktrees.map { worktree in
            PickCandidate(id: "muxify-worktree-" + worktree.id, kind: .muxifyWorktree, title: worktree.name,
                          fields: [.detail(worktree.branch + " · " + worktree.path)],
                          trailing: worktree.topic.map { worktree.state.rawValue + " · " + $0 } ?? worktree.state.rawValue,
                          pick: .available(PaletteItem(ref: .choice(.muxifyWorktree(worktree.id)))))
        }
        return FuzzyRanker.list([PickSectionInput(id: "worktrees", rule: .ranked(showsWhenEmpty: true), candidates: rows)],
                                query: FuzzyQuery(query), rules: rules)
    }

    /// The confirm step of Remove Worktree: what goes, what stays, the Sessions that ⌘↩ stops, and Force.
    func removeWorktreeConfirmationRows(_ worktree: MuxifyWorktreeSummary, draft: PaletteConfirmation) -> [PickCandidate<PaletteItem>] {
        var rows: [PickCandidate<PaletteItem>] = [
            PickCandidate(id: "remove-folder", kind: .command, title: "Remove \(worktree.path)",
                          fields: [.detail("After the project's preDelete hooks. The branch \(worktree.branch) stays.")], pick: .blocked(reason: "Removes")),
        ]
        for name in worktree.sessions {
            rows.append(PickCandidate(id: "session-" + name, kind: .session, title: name, pick: .blocked(reason: "Uses it · ⌘↩ stops it")))
        }
        if let topic = worktree.topic {
            rows.append(PickCandidate(id: "topic", kind: .topic, title: topic, pick: .blocked(reason: "Forgets its Sessions there")))
        }
        let detail = switch worktree.state {
        case .dirty: "It has changes, which only Force removes."
        case .missing: "Its folder is gone already."
        case .clean: "Force also removes it when a preDelete hook fails."
        }
        rows.append(PickCandidate(id: "force", kind: .command, title: "Force", fields: [.detail(detail)],
                                  trailing: draft.force ? "On" : "Off", pick: .available(PaletteItem(ref: .choice(.force)))))
        return rows
    }

    func loadRemoveWorktrees(_ draft: RemoveWorktreeDraft) {
        guard let store else { return }
        let token = invocation
        Task {
            let response = await store.listWorktrees()
            guard self.invocation == token else { return }
            switch response {
            case .worktrees(let worktrees): draft.rows = .ready(worktrees)
            case .failed(let failure): draft.rows = .failed(failure.message)
            default: draft.rows = .failed("Muxify could not list the Worktrees.")
            }
        }
    }

    /// The branches of New Worktree's start step, read with git on the Environment's machine.
    func loadNewWorktreeStarts(_ draft: WorktreeStartDraft) {
        guard let store, let worktree = draft.choice.worktree else { return }
        let token = invocation
        let queries = store.topicQueries()
        Task {
            let result = await queries.muxifyWorktreeStarts(from: worktree.folder.path)
            guard self.invocation == token else { return }
            switch result {
            case .success(let starts): draft.starts = .ready(starts)
            case .failure(let error): draft.starts = .failed(error.message)
            }
        }
    }
}
