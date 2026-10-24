import Foundation

public enum TopicGroupID: Hashable, Sendable {
    case topic(String)
    case locked(String)
    case noTopic
}

public enum Location: Hashable, Codable, Sendable {
    case window(WindowID)
    case emptyTopic(TopicGroupID)

    public var windowID: WindowID? {
        if case .window(let id) = self { return id }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case window
        case emptyTopic = "empty_topic"
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
            case .locked:
                throw EncodingError.invalidValue(group, .init(codingPath: encoder.codingPath, debugDescription: "A Locked Session has no Empty Topic page."))
            case .noTopic: try page.encode(true, forKey: .noTopic)
            }
        }
    }
}
