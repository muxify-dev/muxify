import CoreGraphics

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
