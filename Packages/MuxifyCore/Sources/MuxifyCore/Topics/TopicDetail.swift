import Foundation

/// One open Topic as `topic show` reports it: its record, and its live Sessions with their Windows and Panes.
public struct TopicDetail: Codable, Hashable, Sendable {
    public struct WorktreeEntry: Codable, Hashable, Sendable {
        public var path: String
        /// Nil when HEAD is detached or the branch is unknown.
        public var branch: String?
        /// The full id of the commit that the Topic started this Worktree at. Nil when the Topic did not make the
        /// Worktree, or made it before records stored `base`.
        public var base: String?

        public init(path: String, branch: String?, base: String? = nil) {
            self.path = path
            self.branch = branch
            self.base = base
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(path, forKey: .path)
            try values.encode(branch, forKey: .branch)
            try values.encode(base, forKey: .base)
        }

        private enum CodingKeys: String, CodingKey { case path, branch, base }
    }

    public struct Window: Codable, Hashable, Sendable {
        public var id: String
        public var index: Int
        public var name: String
        public var active: Bool
        public var panes: [PaneSummary]

        public init(id: String, index: Int, name: String, active: Bool, panes: [PaneSummary]) {
            self.id = id
            self.index = index
            self.name = name
            self.active = active
            self.panes = panes
        }
    }

    public struct Session: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var baseName: String
        public var directory: String
        /// Nil when the Session uses the SessionPath folder.
        public var worktree: WorktreeEntry?
        public var windows: [Window]

        public init(id: String, name: String, baseName: String, directory: String, worktree: WorktreeEntry?, windows: [Window]) {
            self.id = id
            self.name = name
            self.baseName = baseName
            self.directory = directory
            self.worktree = worktree
            self.windows = windows
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(name, forKey: .name)
            try values.encode(baseName, forKey: .baseName)
            try values.encode(directory, forKey: .directory)
            try values.encode(worktree, forKey: .worktree)
            try values.encode(windows, forKey: .windows)
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, directory, worktree, windows
            case baseName = "base_name"
        }
    }

    public var id: String
    /// The label `topic list` prints.
    public var label: String
    public var title: String?
    public var slug: String?
    public var createdAt: String?
    public var snoozedUntil: String?
    /// A→Z.
    public var tags: [Tag]
    /// The Sessions whose `@muxify_topic` names this Topic, in tmux order. Empty for a Dormant Topic.
    public var sessions: [Session]

    public init(id: String, label: String, title: String?, slug: String?, createdAt: String?,
                snoozedUntil: String?, tags: [Tag] = [], sessions: [Session]) {
        self.id = id
        self.label = label
        self.title = title
        self.slug = slug
        self.createdAt = createdAt
        self.snoozedUntil = snoozedUntil
        self.tags = tags
        self.sessions = sessions
    }

    /// `branches` reads each Worktree's branch now; a Worktree it cannot read keeps the branch the record remembers.
    /// The Sessions are in the order that the Sidebar shows them.
    public init(record: TopicRecord, snapshot: TmuxSnapshot, sessionPaths: [SessionPath], order: SessionOrder, branches: TopicBranches) {
        let windows = snapshot.windows.filter { $0.topicID == record.id }
        let firsts = windows.reduce(into: [TmuxWindow]()) { firsts, window in
            if !firsts.contains(where: { $0.sessionID == window.sessionID }) { firsts.append(window) }
        }
        let sessionIDs = TopicSessionOrder.ordered(firsts, record: record, order: order, key: TopicSessionKey.init).map(\.sessionID)
        let sessions = sessionIDs.compactMap { sessionID -> Session? in
            let members = windows.filter { $0.sessionID == sessionID }
            guard let first = members.first else { return nil }
            let remembered = record.session(of: first)
            let worktree = remembered?["worktree_path"]?.string.map(Folder.local).map { folder in
                return WorktreeEntry(path: folder.path, branch: branches[folder] ?? remembered?["branch"]?.string,
                                     base: remembered?[TopicWorktrees.baseKey]?.string)
            }
            return Session(id: sessionID, name: first.sessionName,
                           baseName: record.baseName(of: first), directory: first.sessionPath.isEmpty ? first.path : first.sessionPath,
                           worktree: worktree,
                           windows: members.map { window in
                               Window(id: window.id, index: window.index, name: window.name, active: window.isActive,
                                      panes: snapshot.panes.filter { $0.windowID == window.id }.map(PaneSummary.init))
                           })
        }
        self.init(id: record.id, label: TopicSummary(record: record).label, title: record.title, slug: record.slug,
                  createdAt: record.createdAt, snoozedUntil: record.snoozedUntil,
                  tags: record.tags.sorted(), sessions: sessions)
    }

    // Synthesized encoding leaves out a nil key. A reader gets every key, with null for a field the record does not have.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(label, forKey: .label)
        try values.encode(title, forKey: .title)
        try values.encode(slug, forKey: .slug)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(snoozedUntil, forKey: .snoozedUntil)
        try values.encode(tags, forKey: .tags)
        try values.encode(sessions, forKey: .sessions)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, title, slug, tags, sessions
        case createdAt = "created_at", snoozedUntil = "snoozed_until"
    }
}
