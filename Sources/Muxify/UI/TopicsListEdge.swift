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
        let title = TopicsListLine.benchWord(isBenchShown: isBenchShown)
        Button(action: action) {
            HStack(spacing: TopicsListLine.spacing) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: TopicsListLine.ruleWidth)
                Text(title).font(fontSize.font(TopicsListLine.fontSize, weight: .semibold)).lineLimit(1).fixedSize()
                Image(systemName: TopicsListLine.benchChevron(isBenchShown: isBenchShown))
                    .font(fontSize.font(TopicsListLine.chevronFontSize, weight: .bold))
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: TopicsListLine.ruleWidth)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, TopicsListLine.horizontalPadding).frame(height: fontSize(TopicsListLine.designHeight))
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
        HStack(spacing: TopicsListLine.spacing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: TopicsListLine.ruleWidth)
            Text("Guests").font(fontSize.font(TopicsListLine.fontSize, weight: .semibold)).lineLimit(1).fixedSize()
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: TopicsListLine.ruleWidth)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, TopicsListLine.horizontalPadding).frame(height: fontSize(TopicsListLine.designHeight))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Guests")
        .accessibilityIdentifier("topics-guests-line")
    }
}

/// An In Play place that no card fills. A click or its Hint's key asks which Guest Topic or Benched Topic takes it, and
/// a Guest or a Benched card dropped on it takes it.
struct OpenPlaceCard: View {
    let place: Int
    let action: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize
    @Environment(\.quickSwitchHints) private var hints

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OpenPlaceMetrics.cornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: OpenPlaceMetrics.spacing) {
                Image(systemName: OpenPlaceMetrics.symbol).font(fontSize.font(OpenPlaceMetrics.symbolFontSize, weight: .semibold))
                Text(OpenPlaceMetrics.word).font(fontSize.font(OpenPlaceMetrics.fontSize, weight: .medium))
                CardHintSlot(target: .openPlace(place))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, OpenPlaceMetrics.horizontalPadding).frame(height: fontSize(OpenPlaceMetrics.designHeight))
            .contentShape(shape)
            .overlay {
                shape.strokeBorder(Color.secondary.opacity(OpenPlaceMetrics.borderOpacity),
                                   style: StrokeStyle(lineWidth: OpenPlaceMetrics.borderWidth, dash: OpenPlaceMetrics.dash))
            }
        }
        .buttonStyle(.plain)
        .takesFirstClick()
        .accessibilityLabel(OpenPlaceMetrics.label(place: place))
        .accessibilityIdentifier("open-place-\(place)")
        // Outside the button's element, so the Hint is its own accessibility element, as on a Topic card.
        .cardHints(hints)
        .accessibilityElement(children: .contain)
    }
}

/// A pill over an edge of the Topics list that tells the user how many cards are past that edge: over the top of the
/// Bench area for the cards above it, under the block that sticks, or over the bottom of the list for the cards below.
/// A click scrolls the nearest hidden card into view. Near its edge it moves with the cards, so it slides in from under
/// the block, or out under the last card, and does not come or go in one frame. Its sizes are `EdgePillMetrics`, which
/// the AppKit list's pill reads too.
struct EdgePill: View {
    typealias Edge = EdgePillMetrics.Edge

    let edge: Edge
    let count: Int
    /// How far the pill has come in from its edge, which counts up to its band's height: for the top, how far the Bench
    /// has scrolled under the block; for the bottom, how far the end of the list is below the bottom edge.
    let slide: CGFloat
    let theme: TerminalTheme?
    let action: () -> Void
    @Environment(\.interfaceFontSize) private var fontSize

    var body: some View {
        let capsule = Capsule(style: .continuous)
        let height = EdgePillMetrics.height(fontSize)
        Button(action: action) {
            HStack(spacing: EdgePillMetrics.spacing) {
                Image(systemName: EdgePillMetrics.symbol(edge)).font(fontSize.font(EdgePillMetrics.symbolFontSize, weight: .bold))
                Text(EdgePillMetrics.text(count: count)).font(fontSize.font(EdgePillMetrics.fontSize, weight: .semibold))
                    .lineLimit(1).fixedSize()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, EdgePillMetrics.horizontalPadding).frame(height: height - 2 * EdgePillMetrics.margin)
            // The surface of an open card over the Sidebar's chrome, so the cards under it do not show through.
            .background(Color.primary.opacity(EdgePillMetrics.fillOpacity))
            .chrome(theme: theme, material: .sidebar)
            .clipShape(capsule)
            .overlay { capsule.strokeBorder(Color.primary.opacity(EdgePillMetrics.borderOpacity), lineWidth: EdgePillMetrics.borderWidth) }
            .compositingGroup()
            .shadow(color: .black.opacity(EdgePillMetrics.shadowOpacity), radius: EdgePillMetrics.shadowRadius, y: EdgePillMetrics.shadowDrop)
            .frame(maxWidth: .infinity).frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: EdgePillMetrics.offset(edge, slide: slide, height: height))
        .clipped()
        .accessibilityLabel(EdgePillMetrics.label(edge, count: count))
        .accessibilityIdentifier(EdgePillMetrics.identifier(edge))
    }
}
