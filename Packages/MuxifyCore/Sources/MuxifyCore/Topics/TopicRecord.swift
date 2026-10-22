import Foundation

/// Unknown fields remain values, including fields inside remembered Sessions and Windows.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), unsignedInteger(UInt64), number(Decimal), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(UInt64.self) { self = .unsignedInteger(item) }
        else if let item = try? value.decode(Decimal.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([JSONValue].self) { self = .array(item) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .unsignedInteger(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }
}

public struct TopicRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String?
    public var slug: String?
    public var createdAt: String?
    public var settledAt: String?
    public var outcome: String?
    public var order: Double?
    public var snoozedUntil: String?
    public var sessions: [JSONValue] = []
    /// The user ordered the Sessions by hand, so `sessions` gives their order (`session_order: manual`).
    public var hasManualSessionOrder = false
    /// The Topic stays above every Topic that is not Pinned (`pinned: true`).
    public var isPinned = false
    public var isUnread = false
    /// The record keeps them in `tags` as an array of names, A→Z, and leaves the key out when it has nothing to keep.
    public var tags: Set<Tag> = []
    /// What `tags` holds that is not a Tag: the array of those entries, or a `tags` value that is not an array. A
    /// write puts the entries back after the Tags, and the value back while the Topic has no Tags, as it keeps
    /// unknown fields.
    var unreadableTags: JSONValue?
    public var unknownFields: [String: JSONValue] = [:]

    public func isSnoozed(at now: Date) -> Bool {
        guard let deadline = snoozeDeadline else { return false }
        return !deadline.isDue(at: now)
    }

    public var snoozeDeadline: SnoozeDeadline? { snoozedUntil.flatMap(SnoozeDeadline.init(stored:)) }

    public init(id: String, title: String? = nil, slug: String? = nil) {
        self.id = id
        self.title = title
        self.slug = slug
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, slug, outcome, order, sessions
        case createdAt = "created_at", settledAt = "settled_at"
        case snoozedUntil = "snoozed_until", sessionOrder = "session_order", pinned, unread, tags
    }

    private struct FieldKey: CodingKey {
        public let stringValue: String
        public var intValue: Int? { nil }
        public init?(stringValue: String) { self.stringValue = stringValue }
        public init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\0") else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: values, debugDescription: "expected a Topic id that is a filename")
        }
        title = try values.decodeIfPresent(String.self, forKey: .title)
        slug = try values.decodeIfPresent(String.self, forKey: .slug)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        settledAt = try values.decodeIfPresent(String.self, forKey: .settledAt)
        outcome = try values.decodeIfPresent(String.self, forKey: .outcome)
        order = try values.decodeIfPresent(Double.self, forKey: .order)
        snoozedUntil = try values.decodeIfPresent(String.self, forKey: .snoozedUntil)
        sessions = try values.decodeIfPresent([JSONValue].self, forKey: .sessions) ?? []
        hasManualSessionOrder = (try? values.decodeIfPresent(String.self, forKey: .sessionOrder)) == "manual"
        isPinned = (try? values.decodeIfPresent(Bool.self, forKey: .pinned)) == true
        isUnread = (try? values.decodeIfPresent(Bool.self, forKey: .unread)) == true
        switch try values.decodeIfPresent(JSONValue.self, forKey: .tags) {
        case .array(let entries)?:
            // An entry is read as the user types a Tag, so `Backend` and `#backend` are the Tag `backend`.
            let read = entries.map { ($0, $0.string.flatMap(Tag.init(typed:))) }
            tags = Set(read.compactMap(\.1))
            let rest = read.filter { $0.1 == nil }.map(\.0)
            unreadableTags = rest.isEmpty ? nil : .array(rest)
        case let value?: unreadableTags = value
        case nil: break
        }
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        let fields = try decoder.container(keyedBy: FieldKey.self)
        unknownFields = Dictionary(uniqueKeysWithValues: try fields.allKeys.filter { !known.contains($0.stringValue) }.map {
            ($0.stringValue, try fields.decode(JSONValue.self, forKey: $0))
        })
    }

    public func encode(to encoder: Encoder) throws {
        try unknownFields.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(slug, forKey: .slug)
        try values.encodeIfPresent(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(settledAt, forKey: .settledAt)
        try values.encodeIfPresent(outcome, forKey: .outcome)
        try values.encodeIfPresent(order, forKey: .order)
        try values.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
        try values.encode(sessions, forKey: .sessions)
        if hasManualSessionOrder { try values.encode("manual", forKey: .sessionOrder) }
        if isUnread { try values.encode(true, forKey: .unread) }
        if isPinned { try values.encode(true, forKey: .pinned) }
        let names = tags.sorted().map { JSONValue.string($0.name) }
        switch unreadableTags {
        case .array(let rest)?: try values.encode(names + rest, forKey: .tags)
        case let value? where tags.isEmpty: try values.encode(value, forKey: .tags)
        default: if !tags.isEmpty { try values.encode(names, forKey: .tags) }
        }
    }
}
