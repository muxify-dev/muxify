import SwiftUI

extension View {
    /// Calls `action` when this view starts or stops ending below the visible part of the scroll view whose
    /// coordinate space is `viewport`. SwiftUI runs the check on each scroll step, but calls `action` only when its
    /// answer changes.
    func onPassingBottomEdge(of viewport: String, _ action: @escaping (Bool) -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            guard let visible = proxy.bounds(of: .named(viewport)) else { return false }
            return proxy.size.height > visible.maxY + 1
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
