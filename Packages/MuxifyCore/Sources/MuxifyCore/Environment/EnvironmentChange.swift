import Foundation

/// One event of the `environment` subscription. Each has a key, and an event replaces the last one of its key whole,
/// so a subscriber that missed some needs only the last of each key.
public enum EnvironmentChange: Equatable {
    /// That Session's Windows and Panes, or nil when it is gone.
    case session(String, EnvironmentSession?)
    /// One Topic record, or nil when it is gone.
    case topic(String, TopicRecord?)
    /// The Open Places of the Topics list.
    case openPlaces([OpenPlace])
    /// The Locks of the Topics list, live or Dormant.
    case locks([SessionLock])
    /// The server as a whole: its Clients, the last Window, whether it runs, its socket and home.
    case server(EnvironmentServer)

    /// What the event replaces: `session <id>`, `topic <id>`, `open_places`, `guest_sessions` or `server`.
    public var key: String {
        switch self {
        case .session(let id, _): "session \(id)"
        case .topic(let id, _): "topic \(id)"
        case .openPlaces: "open_places"
        case .locks: "guest_sessions"
        case .server: "server"
        }
    }
}

/// One Session as a snapshot read it: its Windows, its Panes and the command lines of its Panes' programs.
public struct EnvironmentSession: Equatable {
    public var windows: [TmuxWindow]
    public var panes: [TmuxPane]
    public var commandLines: PaneCommandLines

    public init(windows: [TmuxWindow], panes: [TmuxPane], commandLines: PaneCommandLines = PaneCommandLines()) {
        self.windows = windows
        self.panes = panes
        self.commandLines = commandLines
    }
}

/// What a snapshot read of the server as a whole, beside its Sessions.
public struct EnvironmentServer: Equatable {
    public var clients: [TmuxClient]
    public var lastWindowID: String?
    public var isRunning: Bool
    /// `#{pid}:#{start_time}`, which changes when another server takes the socket. A subscriber stamps it as the
    /// `sourceID` of what it shows.
    public var serverID: String?
    public var socketPath: String?
    public var browserSocket: String?
    public var home: String
    /// The name of the machine that the server runs on.
    public var hostName: String
    /// The subscriber's own Client, which its Client marker names; nil until the attach writes the marker, or when
    /// the publisher reads no marker.
    public var ownClient: ViewCommandExecutor.Client?

    public init(clients: [TmuxClient] = [], lastWindowID: String? = nil, isRunning: Bool, serverID: String? = nil,
                socketPath: String? = nil, browserSocket: String? = nil, home: String, hostName: String = Tmux.hostName,
                ownClient: ViewCommandExecutor.Client? = nil) {
        self.clients = clients
        self.lastWindowID = lastWindowID
        self.isRunning = isRunning
        self.serverID = serverID
        self.socketPath = socketPath
        self.browserSocket = browserSocket
        self.home = home
        self.hostName = hostName
        self.ownClient = ownClient
    }
}

/// The state that a run of `environment` events left: the publisher's last sent state, or a subscriber's view.
public struct EnvironmentState: Equatable {
    public private(set) var sessions: [String: EnvironmentSession] = [:]
    public private(set) var topics: [String: TopicRecord] = [:]
    public private(set) var openPlaces: [OpenPlace] = []
    public private(set) var locks: [SessionLock] = []
    public private(set) var server: EnvironmentServer?

    public init() {}

    /// The Topic records in id order, as the state database lists them, the Open Places and the Locks.
    public var topicContents: TopicContents {
        TopicContents(records: topics.values.sorted { $0.id < $1.id }, openPlaces: openPlaces, locks: locks)
    }

