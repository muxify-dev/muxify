import Foundation

/// How long ago a Topic was Settled, as a Settled card tells it.
enum SettledAge {
    /// The midnights in `calendar`'s time zone from `settled` to `now`: Settled at 23:50 and seen at 00:10 the next
    /// day is 1. A `settled` after `now`, from a clock that went back, is 0.
    static func days(from settled: Date, to now: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: settled), to: calendar.startOfDay(for: now)).day ?? 0
        return max(days, 0)
    }

    /// "Today", "Yesterday", the weekday for the rest of the last week, "N days ago" up to 29 days, then the date,
    /// with its year when that is not the year of `now`. The words come from `calendar`'s locale.
    static func label(settled: Date, now: Date, calendar: Calendar) -> String {
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
}
