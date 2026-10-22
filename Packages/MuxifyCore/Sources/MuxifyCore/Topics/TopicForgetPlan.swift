import Foundation

public struct TopicForgetChoices: Sendable {
    public struct Worktree: Identifiable, Sendable {
        public var id: String { spec.path }
        public let spec: TopicPlan.WorktreeSpec
        public let isClean: Bool
        public let sessionIDs: Set<String>

        public func canRemove(sessions: [TopicSettleSession]) -> Bool {
            canRemove(killing: Set(sessions.filter { $0.disposition == .kill }.map(\.id)))
        }

        /// Clean, and no Session that stays live works in it.
        public func canRemove(killing killed: Set<String>) -> Bool {
            isClean && sessionIDs.isSubset(of: killed)
        }
    }

    public var sessions: [TopicSettleSession]
    public let worktrees: [Worktree]

    init(topic: TopicRecord, snapshot: TmuxSnapshot, sessionPaths: [SessionPath], root: String) {
        let record = topic.remembering(snapshot, order: .oldestFirst) ?? topic
        sessions = TopicSettleSession.choices(topic: record, snapshot: snapshot, sessionPaths: sessionPaths)
        let root = Folder.local(root)
        let windows = snapshot.windows.map { window in
            (sessionID: window.sessionID, folders: window.folders + snapshot.panes.filter { $0.windowID == window.id }.map { Folder.local($0.path) })
        }
        var seen: Set<Folder> = []
        worktrees = (topic.sessions + record.sessions).compactMap { session in
            guard TopicWorktrees.isCreated(session), let sessionPath = session["repository_path"]?.string,
                  let path = session["worktree_path"]?.string, let branch = session["branch"]?.string else { return nil }
            let folder = Folder.local(path)
            guard TopicWorktrees.isInside(folder, root: root), FileManager.default.fileExists(atPath: path),
                  seen.insert(folder).inserted else { return nil }
            let status = try? Shell.run("/usr/bin/git", ["status", "--porcelain", "--untracked-files=normal"], directory: path)
            return Worktree(spec: .init(repositoryPath: sessionPath, path: path, branch: branch),
                            isClean: status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                            sessionIDs: Set(windows.filter { $0.folders.contains(where: folder.contains) }.map(\.sessionID)))
        }
    }
}

struct TopicForgetPlan {
    let edit: TopicEdit

    init(topic: TopicRecord, snapshot: TmuxSnapshot, sessionPaths: [SessionPath], choices: [TopicSettleSession],
         worktrees: [String], root: String) {
        let available = TopicForgetChoices(topic: topic, snapshot: snapshot, sessionPaths: sessionPaths, root: root)
        let sessions = available.sessions.map { session -> TopicSettleSession in
            var result = session
            result.disposition = choices.first { $0.id == session.id }?.disposition ?? session.disposition
            return result
        }
        var taken = Set(snapshot.windows.map(\.sessionName))
        var commands = sessions.flatMap { session -> [TopicPlan.Command] in
            switch session.disposition {
            case .kill: return [.tmux(["kill-session", "-t", session.id])]
            case .keep:
                guard let window = snapshot.windows.first(where: { $0.sessionID == session.id }) else { return [] }
                return topic.detachedCommands(for: window, taken: &taken)
            }
        }
        for tree in available.worktrees where tree.canRemove(sessions: sessions) && worktrees.contains(tree.id) {
            commands.append(.removeCleanWorktree(tree.spec))
        }
        edit = TopicEdit(record: nil, commands: commands, selection: .unchanged, completion: .forget(topic.id))
    }
}
