import AppKit
import SwiftUI

/// A row's hover label: after the pointer rests on the row, a label opens over it with the row's full title, when the
/// row cuts it off, and a small second line with more about the row. One label shows at a time, in a borderless panel
/// that can reach past the Sidebar's edge. It never takes Focus or a click.
@MainActor
final class HoverLabels {
    static let shared = HoverLabels()

    /// How long the pointer rests on a row before its label opens.
    private static let delay: TimeInterval = 0.4
    /// After a label closes, the next row's label opens at once for this long, so moving down a list reads row by row.
    private static let coolDown: TimeInterval = 0.3

    private let panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilityIdentifier("hover-label")
        return panel
    }()
    private var owner: HoverAnchor?
    private var pending: DispatchWorkItem?
    private var closedAt = Date.distantPast

    func enter(_ anchor: HoverAnchor, detail: String, onlyWhenCutOff: Bool) {
        owner = anchor
        pending?.cancel()
        let show = { [weak self, weak anchor] in
            guard let self, let anchor, self.owner === anchor else { return }
            self.show(anchor, detail: detail, onlyWhenCutOff: onlyWhenCutOff)
        }
        if panel.isVisible || Date().timeIntervalSince(closedAt) < Self.coolDown {
            show()
        } else {
            let work = DispatchWorkItem(block: show)
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
        }
    }

    func leave(_ anchor: HoverAnchor) {
        guard owner === anchor else { return }
        owner = nil
        pending?.cancel()
        guard panel.isVisible else { return }
        closedAt = Date()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func show(_ anchor: HoverAnchor, detail: String, onlyWhenCutOff: Bool) {
        guard let view = anchor.view, let window = view.window else { return }
        let titleFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let cutOff = anchor.title != nil && anchor.fullWidth > titleFrame.width + 0.5
        guard cutOff || (!onlyWhenCutOff && !detail.isEmpty) else { return }
        let content = NSHostingView(rootView: HoverLabelView(title: cutOff ? anchor.title : nil, detail: detail))
        let size = content.fittingSize
        panel.contentView = content
        // The label's title sits on the row's title, so the row seems to open up in place.
        let origin = NSPoint(x: titleFrame.minX - HoverLabelView.padding.leading,
                             y: titleFrame.maxY + HoverLabelView.padding.top - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || panel.isVisible {
            panel.alphaValue = 1
            panel.orderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }
}

private struct HoverLabelView: View {
    static let padding = EdgeInsets(top: 4, leading: 7, bottom: 5, trailing: 8)

    let title: Text?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title { title.lineLimit(1) }
            if !detail.isEmpty { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary) }
        }
        .fixedSize()
        .padding(Self.padding)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// A row's title as its hover label needs it: where the row draws it, the text it draws, and how wide that text is
/// whole, so the label shows the title only when the row cuts it off.
@MainActor
final class HoverAnchor {
    fileprivate weak var view: NSView?
    fileprivate var title: Text?
    fileprivate var fullWidth: CGFloat = 0
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
        if hovering && enabled { HoverLabels.shared.enter(anchor, detail: detail, onlyWhenCutOff: onlyWhenCutOff) }
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
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { anchor?.fullWidth = $0 }
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
