import CoreGraphics
import MuxifyCore

/// The width of a Tab in the Browser's tab strip under the Interface font size (ADR 0067). Tabs share the strip like
/// Chrome's, between a readable least width and a most width; past the least the strip scrolls. A Tab holds its title
/// in that width, so both bounds grow by the factor, and so does the New Tab button beside the Tabs.
enum BrowserTabWidth {
    /// The bounds of a Tab's width at 12.
    static let designBounds: ClosedRange<Double> = 110...220
    /// The strip's padding on each side, and the spacing after each item. They do not scale.
    static let padding: CGFloat = 8
    static let spacing: CGFloat = 4

    static func bounds(_ size: InterfaceFontSize) -> ClosedRange<Double> { size(designBounds) }

    /// The width of each of `tabs` Tabs in a strip `available` points wide, beside the New Tab button.
    static func width(available: CGFloat, tabs: Int, size: InterfaceFontSize) -> CGFloat {
        let count = CGFloat(max(tabs, 1))
        let room = available - 2 * padding - (size(ToolbarIconButton.designSide) + spacing) - spacing * count
        let bounds = bounds(size)
        return min(CGFloat(bounds.upperBound), max(CGFloat(bounds.lowerBound), room / count))
    }
}
