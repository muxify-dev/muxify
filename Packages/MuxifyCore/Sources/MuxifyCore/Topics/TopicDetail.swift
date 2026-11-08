import Foundation

/// One open Topic as `topic show` reports it: its record, and its live Sessions with their Windows and Panes.
public struct TopicDetail: Codable, Hashable, Sendable {
    public struct WorktreeEntry: Codable, Hashable, Sendable {
        public var path: String
        /// Nil when HEAD is detached or the branch is unknown.
        @EncodesNull public var branch: String?
        /// The full id of the commit that the Topic started this Worktree at. Nil when the Topic did not make the
        /// Worktree, or made it before records stored `base`.
        @EncodesNull public var base: String?

        public init(path: String, branch: String?, base: String? = nil) {
            self.path = path
            self.branch = branch
            self.base = base
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
        @EncodesNull public var worktree: WorktreeEntry?
        public var windows: [Window]

        public init(id: String, name: String, baseName: String, directory: String, worktree: WorktreeEntry?, windows: [Window]) {
            self.id = id
            self.name = name
            self.baseName = baseName
            self.directory = directory
            self.worktree = worktree
            self.windows = windows
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, directory, worktree, windows
            case baseName = "base_name"
        }
    }

    public var id: String
    /// The label `topic list` prints.
    public var label: String
    @EncodesNull public var title: String?
    @EncodesNull public var slug: String?
    @EncodesNull public var createdAt: String?
    /// The Topic Note; nil for none.
    @EncodesNull public var note: String?
    public var state: TopicState
    /// As the Topic's card shows them: in Config order, then those that the Config no longer defines, A→Z. With Tags
    /// off, none.
    public var tags: [Tag]
    /// The Sessions whose `@muxify_topic` names this Topic, in tmux order. Empty for a Dormant Topic.
    public var sessions: [Session]

    public init(id: String, label: String, title: String?, slug: String?, createdAt: String?, note: String? = nil,
                state: TopicState, tags: [Tag] = [], sessions: [Session]) {
        self.id = id
        self.label = label
        self.title = title
        self.slug = slug
        self.createdAt = createdAt
        self.note = note
        self.state = state
        self.tags = tags
        self.sessions = sessions
    }

    /// `branches` reads each Worktree's branch now; a Worktree it cannot read keeps the branch the record remembers.
    /// The Sessions are in the order that the Sidebar shows them.
    public init(record: TopicRecord, label: String, snapshot: TmuxSnapshot, sessionPaths: [SessionPath], topics: Config.Topics,
                branches: TopicBranches) {
        let windows = snapshot.windows.filter { $0.topicID == record.id }
        let sessionIDs = TopicSessionOrder.firstWindows(windows, record: record, order: topics.sessionOrder).map(\.sessionID)
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
        self.init(id: record.id, label: label, title: record.title, slug: record.slug, createdAt: record.createdAt, note: record.note,
                  state: TopicState(record: record, hasLiveSession: !sessions.isEmpty), tags: topics.tags?.shown(record.tags).map(\.tag) ?? [],
                  sessions: sessions)
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, title, slug, note, state, tags, sessions
        case createdAt = "created_at"
    }
}
