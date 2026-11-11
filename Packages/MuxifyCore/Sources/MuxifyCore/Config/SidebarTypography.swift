#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// Sidebar text keeps its existing hierarchy around the Interface font size, in the Sidebar font family.
/// Symbols, logos and status dots deliberately do not use this typography.
public struct SidebarTypography: Equatable {
    /// The base of every role: `ui.font_size`.
    public var fontSize = InterfaceFontSize()
    /// `ui.sidebar.font_family`.
    public var fontFamily: String = "system"

    public init(fontSize: InterfaceFontSize = InterfaceFontSize(), fontFamily: String = "system") {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }

    #if canImport(AppKit)
    public static var fontFamilies: [String] { NSFontManager.shared.availableFontFamilies }
    #endif

    /// The families a Config may name, or nil where there is no font catalogue (Linux): there any named family is
    /// accepted, so a Config shared from a Mac reads.
    public static var knownFontFamilies: [String]? {
        #if canImport(AppKit)
        fontFamilies
        #else
        nil
        #endif
    }

    /// Preserve native system-font selection instead of naming a particular
    /// system face. The catalogue is injectable without requiring test fonts; a nil catalogue accepts any name.
    public static func canonicalFamily(_ name: String,
                                       families: () -> [String]? = { Self.knownFontFamilies }) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if name.caseInsensitiveCompare("system") == .orderedSame { return "system" }
        guard let families = families() else { return name }
        return families.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
