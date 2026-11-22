import Foundation

// The JSON form of the `environment` subscription's events (ADR 0087). Each item of the subscription is an
// `EnvironmentItem`: the first holds every key, each later one a single change, keyed so that a newer one replaces an
// unsent one. The Host Server sends what tmux and the records hold; the Mac stamps what is its own, such as
// `isRemote` and `sourceID`, from the `server` event. Every key but an id decodes when it is missing, so a newer
// server may add keys.

/// One item of the `environment` subscription.
public struct EnvironmentItem: Codable, Equatable {
    public var changes: [EnvironmentChange]

    public init(changes: [EnvironmentChange]) { self.changes = changes }
}

extension EnvironmentChange: Codable {
    private enum CodingKeys: String, CodingKey {
        case session, topic, value
        case openPlaces = "open_places"
        case boardSessions = "guest_sessions"
        case server
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try values.decodeIfPresent(String.self, forKey: .session) {
            self = .session(id, try values.decodeIfPresent(EnvironmentSession.self, forKey: .value))
        } else if let id = try values.decodeIfPresent(String.self, forKey: .topic) {
            self = .topic(id, try values.decodeIfPresent(TopicRecord.self, forKey: .value))
        } else if let places = try values.decodeIfPresent([OpenPlace].self, forKey: .openPlaces) {
            self = .openPlaces(places)
        } else if let boardSessions = try values.decodeIfPresent([BoardSession].self, forKey: .boardSessions) {
            self = .boardSessions(boardSessions)
        } else if let server = try values.decodeIfPresent(EnvironmentServer.self, forKey: .server) {
            self = .server(server)
        } else {
            throw ProtocolError(.unsupported, "this muxify does not know the event \(values.allKeys.map(\.stringValue).sorted())")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let id, let session):
            try values.encode(id, forKey: .session)
            try values.encode(session, forKey: .value)
        case .topic(let id, let record):
            try values.encode(id, forKey: .topic)
            try values.encode(record, forKey: .value)
        case .openPlaces(let places): try values.encode(places, forKey: .openPlaces)
        case .boardSessions(let boardSessions): try values.encode(boardSessions, forKey: .boardSessions)
        case .server(let server): try values.encode(server, forKey: .server)
        }
    }
}

extension EnvironmentSession: Codable {
    private enum CodingKeys: String, CodingKey {
        case windows, panes
        case commandLines = "command_lines"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(windows: try values.decodeIfPresent([TmuxWindow].self, forKey: .windows) ?? [],
                  panes: try values.decodeIfPresent([TmuxPane].self, forKey: .panes) ?? [],
                  commandLines: try values.decodeIfPresent(PaneCommandLines.self, forKey: .commandLines) ?? PaneCommandLines())
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let lockOrder {
            try values.encode(windows.map { LockedWindow(window: $0, lockOrder: lockOrder) }, forKey: .windows)
        } else {
            try values.encode(windows, forKey: .windows)
        }
        try values.encode(panes, forKey: .panes)
        try values.encode(commandLines, forKey: .commandLines)
    }
}

/// A Window of a live Guest Session as an older Mac reads it: its keys, and `lock_order`, its Lock's order. The second
/// keyed container of one encoder writes into the same object as the first.
private struct LockedWindow: Encodable {
    let window: TmuxWindow
    let lockOrder: Double

    private enum CodingKeys: String, CodingKey { case lockOrder = "lock_order" }

    func encode(to encoder: Encoder) throws {
        try window.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(lockOrder, forKey: .lockOrder)
    }
}

extension EnvironmentServer: Codable {
    private enum CodingKeys: String, CodingKey {
        case clients
        case lastWindowID = "last_window_id"
        case isRunning = "running"
        case serverID = "server_id"
        case socketPath = "socket_path"
        case browserSocket = "browser_socket"
        case home
        case hostName = "host_name"
        case ownClient = "own_client"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(clients: try values.decodeIfPresent([TmuxClient].self, forKey: .clients) ?? [],
                  lastWindowID: try values.decodeIfPresent(String.self, forKey: .lastWindowID),
                  isRunning: try values.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false,
                  serverID: try values.decodeIfPresent(String.self, forKey: .serverID),
                  socketPath: try values.decodeIfPresent(String.self, forKey: .socketPath),
                  browserSocket: try values.decodeIfPresent(String.self, forKey: .browserSocket),
                  home: try values.decodeIfPresent(String.self, forKey: .home) ?? "",
                  hostName: try values.decodeIfPresent(String.self, forKey: .hostName) ?? "",
                  ownClient: try values.decodeIfPresent(ViewCommandExecutor.Client.self, forKey: .ownClient))
    }

