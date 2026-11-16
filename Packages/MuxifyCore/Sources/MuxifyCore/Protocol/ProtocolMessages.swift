import Foundation

// The messages of the Host Server protocol: the Mac app and `muxify server` speak it over one SSH channel, and a test
// over a pair of pipes. Each frame is one line of JSON (ADR 0085). The two sides agree on a protocol number and on
// capabilities, never on a build (ADR 0086). The JSON form of every message is a contract pinned by tests, and a
// fixtures folder per release keeps the older forms decodable.

/// The constants of the wire and of the version contract.
public enum HostProtocol {
    /// The server's first line. The client skips what a login shell prints before it.
    public static let magicLine = "MUXIFY-PROTOCOL"
    /// The longest frame, without its newline. A longer line is a protocol error that closes the channel.
    public static let maxFrameBytes = 16 * 1024 * 1024
    /// The most shell output that the client skips before the magic line.
    public static let maxPreambleBytes = 64 * 1024
    /// The largest chunk of a streamed response, before base64.
    public static let maxChunkBytes = 64 * 1024
    /// The protocols that this build speaks. Both ends started at 1; a bump needs an ADR.
    public static let supported: ClosedRange<Int> = 1...1
    /// What this build's Host Server adds to its protocol, declared in its `hello`. A client declares only what it
    /// uses: the Mac declares none, the phone all of them.
    public static let capabilities: [String] = HostCapability.allCases.map(\.rawValue)
    /// How long the client waits for the server's `hello`.
    public static let helloTimeout: TimeInterval = 10
    /// How long the server waits for any frame before it exits. Longer than the Mac's own master timeout
    /// (`ServerAliveInterval=15` × `ServerAliveCountMax=2`), so a server never exits while the Mac holds its master.
    public static let serverSilence: TimeInterval = 45
}

/// What a Host Server adds to protocol 1 (ADR 0086's change rule, ADR 0093). Each side sends a request case, a
/// subscription case or a key that a capability adds only when the other side's `hello` declared it, and the server
/// answers `unsupported` to one that a client sends without declaring it.
public enum HostCapability: String, CaseIterable, Sendable {
    /// An `environment` request may carry a Request id, which applies it one time however often it is sent.
    case request
    /// `subscribe { snapshot }`: the computed `environment show` view.
    case snapshot
    /// `subscribe { topic }`: one Topic's detail.
    case topicDetail = "topic-detail"
    /// `session_paths` with `query` or `topic`, and `visit_session_path`.
    case rankedSessionPaths = "ranked-session-paths"
    /// `browser_tabs`: a Window's stored Browser Tabs.
    case browserTabs = "browser-tabs"
}

/// The `kind` of a frame.
public enum ProtocolKind: String, Codable, Sendable {
    case hello, request, item, end, cancel
}

/// What each side says first. The server's carries the protocols it speaks; the client's names the one it picked.
public struct ProtocolHello: Codable, Equatable, Sendable {
    /// The server's highest protocol, or the protocol that the client picked.
    public var protocolVersion: Int
    /// The server's lowest protocol. The client's `hello` has none.
    public var minProtocol: Int?
    /// The `muxify --version` line, `muxify <short-sha> <commit-unix-time>`. Never compared: it goes to Diagnostics
    /// and to the reason a window gives when it falls back to Sessions only.
    public var build: String
    /// What this side adds to its protocol. The other side sends only what this side declared.
    public var capabilities: [String]
    /// The client's only: the nonce of its App Window's Client marker, `@muxify_client_<nonce>`, so the server's
    /// `server` event can name that Client.
    public var nonce: String?

    public init(protocolVersion: Int, minProtocol: Int? = nil, build: String, capabilities: [String] = [], nonce: String? = nil) {
        self.protocolVersion = protocolVersion
        self.minProtocol = minProtocol
        self.build = build
        self.capabilities = capabilities
        self.nonce = nonce
    }

    /// The protocols that a server's `hello` offers.
    public var offered: ClosedRange<Int>? {
        let lowest = minProtocol ?? protocolVersion
        return lowest <= protocolVersion ? lowest...protocolVersion : nil
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case minProtocol = "min_protocol"
        case build, capabilities, nonce
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
        minProtocol = try values.decodeIfPresent(Int.self, forKey: .minProtocol)
        build = try values.decodeIfPresent(String.self, forKey: .build) ?? ""
        capabilities = try values.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        nonce = try values.decodeIfPresent(String.self, forKey: .nonce)
    }
}

