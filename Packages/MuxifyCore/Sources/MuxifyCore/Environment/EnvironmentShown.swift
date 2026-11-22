import Foundation

/// What `muxify environment show --json` prints, and each item of the Host Server's `snapshot` subscription (ADR
/// 0093): the keys of the `EnvironmentSnapshot`, with the Config's `sidebar` beside them. The CLI adds its
/// `capabilities`; the subscription carries none, because the phone reads them from the server's `hello`.
public struct EnvironmentShown: Codable, Equatable, Sendable {
    public var snapshot: EnvironmentSnapshot
    public var sidebar: Sidebar
    /// What the CLI that printed it can do; nil in a `snapshot` item.
    public var capabilities: [String]?

    /// Which Sidebar modes the Config shows.
    public struct Sidebar: Codable, Equatable, Sendable {
        /// Whether the Config shows the Board view, `sidebar.board`. The key stays `topics` for the readers it has.
        public var topics = true
        public var sessions = true

        public init() {}

        public init(_ config: Config.Sidebar) {
            topics = config.board
            sessions = config.sessions
        }
    }

    public init(snapshot: EnvironmentSnapshot, sidebar: Sidebar, capabilities: [String]? = nil) {
        self.snapshot = snapshot
        self.sidebar = sidebar
        self.capabilities = capabilities
    }

    /// The `snapshot` item of the Environment that `contents` and `tmux` show, under `config`.
    public init(contents: TopicContents, tmux: TmuxSnapshot, config: Config) {
        self.init(snapshot: EnvironmentSnapshot(contents: contents, tmux: tmux, topics: config.topics, notifications: config.notifications),
                  sidebar: Sidebar(config.sidebar))
    }

    private enum CodingKeys: String, CodingKey { case capabilities, sidebar }

    public init(from decoder: Decoder) throws {
        snapshot = try EnvironmentSnapshot(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sidebar = try values.decodeIfPresent(Sidebar.self, forKey: .sidebar) ?? Sidebar()
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities)
    }

    public func encode(to encoder: Encoder) throws {
        try snapshot.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sidebar, forKey: .sidebar)
        try values.encodeIfPresent(capabilities, forKey: .capabilities)
    }
}
