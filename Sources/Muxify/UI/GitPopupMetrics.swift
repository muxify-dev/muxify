import CoreGraphics
import MuxifyCore

/// The Git View's popups under the Interface font size (ADR 0067): the commit box, a Git View menu and a Git View
/// prompt. Their text grows by the factor, and so do the widths and heights that hold it. A popup's width never takes
/// more than the Git View shows, less its margins, so it never leaves the App Window.
enum GitPopupMetrics {
    /// Each popup's width at 12.
    static let designCommitBoxWidth: CGFloat = 620
    static let designMenuWidth: CGFloat = 460
    static let designPromptWidth: CGFloat = 520
    /// The room a popup leaves beside it in the Git View, on both sides together. It does not scale.
    static let margin: CGFloat = 48
    /// A row of the commit box's list of staged files.
    static let designFileRowHeight: CGFloat = 24
    /// The rows that list shows before it scrolls.
    static let visibleFileRows: CGFloat = 4.5

    /// The width of a popup `designWidth` wide at 12, in a Git View `gitViewWidth` wide.
    static func width(_ designWidth: CGFloat, in gitViewWidth: CGFloat, size: InterfaceFontSize) -> CGFloat {
        min(size(designWidth), gitViewWidth - margin)
    }

    static func fileRowHeight(_ size: InterfaceFontSize) -> CGFloat { size(designFileRowHeight) }

    /// The height of the commit box's list of `files` staged files: up to 4.5 rows, and it scrolls past them.
    static func fileListHeight(files: Int, size: InterfaceFontSize) -> CGFloat {
        min(CGFloat(files), visibleFileRows) * fileRowHeight(size)
    }
}
