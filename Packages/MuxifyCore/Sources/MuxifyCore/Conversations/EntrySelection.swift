import Foundation

/// Which Entries of a conversation the caller gets, and how much of each. The filters apply first, then one window,
/// then the cut. No step changes an Entry's index.
public struct EntrySelection: Equatable, Sendable {
    public enum Window: Equatable, Sendable {
        case head(Int)
        case tail(Int)
        /// Original indexes, both ends included. A negative end counts from the end: -1 is the last Entry. Nil is open.
        case range(Int?, Int?)
    }

    /// A regular expression over the text and the tool name of each Entry, with `context` Entries before and after
    /// each match. It ignores case unless the pattern has a capital letter, as rg does.
    public struct Grep: Equatable, @unchecked Sendable {
        public let pattern: String
        public let context: Int
        private let expression: NSRegularExpression

        public init(pattern: String, context: Int = 0) throws {
            self.pattern = pattern
            self.context = context
            expression = try NSRegularExpression(pattern: pattern,
                                                 options: pattern.contains(where: \.isUppercase) ? [] : [.caseInsensitive])
        }

        func matches(_ entry: Entry) -> Bool {
            [entry.text, entry.tool ?? ""].contains { text in
                expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }

        public static func == (lhs: Grep, rhs: Grep) -> Bool { lhs.pattern == rhs.pattern && lhs.context == rhs.context }
    }

    /// An Entry as the caller gets it: its text cut at the character limit.
    public struct Selected: Equatable, Sendable {
        public let entry: Entry
        public let text: String
        /// The length of the whole text, in characters.
        public let chars: Int
        public var truncated: Bool { text.count < chars }
    }

    public struct Result: Equatable, Sendable {
        public let entries: [Selected]
        /// Every Entry of the conversation.
        public let total: Int
        /// The Entries that the filters kept, before the window.
        public let filtered: Int
        /// The Entries that the role and tool filters left out.
        public let hiddenByRole: Int
        public var cut: Int { entries.filter(\.truncated).count }
    }

    public var roles: Set<Entry.Role>
    /// Only tool Entries of these tools, compared without case. Empty is every tool.
    public var tools: Set<String>
    public var grep: Grep?
    public var since: Date?
    public var after: Int?
    public var window: Window?
    /// Nil gives each text in full.
    public var maxChars: Int?

    public init(roles: Set<Entry.Role> = [.user, .assistant], tools: Set<String> = [], grep: Grep? = nil, since: Date? = nil,
                after: Int? = nil, window: Window? = nil, maxChars: Int? = 2000) {
        self.roles = roles
        self.tools = tools
        self.grep = grep
        self.since = since
        self.after = after
        self.window = window
        self.maxChars = maxChars
    }

    public func apply(to entries: [Entry]) -> Result {
        // The call that a blocked Agent waits on: the last tool call, when no tool result comes after it.
        let lastCall = entries.last { $0.role == .toolCall }
        let waiting = lastCall.flatMap { call in entries.contains { $0.role == .toolResult && $0.index > call.index } ? nil : call }
        let names = Set(tools.map { $0.lowercased() })
        let byRole = entries.filter { entry in
            (roles.contains(entry.role) || entry == waiting) && (names.isEmpty || names.contains(entry.tool?.lowercased() ?? ""))
        }
        var kept = byRole
        if let grep {
            let matches = byRole.indices.filter { grep.matches(byRole[$0]) }
            var shown = IndexSet()
            for match in matches { shown.insert(integersIn: max(0, match - grep.context)...min(byRole.count - 1, match + grep.context)) }
            kept = shown.map { byRole[$0] }
        }
        if let since { kept = kept.filter { $0.at.map { $0 >= since } ?? false } }
        if let after { kept = kept.filter { $0.index > after } }
        let filtered = kept.count
        switch window {
        case .head(let count): kept = Array(kept.prefix(count))
        case .tail(let count): kept = Array(kept.suffix(count))
        case .range(let first, let last):
            func resolved(_ end: Int?) -> Int? { end.map { $0 < 0 ? entries.count + $0 : $0 } }
            let low = resolved(first) ?? Int.min, high = resolved(last) ?? Int.max
            kept = kept.filter { $0.index >= low && $0.index <= high }
        case nil: break
        }
        let selected = kept.map { entry in
            Selected(entry: entry, text: maxChars.map { String(entry.text.prefix($0)) } ?? entry.text, chars: entry.text.count)
        }
        return Result(entries: selected, total: entries.count, filtered: filtered, hiddenByRole: entries.count - byRole.count)
    }

    /// The time that `--since` names: an ISO 8601 time, or a `TypedTime` toward the past. 2h is two
    /// hours ago, 17:30 the last time the clock showed 17:30, mon 9am the last Monday at 9:00.
    public static func since(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed))
            ?? (try? Date.ISO8601FormatStyle().parse(trimmed)) {
            return date
        }
        switch TypedTime(trimmed) {
        case .relative(let count, let component)?:
            return calendar.date(byAdding: component, value: -count, to: now)
        case .next(let hour, let minute)?:
            return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime,
                                     direction: .backward)
        case .weekday(let weekday, let hour, let minute)?:
            return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                                     matchingPolicy: .nextTime, direction: .backward)
        case .day(0, let hour, let minute)?:
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now).flatMap { $0 <= now ? $0 : nil }
        case .day?, nil:
            return nil
        }
    }
}
