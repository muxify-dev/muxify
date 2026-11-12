import MuxifyCore
import SwiftUI

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
                HStack(spacing: CardTagMetrics.spacing) { ForEach(tags.items) { TagMark(shown: $0.shown) } }
            case .title:
                HStack(spacing: CardTagMetrics.spacing) {
                    if let first = tags.items.first { TagChip(text: first.text, shown: first.shown) }
                    if tags.items.count > 1 { MoreTagsChip(count: tags.items.count - 1) }
                }
            case .line:
                // The widest row that fits: all chips, then one fewer with "+N", down to "+N" alone.
                ViewThatFits(in: .horizontal) {
                    ForEach(tags.lineRows, id: \.self) { shown in
                        HStack(spacing: CardTagMetrics.spacing) {
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
        RoundedRectangle(cornerRadius: CardTagMetrics.markCornerRadius, style: .continuous)
            .fill(shown.definition?.color.color ?? Color.secondary)
            .opacity(shown.definition == nil ? CardTagMetrics.undefinedMarkOpacity : 1)
            .frame(width: CardTagMetrics.markSide(fontSize), height: CardTagMetrics.markSide(fontSize))
    }
}

private struct TagChip: View {
    let text: String
    let shown: ShownTag
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let color = shown.definition?.color.color ?? Color.secondary
        Text(text)
            .font(fontSize.font(CardTagMetrics.chipFontSize, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, CardTagMetrics.chipHorizontalPadding)
            .padding(.vertical, CardTagMetrics.chipVerticalPadding)
            .background(RoundedRectangle(cornerRadius: CardTagMetrics.chipCornerRadius, style: .continuous)
                .fill(color.opacity(CardTagMetrics.chipFillOpacity)))
            .opacity(shown.definition == nil ? CardTagMetrics.undefinedChipOpacity : 1)
            .fixedSize()
    }
}

private struct MoreTagsChip: View {
    let count: Int
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        Text("+\(count)")
            .font(fontSize.font(CardTagMetrics.chipFontSize, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, CardTagMetrics.moreHorizontalPadding)
            .padding(.vertical, CardTagMetrics.chipVerticalPadding)
            .background(RoundedRectangle(cornerRadius: CardTagMetrics.chipCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(CardTagMetrics.moreFillOpacity)))
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
                        .accessibilityIdentifier(tags.accessibilityID)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }
}
