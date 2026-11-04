import AppKit
import MuxifyCore
import SwiftUI

extension SidebarTypography {
    enum Role: CaseIterable {
        case session, title, section, location, badge

        /// The size at the Interface font size's design size, 12.
        var defaultSize: CGFloat {
            switch self {
            case .session: return 14
            case .title: return 12
            case .section: return 11
            case .location: return 10.5
            case .badge: return 10
            }
        }

        var weight: Font.Weight {
            switch self {
            case .session, .section: return .semibold
            case .badge: return .medium
            case .title, .location: return .regular
            }
        }

        /// NSFontManager's 0–15 weight scale; its lookup chooses the nearest
        /// available weight in a family when there is no exact match.
        var familyWeight: Int {
            switch self {
            case .session, .section: return 8
            case .badge: return 6
            case .title, .location: return 5
            }
        }
    }

    /// The role's size at 12, scaled by the Interface font size: at 12 every role keeps its design size.
    func size(for role: Role) -> CGFloat { fontSize(role.defaultSize) }

    func font(for role: Role,
              lookup: (String, Int, CGFloat) -> NSFont? = Self.lookup) -> Font {
        let size = size(for: role)
        if fontFamily != "system", let font = lookup(fontFamily, role.familyWeight, size) {
            return Font(font)
        }
        return .system(size: size, weight: role.weight)
    }

    /// The AppKit font of `font(for:)`, to measure text before SwiftUI lays it out.
    func nsFont(for role: Role) -> NSFont {
        let size = size(for: role)
        if fontFamily != "system", let font = Self.lookup(family: fontFamily, weight: role.familyWeight, size: size) { return font }
        let weights: [Font.Weight: NSFont.Weight] = [.semibold: .semibold, .medium: .medium, .regular: .regular]
        return .systemFont(ofSize: size, weight: weights[role.weight] ?? .regular)
    }

    static func lookup(family: String, weight: Int, size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: weight, size: size)
    }
}

private struct SidebarTypographyKey: EnvironmentKey {
    static let defaultValue = SidebarTypography()
}

extension EnvironmentValues {
    var sidebarTypography: SidebarTypography {
        get { self[SidebarTypographyKey.self] }
        set { self[SidebarTypographyKey.self] = newValue }
    }
}
