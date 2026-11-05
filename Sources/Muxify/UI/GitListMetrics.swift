import CoreGraphics
import MuxifyCore

/// The Git View's List pane under the Interface font size (ADR 0068). Its rows, its headers and the History graph hold
/// text, so their design sizes at 12 grow by the factor; the list's padding does not. The pane's width bounds grow
/// too, inside the Git View.
enum GitListMetrics {
    /// A row of a list: a change, a file, a commit, a stash or a branch.
    static let designRowHeight: CGFloat = 24
    /// A row that is not an item, such as "No stashes".
    static let designNoteHeight: CGFloat = 22
    /// The header above a list, with its name and count.
    static let designHeaderHeight: CGFloat = 36
    /// A lane of the History graph.
    static let designLane: CGFloat = 11
    /// The padding around a list's rows, above and below together. It does not scale.
    static let listPadding: CGFloat = 12
    /// The pane's width bounds at 12, and its share of the Git View between them.
    static let designWidthBounds: ClosedRange<Double> = 240...380
    static let widthShare: CGFloat = 0.3

    static func rowHeight(_ size: InterfaceFontSize) -> CGFloat { size(designRowHeight) }

    /// The height a list over the Diff files needs for `rows` rows: its header, its rows and their padding.
    static func listHeight(rows: Int, size: InterfaceFontSize) -> CGFloat {
        size(designHeaderHeight) + CGFloat(max(1, rows)) * rowHeight(size) + listPadding
    }

    /// The pane's width in a Git View `gitViewWidth` wide: its share, inside the scaled bounds. A scaled width never
    /// takes more than half of the Git View, so the diff keeps room beside it. At 12 that limit never applies: the
    /// pane is at most the larger of 240 and its share, as it always was.
    static func paneWidth(in gitViewWidth: CGFloat, size: InterfaceFontSize) -> CGFloat {
        let bounds = size(designWidthBounds)
        let width = min(CGFloat(bounds.upperBound), max(CGFloat(bounds.lowerBound), gitViewWidth * widthShare))
        return min(width, max(CGFloat(designWidthBounds.lowerBound), gitViewWidth / 2))
    }
}
