import Foundation

/// A Session Path or Worktree row in the JSON of `muxify session-paths --json` and `muxify topic session-paths --json`,
/// and of the Host Server's `session_paths` answers to a `query` or a `topic`.
public struct SessionPathAnswer: Codable, Equatable, Sendable {
    public struct Topic: Codable, Hashable, Sendable {
        public let id: String
        public let label: String
        public init(_ summary: TopicSummary) { id = summary.id; label = summary.label }
    }

    public struct Checkout: Codable, Hashable, Sendable {
        public let path: String
        @EncodesNull public var branch: String?
    }

    public let kind: String
    public let name: String
    public let label: String
    public let directory: String
    public let worktree: Checkout?
    /// Only `topic session-paths` has it: whether a Session of that Topic uses this exact folder.
    public let inThisTopic: Bool?
    public let alsoIn: [Topic]
    /// ISO 8601, in UTC.
    public let lastVisit: String?

    public init(_ row: SessionPathRow, inThisTopic: Bool? = nil, lastVisit: Date?) {
        let choice = row.choice
        kind = choice.isWorktree ? "worktree" : "session_path"
        name = choice.name
        label = choice.displayName
        directory = choice.directory.path
        worktree = choice.worktree.map { Checkout(path: $0.folder.path, branch: $0.branch) }
        self.inThisTopic = inThisTopic
        alsoIn = row.alsoIn.map(Topic.init)
        self.lastVisit = lastVisit.map(Self.timestamp)
    }

    public static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private enum CodingKeys: String, CodingKey {
        case kind, name, label, directory, worktree
        case inThisTopic = "in_this_topic"
        case alsoIn = "also_in"
        case lastVisit = "last_visit"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        label = try container.decode(String.self, forKey: .label)
        directory = try container.decode(String.self, forKey: .directory)
        worktree = try container.decodeIfPresent(Checkout.self, forKey: .worktree)
        inThisTopic = try container.decodeIfPresent(Bool.self, forKey: .inThisTopic)
        alsoIn = try container.decode([Topic].self, forKey: .alsoIn)
        lastVisit = try container.decodeIfPresent(String.self, forKey: .lastVisit)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(label, forKey: .label)
        try container.encode(directory, forKey: .directory)
        try container.encode(worktree, forKey: .worktree)
        try container.encodeIfPresent(inThisTopic, forKey: .inThisTopic)
        try container.encode(alsoIn, forKey: .alsoIn)
        try container.encode(lastVisit, forKey: .lastVisit)
    }
}

/// What `muxify session-paths --json` prints, and the Host Server's answer to `session_paths` with a `query` or
/// with nothing: this machine's Session Paths and Worktrees in the order of Go to….
public struct RankedSessionPathsAnswer: Codable, Equatable, Sendable {
    public let rows: [SessionPathAnswer]

    public init(_ ranked: [RankedSessionPath]) {
        rows = ranked.map { SessionPathAnswer($0.row, lastVisit: $0.lastVisit) }
    }
}

/// What `muxify topic session-paths --json` prints, and the Host Server's answer to `session_paths` with a `topic`:
/// the Add a Session rows of the Topic, and the other running Sessions.
public struct TopicSessionPathsAnswer: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let directory: String
        @EncodesNull public var topic: SessionPathAnswer.Topic?
    }

    public let topic: SessionPathAnswer.Topic
    public let rows: [SessionPathAnswer]
    public let sessions: [Session]

    /// `visits` are this machine's: each row's `last_visit` is the visit to its folder.
    public init(_ choices: TopicSessionPathChoices, visits: [VisitKey: Date]) {
        topic = SessionPathAnswer.Topic(choices.topic)
        rows = choices.rows.map {
            SessionPathAnswer($0.row, inThisTopic: $0.inThisTopic, lastVisit: visits[.directory($0.row.choice.directory.real)])
        }
        sessions = choices.sessions.map {
            Session(id: $0.id, name: $0.name, directory: $0.directory, topic: $0.topic.map(SessionPathAnswer.Topic.init))
        }
    }
}
