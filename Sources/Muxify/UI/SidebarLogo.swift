import AppKit

/// The logos of programs in `Resources/Logos` (`<name>.svg` or `<name>.png`), for SwiftUI's `Logo` and for the AppKit
/// Sessions list (ADR 0074).
@MainActor enum LogoImages {
    /// The system symbol in place of a logo when the bundle has not even the terminal logo, at this share of the
    /// logo's side.
    static let fallbackSymbol = "terminal"
    static let fallbackScale: CGFloat = 11 / 14

    /// Logos in black only, which draw in the text colour so they stay visible on a dark theme.
    private static let monochrome: Set<String> = ["pi"]
    /// Looked up once per name; nil when the bundle has no logo for it.
    private static var cache: [String: NSImage?] = [:]

    /// The logo of `name`, or the terminal logo when there is none. On a dark theme `<name>.dark` wins when there is one.
    static func image(_ name: String, dark: Bool) -> NSImage? {
        (dark ? image(name + ".dark") : nil) ?? image(name) ?? image("terminal")
    }

    static func isMonochrome(_ name: String) -> Bool { monochrome.contains(name) }

    private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let url = name.isEmpty ? nil : ["svg", "png"].lazy
            .compactMap { Bundle.main.url(forResource: name, withExtension: $0) }.first
        let image = url.flatMap(NSImage.init(contentsOf:))
        cache[name] = image
        return image
    }
}

/// A program's logo in the AppKit Sessions list (ADR 0074), as SwiftUI's `Logo` draws it: fitted in a square, in its
/// own colours, or in the text colour for a logo in black only.
final class SidebarLogo: NSView {
    var name = "" {
        didSet {
            if name != oldValue { needsDisplay = true }
        }
    }
    /// The side of the square.
    var side = WindowRowMetrics.iconSize {
        didSet {
            if side != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let image = LogoImages.image(name, dark: dark), image.size.width > 0, image.size.height > 0 else {
            return drawFallback()
        }
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        guard LogoImages.isMonochrome(name) else {
            return image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
        }
        let ink = NSColor.labelColor
        let inked = NSImage(size: size, flipped: false) { frame in
            image.draw(in: frame)
            ink.set()
            frame.fill(using: .sourceIn)
            return true
        }
        inked.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
    }

    /// The terminal symbol, in the secondary text colour, in the middle of the square.
    private func drawFallback() {
        guard let symbol = NSImage(systemSymbolName: LogoImages.fallbackSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: side * LogoImages.fallbackScale, weight: .regular)) else { return }
        let ink = NSColor.secondaryLabelColor
        let inked = NSImage(size: symbol.size, flipped: false) { frame in
            symbol.draw(in: frame)
            ink.set()
            frame.fill(using: .sourceIn)
            return true
        }
        let rect = NSRect(x: (bounds.width - symbol.size.width) / 2, y: (bounds.height - symbol.size.height) / 2,
                          width: symbol.size.width, height: symbol.size.height)
        inked.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
