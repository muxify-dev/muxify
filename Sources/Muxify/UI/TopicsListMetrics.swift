import CoreGraphics
import MuxifyCore

/// Where the Topics list puts its items, for both versions of the list
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md).
enum TopicsListMetrics {
    /// The gap between two items: cards, lines and Open Places.
    static let itemSpacing: CGFloat = 6
    /// The room between the items and the sides of the list.
    static let horizontalInset: CGFloat = 6
    /// The room above the first item and below the last.
    static let verticalInset: CGFloat = 4
}

/// A line of the Topics list between its cards, the Guests line and the Bench line, for both versions of the list: a
/// rule on each side of its word, and on the Bench line a chevron after the word. Its lengths are design sizes at 12,
/// which grow with the Interface font size.
enum TopicsListLine {
    static let designHeight: CGFloat = 20
    /// The room between the line's ends and the sides of the list's items.
    static let horizontalPadding: CGFloat = 8
    /// The room between the rules, the word and the chevron.
    static let spacing: CGFloat = 8
    static let fontSize: CGFloat = 11
    /// The rules are this high.
    static let ruleWidth: CGFloat = 1
    /// The chevron of the Bench line is bold, at this size.
    static let chevronFontSize: CGFloat = 9

    /// The word of the Bench line, which says what a press on it does.
    static func benchWord(isBenchShown: Bool) -> String { isBenchShown ? "Hide Bench" : "Bench" }

    /// The chevron of the Bench line: up while the Bench shows, down while it is hidden.
    static func benchChevron(isBenchShown: Bool) -> String { isBenchShown ? "chevron.up" : "chevron.down" }
}

/// An Open Place of the Topics list, an In Play place that no card fills, for both versions of the list: a plus in a
/// circle and its word in the secondary text colour, in a dashed border. Its lengths are design sizes at 12, which grow
/// with the Interface font size, except the border's.
enum OpenPlaceMetrics {
    static let designHeight: CGFloat = 32
    /// The room between the border and the plus.
    static let horizontalPadding: CGFloat = 10
    /// The room between the plus, the word and the Hint.
    static let spacing: CGFloat = 6
    static let cornerRadius: CGFloat = 9
    /// The plus is semibold, at this size.
    static let symbol = "plus.circle"
    static let symbolFontSize: CGFloat = 11
    /// The word is medium, at this size.
    static let word = "Open Place"
    static let fontSize: CGFloat = 12
    /// The border is the secondary text colour at `borderOpacity`, `borderWidth` wide, in dashes of `dash`.
    static let borderWidth: CGFloat = 1
    static let borderOpacity = 0.5
    static let dash: [CGFloat] = [5, 4]

    /// The Open Place's name to accessibility, with its number from 1.
    static func label(place: Int) -> String { "\(word) \(place)" }
}

/// The pills over the edges of the Topics list, "N more above" and "N more below", for both versions of the list: an
/// arrow and the count in the secondary text colour, on a capsule of the Sidebar's chrome with a faint fill and border
/// of the text colour, over a shadow. The capsule lies in a band that holds it and the room for its shadow, and slides
/// in from the band's edge. Its lengths are design sizes at 12, which grow with the Interface font size, except the
/// band's margin, the border and the shadow.
enum EdgePillMetrics {
    enum Edge {
        case top, bottom
    }

    /// The band the pill lies in at 12: the pill and the room around it for its shadow. It holds the pill's text, so
    /// it grows with the Interface font size; the Bench's geometry keeps a card it reveals under the band at that size.
    static let designHeight: CGFloat = 30
    /// The room around the pill for its shadow, which does not grow.
    static let margin: CGFloat = 4
    /// The room between the capsule's ends and its arrow and count.
    static let horizontalPadding: CGFloat = 10
    /// The room between the arrow and the count.
    static let spacing: CGFloat = 4
    /// The arrow is bold, at this size.
    static let symbolFontSize: CGFloat = 9
    /// The count is semibold, at this size.
    static let fontSize: CGFloat = 11
    /// The text colour at this opacity fills the capsule over the chrome, as an open card's surface.
    static let fillOpacity = 0.08
    /// The border is the text colour at this opacity, this wide, inside the capsule's edge.
    static let borderOpacity = 0.08
    static let borderWidth: CGFloat = 1
    /// The shadow is black at this opacity, with this radius, and falls this far below the capsule.
    static let shadowOpacity = 0.22
    static let shadowRadius: CGFloat = 4
    static let shadowDrop: CGFloat = 1

    static func height(_ size: InterfaceFontSize) -> CGFloat { size(designHeight) }

    static func symbol(_ edge: Edge) -> String { edge == .top ? "arrow.up" : "arrow.down" }

    /// The words of the pill.
    static func text(count: Int) -> String { "\(count) more" }

    /// The pill's name to accessibility, "N more above" or "N more below".
    static func label(_ edge: Edge, count: Int) -> String { text(count: count) + (edge == .top ? " above" : " below") }

    static func identifier(_ edge: Edge) -> String { edge == .top ? "topics-more-above" : "topics-more-below" }

    /// How far the pill stands down from its place in its band of `height`, once it has come `slide` points in from
    /// its edge: from a whole band above it at the top, or below it at the bottom, to none.
    static func offset(_ edge: Edge, slide: CGFloat, height: CGFloat) -> CGFloat {
        edge == .top ? min(slide, height) - height : height - min(slide, height)
    }
}
