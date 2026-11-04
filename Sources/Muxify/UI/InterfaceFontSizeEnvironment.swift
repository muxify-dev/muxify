import MuxifyCore
import SwiftUI

extension InterfaceFontSize {
    /// The system font at a design size, scaled: `size.font(13, weight: .medium)` in place of
    /// `.system(size: 13, weight: .medium)`.
    func font(_ designSize: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: self(designSize), weight: weight, design: design)
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
