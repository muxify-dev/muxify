import Foundation

/// One frame as it arrived: its envelope, and the line that its payload is decoded from when its reader knows the
/// payload's type. `item` and `end` carry the id of the request that they answer, and `cancel` the id of the request
/// that it cancels. A `hello` has id 0.
public struct ProtocolFrame: Sendable {
    public let id: Int
    public let kind: ProtocolKind
    let line: Data

    private struct Envelope: Decodable {
        let id: Int
        let kind: String
    }

    /// The frame on one line, or nil for a `kind` that this build does not know. A line that is not an envelope
    /// throws.
    public static func decode(_ line: Data) throws -> ProtocolFrame? {
        let envelope = try JSONDecoder().decode(Envelope.self, from: line)
        guard let kind = ProtocolKind(rawValue: envelope.kind) else { return nil }
        return ProtocolFrame(id: envelope.id, kind: kind, line: line)
    }

    /// The payload, under the key that the frame's `kind` names. Keys that the type does not know are ignored.
    public func payload<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(Payload<T>.self, from: line).value
    }

    /// The outcome of an `end`: its `ok` value, or its `error`.
    public func outcome<T: Decodable>(_ type: T.Type) -> Result<T, ProtocolError> {
        do {
            let end = try payload(EndBody<T>.self)
            if let error = end.error { return .failure(error) }
            guard let ok = end.ok else { return .failure(ProtocolError(.invalid, "the end has neither ok nor error")) }
            return .success(ok)
        } catch let error as ProtocolError {
            return .failure(error)
        } catch {
            return .failure(ProtocolError(.invalid, "the answer does not decode: \(error)"))
        }
    }

    private struct Payload<T: Decodable>: Decodable {
        let value: T

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: ProtocolKey.self)
            let kind = try values.decode(String.self, forKey: ProtocolKey("kind"))
            value = try values.decode(T.self, forKey: ProtocolKey(kind))
        }
    }

    private struct EndBody<T: Decodable>: Decodable {
        let ok: T?
        let error: ProtocolError?
    }
}

/// The lines that one side writes. Keys are sorted, so the JSON of each message is stable and pinned by tests.
enum ProtocolLine {
    static func hello(_ hello: ProtocolHello) throws -> Data { try frame(id: 0, kind: .hello, payload: hello) }

    static func request<T: Encodable>(id: Int, _ body: T) throws -> Data { try frame(id: id, kind: .request, payload: body) }

    static func item<T: Encodable>(id: Int, _ body: T) throws -> Data { try frame(id: id, kind: .item, payload: body) }

    static func ok<T: Encodable>(id: Int, _ value: T) throws -> Data { try frame(id: id, kind: .end, payload: EndOut.ok(value)) }

    static func error(id: Int, _ error: ProtocolError) -> Data {
        // Two strings and an integer always encode.
        (try? frame(id: id, kind: .end, payload: EndOut<ProtocolEmpty>.error(error))) ?? Data()
    }

    static func cancel(id: Int) -> Data { (try? frame(id: id, kind: .cancel, payload: ProtocolEmpty?.none)) ?? Data() }

    static let magic = Data((HostProtocol.magicLine + "\n").utf8)

    private static func frame<T: Encodable>(id: Int, kind: ProtocolKind, payload: T?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSONEncoder escapes newlines inside strings, so the line is always exactly one frame.
        var line = try encoder.encode(Out(id: id, kind: kind, payload: payload))
        line.append(UInt8(ascii: "\n"))
        return line
    }

    private struct Out<T: Encodable>: Encodable {
        let id: Int
        let kind: ProtocolKind
        let payload: T?

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: ProtocolKey.self)
            try values.encode(id, forKey: ProtocolKey("id"))
            try values.encode(kind, forKey: ProtocolKey("kind"))
            if let payload { try values.encode(payload, forKey: ProtocolKey(kind.rawValue)) }
        }
    }

    private enum EndOut<T: Encodable>: Encodable {
        case ok(T)
        case error(ProtocolError)

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: ProtocolKey.self)
            switch self {
            case .ok(let value): try values.encode(value, forKey: ProtocolKey("ok"))
            case .error(let error): try values.encode(error, forKey: ProtocolKey("error"))
            }
        }
    }
}
