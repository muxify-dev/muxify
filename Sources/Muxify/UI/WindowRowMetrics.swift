import CoreGraphics
import MuxifyCore

/// Where a Window row puts its parts, for the AppKit and the SwiftUI rows (ADR 0074). A length that grows with the
/// Interface font size is its size at 12.
enum WindowRowMetrics {
    static let leading: CGFloat = 8
    static let trailing: CGFloat = 6
    /// The room above and below the row's parts.
    static let vertical: CGFloat = 4
    /// Between two parts of the row, from the left: the room for a Hint, the icon, the title, the space that pushes
    /// the badges to the end, and each badge.
    static let spacing: CGFloat = 6
    /// Between the title and each line under it.
    static let lineSpacing: CGFloat = 1
    /// The least room between the title and the badges.
    static let endGap: CGFloat = 4
    static let cornerRadius: CGFloat = 6
    /// Between a badge's symbol and its count.
    static let badgeSpacing: CGFloat = 2
    /// The room on each side of the Pane count, which the capsule of a Zoomed Pane fills.
    static let paneCountPadding: CGFloat = 4
    /// The capsule of a Zoomed Pane is the accent colour at this opacity.
    static let zoomFillOpacity = 0.2
    /// The side of an app icon. It does not grow with the Interface font size.
    static let iconSize: CGFloat = 14
    /// The room the row keeps before its icon for a Window Hint, at 12.
    static let hintRoom: CGFloat = 10
    /// The size of the symbols of the badges and of the Formats' symbol parts, at 12.
    static let symbolSize: CGFloat = 10
    /// The side of the Git View icon, at 12.
    static let gitViewIconSize: CGFloat = 11
    static let tabSymbol = "globe"
    static let paneSymbol = "rectangle.split.2x1"
}

/// The words of a Window row, for the AppKit and the SwiftUI rows (ADR 0074): the line under the title, the help of
/// the badges, and the label of the Pane count.
enum WindowRowText {
    static let mainWorkingCopy = "Main working copy"
    static let gitViewOpen = "Git View open"
    static let zoomed = "One Pane is Zoomed. The others are hidden."
    /// The label of the Tab count's globe, which SwiftUI gives the symbol by itself.
    static let tabSymbolLabel = "Globe"

    static func tabs(_ count: Int) -> String { "\(count) browser tab(s)" }

    /// The detail line of the row's hover label: the Window's place in its Session and its path.
    static func hoverDetail(_ window: TmuxWindow) -> String { "\(window.sessionName):\(window.index) — \(window.abbreviatedPath)" }

    /// The row's own identifier and value replace the badge's, so the label is where a client reads Zoom.
    static func panes(_ count: Int, isZoomed: Bool) -> String { isZoomed ? "\(count), Zoomed" : "\(count)" }
}

/// How the Sidebar marks the selected Window or Pane row, for the AppKit and the SwiftUI rows (ADR 0074): a soft
/// accent tint that fades in, so moving between Windows does not flash a block of full colour from row to row. A row
/// under the pointer has a faint fill of the text colour.
enum SelectedRow {
    /// The tint is the accent colour at this opacity.
    static let tintOpacity = 0.22
    /// The fill of a row under the pointer is the text colour at this opacity.
    static let hoverOpacity = 0.07
    /// The tint fades in and out with ease-out over this many seconds.
    static let fade = 0.14
}
