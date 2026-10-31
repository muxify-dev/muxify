import SwiftUI

extension View {
    /// Calls `action` with where this view stands against the visible part of the scroll view whose coordinate space is
    /// `viewport`, whose top is `visibleTop` points under the viewport's top. SwiftUI runs the check on each scroll step,
    /// but calls `action` only when its answer changes.
    func onEdgePlace(of viewport: String, visibleTop: CGFloat, _ action: @escaping (EdgePlace) -> Void) -> some View {
        onGeometryChange(for: EdgePlace.self) { proxy in
            guard let visible = proxy.bounds(of: .named(viewport)) else { return EdgePlace() }
            return EdgePlace(top: -visible.minY, bottom: proxy.size.height - visible.minY, visibleTop: visibleTop,
                             visibleBottom: visible.height)
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

    var body: some View {
        let title = isBenchShown ? "Hide Bench" : "Bench"
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                Image(systemName: isBenchShown ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("topics-bench-line")
    }
}

/// Tells the user that the last card they see is not the last card. It lies over the bottom of the list, under a
/// shadow, and a click scrolls the first hidden card to the top. In the last stretch of the list it moves down with
/// the cards, so it slides out under the last card and does not go away in one frame.
struct MoreBelowLine: View {
    let count: Int
    /// How far the end of the list is below the bottom edge, up to `height`.
    let listEnd: CGFloat
    let theme: TerminalTheme?
    let action: () -> Void

    static var height: CGFloat { shade + bar }
    private static var shade: CGFloat { 10 }
    private static var bar: CGFloat { 20 }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.shade)
                .allowsHitTesting(false)
            Button(action: action) {
                HStack(spacing: 8) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                    Text("\(count) more below").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(height: Self.bar)
                .chrome(theme: theme, material: .sidebar)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("topics-more-below")
        }
        .offset(y: Self.height - min(listEnd, Self.height))
        .clipped()
    }
}

/// Tells the user that cards of the Bench are above its top edge, under the block that sticks. It lies over the top of
/// the Bench area, over a shadow, and a click scrolls up to the nearest hidden card. In the first stretch of the Bench's
/// scroll it moves up with the cards, so it slides in from under the block and does not come in one frame.
struct MoreAboveLine: View {
    let count: Int
    /// How far the Bench has scrolled under the block, which counts up to `height`.
    let benchScroll: CGFloat
    let theme: TerminalTheme?
    let action: () -> Void

    static var height: CGFloat { shade + bar }
    private static var shade: CGFloat { 10 }
    private static var bar: CGFloat { 20 }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                    Text("\(count) more above").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).frame(height: Self.bar)
                .chrome(theme: theme, material: .sidebar)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("topics-more-above")
            LinearGradient(colors: [.black.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.shade)
                .allowsHitTesting(false)
        }
        .offset(y: min(benchScroll, Self.height) - Self.height)
        .clipped()
    }
}
