import MuxifyCore
import SwiftUI

extension InterfaceFontSize {
    /// The system font at a design size, scaled: `size.font(13, weight: .medium)` in place of
    /// `.system(size: 13, weight: .medium)`.
    func font(_ designSize: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: self(designSize), weight: weight, design: design)
    }

    /// The control size of a system control, such as a segmented picker, that is regular at 12. A system control
    /// ignores `.font`, so it takes the size macOS draws nearest to its regular height times the factor: large at 15,
    /// and extra large at 18.
    var systemControlSize: ControlSize {
        let height = Self.regularControlHeight * factor
        return Self.controlHeights.min { abs($0.height - height) < abs($1.height - height) }?.size ?? .regular
    }

    /// The heights macOS draws a segmented control at, in points.
    private static let regularControlHeight: CGFloat = 24
    private static let controlHeights: [(size: ControlSize, height: CGFloat)] =
        [(.small, 20), (.regular, regularControlHeight), (.large, 28), (.extraLarge, 36)]
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