    /// The server as these events show it, in tmux's order: Sessions by name, each with its Windows and Panes in
    /// the order they came. Nil before a `server` event.
    public var snapshot: TmuxSnapshot? {
        guard let server else { return nil }
        let ordered = sessions.values.sorted {
            ($0.windows.first?.sessionName ?? "", $0.windows.first?.sessionID ?? "") < ($1.windows.first?.sessionName ?? "", $1.windows.first?.sessionID ?? "")
        }
        var snapshot = TmuxSnapshot(windows: ordered.flatMap(\.windows), clients: server.clients, panes: ordered.flatMap(\.panes),
                                    lastWindowID: server.lastWindowID, serverRunning: server.isRunning, serverID: server.serverID,
                                    ownClientTTY: server.ownClient?.tty, homeDirectory: server.home)
        snapshot.socketPath = server.socketPath
        snapshot.browserSocket = server.browserSocket
        snapshot.commandLines = ordered.reduce(PaneCommandLines()) { $0.merging($1.commandLines) }
        return snapshot
    }

    /// The events of every key, as the first item of a subscription carries them.
    public var all: [EnvironmentChange] {
        sessions.sorted { $0.key < $1.key }.map { .session($0.key, $0.value) }
            + topics.values.sorted { $0.id < $1.id }.map { .topic($0.id, $0) }
            + [.openPlaces(openPlaces), .locks(locks)]
            + (server.map { [.server($0)] } ?? [])
    }

    public mutating func apply(_ changes: [EnvironmentChange]) {
        for change in changes {
            switch change {
            case .session(let id, let session): sessions[id] = session
            case .topic(let id, let record): topics[id] = record
            case .openPlaces(let places): openPlaces = places
            case .locks(let locks): self.locks = locks
            case .server(let server): self.server = server
            }
        }
    }

    /// The events that bring this state to `snapshot`: a Session that differs, one that is gone, and the server when
    /// it differs. With `all`, every Session and the server.
    public func changes(to snapshot: TmuxSnapshot, home: String, hostName: String = Tmux.hostName,
                        ownClient: ViewCommandExecutor.Client? = nil, all: Bool = false) -> [EnvironmentChange] {
        let next = Self.sessions(in: snapshot)
        let server = EnvironmentServer(clients: snapshot.clients, lastWindowID: snapshot.lastWindowID,
                                       isRunning: snapshot.serverRunning, serverID: snapshot.serverID,
                                       socketPath: snapshot.socketPath, browserSocket: snapshot.browserSocket, home: home,
                                       hostName: hostName, ownClient: ownClient)
        var changes: [EnvironmentChange] = []
        for (id, session) in next.sorted(by: { $0.key < $1.key }) where all || sessions[id] != session {
            changes.append(.session(id, session))
        }
        for id in sessions.keys.sorted() where next[id] == nil {
            changes.append(.session(id, nil))
        }
        if all || self.server != server { changes.append(.server(server)) }
        return changes
    }

    /// The events that bring this state to `contents`: a record that differs, one that is gone, and the Open Places
    /// and the Locks when they differ. With `all`, every record, the Open Places and the Locks.
    public func changes(to contents: TopicContents, all: Bool = false) -> [EnvironmentChange] {
        var changes: [EnvironmentChange] = []
        let ids = Set(contents.records.map(\.id))
        for record in contents.records where all || topics[record.id] != record {
            changes.append(.topic(record.id, record))
        }
        for id in topics.keys.sorted() where !ids.contains(id) {
            changes.append(.topic(id, nil))
        }
        if all || openPlaces != contents.openPlaces { changes.append(.openPlaces(contents.openPlaces)) }
        if all || locks != contents.locks { changes.append(.locks(contents.locks)) }
        return changes
    }

    /// The snapshot's Sessions by id. A Pane belongs to the Session of the first Window line that names its Window.
    static func sessions(in snapshot: TmuxSnapshot) -> [String: EnvironmentSession] {
        var sessions: [String: EnvironmentSession] = [:]
        var sessionOfWindow: [String: String] = [:]
        for window in snapshot.windows {
            sessions[window.sessionID, default: EnvironmentSession(windows: [], panes: [])].windows.append(window)
            if sessionOfWindow[window.id] == nil { sessionOfWindow[window.id] = window.sessionID }
        }
        for pane in snapshot.panes {
            guard let id = sessionOfWindow[pane.windowID] else { continue }
            sessions[id]?.panes.append(pane)
        }
        for (id, session) in sessions {
            sessions[id]?.commandLines = snapshot.commandLines.only(Set(session.panes.map(\.id)))
        }
        return sessions
    }
}
