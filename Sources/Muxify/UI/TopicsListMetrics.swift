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
/// rule on each side of its word. Its lengths are design sizes at 12, which grow with the Interface font size.
enum TopicsListLine {
    static let designHeight: CGFloat = 20
    /// The room between the line's ends and the sides of the list's items.
    static let horizontalPadding: CGFloat = 8
    /// The room between the rules and the word.
    static let spacing: CGFloat = 8
    static let fontSize: CGFloat = 11
    /// The rules are this high.
    static let ruleWidth: CGFloat = 1
}
