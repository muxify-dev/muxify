import AppKit

/// The diff's code and the gutters that frame it, from the code font: the Terminal's `font-size` less one point, not
/// the Interface font size (ADR 0068). Each length is in the code font's units, so nothing clips at a large Terminal
/// size:
///
/// - a line-number column fits the widest line number the diff shows, and at least 4 digits, in the line numbers' font,
///   a point smaller than the code, with three quarters of the code's size on each side;
/// - the marker column, which holds a line's `+` or `−`, is one and a half times the code's size;
/// - the bands behind the line numbers span their columns, two in the unified layout and one a side in the split;
/// - the code starts after the marker, and wraps at the pane's edge less its trailing room.
///
/// At the code size 12, from the Terminal's default of 13, these are 46, 18, 92 (46 split) and 110 (64 split) points,
/// the fixed numbers they were, and a 4-digit line number sits where it did.
extension GitView.TextMetrics {
    /// The fewest digits a line-number column holds.
    static let leastDigits = 4
    /// The room on each side of a line number, and the marker column, in units of the code's size.
    static let numberPaddingEms: CGFloat = 0.75
    static let markerEms: CGFloat = 1.5
    /// The line numbers' font is this much smaller than the code's.
    static let numberSizeOffset: CGFloat = 1
    /// The room after the code: its padding.
    static let trailingRoom: CGFloat = 12
    /// A hunk header is a line of code high and this much more: 30 points at 12.
    static let hunkRoom: CGFloat = 11

    init(fontSize: CGFloat, layout: GitView.Layout, width: CGFloat, widestNumber: Int) {
        let charWidth = Self.digitWidth(ofSize: fontSize)
        let digits = max(Self.leastDigits, String(max(0, widestNumber)).count)
        let numberPadding = Self.numberPaddingEms * fontSize
        let numberWidth = (CGFloat(digits) * Self.digitWidth(ofSize: Self.numberSize(fontSize)) + 2 * numberPadding).rounded(.up)
        let markerWidth = (Self.markerEms * fontSize).rounded(.up)
        let isSplit = layout == .split
        let gutterWidth = isSplit ? numberWidth : 2 * numberWidth
        let room = (isSplit ? (width - 1) / 2 : width) - gutterWidth - markerWidth - Self.trailingRoom
        self.init(fontSize: fontSize, charWidth: charWidth, lineHeight: Self.lineHeight(fontSize),
                  columns: max(10, Int(room / charWidth)), numberWidth: numberWidth, numberPadding: numberPadding,
                  markerWidth: markerWidth, gutterWidth: gutterWidth)
    }

    /// The height of a line of code, and of each line it wraps to.
    static func lineHeight(_ fontSize: CGFloat) -> CGFloat { (fontSize * 1.6).rounded() }

    /// The size of the line numbers' font.
    static func numberSize(_ fontSize: CGFloat) -> CGFloat { fontSize - numberSizeOffset }

    /// The size of a hunk header's text: its `@@ … @@` and its context.
    static func hunkSize(_ fontSize: CGFloat) -> CGFloat { fontSize - 0.5 }

    /// The height of a hunk header.
    var hunkHeight: CGFloat { lineHeight + Self.hunkRoom }

    /// The advance of "0" in the system's monospaced font, which is every digit's and every character's of the code.
    /// The font's advance, not a typeset string: `size(withAttributes:)` on every redraw threw from inside CoreText and
    /// ended the app when many apps drew at once.
    static func digitWidth(ofSize size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        var zero = UniChar(48)
        var glyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font as CTFont, &zero, &glyph, 1)
        return font.advancement(forCGGlyph: glyph).width
    }
}
