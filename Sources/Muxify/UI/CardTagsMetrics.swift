import AppKit
import MuxifyCore

// What both versions of a Topic card read for its Tags (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md):
// the Tags a card shows, their sizes, and where a title that shares its first line with Tag chips breaks. SwiftUI draws
// them with `CardTagsView` in CardTags.swift, AppKit with `SidebarTagsView`.

/// The Tags a Topic card shows: one item for each pass of the `topic.tags` Format's `T` loop, and where they go.
struct CardTags: Equatable {
    struct Item: Identifiable, Equatable {
        let shown: ShownTag
        /// What the Format gave: a chip's text, or a Tag Mark's hover text.
        let text: String
        var id: String { shown.tag.name }
    }

    let placement: Config.Sidebar.TagPlacement
    let items: [Item]
    /// The Topic's accessibility id, so a check finds the Tags of one card.
    let identifier: String

    /// Every Tag, for the hover label and the accessibility value, also those a "+N" chip stands for.
    var names: String { items.map(\.text).joined(separator: ", ") }

    /// The accessibility identifier of the Tags of the card: `tags-` and the Topic's accessibility id.
    var accessibilityID: String { "tags-" + identifier }

    /// The number of chips that each row of the `line` placement shows, from the widest: all chips, then one fewer with
    /// "+N", down to "+N" alone. The card shows the first row that fits, else the last.
    var lineRows: [Int] { Array(stride(from: items.count, through: 0, by: -1)) }
}

/// The sizes of a card's Tags. A length is a design size at 12 where it grows with the Interface font size.
enum CardTagMetrics {
    /// The room between two Tag Marks or two chips.
    static let spacing: CGFloat = 3
    /// The side of a Tag Mark, at 12.
    static let designMarkSide: CGFloat = 8
    static let markCornerRadius: CGFloat = 2
    /// A Tag that the Config no longer defines has no colour: its Tag Mark is dimmed to this opacity.
    static let undefinedMarkOpacity = 0.35
    /// The text of a chip and of "+N", at 12, in the medium weight.
    static let chipFontSize: CGFloat = 10
    static let chipHorizontalPadding: CGFloat = 5
    static let moreHorizontalPadding: CGFloat = 4
    static let chipVerticalPadding: CGFloat = 1
    static let chipCornerRadius: CGFloat = 4
    /// A chip's fill is its Tag's colour at this opacity.
    static let chipFillOpacity = 0.16
    /// A chip of a Tag that the Config no longer defines is dimmed to this opacity.
    static let undefinedChipOpacity = 0.55
    /// The fill of "+N" is the text colour at this opacity.
    static let moreFillOpacity = 0.08

    static func markSide(_ size: InterfaceFontSize) -> CGFloat { size(designMarkSide) }
}

/// Where a title that shares its first line with Tag chips breaks: the words that fit in `width`, and the rest.
enum TitleLines {
    static func split(_ title: String, font: NSFont, width: CGFloat) -> (first: String, rest: String) {
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: font]))
        let count = CTTypesetterSuggestLineBreak(typesetter, 0, Double(max(width, 0)))
        let text = title as NSString
        guard count < text.length else { return (title, "") }
        return (text.substring(to: count).trimmingCharacters(in: .whitespaces), text.substring(from: count).trimmingCharacters(in: .whitespaces))
    }

    /// The room of the title's first line: the title line, less the place of the card's Hint, the marks and Tags at its
    /// end, the gaps after the title, after the Hint and before the marks, and 2 points against rounding.
    static func firstLineRoom(lineWidth: CGFloat, hintWidth: CGFloat, endWidth: CGFloat) -> CGFloat {
        lineWidth - hintWidth - endWidth - 3 * CardHeaderSpacing.titleLine - 2
    }
}
