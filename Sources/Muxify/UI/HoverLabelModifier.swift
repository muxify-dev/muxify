import AppKit
import MuxifyCore
import SwiftUI

/// A SwiftUI row's hover label, for the rows of the areas that have not moved to AppKit
/// (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md): `hoverLabel(detail:onlyWhenCutOff:enabled:)`
/// and `hoverLabelTitle()`. The one panel of `HoverLabels` shows it, with this label drawn in SwiftUI. A row in AppKit
/// gives the panel a `RowHoverAnchor` and gets the AppKit label, `HoverLabelView`, which looks the same.
private struct SwiftUIHoverLabelView: View {
    let title: Text?
    let detail: String
    @Environment(\.interfaceFontSize) private var fontSize

    private static let padding = EdgeInsets(top: HoverLabelMetrics.padding.top, leading: HoverLabelMetrics.padding.left,
                                            bottom: HoverLabelMetrics.padding.bottom, trailing: HoverLabelMetrics.padding.right)

    var body: some View {
        VStack(alignment: .leading, spacing: HoverLabelMetrics.spacing) {
            if let title { title.lineLimit(1) }
            if !detail.isEmpty { Text(detail).font(fontSize.font(HoverLabelMetrics.detailFontSize)).foregroundStyle(.secondary) }
        }
        .fixedSize()
        .padding(Self.padding)
        .background(RoundedRectangle(cornerRadius: HoverLabelMetrics.cornerRadius, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: HoverLabelMetrics.cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(HoverLabelMetrics.borderOpacity)))
    }
}

/// A SwiftUI row's title as its hover label needs it: where the row draws it, the text it draws, and how wide that
/// text is whole, so the label shows the title only when the row cuts it off.
@MainActor
private final class HoverAnchor: HoverLabelAnchor {
    weak var view: NSView?
    var title: Text?
    var width: CGFloat = 0

    var titleView: NSView? { view }

    var hasTitle: Bool { title != nil }

    var fullWidth: CGFloat { width }

    func label(showsTitle: Bool, detail: String, fontSize: InterfaceFontSize, scale: CGFloat) -> NSView {
        NSHostingView(rootView: SwiftUIHoverLabelView(title: showsTitle ? title : nil, detail: detail)
            .environment(\.interfaceFontSize, fontSize))
    }
}

private struct HoverAnchorView: NSViewRepresentable {
    let anchor: HoverAnchor
    let title: Text

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
        anchor.title = title
    }
}

private struct HoverAnchorKey: EnvironmentKey {
    static let defaultValue: HoverAnchor? = nil
}

extension EnvironmentValues {
    fileprivate var hoverAnchor: HoverAnchor? {
        get { self[HoverAnchorKey.self] }
        set { self[HoverAnchorKey.self] = newValue }
    }
}

private struct HoverLabelModifier: ViewModifier {
    let detail: String
    let onlyWhenCutOff: Bool
    let enabled: Bool

    @State private var anchor = HoverAnchor()
    @State private var hovering = false
    @Environment(\.interfaceFontSize) private var fontSize

    func body(content: Content) -> some View {
        content
            .environment(\.hoverAnchor, anchor)
            .onHover { inside in
                hovering = inside
                update()
            }
            .onChange(of: enabled) { _, _ in update() }
            .onChange(of: onlyWhenCutOff) { _, _ in
                HoverLabels.shared.leave(anchor)
                update()
            }
            .onDisappear { HoverLabels.shared.leave(anchor) }
    }

    private func update() {
        if hovering && enabled {
            HoverLabels.shared.enter(anchor, detail: detail, onlyWhenCutOff: onlyWhenCutOff, fontSize: fontSize)
        }
        else { HoverLabels.shared.leave(anchor) }
    }
}

/// The title on one line, cut with "…". A hidden copy at its full width, laid out behind it, tells the anchor how wide
/// the whole text is; the label compares that with the width the row gives the title.
private struct HoverTitle: View {
    let text: Text
    @Environment(\.hoverAnchor) private var anchor

    var body: some View {
        text.lineLimit(1).truncationMode(.tail)
            .background(alignment: .leading) {
                text.lineLimit(1).fixedSize().hidden().allowsHitTesting(false).accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { anchor?.width = $0 }
            }
            .background { if let anchor { HoverAnchorView(anchor: anchor, title: text).accessibilityHidden(true) } }
    }
}

extension View {
    /// Gives the row a hover label with `detail`, and with the row's full title over it when the row cuts the title
    /// off. With `onlyWhenCutOff`, for a row that already shows its detail, the label opens only when the title is cut
    /// off. `enabled: false` suppresses the label entirely. Draw the row's title with `hoverLabelTitle()`.
    func hoverLabel(detail: String, onlyWhenCutOff: Bool = false, enabled: Bool = true) -> some View {
        modifier(HoverLabelModifier(detail: detail, onlyWhenCutOff: onlyWhenCutOff, enabled: enabled))
    }
}

extension Text {
    /// The title of a row with a `hoverLabel`, on one line and cut with "…". The label aligns with it, and shows this
    /// same text, in its font, when the row cuts it off.
    func hoverLabelTitle() -> some View { HoverTitle(text: self) }
}
