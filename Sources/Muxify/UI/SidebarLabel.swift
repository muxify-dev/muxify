import AppKit

/// One line of text in the AppKit Sessions list, cut with "…" at its end when it does not fit (ADR 0074). The view
/// draws the text itself. An `NSTextField` label draws through a private subview, and `CALayer.render(in:)`, which
/// the verify driver's `snapshot` uses, draws the text of both: a picture would show the text twice, brighter than
/// the screen does.
final class SidebarLabel: NSView {
    var text = "" {
        didSet {
            if text != oldValue { needsDisplay = true }
        }
    }
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize) {
        didSet {
            if font != oldValue { needsDisplay = true }
        }
    }

    override var isFlipped: Bool { true }

    /// The height of the line, which is what SwiftUI's `Text` takes for one line of the font.
    var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        // The text colour of the appearance that draws, as SwiftUI's primary colour.
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            .draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
