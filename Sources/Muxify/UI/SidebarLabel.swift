import AppKit
import CoreText
import MuxifyCore

/// The colour of a text or a symbol in the AppKit Sessions list (ADR 0074): the text colour of the appearance that
/// draws, as SwiftUI's primary and secondary styles.
enum SidebarInk: Equatable {
    case primary, secondary
    /// The accent colour, as SwiftUI's `Color.accentColor`.
    case accent
    /// The text colour at an opacity, as `Color.primary.opacity`.
    case faded(Double)
    /// The colour of a link, as SwiftUI's link button draws its title, and of a disabled one.
    case link, disabledLink
    /// The yellow of a Topic Note.
    case note
    /// A colour of the Config, such as a Tag's, which can differ in the light and the dark appearance.
    case mark(MarkColor)
    /// The trade colour of a list's drag (`NSColor.tradeMark`), and white on it.
    case trade, onTrade

    /// The colour in the appearance that draws now.
    var color: NSColor {
        switch self {
        case .primary: return .labelColor
        case .secondary: return .secondaryLabelColor
        case .accent: return .controlAccentColor
        case .faded(let opacity): return NSColor.labelColor.faded(opacity)
        case .link: return .linkColor
        case .disabledLink: return .disabledControlTextColor
        case .note: return .cardNote
        case .mark(let color): return color.nsColor(in: NSAppearance.currentDrawing())
        case .trade: return .tradeMark
        case .onTrade: return .white
        }
    }
}

extension NSColor {
    /// The colour at an opacity of its own, as SwiftUI's `Color.opacity`. Call it in the appearance that draws.
    func faded(_ opacity: Double) -> NSColor { withAlphaComponent(alphaComponent * opacity) }
}

extension NSImage {
    /// The image's shape in one colour: the ink stays only where the image is, as SwiftUI draws a template image in its
    /// foreground style. The new image is `size` big, the image's own size when nil, and the image fills it.
    func inked(_ ink: NSColor, size: NSSize? = nil) -> NSImage {
        NSImage(size: size ?? self.size, flipped: false) { rect in
            self.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}

extension CGFloat {
    /// The length in whole pixels, not shorter: SwiftUI gives a text this room.
    func roundedUp(toPixelsOf scale: CGFloat) -> CGFloat { (self * scale - 0.001).rounded(.up) / scale }

    /// The nearest place on a pixel, where SwiftUI puts a view.
    func rounded(toPixelsOf scale: CGFloat) -> CGFloat { (self * scale).rounded() / scale }
}

/// A text laid out as SwiftUI's `Text` lays it out (ADR 0074): on one line, cut with "…" at its end when the line is
/// too long for its room, or wrapped onto the lines it needs. Core Text makes the lines, so the layout cuts and
/// wraps where SwiftUI does, and the AppKit list measures the same room for a title as the SwiftUI list.
struct SidebarTextLayout {
    let lines: [CTLine]
    /// The room the text takes: its widest line, and all of its lines. An empty text takes one line.
    let size: NSSize
    let lineHeight: CGFloat
    /// The baseline of the first line, from the top.
    private let baseline: CGFloat

    /// The lines draw in the fill colour of their context, which is the colour of the appearance that draws.
    private static let inkFromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)

    /// Lays `text` out in a room `width` wide. A text that does not wrap takes one line.
    init(_ text: String, font: NSFont, width: CGFloat = .greatestFiniteMagnitude, wraps: Bool = false, scale: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, Self.inkFromContext: true]
        let string = NSAttributedString(string: text, attributes: attributes)
        var lines: [CTLine] = []
        if wraps {
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            var start = 0
            while start < string.length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
                lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                start += count
            }
        } else if string.length > 0 {
            let line = CTLineCreateWithAttributedString(string)
            if CTLineGetTypographicBounds(line, nil, nil, nil) <= Double(width) {
                lines = [line]
            } else {
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                lines = CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis).map { [$0] } ?? []
            }
        }
        self.lines = lines
        lineHeight = Self.lineHeight(of: font, scale: scale)
        baseline = Self.baseline(of: font)
        // A line counts the space it ends with, as far as its room goes.
        let widest = CGFloat(lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 0)
        size = NSSize(width: min(widest.roundedUp(toPixelsOf: scale), max(0, width)), height: CGFloat(max(1, lines.count)) * lineHeight)
    }

    /// The height of one line of the font, which is what SwiftUI's `Text` takes for it. The system font has line
    /// heights of its own, which its metrics do not give: 14 points at 11, where its ascender and descender sum to 13.
    static func lineHeight(of font: NSFont, scale: CGFloat) -> CGFloat {
        NSAttributedString(string: " ", attributes: [.font: font])
            .boundingRect(with: .zero, options: .usesLineFragmentOrigin).height.roundedUp(toPixelsOf: scale)
    }

    /// Where SwiftUI's `Text` draws the first baseline under its top: where TextKit puts it in a line of the font, a
    /// whole point. The font's ascender gives the same place at a whole font size, and half a point lower at some
    /// others, such as the 11.5 points of a Topic Note.
    static func baseline(of font: NSFont) -> CGFloat { typesetter.defaultBaselineOffset(for: font) }

    private static let typesetter = NSLayoutManager()

    /// Draws the lines from `origin`, the top left corner of the text, in the current context of a flipped view.
    func draw(at origin: NSPoint, ink: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setFillColor(ink.cgColor)
        // The view counts down from its top, and Core Text draws its glyphs upward.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: origin.x, y: origin.y + baseline + CGFloat(index) * lineHeight)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }
}

