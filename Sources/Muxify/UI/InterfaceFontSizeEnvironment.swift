import MuxifyCore
import SwiftUI

extension InterfaceFontSize {
    /// The system font at a design size, scaled: `size.font(13, weight: .medium)` in place of
    /// `.system(size: 13, weight: .medium)`.
    func font(_ designSize: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: self(designSize), weight: weight, design: design)
    }

    /// A text style, such as `.caption`, at the point size macOS gives it times the factor: `size.font(.caption)` in
    /// place of `.caption`. At 12 it is the text style itself. A `weight` or `design` applies as on the text style.
    func font(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        if factor == 1 { return .system(style, design: design, weight: weight) }
        let designFont = style.designFont
        return .system(size: self(designFont.size), weight: weight ?? designFont.weight, design: design)
    }

    /// The control size of a system control, such as a segmented picker, that is regular at 12. A system control
    /// ignores `.font`, so it takes the size macOS draws nearest to its regular height times the factor: large at 15,
    /// and extra large at 18.
    var systemControlSize: ControlSize { systemControlSize(at: .regular) }

    /// The control size of a system control that is `designSize` at 12, such as a find bar's small field and buttons:
    /// the size macOS draws nearest to that size's height times the factor.
    func systemControlSize(at designSize: ControlSize) -> ControlSize {
        let designHeight = Self.controlHeights.first { $0.size == designSize }?.height ?? Self.regularControlHeight
        let height = designHeight * factor
        return Self.controlHeights.min { abs($0.height - height) < abs($1.height - height) }?.size ?? designSize
    }

    /// The heights macOS draws a segmented control at, in points.
    private static let regularControlHeight: CGFloat = 24
    private static let controlHeights: [(size: ControlSize, height: CGFloat)] =
        [(.small, 20), (.regular, regularControlHeight), (.large, 28), (.extraLarge, 36)]
}

extension Font.TextStyle {
    /// The point size and weight macOS draws this text style at, which an App Window at 12 shows: a caption is 10
    /// points, a headline 13 and bold. A style macOS adds later is taken as the body's.
    var designFont: (size: CGFloat, weight: Font.Weight) {
        switch self {
        case .largeTitle: (26, .regular)
        case .title: (22, .regular)
        case .title2: (17, .regular)
        case .title3: (15, .regular)
        case .headline: (13, .bold)
        case .subheadline: (11, .regular)
        case .callout: (12, .regular)
        case .footnote, .caption: (10, .regular)
        case .caption2: (10, .medium)
        default: (13, .regular)
        }
    }
}

private struct InterfaceFontSizeKey: EnvironmentKey {
    static let defaultValue = InterfaceFontSize()
}

extension EnvironmentValues {
    /// The Interface font size of the App Window, from its own Config: its Remote Environment's when that machine has
    /// one (ADR 0010, ADR 0067). The App Window's root sets it, so everything under it reads one value.
    var interfaceFontSize: InterfaceFontSize {
        get { self[InterfaceFontSizeKey.self] }
        set { self[InterfaceFontSizeKey.self] = newValue }
    }
}
