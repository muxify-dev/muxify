import Foundation

/// How long ago a Topic was Settled, as a Settled card tells it.
public enum SettledAge {
    /// The midnights in `calendar`'s time zone from `settled` to `now`: Settled at 23:50 and seen at 00:10 the next
    /// day is 1. A `settled` after `now`, from a clock that went back, is 0.
    public static func days(from settled: Date, to now: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: settled), to: calendar.startOfDay(for: now)).day ?? 0
        return max(days, 0)
    }

    /// "Today", "Yesterday", the weekday for the rest of the last week, "N days ago" up to 29 days, then the date,
    /// with its year when that is not the year of `now`. The words come from `calendar`'s locale.
    public static func label(settled: Date, now: Date, calendar: Calendar) -> String {
        let count = days(from: settled, to: now, calendar: calendar)
        switch count {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return calendar.weekdaySymbols[calendar.component(.weekday, from: settled) - 1]
        case 7...29: return "\(count) days ago"
        default:
            let style = Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day()
            let sameYear = calendar.component(.year, from: settled) == calendar.component(.year, from: now)
            return settled.formatted(sameYear ? style : style.year())
        }
    }

    /// The first moment after `date` at which a label can change: the next midnight in `calendar`'s time zone, or the
    /// first moment of that day where the clocks skip midnight. A Settled card's label counts days, so the Settled group
    /// draws its cards again then.
    public static func nextMidnight(after date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
    }

    /// The Settled Topics that Forget Settled Older Than… forgets: Settled more than `days` days before `now`, in the
    /// days that `days(from:to:calendar:)` counts. With 14, a card that says "15 days ago" goes and one that says
    /// "14 days ago" stays. Oldest first.
    public static func settled(olderThan days: Int, in records: [TopicRecord], now: Date, calendar: Calendar) -> [TopicRecord] {
        records.compactMap { record in record.settledDate.map { (record, $0) } }
            .filter { Self.days(from: $0.1, to: now, calendar: calendar) > days }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }
}

extension TopicRecord {
    /// When the Topic was Settled. Nil for an open Topic, and for a `settled_at` that is not a date.
    public var settledDate: Date? { settledAt.flatMap { try? Date.ISO8601FormatStyle().parse($0) } }
}
