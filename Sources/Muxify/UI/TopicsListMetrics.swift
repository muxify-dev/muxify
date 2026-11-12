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
