import Foundation

public struct EnvironmentBrowserState: Codable, Hashable, Sendable {
    public var window: WindowID
    public var browser: StoredBrowser

    public init(window: WindowID, browser: StoredBrowser) {
        self.window = window
        self.browser = browser
    }
}

public enum EnvironmentVisit: Codable, Hashable, Sendable {
    case panes(window: WindowID, shown: Set<PaneID>)
    case emptyTopic(String)
}

public enum PaneDirection: String, Codable, Hashable, Sendable {
    case up, down, left, right
}

public enum PaneAction: Codable, Hashable, Sendable {
    case split(PaneDirection)
    case select(PaneDirection)
    case previous, next
    case resize(PaneDirection, amount: Int)
    case zoom
    case equalize
}

public struct EnvironmentAttachment: Codable, Hashable, Sendable {
    public struct Destination: Codable, Hashable, Sendable {
        public var session: SessionID
        public var window: WindowID

        public init(session: SessionID, window: WindowID) {
            self.session = session
            self.window = window
        }
    }

    public var destination: Destination?
    public var directory: String?
    public var createSessionIfNeeded: Bool

    public init(destination: Destination? = nil, directory: String? = nil, createSessionIfNeeded: Bool = true) {
        self.destination = destination
        self.directory = directory
        self.createSessionIfNeeded = createSessionIfNeeded
    }

    public var target: String? {
        destination.map { $0.session.rawValue + ":" + $0.window.rawValue }
    }
}

/// The driver starts the native Terminal and observes its Client with a bounded readiness read.
@MainActor public protocol EnvironmentAttachmentDriver: AnyObject {
    func attach(_ plan: EnvironmentAttachment, completion: @escaping (Result<Void, Error>) -> Void)
}

public struct EnvironmentClientMarker: Codable, Hashable, Sendable {
    public var id: UUID
    public var pid: Int
    public var tty: String
    public var home: String
    public var host: String

    public init(id: UUID, pid: Int, tty: String, home: String, host: String) {
        self.id = id
        self.pid = pid
        self.tty = tty
        self.home = home
        self.host = host
    }

    var option: String { Self.option(id) }
    static func option(_ id: UUID) -> String { "@muxify_client_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

/// Writes from one reader. The module owns automatic rules.
public enum EnvironmentOperation: Codable, Hashable, Sendable {
    case browser([EnvironmentBrowserState])
    case openBrowser(target: String, urls: [String])
    /// Publishes the socket that serves this server's Browsers, or removes it when nil.
    case browserSocket(String?)
    case visit(EnvironmentVisit, manualRead: Bool)
    case pane(window: WindowID, action: PaneAction)
    case paneSearch(PaneSearch.Operation)
    case selectPane(PaneID)
    case switchClient(session: SessionID, window: WindowID)
    case rememberWindow(WindowID)
    case consumeOpen(WindowID)
    case sendText(pane: PaneID, text: String)
    case pasteText(pane: PaneID, text: String)
    case editorWindow(session: SessionID, after: WindowID?, directory: String, command: String)
    case attach(EnvironmentAttachment)
    case registerClient(EnvironmentClientMarker)
    case removeClient(UUID)
    /// Puts each Guest at the end of In Play, for the `topics.in_play` of the request (ADR 0061).
    case gatherGuests

    var needsRecords: Bool {
        switch self {
        case .visit(.emptyTopic, _), .gatherGuests: return true
        default: return false
        }
    }

    var requiredPersistence: Bool {
        switch self {
        case .browser, .browserSocket(nil), .visit(.emptyTopic, _), .removeClient, .paneSearch(.cancel): return true
        default: return false
        }
    }
}
