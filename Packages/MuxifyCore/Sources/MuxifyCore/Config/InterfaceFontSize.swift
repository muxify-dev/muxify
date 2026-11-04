import CoreGraphics

/// `ui.font_size`: the size in points that all of Muxify's own text in an App Window keeps its ratio to (ADR 0067).
/// Every surface gives its sizes as they are at 12, its design sizes, and takes them through this value: fonts, the
/// symbols beside text, and the fixed heights and widths that hold text. Paddings and spacing do not scale.
public struct InterfaceFontSize: Equatable, Sendable {
    /// The size every surface is designed at, and the default.
    public static let design: Double = 12
    /// The sizes `ui.font_size` accepts.
    public static let range: ClosedRange<Double> = 9...24

    /// In macOS points, like Ghostty's `font-size`.
    public var points: Double

    public init(_ points: Double = InterfaceFontSize.design) {
        self.points = points
    }

    /// How much every design size grows: `points / 12`.
    public var factor: CGFloat { CGFloat(points / Self.design) }

    /// The size of a font, a symbol or a fixed length whose design size, at 12, is `designSize`.
    public func callAsFunction(_ designSize: CGFloat) -> CGFloat { designSize * factor }

    /// A range of lengths at 12, such as a panel's resize bounds, at this size.
    public func callAsFunction(_ designRange: ClosedRange<Double>) -> ClosedRange<Double> {
        Double(self(CGFloat(designRange.lowerBound)))...Double(self(CGFloat(designRange.upperBound)))
    }
}
