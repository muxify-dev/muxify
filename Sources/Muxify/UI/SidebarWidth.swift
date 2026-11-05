import CoreGraphics
import MuxifyCore

/// The Sidebar's width under the Interface font size (ADR 0068). Its resize bounds and its default width scale by the
/// factor. A width the user dragged stays as dragged, pulled inside the scaled bounds only when it falls outside them.
enum SidebarWidth {
    /// The resize bounds at 12.
    static let designBounds: ClosedRange<Double> = 180...420
    /// The width at 12 of a Sidebar the user never dragged.
    static let designDefault: Double = 260

    static func bounds(_ size: InterfaceFontSize) -> ClosedRange<Double> { size(designBounds) }

    /// The width the Sidebar shows: `dragged`, the width a drag stored, or the scaled default when there is none.
    static func shown(dragged: Double?, size: InterfaceFontSize) -> Double {
        let bounds = bounds(size)
        return min(max(dragged ?? Double(size(CGFloat(designDefault))), bounds.lowerBound), bounds.upperBound)
    }
}