    /// Every key is always there; one with no value is `null`.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(clients, forKey: .clients)
        try values.encode(lastWindowID, forKey: .lastWindowID)
        try values.encode(isRunning, forKey: .isRunning)
        try values.encode(serverID, forKey: .serverID)
        try values.encode(socketPath, forKey: .socketPath)
        try values.encode(browserSocket, forKey: .browserSocket)
        try values.encode(home, forKey: .home)
        try values.encode(hostName, forKey: .hostName)
        try values.encode(ownClient, forKey: .ownClient)
    }
}

extension ViewCommandExecutor.Client: Codable {
    private enum CodingKeys: String, CodingKey { case tty, pid }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tty: try values.decode(String.self, forKey: .tty), pid: try values.decode(Int.self, forKey: .pid))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tty, forKey: .tty)
        try values.encode(pid, forKey: .pid)
    }
}

extension TmuxClient: Codable {
    private enum CodingKeys: String, CodingKey {
        case tty
        case sessionID = "session_id"
        case windowID = "window_id"
        case pid
        case isControl = "control"
        case ignoresSize = "ignore_size"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tty: try values.decodeIfPresent(String.self, forKey: .tty) ?? "",
                  sessionID: try values.decodeIfPresent(String.self, forKey: .sessionID) ?? "",
                  windowID: try values.decodeIfPresent(String.self, forKey: .windowID) ?? "",
                  pid: try values.decodeIfPresent(Int.self, forKey: .pid) ?? 0,
                  isControl: try values.decodeIfPresent(Bool.self, forKey: .isControl) ?? false,
                  ignoresSize: try values.decodeIfPresent(Bool.self, forKey: .ignoresSize) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(tty, forKey: .tty)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(windowID, forKey: .windowID)
        try values.encode(pid, forKey: .pid)
        try values.encode(isControl, forKey: .isControl)
        if ignoresSize { try values.encode(ignoresSize, forKey: .ignoresSize) }
    }
}

extension TmuxPane: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case windowID = "window_id"
        case index
        case isActive = "active"
        case title, path, command, agent
        case agentStatus = "agent_status"
        case unread
        case agentConversation = "agent_conversation"
        case tty
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  windowID: try values.decodeIfPresent(String.self, forKey: .windowID) ?? "",
                  index: try values.decodeIfPresent(Int.self, forKey: .index) ?? 0,
                  isActive: try values.decodeIfPresent(Bool.self, forKey: .isActive) ?? false,
                  title: try values.decodeIfPresent(String.self, forKey: .title) ?? "",
                  path: try values.decodeIfPresent(String.self, forKey: .path) ?? "",
                  command: try values.decodeIfPresent(String.self, forKey: .command) ?? "",
                  agent: try values.decodeIfPresent(String.self, forKey: .agent) ?? "",
                  agentStatus: try values.decodeIfPresent(String.self, forKey: .agentStatus) ?? "",
                  unread: try values.decodeIfPresent(Bool.self, forKey: .unread) ?? false,
                  agentConversation: try values.decodeIfPresent(String.self, forKey: .agentConversation) ?? "",
                  tty: try values.decodeIfPresent(String.self, forKey: .tty) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(windowID, forKey: .windowID)
        try values.encode(index, forKey: .index)
        try values.encode(isActive, forKey: .isActive)
        try values.encode(title, forKey: .title)
        try values.encode(path, forKey: .path)
        try values.encode(command, forKey: .command)
        try values.encode(agent, forKey: .agent)
        try values.encode(agentStatus, forKey: .agentStatus)
        try values.encode(unread, forKey: .unread)
        try values.encode(agentConversation, forKey: .agentConversation)
        try values.encode(tty, forKey: .tty)
    }
}