/// A text in the AppKit Sessions list (ADR 0074): on one line, cut with "…" at its end when it does not fit, or
/// wrapped so that it shows whole. The view draws the text itself. An `NSTextField` label draws through a private
/// subview, and `CALayer.render(in:)`, which the verify driver's `snapshot` uses, draws the text of both: a picture
/// would show the text twice, brighter than the screen does.
final class SidebarLabel: NSView {
    var text = "" {
        didSet {
            if text != oldValue { changed() }
        }
    }
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize) {
        didSet {
            if font != oldValue { changed() }
        }
    }
    /// The text wraps onto the lines it needs. False keeps it on one line.
    var wraps = false {
        didSet {
            if wraps != oldValue { changed() }
        }
    }
    var ink = SidebarInk.primary {
        didSet {
            if ink != oldValue { needsDisplay = true }
        }
    }
    /// The pixels in a point on the display.
    var scale: CGFloat = 2 {
        didSet {
            if scale != oldValue { changed() }
        }
    }
    /// The layout of the last `fit`, which the view draws, and the room it was made for.
    private var fitted: (width: CGFloat, layout: SidebarTextLayout)?

    override var isFlipped: Bool { true }

    /// Lays the text out in a room `width` wide, and returns the room it takes. The view draws this layout.
    func fit(width: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        if let fitted, fitted.width == width { return fitted.layout.size }
        let layout = SidebarTextLayout(text, font: font, width: width, wraps: wraps, scale: scale)
        fitted = (width, layout)
        needsDisplay = true
        return layout.size
    }

    /// The height of one line of the font.
    var lineHeight: CGFloat { SidebarTextLayout.lineHeight(of: font, scale: scale) }

    private func changed() {
        fitted = nil
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if fitted == nil { _ = fit(width: bounds.width) }
        fitted?.layout.draw(at: .zero, ink: ink.color)
    }
}

/// A system symbol in the AppKit Sessions list (ADR 0074), in the room that SwiftUI's `Image(systemName:)` takes at
/// a font size. As a row of its own to accessibility, its frame is its glyph's, as SwiftUI gives it.
final class SidebarSymbol: NSView {
    let name: String
    /// The font size of the symbol, in points.
    var pointSize: CGFloat = 0 {
        didSet {
            if pointSize != oldValue { changed() }
        }
    }
    var weight = NSFont.Weight.regular {
        didSet {
            if weight != oldValue { changed() }
        }
    }
    var ink = SidebarInk.secondary {
        didSet {
            if ink != oldValue { needsDisplay = true }
        }
    }
    /// The pixels in a point on the display.
    var scale: CGFloat = 2 {
        didSet {
            if scale != oldValue { changed() }
        }
    }
    private var image: NSImage?

    init(_ name: String) {
        self.name = name
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private func changed() {
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
        needsDisplay = true
    }

    /// The room the symbol takes. AppKit gives a symbol's size in whole points, and SwiftUI in whole pixels: where the
    /// symbol is lower than AppKit's whole point says, AppKit added the rest above it. The symbol's own measures,
    /// the height of a capital letter and the room under the baseline, which is also the room above the capital, tell.
    var symbolSize: NSSize {
        guard let image else { return .zero }
        let measures = image.alignmentRect
        let added = measures.height + 2 * measures.minY < image.size.height ? 1 - 1 / scale : 0
        return NSSize(width: measures.width.roundedUp(toPixelsOf: scale), height: image.size.height - added)
    }

    /// The symbol's baseline, from the top of the room it takes: SwiftUI stands it on a text's baseline in a row that
    /// aligns their first baselines. The room under the baseline is the bottom of the symbol's measures.
    var baseline: CGFloat {
        guard let image else { return 0 }
        return symbolSize.height - image.alignmentRect.minY
    }

    /// Where the glyph stands in the view: the room the symbol takes has some space around it. SwiftUI gives this as
    /// the frame of the image's accessibility row.
    var glyphFrame: NSRect {
        guard let image else { return .zero }
        let key = "\(name) \(pointSize) \(weight.rawValue) \(scale)"
        let glyph = Self.glyphs[key] ?? Self.glyph(of: image, scale: scale)
        Self.glyphs[key] = glyph
        return glyph.offsetBy(dx: 0, dy: symbolSize.height - image.size.height)
    }

    /// The glyph's frame in each image that a symbol view drew, from the image's top left corner.
    private static var glyphs: [String: NSRect] = [:]

    /// The frame of the pixels that the image covers, from its top left corner, at the display's scale.
    private static func glyph(of image: NSImage, scale: CGFloat) -> NSRect {
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: width * 4, bitsPerPixel: 32) else { return .zero }
        // The size in points first: the context then draws a point on `scale` pixels.
        bitmap.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap), let pixels = bitmap.bitmapData else { return .zero }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var left = width, top = height, right = -1, bottom = -1
        // The bitmap's rows count down from its top.
        for row in 0..<height {
            for column in 0..<width where pixels[(row * width + column) * 4 + 3] > 0 {
                left = min(left, column)
                right = max(right, column)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        guard right >= left else { return .zero }
        return NSRect(x: CGFloat(left) / scale, y: CGFloat(top) / scale,
                      width: CGFloat(right - left + 1) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(glyphFrame, to: nil))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let inked = image.inked(ink.color)
        // The symbol stands on the bottom left corner of AppKit's image.
        inked.draw(in: NSRect(x: 0, y: symbolSize.height - image.size.height, width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
