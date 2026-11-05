import AppKit
import MuxifyCore
import SwiftUI

/// The Tags a Topic card shows: one item for each pass of the `topic.tags` Format's `T` loop, and where they go.
struct CardTags {
    struct Item: Identifiable {
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
}

/// The Tags of a card where its `placement` puts them. A card header lays out a hidden copy, so the Tags take room
/// in the header's lines, and the card draws this view over that copy as its own accessibility element
/// (`cardTagsOverlay`): the header is one element that hides its children, and its accessibility modifiers would
/// also name the Tags.
struct CardTagsView: View {
    let tags: CardTags

    var body: some View {
        Group {
            switch tags.placement {
            case .none:
                EmptyView()
            case .corner:
                HStack(spacing: 3) { ForEach(tags.items) { TagMark(shown: $0.shown) } }
            case .title:
                HStack(spacing: 3) {
                    if let first = tags.items.first { TagChip(text: first.text, shown: first.shown) }
                    if tags.items.count > 1 { MoreTagsChip(count: tags.items.count - 1) }
                }
            case .line:
                // The widest row that fits: all chips, then one fewer with "+N", down to "+N" alone.
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(stride(from: tags.items.count, through: 0, by: -1)), id: \.self) { shown in
                        HStack(spacing: 3) {
                            ForEach(tags.items.prefix(shown)) { TagChip(text: $0.text, shown: $0.shown) }
                            if shown < tags.items.count { MoreTagsChip(count: tags.items.count - shown) }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: tags.placement != .line, vertical: true)
    }
}

/// One Tag of a card in the `corner` placement: a small rounded square in the Tag's colour. The Unread mark is a
/// circle, so the two do not look alike.
struct TagMark: View {
    let shown: ShownTag
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(shown.definition?.color.color ?? Color.secondary)
            .opacity(shown.definition == nil ? 0.35 : 1)
            .frame(width: fontSize(8), height: fontSize(8))
    }
}

private struct TagChip: View {
    let text: String
    let shown: ShownTag
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let color = shown.definition?.color.color ?? Color.secondary
        Text(text)
            .font(fontSize.font(10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.16)))
            .opacity(shown.definition == nil ? 0.55 : 1)
            .fixedSize()
    }
}

private struct MoreTagsChip: View {
    let count: Int
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text("+\(count)")
            .font(fontSize.font(10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.08)))
            .fixedSize()
    }
}

/// Where the hidden copy of a card's Tags sits in the header.
struct CardTagsAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The room for a card's Tags in a header line.
struct CardTagsSlot: View {
    let tags: CardTags

    var body: some View {
        CardTagsView(tags: tags).hidden().accessibilityHidden(true)
            .anchorPreference(key: CardTagsAnchor.self, value: .bounds) { $0 }
    }
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
}

extension View {
    /// Draws the Tags over their slot, as one accessibility element with the Tag names and a hover label. Above the
    /// header, they take its clicks, so a click on them does what a click on the header does.
    func cardTagsOverlay(_ tags: CardTags?, onPress: @escaping () -> Void) -> some View {
        overlayPreferenceValue(CardTagsAnchor.self) { anchor in
            if let tags, let anchor {
                GeometryReader { proxy in
                    let rect = proxy[anchor]
                    CardTagsView(tags: tags)
                        .frame(width: rect.width, height: rect.height)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onPress)
                        .help(tags.names)
                        .accessibilityElement(children: .ignore)
                        // A static text element carries its value into the accessibility tree.
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel("Tags")
                        .accessibilityValue(tags.names)
                        .accessibilityIdentifier("tags-" + tags.identifier)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }
}
