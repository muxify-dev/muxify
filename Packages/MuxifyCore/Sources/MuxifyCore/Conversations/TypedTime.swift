import Foundation

/// A time as the user types it: `2h`, `17:30`, `today 9am`, `mon 9:00`. The CLI's `--since` reads it toward the past.
public enum TypedTime: Equatable, Sendable {
    case relative(Int, Calendar.Component)
    case day(Int, hour: Int, minute: Int)
    case weekday(Int, hour: Int, minute: Int)
    /// The next time the clock shows this hour and minute: today if it is still ahead, else tomorrow.
    case next(hour: Int, minute: Int)

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let relative = text.hasPrefix("+") ? String(text.dropFirst()) : text
        if let unit = relative.last, let count = Int(relative.dropLast()), count > 0,
           relative.dropLast().allSatisfy(\.isNumber), count <= 1_000_000 {
            let components: [Character: Calendar.Component] = ["m": .minute, "h": .hour, "d": .day]
            if let component = components[unit] { self = .relative(count, component); return }
        }
        if let clock = Self.clock(text[...]) { self = .next(hour: clock.hour, minute: clock.minute); return }
        guard let day = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let rest = text.dropFirst(day.count).drop(while: \.isWhitespace)
        var hour = 9, minute = 0
        if !rest.isEmpty {
            guard let clock = Self.clock(rest) else { return nil }
            hour = clock.hour; minute = clock.minute
        }
        switch day {
        case "today": self = .day(0, hour: hour, minute: minute)
        case "tomorrow": self = .day(1, hour: hour, minute: minute)
        default:
            guard let index = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: String(day)) else { return nil }
            self = .weekday(index + 1, hour: hour, minute: minute)
        }
    }

    /// Reads H, HH, HMM, HHMM, H:MM or HH:MM, each with an optional am or pm.
    private static func clock(_ text: Substring) -> (hour: Int, minute: Int)? {
        let meridiem = ["am", "pm"].first { text.hasSuffix($0) }
        var digits = meridiem == nil ? text : text.dropLast(2)
        while digits.last?.isWhitespace == true { digits = digits.dropLast() }
        let pieces = digits.split(separator: ":", omittingEmptySubsequences: false)
        let hourText: Substring, minuteText: Substring
        switch (pieces.count, digits.count) {
        case (1, 1...2): hourText = digits; minuteText = "0"
        case (1, 3...4): hourText = digits.dropLast(2); minuteText = digits.suffix(2)
        case (2, _) where (1...2).contains(pieces[0].count) && pieces[1].count == 2: hourText = pieces[0]; minuteText = pieces[1]
        default: return nil
        }
        guard (hourText + minuteText).allSatisfy({ $0.isASCII && $0.isNumber }),
              let hour = Int(hourText), let minute = Int(minuteText), (0...59).contains(minute) else { return nil }
        guard let meridiem else { return (0...23).contains(hour) ? (hour, minute) : nil }
        guard (1...12).contains(hour) else { return nil }
        return (hour % 12 + (meridiem == "pm" ? 12 : 0), minute)
    }
}
