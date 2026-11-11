import Foundation

/// One line of the Diagnostics log that a program reads: the timestamp, a kind word, then space-separated
/// `key=value` fields. A value holds no spaces; a list is comma-separated, and a pair in a list is `name:value`,
/// split at its last colon.
/// The app writes every record through it, and `muxify diagnostics summary` parses through it. The free-text
/// event lines (launch, app and window changes, Muxify's messages) are not records.
public struct DiagnosticsRecord: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case minute, burst, freeze, digest, limit
    }

    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: String
    }

    /// The local time of a line, to the millisecond: `2026-11-11 17:07:34.120`.
    public static let timestampFormat = "yyyy-MM-dd HH:mm:ss.SSS"

    public var kind: Kind
    /// In the order they were added, which is the order they are written in.
    public private(set) var fields: [Field] = []

    public init(_ kind: Kind, _ fields: [(String, String)] = []) {
        self.kind = kind
        for (key, value) in fields { append(key, value) }
    }

    /// Adds `key=value`. Whitespace in the value becomes `_`, so the value stays one word.
    public mutating func append(_ key: String, _ value: String) {
        let word = String(value.map { $0.isWhitespace ? "_" : $0 })
        fields.append(Field(key: key, value: word))
    }

    public subscript(key: String) -> String? {
        fields.first { $0.key == key }?.value
    }

    /// The line without its timestamp, as `Diagnostics.write` takes it: `minute cpu.app.avg=1.2 …`.
    public var text: String {
        ([kind.rawValue] + fields.map { "\($0.key)=\($0.value)" }).joined(separator: " ")
    }

    /// The whole line, as the Diagnostics log writes it.
    public func line(at date: Date, formatter: DateFormatter = DiagnosticsRecord.formatter()) -> String {
        "\(formatter.string(from: date)) \(text)"
    }

    /// The record in `text`, a line without its timestamp. Nil when its first word is not a kind, or a field is
    /// not `key=value`.
    public init?(text: String) {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = words.first, let kind = Kind(rawValue: String(first)) else { return nil }
        self.kind = kind
        for word in words.dropFirst() {
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return nil }
            fields.append(Field(key: String(word[..<equals]), value: String(word[word.index(after: equals)...])))
        }
    }

    /// The timestamp and record of a whole log line. Nil for a line that is not a record, such as a free-text
    /// event line or a line cut short. A reader of many lines passes one `formatter()` to every call.
    public static func parse(_ line: String, formatter: DateFormatter = DiagnosticsRecord.formatter()) -> (date: Date, record: DiagnosticsRecord)? {
        guard let (date, text) = timestamped(line, formatter: formatter), let record = DiagnosticsRecord(text: text) else { return nil }
        return (date, record)
    }

    /// The timestamp of a whole log line and the text after it, a record's or a free-text event line's. Nil for a
    /// line with no timestamp, such as one cut short.
    public static func timestamped(_ line: String, formatter: DateFormatter = DiagnosticsRecord.formatter()) -> (date: Date, text: String)? {
        // The timestamp is two words: the date and the time.
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let date = formatter.date(from: "\(parts[0]) \(parts[1])") else { return nil }
        return (date, String(parts[2]))
    }

    /// A figure with one decimal, as the records write CPU, lengths and shares: `42.5`.
    static func decimal(_ value: Double) -> String { String(format: "%.1f", value) }

    // MARK: Lists

    /// `a,b,c`.
    public static func list(_ items: [String]) -> String {
        items.joined(separator: ",")
    }

    /// `name:value,name:value`.
    public static func pairs(_ items: [(String, String)]) -> String {
        list(items.map { "\($0.0):\($0.1)" })
    }

    /// The comma-separated items of `key`, or nil when the record has no `key`.
    public func list(_ key: String) -> [String]? {
        self[key].map { $0.split(separator: ",").map(String.init) }
    }

    /// The `name:value` pairs of `key`. Nil when the record has no `key`, or an item is not a pair.
    public func pairs(_ key: String) -> [(name: String, value: String)]? {
        self[key].flatMap(Self.pairs(in:))
    }

    /// The `name:value` pairs of a value. A pair splits at its last `:`, so a name may hold colons, as a symbol's
    /// does in a `digest` record. Nil when an item is not a pair.
    public static func pairs(in value: String) -> [(name: String, value: String)]? {
        var pairs: [(name: String, value: String)] = []
        for item in value.split(separator: ",") {
            guard let colon = item.lastIndex(of: ":") else { return nil }
            pairs.append((String(item[..<colon]), String(item[item.index(after: colon)...])))
        }
        return pairs
    }

    /// A new formatter of `timestampFormat` in local time. DateFormatter is not safe to share across threads.
    public static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = timestampFormat
        return formatter
    }
}
