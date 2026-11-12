import AppKit

/// A line of the AppKit Topics list between its cards (docs/adr/0075-muxify-leaves-swiftui-entirely-one-area-at-a-time.md):
/// a rule on each side of its word, in the secondary text colour, as `GuestsLine` and `BenchLine` draw them in SwiftUI.
///
/// The Guests line takes no press. To accessibility it is one row with its word as its label, as SwiftUI gives it: of
/// no role, and as large as its rules and its word together.
///
/// The Bench line has a chevron after its word, and a press on it shows or hides the Bench. To accessibility it is a
/// button named by its word, "Bench" or "Hide Bench", as large as the line, as SwiftUI gives its button.
final class TopicsLineView: SidebarPressView {
    let id: String
    private let isBenchLine: Bool
    private let word = SidebarLabel()
    /// The Bench line's chevron, which comes again when its symbol changes. Nil on the Guests line.
    private var chevron: SidebarSymbol?
    private let leading = TopicsLineRuleView()
    private let trailing = TopicsLineRuleView()
    private var environment = SidebarListEnvironment()

    /// The Guests line.
    static func guests() -> TopicsLineView {
        TopicsLineView(id: TopicsModel.ListItem.guestsLineID, identifier: "topics-guests-line", isBenchLine: false)
    }

    /// The Bench line. A press on it calls `onPress`.
    static func bench() -> TopicsLineView {
        TopicsLineView(id: TopicsModel.ListItem.benchLineID, identifier: "topics-bench-line", isBenchLine: true)
    }

    private init(id: String, identifier: String, isBenchLine: Bool) {
        self.id = id
        self.isBenchLine = isBenchLine
        super.init(frame: .zero)
        word.ink = .secondary
        subviews = [leading, word, trailing]
        setAccessibilityElement(true)
        setAccessibilityRole(isBenchLine ? .button : .unknown)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { isBenchLine ? super.hitTest(point) : nil }

    /// Shows the Guests line, or the Bench line as the Bench is: shown or hidden.
    func show(isBenchShown: Bool = false, environment: SidebarListEnvironment) {
        self.environment = environment
        let text = isBenchLine ? TopicsListLine.benchWord(isBenchShown: isBenchShown) : "Guests"
        word.text = text
        word.font = .systemFont(ofSize: environment.fontSize(TopicsListLine.fontSize), weight: .semibold)
        word.scale = environment.displayScale
        setAccessibilityLabel(text)
        if isBenchLine {
            let name = TopicsListLine.benchChevron(isBenchShown: isBenchShown)
            if chevron?.name != name {
                chevron?.removeFromSuperview()
                let symbol = SidebarSymbol(name)
                addSubview(symbol)
                chevron = symbol
            }
            chevron?.pointSize = environment.fontSize(TopicsListLine.chevronFontSize)
            chevron?.weight = .bold
            chevron?.scale = environment.displayScale
        }
        layOut()
    }

    var height: CGFloat { environment.fontSize(TopicsListLine.designHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layOut()
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return .zero }
        let parts = isBenchLine ? bounds : NSRect(x: TopicsListLine.horizontalPadding, y: word.frame.minY,
                                                  width: max(0, bounds.width - 2 * TopicsListLine.horizontalPadding),
                                                  height: word.frame.height)
        return window.convertToScreen(convert(parts, to: nil))
    }

    override func accessibilityActivationPoint() -> NSPoint { accessibilityFrame().centre }

    /// Lays the line out as SwiftUI lays out the `HStack` of `GuestsLine` and `BenchLine`: the word and the chevron take
    /// their width, the rules share the room left on each side, and each stands with its middle on the line's middle.
    private func layOut() {
        let scale = environment.displayScale
        let room = max(0, bounds.width - 2 * TopicsListLine.horizontalPadding)
        let size = word.fit()
        let chevronSize = chevron?.symbolSize ?? .zero
        let fixed = size.width + (chevron == nil ? 2 : 3) * TopicsListLine.spacing + chevronSize.width
        let rule = max(0, (room - fixed) / 2)
        let left = TopicsListLine.horizontalPadding
        let ruleTop = ((bounds.height - TopicsListLine.ruleWidth) / 2).rounded(toPixelsOf: scale)
        leading.frame = NSRect(x: left, y: ruleTop, width: rule, height: TopicsListLine.ruleWidth)
        let wordX = left + rule + TopicsListLine.spacing
        word.frame = NSRect(x: wordX.rounded(toPixelsOf: scale), y: ((bounds.height - size.height) / 2).rounded(toPixelsOf: scale),
                            width: size.width, height: size.height)
        chevron?.frame = NSRect(x: (wordX + size.width + TopicsListLine.spacing).rounded(toPixelsOf: scale),
                                y: ((bounds.height - chevronSize.height) / 2).rounded(toPixelsOf: scale),
                                width: chevronSize.width, height: chevronSize.height)
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
