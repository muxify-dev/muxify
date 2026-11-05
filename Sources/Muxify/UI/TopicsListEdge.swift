import MuxifyCore
import SwiftUI

extension View {
    /// Calls `action` with where this view stands against the visible part of the scroll view whose coordinate space is
    /// `viewport`, whose top is `visibleTop` points under the viewport's top. SwiftUI runs the check on each scroll step,
    /// but calls `action` only when its answer changes.
    func onEdgePlace(of viewport: String, visibleTop: CGFloat, indicatorHeight: CGFloat,
                     _ action: @escaping (EdgePlace) -> Void) -> some View {
        onGeometryChange(for: EdgePlace.self) { proxy in
            guard let visible = proxy.bounds(of: .named(viewport)) else { return EdgePlace() }
            return EdgePlace(top: -visible.minY, bottom: proxy.size.height - visible.minY, visibleTop: visibleTop,
                             visibleBottom: visible.height, indicatorHeight: indicatorHeight)
        } action: { action($0) }
    }

    /// Calls `action` with how far this view ends below the visible part of the scroll view whose coordinate space is
    /// `viewport`, from zero up to `limit`. Past `limit` the answer stays the same, so a long scroll calls `action` only
    /// near the end.
    func onOverhangingBottomEdge(of viewport: String, upTo limit: CGFloat, _ action: @escaping (CGFloat) -> Void) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            guard let visible = proxy.bounds(of: .named(viewport)) else { return 0 }
            return min(max(0, proxy.size.height - visible.maxY), limit)
        } action: { action($0) }
    }
}

/// The line between the In Play cards and the Bench. A click shows or hides the Bench. It has no count and no Agent
/// marks, so it does not pull the user's attention to the Bench.
struct BenchLine: View {
    let isBenchShown: Bool
    let action: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let title = isBenchShown ? "Hide Bench" : "Bench"
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                Text(title).font(fontSize.font(11, weight: .semibold)).lineLimit(1).fixedSize()
                Image(systemName: isBenchShown ? "chevron.up" : "chevron.down").font(fontSize.font(9, weight: .bold))
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: fontSize(20))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("topics-bench-line")
    }
}

/// The line between the In Play places and the Guests, which are In Play above `topics.in_play`. A drag across it trades.
struct GuestsLine: View {
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            Text("Guests").font(fontSize.font(11, weight: .semibold)).lineLimit(1).fixedSize()
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).frame(height: fontSize(20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Guests")
        .accessibilityIdentifier("topics-guests-line")
    }
}

/// An In Play place that no card fills. A click asks which Guest Topic or Benched Topic takes it, and a Guest or a
/// Benched card dropped on it takes it.
struct OpenPlaceCard: View {
    let place: Int
    let action: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").font(fontSize.font(11, weight: .semibold))
                Text("Open Place").font(fontSize.font(12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: fontSize(32))
            .contentShape(shape)
            .overlay { shape.strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
        }
        .buttonStyle(.plain)
        .takesFirstClick()
        .accessibilityLabel("Open Place \(place)")
        .accessibilityIdentifier("open-place-\(place)")
    }
}

/// A pill over an edge of the Topics list that tells the user how many cards are past that edge: over the top of the
/// Bench area for the cards above it, under the block that sticks, or over the bottom of the list for the cards below.
/// A click scrolls the nearest hidden card into view. Near its edge it moves with the cards, so it slides in from under
/// the block, or out under the last card, and does not come or go in one frame.
struct EdgePill: View {
    enum Edge {
        case top, bottom
    }

    let edge: Edge
    let count: Int
    /// How far the pill has come in from its edge, which counts up to `height`: for the top, how far the Bench has
    /// scrolled under the block; for the bottom, how far the end of the list is below the bottom edge.
    let slide: CGFloat
    let theme: TerminalTheme?
    let action: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize

    /// The band the pill lies in at 12: the pill and the room around it for its shadow. It holds the pill's text, so it
    /// grows with the Interface font size; the Bench's geometry keeps a card it reveals under the band at that size.
    static let designHeight: CGFloat = 30
    /// The room around the pill for its shadow, which does not grow.
    private static let margin: CGFloat = 4

    static func height(_ size: InterfaceFontSize) -> CGFloat { size(designHeight) }

    var body: some View {
        let capsule = Capsule(style: .continuous)
        let isTop = edge == .top
        let height = Self.height(fontSize)
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isTop ? "arrow.up" : "arrow.down").font(fontSize.font(9, weight: .bold))
                Text("\(count) more").font(fontSize.font(11, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: height - 2 * Self.margin)
            // The surface of an open card over the Sidebar's chrome, so the cards under it do not show through.
            .background(Color.primary.opacity(0.08))
            .chrome(theme: theme, material: .sidebar)
            .clipShape(capsule)
            .overlay { capsule.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 4, y: 1)
            .frame(maxWidth: .infinity).frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: isTop ? min(slide, height) - height : height - min(slide, height))
        .clipped()
        .accessibilityLabel("\(count) more \(isTop ? "above" : "below")")
        .accessibilityIdentifier(isTop ? "topics-more-above" : "topics-more-below")
    }
}