/// Why a request ended without `ok`.
public enum ProtocolErrorCode: String, Codable, Sendable, CaseIterable {
    /// The receiver does not know the request.
    case unsupported
    /// The receiver knows the request, but its values do not decode or make no sense.
    case invalid
    /// The request was cancelled before it changed anything.
    case cancelled
    /// The channel ended, or a subscriber fell behind.
    case unavailable
    /// A domain failure, with MuxifyCore's message.
    case failed

    /// A code that a newer peer added reads as `failed`, so its message still reaches the user.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
    }
}

/// The `error` of an `end`.
public struct ProtocolError: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: ProtocolErrorCode
    public var message: String
    /// The `TopicFailure` of a `failed` Environment request, so the Mac shows its phase and kind as the local path
    /// does. Optional, as every new key is.
    public var topicFailure: TopicFailure?

    public init(_ code: ProtocolErrorCode, _ message: String, topicFailure: TopicFailure? = nil) {
        self.code = code
        self.message = message
        self.topicFailure = topicFailure
    }

    private enum CodingKeys: String, CodingKey {
        case code, message
        case topicFailure = "topic_failure"
    }

    public var errorDescription: String? { message }

    /// Every waiting request fails with this when its channel ends. Nothing is replayed.
    public static let channelEnded = ProtocolError(.unavailable, "the connection to the Host Server ended")
}

/// The `ok` of a request that answers nothing: `{}`.
public struct ProtocolEmpty: Codable, Equatable, Sendable {
    public init() {}
}

/// One `item` of a streamed response: at most `HostProtocol.maxChunkBytes`, as base64.
public struct ProtocolChunk: Codable, Equatable, Sendable {
    public var data: Data

    public init(data: Data) { self.data = data }
}

/// A request that the Mac sends to the Host Server (ADR 0087): a typed MuxifyCore command or subscription, never
/// a script or a raw tmux command. Later releases add cases, each behind a capability. A case that this build does
/// not know is answered `unsupported`.
public enum HostRequest: Codable, Equatable, Sendable {
    /// Answers `ok`. The Mac sends one every 15 s when it has sent nothing else.
    case ping
    /// Answers `ok`, then the server exits.
    case shutdown
    /// A subscription: its items are events, the first holding the whole state.
    case subscribe(HostSubscription)
    /// An `EnvironmentRequest`, run by the Host's `EnvironmentService` and answered with its `EnvironmentResponse`.
    /// A failure ends `failed` with MuxifyCore's message.
    case environment(EnvironmentRequest)
    /// Unread on visit: clears the Unread marks of what the App Window shows. Answers `{}`.
    case markRead(MarkRead)
    /// One of the App Window's own tmux commands, answered with tmux's output as `ViewOutput`.
    case view(ViewCommand)
    /// The Sessions that Settle or Forget offers for a Topic, as the Host's `EnvironmentService` reads them now,
    /// answered as `TopicChoices`. A failure ends `failed` with its `TopicFailure`.
    case topicChoices(TopicChoicesRequest)
    /// New Worktree's start choices from a checkout on the Host (`git worktree list`, `for-each-ref`), answered as
    /// `WorktreeStarts`.
    case worktreeStarts(WorktreeStartsRequest)
    /// The Mac's Muxify Worktree rows that wait to move to this Host (ADR 0090). The server writes each as a record
    /// of the Host, as the import of the old record files does, and answers `AdoptedWorktrees`, one per row.
    case adoptWorktrees(AdoptWorktrees)
    /// The App Window of this channel now consumes `@muxify_open`: the server writes its own socket into
    /// `@muxify_browser_socket` (ADR 0091). Answers `{}`.
    case claimOpen
    /// The App Window of this channel no longer consumes `@muxify_open`: the server clears
    /// `@muxify_browser_socket` if it still names its own socket. Answers `{}`.
    case releaseOpen
    /// One of the Git View's reads, run by the Host's `GitReader`. A snapshot, log or remote answers as its value; a
    /// diff streams its text as chunks. A failure ends `failed` with the Git View's message.
    case git(GitRead)
    /// One of the Git View's writes that need no network, run by the Host's `GitWriter`, answered as `GitWritten`. A
    /// failure ends `failed` with git's words. It is never sent again: a channel that ends first leaves it unknown.
    case gitWrite(GitWrite)
    /// One of the Git View's commands that talk to a remote, run by the Host's `GitNetworkRunner`, answered as
    /// `GitWritten`. Each of git's and ssh's questions comes to the Mac as an `ask` of its operation while it runs. A
    /// cancelled question ends it `cancelled`; any other failure `failed` with git's words. It is never sent again.
    case gitNetwork(GitNetworkRequest)
    /// Session Path discovery on the Host, for New Session and Add Session, answered as `SessionPathsOutput`. With the
    /// `ranked-session-paths` capability it also answers Go to…'s rows (`RankedSessionPathsAnswer`) and a Topic's Add
    /// a Session rows (`TopicSessionPathsAnswer`).
    case sessionPaths(SessionPathsRequest)
    /// Records a visit to a folder, as `muxify session-paths visit` does. Answers `{}`. It needs `ranked-session-paths`.
    case visitSessionPath(VisitSessionPath)
    /// One chunk of an Attachment's upload, answered with the file's path on the Host as `UploadPath`. A failed chunk
    /// ends `failed` and the server deletes the partial file.
    case upload(UploadChunk)

