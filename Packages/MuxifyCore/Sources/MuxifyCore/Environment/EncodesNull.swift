import Foundation

/// An optional field of a wire type that a reader always finds: nil encodes as `null`, where synthesized Codable
/// leaves the key out. A missing key still decodes as nil.
@propertyWrapper
public struct EncodesNull<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        wrappedValue = value.decodeNil() ? nil : try value.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    public func decode<Value>(_ type: EncodesNull<Value>.Type, forKey key: Key) throws -> EncodesNull<Value> {
        try decodeIfPresent(type, forKey: key) ?? EncodesNull(wrappedValue: nil)
    }
}
