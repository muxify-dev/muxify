import CoreGraphics
import MuxifyCore

/// The sizes and colours of a Hint's badge, for the AppKit and the SwiftUI rows (ADR 0074). The font size is at 12,
/// and grows with the Interface font size.
enum HintBadgeMetrics {
    /// The keys are semibold and monospaced.
    static let fontSize: CGFloat = 11
    static let horizontalPadding: CGFloat = 5
    static let verticalPadding: CGFloat = 2
    static let cornerRadius: CGFloat = 5
    /// The box is this colour in sRGB at `fillOpacity`, with a border of white at `borderOpacity`. The keys are the text
    /// colour of the dark scheme, also in a light theme.
    static let fill = (red: 30.0 / 255, green: 31.0 / 255, blue: 35.0 / 255)
    static let fillOpacity = 0.9
    static let borderOpacity = 0.35
    static let borderWidth: CGFloat = 1

    /// The keys of the badge, joined by a space, such as "⌃2".
    static func text(_ triggers: [KeyTrigger]) -> String { triggers.map(\.symbol).joined(separator: " ") }
}

/// Where a Window row's Hint stands and how its key at rest looks, for the AppKit and the SwiftUI rows (ADR 0074).
enum WindowHintMetrics {
    /// The Hint stands this far right of and below the row's top left corner, in the room the row keeps for it.
    static let inset: CGFloat = 5
    /// The key at rest is medium and monospaced, in the secondary text colour, at 12.
    static let keyFontSize: CGFloat = 10
}

/// The sizes and colours of a card's key at rest, for both versions of the card (ADR 0074). The sizes are at 12, and
/// grow with the Interface font size.
enum CardRestKeyMetrics {
    /// The key is semibold, in the rounded design.
    static let fontSize: CGFloat = 10
    static let horizontalPadding: CGFloat = 4
    /// The capsule is at least this wide and this high.
    static let minSide: CGFloat = 16
    /// The key is the text colour at this opacity, and its capsule at `fillOpacity`.
    static let textOpacity = 0.7
    static let fillOpacity = 0.12
}
