import Foundation

/// What a view verb asks the App Window to show: `muxify session open`, `window open` and `topic open`. Locally it
/// travels as a `muxify://select` URL; on a Host, as a `select` request through the Host Server (ADR 0091), whose
/// JSON is `{"session": "<name>"}`, `{"window": "<id>"}` or `{"topic": "<id>"}`.
public enum SelectRequest: Codable, Equatable, Sendable {
    case session(String)
    case window(String)
    case topic(String)

    private enum CodingKeys: String, CodingKey, CaseIterable { case session, window, topic }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = CodingKeys.allCases.first(where: values.contains) else {
            throw ProtocolError(.unsupported, "this muxify does not know what to select")
        }
        let value = try values.decode(String.self, forKey: key)
        switch key {
        case .session: self = .session(value)
        case .window: self = .window(value)
        case .topic: self = .topic(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let name): try values.encode(name, forKey: .session)
        case .window(let id): try values.encode(id, forKey: .window)
        case .topic(let id): try values.encode(id, forKey: .topic)
        }
    }
}
