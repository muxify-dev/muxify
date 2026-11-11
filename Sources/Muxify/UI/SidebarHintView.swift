import AppKit
import MuxifyCore

/// A Hint in the AppKit Sessions list (ADR 0074): the badge while the user holds its modifier, `HintBadge` in
/// SwiftUI, or a Window row's key at rest, `HintKey`. A card's key at rest is `CardRestKeyView`. It takes no click. To
/// accessibility it is a row of its own, with the identifier of its target and its keys as its value.
final class SidebarHintView: NSView {
    enum Look: Equatable {
        /// The keys of the held modifier, such as ⌃2, on the badge's dark box.
        case badge([KeyTrigger])
        /// A Window row's key at rest, alone.
        case key(String)
    }

    private let box = HintBadgeBox()
    private let label = SidebarLabel()
    private var look = Look.key("")

    init() {
        super.init(frame: .zero)
        // SwiftUI cuts a text's ink off at its frame, where the edge of a glyph such as ⌘ reaches past it.
        label.clipsToBounds = true
        subviews = [box, label]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var isBadge: Bool {
        if case .badge = look { return true }
        return false
    }

    /// Shows the Hint of `target` in its look.
    func show(_ look: Look, target: QuickSwitchTarget, fontSize: InterfaceFontSize, scale: CGFloat) {
        self.look = look
        switch look {
        case .badge(let triggers):
            label.text = HintBadgeMetrics.text(triggers)
            label.font = .monospacedSystemFont(ofSize: fontSize(HintBadgeMetrics.fontSize), weight: .semibold)
            label.ink = .primary
            // The badge is in the dark scheme, also in a light theme.
            appearance = NSAppearance(named: .darkAqua)
        case .key(let key):
            label.text = key
            label.font = .monospacedSystemFont(ofSize: fontSize(WindowHintMetrics.keyFontSize), weight: .medium)
            label.ink = .secondary
            appearance = nil
        }
        label.scale = scale
        box.isHidden = !isBadge
        setAccessibilityIdentifier(target.accessibilityID)
        setAccessibilityValue(label.text)
        layOut()
    }

    /// The room the Hint takes: its keys, and on a badge the padding around them.
    var size: NSSize {
        let text = label.fit()
        guard isBadge else { return text }
        return NSSize(width: text.width + 2 * HintBadgeMetrics.horizontalPadding, height: text.height + 2 * HintBadgeMetrics.verticalPadding)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    private func layOut() {
        box.frame = bounds
        let inset = isBadge ? NSPoint(x: HintBadgeMetrics.horizontalPadding, y: HintBadgeMetrics.verticalPadding) : .zero
        label.frame = NSRect(origin: inset, size: label.fit())
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }
}

/// The box of a Hint's badge: a dark fill with a light border inside it, in a rounded shape with SwiftUI's continuous
/// corners. Its colours are the same in every appearance. The shapes are layers under the view's own: the driver's
/// `snapshot` draws the corners of a view's own layer square.
private final class HintBadgeBox: NSView {
    private let fill = CALayer()
    private let border = CALayer()

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for shape in [fill, border] {
            shape.cornerRadius = HintBadgeMetrics.cornerRadius
            shape.cornerCurve = .continuous
            layer?.addSublayer(shape)
        }
        let color = HintBadgeMetrics.fill
        fill.backgroundColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: HintBadgeMetrics.fillOpacity)
        border.borderWidth = HintBadgeMetrics.borderWidth
        border.borderColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: HintBadgeMetrics.borderOpacity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        LayerGlide.withoutActions {
            fill.frame = bounds
            border.frame = bounds
        }
    }
}
