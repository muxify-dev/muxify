import Foundation

/// A macOS system color that `ui.agent_colors` and `topics.tags` can name. Each one adapts to light and dark appearance.
public enum SystemColorName: String, CaseIterable, Sendable {
    case blue, orange, red, green, yellow, purple, pink, teal, gray
}

/// The color of one kind of Agent mark, or of a Tag Mark: one color for both appearances, or one for each.
public enum MarkColor: Hashable, Sendable {
    case single(Single)
    case pair(light: Single, dark: Single)

    public enum Single: Hashable, Sendable {
        case system(SystemColorName)
        /// The same in light and dark appearance.
        case rgb(red: UInt8, green: UInt8, blue: UInt8)

        /// A system color name or `#RRGGBB`, in any case.
        public init?(_ text: String) {
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            if let name = SystemColorName(rawValue: value) {
                self = .system(name)
                return
            }
            let digits = value.dropFirst()
            guard value.hasPrefix("#"), digits.count == 6, digits.allSatisfy(\.isHexDigit),
                  let packed = UInt32(digits, radix: 16) else { return nil }
            self = .rgb(red: UInt8(packed >> 16 & 0xff), green: UInt8(packed >> 8 & 0xff), blue: UInt8(packed & 0xff))
        }
    }
}

/// An opacity for light appearance and one for dark, each above 0 and at most 1.
public struct AppearanceOpacity: Hashable, Sendable {
    public var light: Double
    public var dark: Double

    public init(light: Double, dark: Double) {
        self.light = light
        self.dark = dark
    }
}

/// `ui.agent_colors`: the color of each kind of Agent mark, on every surface.
public struct AgentColors: Equatable, Sendable {
    public var working = MarkColor.single(.system(.gray))
    public var done = MarkColor.single(.system(.blue))
    public var failed = MarkColor.single(.system(.red))
    public var blocked = MarkColor.single(.system(.orange))

    public init() {}

    public subscript(mark: AgentMark) -> MarkColor {
        get {
            switch mark {
            case .working: working
            case .done: done
            case .failed: failed
            case .blocked: blocked
            }
        }
        set {
            switch mark {
            case .working: working = newValue
            case .done: done = newValue
            case .failed: failed = newValue
            case .blocked: blocked = newValue
            }
        }
    }
}
