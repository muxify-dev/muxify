import CoreGraphics
import MuxifyCore

/// The Command Palette under the Interface font size (ADR 0068). Its rows and section headers hold text in fixed
/// heights, and the palette holds it in a fixed width, so their design sizes at 12 grow by the factor. The list still
/// shows six and a half rows before it scrolls, and the palette never takes more than the App Window shows, less its
/// margins.
enum PaletteMetrics {
    /// A row of the list.
    static let designRowHeight: CGFloat = 52
    /// A section's header above its rows, such as "Topics".
    static let designHeaderHeight: CGFloat = 24
    /// The rows the list shows before it scrolls: a half row shows there is more.
    static let visibleRows: CGFloat = 6.5
    /// The palette's width at 12.
    static let designWidth: CGFloat = 700
    /// The room the palette leaves beside it in the App Window, on both sides together. It does not scale.
    static let margin: CGFloat = 48

    static func rowHeight(_ size: InterfaceFontSize) -> CGFloat { size(designRowHeight) }

    static func headerHeight(_ size: InterfaceFontSize) -> CGFloat { size(designHeaderHeight) }

    /// The height of a list of `rows` rows under `headers` section headers: all of them, up to six and a half rows.
    static func listHeight(rows: Int, headers: Int, size: InterfaceFontSize) -> CGFloat {
        let height = CGFloat(rows) * rowHeight(size) + CGFloat(headers) * headerHeight(size)
        return min(height, visibleRows * rowHeight(size))
    }

    /// The palette's width in an App Window of `windowSize`. A Pill takes the same width.
    static func width(in windowSize: CGSize, size: InterfaceFontSize) -> CGFloat {
        min(size(designWidth), windowSize.width - margin)
    }
}
