import AppKit
import MuxifyCore

/// A row's hover label: after the pointer rests on the row, a label opens over it with the row's full title, when the
/// row cuts it off, and a small second line with more about the row. One label shows at a time, in a borderless panel
/// that can reach past the Sidebar's edge. It never takes Focus or a click. The panel is outside the App Window's view
/// tree, so the row passes its Interface font size in, and the label's detail grows with it.
///
/// The panel is AppKit (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md). It shows the label that
/// the row's anchor makes: a row in AppKit gives a `RowHoverAnchor`, whose label is `HoverLabelView`, and a SwiftUI row
/// keeps the SwiftUI label of `hoverLabel(detail:onlyWhenCutOff:enabled:)` until its area moves.
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
    private var owner: (any HoverLabelAnchor)?
    private var pending: DispatchWorkItem?
    private var closedAt = Date.distantPast

    func enter(_ anchor: any HoverLabelAnchor, detail: String, onlyWhenCutOff: Bool, fontSize: InterfaceFontSize) {
        owner = anchor
        pending?.cancel()
        let show = { [weak self, weak anchor] in
            guard let self, let anchor, self.owner === anchor else { return }
            self.show(anchor, detail: detail, onlyWhenCutOff: onlyWhenCutOff, fontSize: fontSize)
        }
        if panel.isVisible || Date().timeIntervalSince(closedAt) < Self.coolDown {
            show()
        } else {
            let work = DispatchWorkItem(block: show)
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
        }
    }

    func leave(_ anchor: any HoverLabelAnchor) {
        guard owner === anchor else { return }
        owner = nil
        pending?.cancel()
        guard panel.isVisible else { return }
        closedAt = Date()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func show(_ anchor: any HoverLabelAnchor, detail: String, onlyWhenCutOff: Bool, fontSize: InterfaceFontSize) {
        guard let view = anchor.titleView, let window = view.window else { return }
        let titleFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let cutOff = anchor.hasTitle && anchor.fullWidth > titleFrame.width + 0.5
        guard cutOff || (!onlyWhenCutOff && !detail.isEmpty) else { return }
        let content = anchor.label(showsTitle: cutOff, detail: detail, fontSize: fontSize, scale: window.backingScaleFactor)
        let size = content.fittingSize
        panel.contentView = content
        // The label's title sits on the row's title, so the row seems to open up in place.
        let origin = NSPoint(x: titleFrame.minX - HoverLabelMetrics.padding.left,
                             y: titleFrame.maxY + HoverLabelMetrics.padding.top - size.height)
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

/// A row's title as its hover label needs it: where the row draws it, how wide the whole title is, and the label that
/// shows it.
@MainActor
protocol HoverLabelAnchor: AnyObject {
    /// The view that draws the row's title. The label's title stands on it.
    var titleView: NSView? { get }
    /// The row has a title, which its label shows when the row cuts it off.
    var hasTitle: Bool { get }
    /// How wide the whole title is on one line.
    var fullWidth: CGFloat { get }
    /// The label: the row's title, with `showsTitle`, over `detail`. `scale` is the pixels in a point of the display.
    func label(showsTitle: Bool, detail: String, fontSize: InterfaceFontSize, scale: CGFloat) -> NSView
}

/// The look of a hover label, for the AppKit and the SwiftUI label. The sizes are at 12; the detail grows with the
/// Interface font size, and the title is in the row's own font.
enum HoverLabelMetrics {
    /// The room around the texts.
    static let padding = NSEdgeInsets(top: 4, left: 7, bottom: 5, right: 8)
    /// The room between the title and the detail.
    static let spacing: CGFloat = 2
    static let cornerRadius: CGFloat = 6
    /// The detail is in the system font, in the secondary text colour.
    static let detailFontSize: CGFloat = 10.5
    /// The border is the text colour at this opacity, one point wide inside the label's edge.
    static let borderOpacity = 0.12
}

/// A row's hover label in AppKit, as SwiftUI draws it for a SwiftUI row: the row's title on one line, in its font, over
/// the detail, both whole, with the room of `HoverLabelMetrics` around them, on the regular material with continuous
/// corners and a faint border. To accessibility each text is a static text with the text as its value.
final class HoverLabelView: NSView {
    private let material = NSVisualEffectView()
    private let border = HoverLabelBorderView()
    private let title = SidebarLabel()
    private let detail = SidebarLabel()
    private let scale: CGFloat

    /// `title` is the row's title in its font, nil for a label without it.
    init(title: (text: String, font: NSFont)?, detail: String, fontSize: InterfaceFontSize, scale: CGFloat) {
        self.scale = scale
        super.init(frame: .zero)
        // SwiftUI's regular material: the popover's colours over what stands behind the label in its panel, active
        // also while the panel is not the key window.
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        // Its corners clip the material's layers. A mask would draw the material's layers as one group, and its
        // blend with what is under it would differ from SwiftUI's.
        material.wantsLayer = true
        material.layer?.cornerRadius = HoverLabelMetrics.cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        for (label, text) in [(self.title, title?.text), (self.detail, detail)] {
            label.text = text ?? ""
            label.scale = scale
            label.isHidden = label.text.isEmpty
            label.setAccessibilityElement(true)
            label.setAccessibilityRole(.staticText)
            label.setAccessibilityValue(label.text)
        }
        if let title { self.title.font = title.font }
        self.detail.font = .systemFont(ofSize: fontSize(HoverLabelMetrics.detailFontSize))
        self.detail.ink = .secondary
        subviews = [material, border, self.title, self.detail]
        frame.size = fittingSize
        layOut()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The texts that show, from the top.
    private var texts: [SidebarLabel] { [title, detail].filter { !$0.isHidden } }

    /// The texts whole, the room between them, and the padding around them.
    override var fittingSize: NSSize {
        let sizes = texts.map { $0.fit() }
        let padding = HoverLabelMetrics.padding
        let height = sizes.map(\.height).reduce(0, +) + HoverLabelMetrics.spacing * CGFloat(max(0, sizes.count - 1))
        return NSSize(width: (sizes.map(\.width).max() ?? 0) + padding.left + padding.right,
                      height: height + padding.top + padding.bottom)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    /// The label stands at its fitting size in the middle of the view, on the pixel grid: the panel rounds its size
    /// to whole points, and SwiftUI's hosting view sets its label in the middle of that room in the same way.
    private func layOut() {
        let size = fittingSize
        let label = NSRect(x: ((bounds.width - size.width) / 2).rounded(toPixelsOf: scale),
                           y: ((bounds.height - size.height) / 2).rounded(toPixelsOf: scale),
                           width: size.width, height: size.height)
        material.frame = label
        border.frame = label
        var top = label.minY + HoverLabelMetrics.padding.top
        for text in texts {
            text.frame = NSRect(origin: NSPoint(x: label.minX + HoverLabelMetrics.padding.left, y: top), size: text.fit())
            top = text.frame.maxY + HoverLabelMetrics.spacing
        }
    }
}

/// The border of a hover label: the text colour at `HoverLabelMetrics.borderOpacity`, one point wide inside the edge,
/// with continuous corners. The shape is a layer under the view's own: the driver's `snapshot` draws the corners of a
/// view's own layer square.
private final class HoverLabelBorderView: LayerColoredView {
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        ring.borderWidth = 1
        ring.cornerRadius = HoverLabelMetrics.cornerRadius
        ring.cornerCurve = .continuous
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions { ring.frame = bounds }
    }

    override func colorLayers() {
        ring.borderColor = NSColor.labelColor.faded(HoverLabelMetrics.borderOpacity).cgColor
    }
}