    /// The capability that the client must have declared for the server to serve this request; nil for protocol 1's
    /// base. A new case does not compile until it chooses.
    public var capability: HostCapability? {
        switch self {
        case .environment(let request): return request.request == nil ? nil : .request
        case .sessionPaths(let request): return request.ask.capability
        case .visitSessionPath: return .rankedSessionPaths
        case .subscribe(let subscription): return subscription.capability
        case .ping, .shutdown, .markRead, .view, .topicChoices, .worktreeStarts, .adoptWorktrees, .claimOpen, .releaseOpen, .git, .gitWrite,
             .gitNetwork, .upload:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ping, shutdown, subscribe, environment
        case markRead = "mark_read"
        case view
        case topicChoices = "topic_choices"
        case worktreeStarts = "worktree_starts"
        case adoptWorktrees = "adopt_worktrees"
        case claimOpen = "claim_open"
        case releaseOpen = "release_open"
        case git
        case gitWrite = "git_write"
        case gitNetwork = "git_network"
        case sessionPaths = "session_paths"
        case visitSessionPath = "visit_session_path"
        case upload
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProtocolKey.self)
        guard let known = CodingKeys.allCases.first(where: { values.contains(ProtocolKey($0.rawValue)) }) else {
            let names = values.allKeys.map(\.stringValue).sorted().joined(separator: ", ")
            throw ProtocolError(.unsupported, "this muxify does not know the request \(names.isEmpty ? "{}" : names)")
        }
        let key = ProtocolKey(known.rawValue)
        switch known {
        case .ping: self = .ping
        case .shutdown: self = .shutdown
        case .subscribe: self = .subscribe(try values.decode(HostSubscription.self, forKey: key))
        case .environment: self = .environment(try values.decode(EnvironmentRequest.self, forKey: key))
        case .markRead: self = .markRead(try values.decode(MarkRead.self, forKey: key))
        case .view: self = .view(try values.decode(ViewCommand.self, forKey: key))
        case .topicChoices: self = .topicChoices(try values.decode(TopicChoicesRequest.self, forKey: key))
        case .worktreeStarts: self = .worktreeStarts(try values.decode(WorktreeStartsRequest.self, forKey: key))
        case .adoptWorktrees: self = .adoptWorktrees(try values.decode(AdoptWorktrees.self, forKey: key))
        case .claimOpen: self = .claimOpen
        case .releaseOpen: self = .releaseOpen
        case .git: self = .git(try values.decode(GitRead.self, forKey: key))
        case .gitWrite: self = .gitWrite(try values.decode(GitWrite.self, forKey: key))
        case .gitNetwork: self = .gitNetwork(try values.decode(GitNetworkRequest.self, forKey: key))
        case .sessionPaths: self = .sessionPaths(try values.decode(SessionPathsRequest.self, forKey: key))
        case .visitSessionPath: self = .visitSessionPath(try values.decode(VisitSessionPath.self, forKey: key))
        case .upload: self = .upload(try values.decode(UploadChunk.self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping: try values.encode(ProtocolEmpty(), forKey: .ping)
        case .shutdown: try values.encode(ProtocolEmpty(), forKey: .shutdown)
        case .subscribe(let subscription): try values.encode(subscription, forKey: .subscribe)
        case .environment(let request): try values.encode(request, forKey: .environment)
        case .markRead(let mark): try values.encode(mark, forKey: .markRead)
        case .view(let command): try values.encode(command, forKey: .view)
        case .topicChoices(let choices): try values.encode(choices, forKey: .topicChoices)
        case .worktreeStarts(let request): try values.encode(request, forKey: .worktreeStarts)
        case .adoptWorktrees(let adopt): try values.encode(adopt, forKey: .adoptWorktrees)
        case .claimOpen: try values.encode(ProtocolEmpty(), forKey: .claimOpen)
        case .releaseOpen: try values.encode(ProtocolEmpty(), forKey: .releaseOpen)
        case .git(let read): try values.encode(read, forKey: .git)
        case .gitWrite(let write): try values.encode(write, forKey: .gitWrite)
        case .gitNetwork(let network): try values.encode(network, forKey: .gitNetwork)
        case .sessionPaths(let request): try values.encode(request, forKey: .sessionPaths)
        case .visitSessionPath(let visit): try values.encode(visit, forKey: .visitSessionPath)
        case .upload(let chunk): try values.encode(chunk, forKey: .upload)
        }
    }
}

/// A request that the Host Server sends to its Mac (ADR 0091): what a program on the Host sent the server's own
/// socket. Protocol 1's base, so it needs no capability. A Mac with no handler for it ends it `unavailable`.
public enum MacRequest: Codable, Equatable, Sendable {
    /// A Browser command, served by the Browsers of the App Window whose channel carried it. Its `end` is the
    /// `BrowserAgentReply`, except that a `png` comes as `ProtocolChunk` items of at most
    /// `HostProtocol.maxChunkBytes`, and its `end` is `{"png": ""}`.
    case browser(BrowserAgentRequest)
    /// A view verb: the App Window shows the target and comes to the front. Answers `{}`.
    case select(SelectRequest)
    /// git's or ssh's question from the askpass helper of a `git_network` request's operation, asked in the Git View
    /// that started it. Answers `AskAnswer`; a cancelled question ends `cancelled`, and an `ask` that no operation waits
    /// for ends `unavailable`.
    case ask(AskRequest)

    private enum CodingKeys: String, CodingKey, CaseIterable { case browser, select, ask }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProtocolKey.self)
        guard let known = CodingKeys.allCases.first(where: { values.contains(ProtocolKey($0.rawValue)) }) else {
            let names = values.allKeys.map(\.stringValue).sorted().joined(separator: ", ")
            throw ProtocolError(.unsupported, "this Muxify does not know the request \(names.isEmpty ? "{}" : names)")
        }
        let key = ProtocolKey(known.rawValue)
        switch known {
        case .browser: self = .browser(try values.decode(BrowserAgentRequest.self, forKey: key))
        case .select: self = .select(try values.decode(SelectRequest.self, forKey: key))
        case .ask: self = .ask(try values.decode(AskRequest.self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .browser(let request): try values.encode(request, forKey: .browser)
        case .select(let request): try values.encode(request, forKey: .select)
        case .ask(let request): try values.encode(request, forKey: .ask)
        }
    }
}

/// What a `subscribe` request subscribes to. Later releases add cases.
public enum HostSubscription: Codable, Equatable, Sendable {
    /// The Host's Sessions, Topic records, Open Places and server, as `EnvironmentItem`s keyed `session <id>`,
    /// `topic <id>`, `open_places` and `server`.
    case environment
    /// The Host's Config, as `HostConfig` items keyed `config`: the whole Config each time, first at once, then
    /// after each change in its folders that changes it. One without `text` says the Host has no Config.
    case config
    /// A folder's repository, as `RepositoryEvent`s keyed `repository`: the first is the whole state, each later one a
    /// change of HEAD, the index or the working tree.
    case repository(RepositorySubscription)
    /// One Topic's detail, as `TopicDetailItem`s keyed `topic <id>`: the first is the current state, each later one
    /// the detail after a change of the Topic's record or of its Sessions, Windows or Panes. Needs `topic-detail`.
    case topic(TopicSubscription)

    /// The capability that this subscription needs; nil for protocol 1's base.
    public var capability: HostCapability? {
        switch self {
        case .environment, .config, .repository: return nil
        case .topic: return .topicDetail
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case environment, config, repository, topic }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: ProtocolKey.self)
        guard let known = CodingKeys.allCases.first(where: { values.contains(ProtocolKey($0.rawValue)) }) else {
            let names = values.allKeys.map(\.stringValue).sorted().joined(separator: ", ")
            throw ProtocolError(.unsupported, "this muxify does not know the subscription \(names.isEmpty ? "{}" : names)")
        }
        switch known {
        case .environment: self = .environment
        case .config: self = .config
        case .repository: self = .repository(try values.decode(RepositorySubscription.self, forKey: ProtocolKey(known.rawValue)))
        case .topic: self = .topic(try values.decode(TopicSubscription.self, forKey: ProtocolKey(known.rawValue)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .environment: try values.encode(ProtocolEmpty(), forKey: .environment)
        case .config: try values.encode(ProtocolEmpty(), forKey: .config)
        case .repository(let repository): try values.encode(repository, forKey: .repository)
        case .topic(let topic): try values.encode(topic, forKey: .topic)
        }
    }
}

/// What the `topic` subscription subscribes to: one Topic, by its id.
public struct TopicSubscription: Codable, Equatable, Sendable {
    public var id: String

    public init(id: String) { self.id = id }
}

/// An item of the `topic` subscription: the Topic's detail exactly as `environment { show }` answers it, which is the
/// JSON of `muxify topic show --json`, or nil, sent as `null`, when the Topic is gone: forgotten, Settled or never there.
public typealias TopicDetailItem = EnvironmentResponse?

/// `mark_read`: Unread on visit. The server clears the Topic Unread of `topics` and the Agent Unread of `panes`,
/// then reads the server again, which writes the Topics' remembered Sessions and sends the events of all of it.
public struct MarkRead: Codable, Equatable, Sendable {
    /// The ids of the Topics whose Unread the visit clears.
    public var topics: [String]
    /// The ids of the Agent Panes whose Unread the visit clears.
    public var panes: [String]

    public init(topics: [String] = [], panes: [String] = []) {
        self.topics = topics
        self.panes = panes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        topics = try values.decodeIfPresent([String].self, forKey: .topics) ?? []
        panes = try values.decodeIfPresent([String].self, forKey: .panes) ?? []
    }
}

/// `topic_choices`: which Action's choices, for which Topic.
public struct TopicChoicesRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case settle, forget
    }

    public var action: Action
    public var target: EnvironmentTarget

    public init(_ action: Action, target: EnvironmentTarget) {
        self.action = action
        self.target = target
    }
}

/// The answer to `topic_choices`: the Topic's Sessions, each with what the Action does to it by default.
public struct TopicChoices: Codable, Equatable, Sendable {
    public var sessions: [TopicSettleSession]

