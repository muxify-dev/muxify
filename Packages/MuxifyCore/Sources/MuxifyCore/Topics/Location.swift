import Foundation

public enum TopicGroupID: Hashable, Sendable {
    case topic(String)
    case session(String)
    case noTopic

    /// The card that a Window's Session is on: its open Topic, else its Board Session, else none. `boardSessions` has the
    /// id of each live Board Session, by the Session's tmux id.
    public init(_ window: TmuxWindow, open: Set<String>, boardSessions: [String: String]) {
        if let id = window.topicID, open.contains(id) { self = .topic(id) }
        else if let id = boardSessions[window.sessionID] { self = .session(id) }
        else { self = .noTopic }
    }

    /// The group that a look at a Window's Session visits: its open Topic, else No Topic, also for a Board Session.
    /// The app and the Host's `visit_session` both use it, so a visit from either ranks the same rows.
    public static func visited(_ window: TmuxWindow, open: Set<String>) -> TopicGroupID {
        TopicGroupID(window, open: open, boardSessions: [:])
    }

    /// The id of the card's row in a list, stable across queries: the Sidebar's and Go to…'s.
    public var accessibilityID: String {
        switch self {
        case .topic(let id): return "topic-\(id)"
        case .session(let id): return "board-session-\(id)"
        case .noTopic: return "no-topic"
        }
    }
}

public enum Location: Hashable, Codable, Sendable {
    case window(WindowID)
    case emptyTopic(TopicGroupID)
    /// The Open Place page of the Open Place with this id.
    case openPlace(String)

    public var windowID: WindowID? {
        if case .window(let id) = self { return id }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case window
        case emptyTopic = "empty_topic"
        case openPlace = "open_place"
    }

    private enum ValueKeys: String, CodingKey {
        case id
        case noTopic = "no_topic"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one Location."))
        }
        if values.contains(.window) {
            let window = try values.nestedContainer(keyedBy: ValueKeys.self, forKey: .window)
            self = .window(try window.decode(WindowID.self, forKey: .id))
        } else if values.contains(.openPlace) {
            let place = try values.nestedContainer(keyedBy: ValueKeys.self, forKey: .openPlace)
            self = .openPlace(try place.decode(String.self, forKey: .id))
        } else {
            let page = try values.nestedContainer(keyedBy: ValueKeys.self, forKey: .emptyTopic)
            if page.contains(.id) {
                self = .emptyTopic(.topic(try page.decode(String.self, forKey: .id)))
            } else if try page.decode(Bool.self, forKey: .noTopic) {
                self = .emptyTopic(.noTopic)
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected an Empty Topic page."))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .window(let id):
            var window = values.nestedContainer(keyedBy: ValueKeys.self, forKey: .window)
            try window.encode(id, forKey: .id)
        case .emptyTopic(let group):
            var page = values.nestedContainer(keyedBy: ValueKeys.self, forKey: .emptyTopic)
            switch group {
            case .topic(let id): try page.encode(id, forKey: .id)
            case .session:
                throw EncodingError.invalidValue(group, .init(codingPath: encoder.codingPath,
                                                              debugDescription: "Only the Mac shows a Board Session's page; no request names it."))
            case .noTopic: try page.encode(true, forKey: .noTopic)
            }
        case .openPlace(let id):
            var place = values.nestedContainer(keyedBy: ValueKeys.self, forKey: .openPlace)
            try place.encode(id, forKey: .id)
        }
    }
}
