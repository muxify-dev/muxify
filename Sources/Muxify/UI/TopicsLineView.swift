import AppKit

/// A line of the AppKit Topics list between its cards (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md):
/// a rule on each side of its word, in the secondary text colour, as `GuestsLine` draws it in SwiftUI. To
/// accessibility it is one row with its word as its label, as SwiftUI gives it: of no role, and as large as its rules and
/// its word together.
final class TopicsLineView: NSView {
    let id: String
    private let word = SidebarLabel()
    private let leading = TopicsLineRuleView()
    private let trailing = TopicsLineRuleView()
    private var environment = SidebarListEnvironment()

    init(id: String, word text: String, identifier: String) {
        self.id = id
        super.init(frame: .zero)
        word.text = text
        word.ink = .secondary
        subviews = [leading, word, trailing]
        setAccessibilityElement(true)
        setAccessibilityRole(.unknown)
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(environment: SidebarListEnvironment) {
        self.environment = environment
        word.font = .systemFont(ofSize: environment.fontSize(TopicsListLine.fontSize), weight: .semibold)
        word.scale = environment.displayScale
        layOut()
    }

    var height: CGFloat { environment.fontSize(TopicsListLine.designHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        let parts = NSRect(x: TopicsListLine.horizontalPadding, y: word.frame.minY,
                           width: max(0, bounds.width - 2 * TopicsListLine.horizontalPadding), height: word.frame.height)
        return window.convertToScreen(convert(parts, to: nil))
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    /// The word in the middle, and the rules in the room left on each side, each with its middle on the line's middle.
    private func layOut() {
        let scale = environment.displayScale
        let room = max(0, bounds.width - 2 * TopicsListLine.horizontalPadding)
        let size = word.fit()
        let rule = max(0, (room - size.width - 2 * TopicsListLine.spacing) / 2)
        let left = TopicsListLine.horizontalPadding
        let ruleTop = ((bounds.height - TopicsListLine.ruleWidth) / 2).rounded(toPixelsOf: scale)
        leading.frame = NSRect(x: left, y: ruleTop, width: rule, height: TopicsListLine.ruleWidth)
        word.frame = NSRect(x: (left + rule + TopicsListLine.spacing).rounded(toPixelsOf: scale),
                            y: ((bounds.height - size.height) / 2).rounded(toPixelsOf: scale), width: size.width, height: size.height)
        trailing.frame = NSRect(x: (left + room - rule).rounded(toPixelsOf: scale), y: ruleTop, width: rule, height: TopicsListLine.ruleWidth)
    }
}

/// A rule of a line of the Topics list, in the separator colour.
private final class TopicsLineRuleView: LayerColoredView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func colorLayers() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