    public init(sessions: [TopicSettleSession]) { self.sessions = sessions }
}

/// `worktree_starts`: the checkout that a new Worktree starts from.
public struct WorktreeStartsRequest: Codable, Equatable, Sendable {
    public var from: String

    public init(from: String) { self.from = from }
}

/// The answer to `worktree_starts`: each local branch, newest commit first, with the Worktree that has it checked out.
public struct WorktreeStarts: Codable, Equatable, Sendable {
    public var starts: [WorktreeStartChoice]

    public init(starts: [WorktreeStartChoice]) { self.starts = starts }
}

/// `adopt_worktrees`: the Mac's rows waiting to move to this Host, as records.
public struct AdoptWorktrees: Codable, Equatable, Sendable {
    public var rows: [MuxifyWorktreeRecord]

    public init(rows: [MuxifyWorktreeRecord]) { self.rows = rows }
}

/// The answer to `adopt_worktrees`: one entry for each row, in order.
public struct AdoptedWorktrees: Codable, Equatable, Sendable {
    public var rows: [AdoptedWorktree]

    public init(rows: [AdoptedWorktree]) { self.rows = rows }
}

/// What the Host did with one row: `taken`, so the Mac deletes its row, or `skipped` with the reason, so the Mac
/// keeps it and sends it again on the next connect.
public struct AdoptedWorktree: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        case taken, skipped
    }

    public var id: String
    public var result: Result
    public var reason: String?

    public init(id: String) {
        self.id = id
        result = .taken
        reason = nil
    }

    public init(id: String, skipped reason: String) {
        self.id = id
        result = .skipped
        self.reason = reason
    }
}