/// The fields that tmux and the Topic options give a Window. The Mac's own (`homeDirectory`, `hostName`,
/// `isRemote`, `sourceID`) stay off the wire: it stamps them from the `server` event. The Host imports a Lock that an
/// older Muxify kept in `@muxify_lock` itself, so the option stays off the wire too. `lock_order` goes only to an older
/// Mac (`LockedWindow`), and the Mac reads the Locks from the `guest_sessions` event, never from `lock_order`.
extension TmuxWindow: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case sessionName = "session_name"
        case index, name
        case paneTitle = "pane_title"
        case path, command
        case isActive = "active"
        case paneCount = "pane_count"
        case hasBell = "bell"
        case sessionActivity = "session_activity"
        case agent
        case storedBrowser = "browser"
        case openRequests = "open_requests"
        case topicID = "topic_id"
        case savedSessionID = "saved_session_id"
        case sessionPath = "session_path"
        case activePaneID = "active_pane_id"
        case startCommand = "start_command"
        case sessionCreated = "session_created"
        case layout
        case isZoomed = "zoomed"
        case isLastWindow = "last_window"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  sessionID: try values.decodeIfPresent(String.self, forKey: .sessionID) ?? "",
                  sessionName: try values.decodeIfPresent(String.self, forKey: .sessionName) ?? "",
                  index: try values.decodeIfPresent(Int.self, forKey: .index) ?? 0,
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? "",
                  paneTitle: try values.decodeIfPresent(String.self, forKey: .paneTitle) ?? "",
                  path: try values.decodeIfPresent(String.self, forKey: .path) ?? "",
                  command: try values.decodeIfPresent(String.self, forKey: .command) ?? "",
                  isActive: try values.decodeIfPresent(Bool.self, forKey: .isActive) ?? false,
                  paneCount: try values.decodeIfPresent(Int.self, forKey: .paneCount) ?? 1,
                  hasBell: try values.decodeIfPresent(Bool.self, forKey: .hasBell) ?? false,
                  sessionActivity: try values.decodeIfPresent(Int.self, forKey: .sessionActivity) ?? 0,
                  agent: try values.decodeIfPresent(String.self, forKey: .agent) ?? "",
                  storedBrowser: try values.decodeIfPresent(StoredBrowser.self, forKey: .storedBrowser) ?? StoredBrowser(),
                  openRequests: try values.decodeIfPresent([String].self, forKey: .openRequests) ?? [],
                  topicID: try values.decodeIfPresent(String.self, forKey: .topicID),
                  savedSessionID: try values.decodeIfPresent(String.self, forKey: .savedSessionID) ?? "",
                  sessionPath: try values.decodeIfPresent(String.self, forKey: .sessionPath) ?? "",
                  activePaneID: try values.decodeIfPresent(String.self, forKey: .activePaneID) ?? "",
                  startCommand: try values.decodeIfPresent(String.self, forKey: .startCommand) ?? "",
                  sessionCreated: try values.decodeIfPresent(Int.self, forKey: .sessionCreated) ?? 0,
                  layout: try values.decodeIfPresent(String.self, forKey: .layout) ?? "",
                  isZoomed: try values.decodeIfPresent(Bool.self, forKey: .isZoomed) ?? false,
                  isLastWindow: try values.decodeIfPresent(Bool.self, forKey: .isLastWindow) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(sessionID, forKey: .sessionID)
        try values.encode(sessionName, forKey: .sessionName)
        try values.encode(index, forKey: .index)
        try values.encode(name, forKey: .name)
        try values.encode(paneTitle, forKey: .paneTitle)
        try values.encode(path, forKey: .path)
        try values.encode(command, forKey: .command)
        try values.encode(isActive, forKey: .isActive)
        try values.encode(paneCount, forKey: .paneCount)
        try values.encode(hasBell, forKey: .hasBell)
        try values.encode(sessionActivity, forKey: .sessionActivity)
        try values.encode(agent, forKey: .agent)
        try values.encode(storedBrowser, forKey: .storedBrowser)
        try values.encode(openRequests, forKey: .openRequests)
        try values.encodeIfPresent(topicID, forKey: .topicID)
        try values.encode(savedSessionID, forKey: .savedSessionID)
        try values.encode(sessionPath, forKey: .sessionPath)
        try values.encode(activePaneID, forKey: .activePaneID)
        try values.encode(startCommand, forKey: .startCommand)
        try values.encode(sessionCreated, forKey: .sessionCreated)
        try values.encode(layout, forKey: .layout)
        try values.encode(isZoomed, forKey: .isZoomed)
        // A new optional key (ADR 0086 change rule 1): absent is false, so an older Host Server marks no Last Window.
        if isLastWindow { try values.encode(isLastWindow, forKey: .isLastWindow) }
    }
}
