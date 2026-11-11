import CoreGraphics

/// Where a Pane row puts its parts, for the AppKit and the SwiftUI rows (ADR 0074). A length that grows with the
/// Interface font size is its size at 12.
enum PaneRowMetrics {
    /// The room before the mark's place of a row under its Window row, which indents it.
    static let leadingUnderWindow: CGFloat = 28
    /// The room before the mark's place of a row that stands in for its Session's only Window row.
    static let leading: CGFloat = 8
    static let trailing: CGFloat = 6
    /// The room above and below the row's parts.
    static let vertical: CGFloat = 3
    /// Between two parts of the row, from the left: the mark's place, the split icon, the title, and the space at the
    /// end.
    static let spacing: CGFloat = 6
    /// Between the title and the Summary.
    static let lineSpacing: CGFloat = 1
    /// The least room after the title.
    static let endGap: CGFloat = 4
    /// The side of the Agent mark's place, at 12. It stays empty without a mark.
    static let markPlace: CGFloat = 10
    /// The width the split icon takes, at 12.
    static let iconRoom: CGFloat = 14
    /// The size of the split icon, at 12.
    static let iconSize: CGFloat = 10
    /// The size of the title, at 12.
    static let titleSize: CGFloat = 12
    /// The size of the Summary, at 12.
    static let summarySize: CGFloat = 11
    /// The split icon of the active Pane, and of another Pane.
    static let activeSymbol = "rectangle.split.2x1.fill"
    static let symbol = "rectangle.split.2x1"

    static func leading(isUnderWindowRow: Bool) -> CGFloat { isUnderWindowRow ? leadingUnderWindow : leading }
}

/// The row that ends a long card, for the AppKit and the SwiftUI rows (ADR 0074): "N more…", where N is the number
/// of rows the card holds back. A length that grows with the Interface font size is its size at 12.
enum MoreRowMetrics {
    /// The room before the text.
    static let leading: CGFloat = 28
    /// The size of the text, at 12.
    static let fontSize: CGFloat = 11
    /// The least height of the row, at 12.
    static let minHeight: CGFloat = 20

    static func text(_ count: Int) -> String { "\(count) more…" }
}