/// `session_paths`. With `roots` alone, the roots of the Mac's Config's `sessions.paths`, each with its depth: the
/// Host runs `SessionPathDiscovery` with them, so `~` is the Host's home, and answers `SessionPathsOutput`. With the
/// `ranked-session-paths` capability, a `topic` asks for that Topic's Add a Session rows (`TopicSessionPathsAnswer`),
/// and a `query`, or no key at all, for the Host's rows of Go to… (`RankedSessionPathsAnswer`).
public struct SessionPathsRequest: Codable, Equatable, Sendable {
    public struct Root: Codable, Equatable, Sendable {
        /// Absolute, or starting with `~`. It may be a glob.
        public var path: String
        /// 0 is each matched folder itself.
        public var depth: Int

        public init(path: String, depth: Int) {
            self.path = path
            self.depth = depth
        }
    }

    /// What the request asks the Host for.
    public enum Ask: Equatable, Sendable {
        /// The discovery's output for these roots. How a SessionPath is named stays with the Mac, which reads it.
        case discovery([SessionPathRoot])
        /// The Host's Session Paths and Worktrees with no Topic, ranked for the text as Go to… ranks them, the last
        /// visited first for "": the rows of `muxify session-paths --query <text> --json`.
        case ranked(query: String)
        /// The Add a Session rows of the Topic with this id, slug or title: those of
        /// `muxify topic session-paths --topic <topic> --json`.
        case topic(String)

        /// Nil for the discovery, protocol 1's base.
        public var capability: HostCapability? {
            if case .discovery = self { return nil }
            return .rankedSessionPaths
        }
    }

    public var roots: [Root]?
    public var query: String?
    public var topic: String?

    public init(roots: [SessionPathRoot]) {
        self.roots = roots.map { Root(path: $0.path, depth: $0.depth) }
    }

    public init(_ ask: Ask) {
        switch ask {
        case .discovery(let roots): self.roots = roots.map { Root(path: $0.path, depth: $0.depth) }
        case .ranked(let query): self.query = query
        case .topic(let topic): self.topic = topic
        }
    }

    /// A `topic` before a `query`, and a `query` before `roots`; with no key, the ranking for "".
    public var ask: Ask {
        if let topic { return .topic(topic) }
        if let query { return .ranked(query: query) }
        if let roots { return .discovery(roots.map { SessionPathRoot(path: $0.path, depth: $0.depth) }) }
        return .ranked(query: "")
    }
}

/// `visit_session_path`: a Session opened at `folder` on the Host now. The visit goes to the Session Path or Worktree
/// that holds the folder, else to the folder itself, as `muxify session-paths visit` records it.
public struct VisitSessionPath: Codable, Equatable, Sendable {
    public var folder: String

    public init(folder: String) { self.folder = folder }
}

/// The answer to `session_paths`: `SessionPathDiscovery`'s output, which the Mac reads and saves as it reads a local
/// run's. Null when discovery found nothing to run or failed.
public struct SessionPathsOutput: Codable, Equatable, Sendable {
    public var output: String?

    public init(output: String?) { self.output = output }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(output, forKey: .output)
    }
}

/// `upload`: one chunk of an Attachment. An upload is a pipelined run of these, of at most
/// `HostProtocol.maxChunkBytes` each, in order of `offset`; the one at offset 0 starts it, and the one with `last`
/// publishes the whole file under `name`.
public struct UploadChunk: Codable, Equatable, Sendable {
    /// The file's name on the Host: one path component.
    public var name: String
    /// Where `data` starts in the file.
    public var offset: Int
    public var data: Data
    public var last: Bool

    public init(name: String, offset: Int, data: Data, last: Bool) {
        self.name = name
        self.offset = offset
        self.data = data
        self.last = last
    }
}

/// The answer to each `upload` chunk: the path that the file has on the Host once its last chunk is written.
public struct UploadPath: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) { self.path = path }
}

/// The answer to a `view` request: what tmux printed.
public struct ViewOutput: Codable, Equatable, Sendable {
    public var output: String

    public init(output: String) { self.output = output }
}

/// A key named at run time, such as the payload key of a frame, which is its `kind`.
struct ProtocolKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
